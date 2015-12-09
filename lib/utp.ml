(* Copyright (C) 2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   This file is part of ocaml-libutp.

   This library is free software; you can redistribute it and/or modify it under
   the terms of the GNU Lesser General Public License as published by the Free
   Software Foundation; either version 2.1 of the License, or (at your option)
   any later version.

   This library is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
   FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
   details.

   You should have received a copy of the GNU Lesser General Public License
   along with this library; if not, write to the Free Software Foundation, Inc.,
   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA *)

type utp_context
type socket

type socket_stats =
  {
    nbytes_recv : int;
    nbytes_xmit : int;
    rexmit : int;
    fastrexmit : int;
    nxmit : int;
    nrecv : int;
    nduprecv : int;
    mtu_guess : int;
  }

type context_stats =
  {
    nraw_recv_empty : int;
    nraw_recv_small : int;
    nraw_recv_mid : int;
    nraw_recv_big : int;
    nraw_recv_huge : int;
    nraw_send_empty : int;
    nraw_send_small : int;
    nraw_send_mid : int;
    nraw_send_big : int;
    nraw_send_huge : int;
  }

type context =
  {
    utp_ctx : utp_context;
    fd : Lwt_unix.file_descr;
    accepting : (socket * Unix.sockaddr) Lwt.u Lwt_sequence.t;
  }

module B : sig
  type t

  val create : int -> t
  val push : t -> Lwt_bytes.t -> unit
  val pop : t -> bytes -> int -> int -> int
  val length : t -> int
end = struct
  type chunk =
    {
      data : bytes;
      mutable max : int;
    }

  type t = int * chunk Lwt_sequence.t

  let create sz =
    if sz <= 0 then invalid_arg "B.create";
    let seq = Lwt_sequence.create () in
    ignore (Lwt_sequence.add_r {data = Bytes.create sz; max = 0} seq : _ Lwt_sequence.node);
    (sz, seq)

  let push (sz, seq) data =
    let rec loop chk off =
      if off < Lwt_bytes.length data then begin
        let chk =
          if chk.max >= Bytes.length chk.data then begin
            ignore (Lwt_sequence.add_r chk seq : _ Lwt_sequence.node);
            Printf.eprintf "debug: adding bucket (curr = %d)\n%!" (Lwt_sequence.length seq);
            {data = Bytes.create sz; max = 0};
          end else
            chk
        in
        let n = min (Bytes.length chk.data - chk.max) (Lwt_bytes.length data - off) in
        Lwt_bytes.blit_to_bytes data off chk.data chk.max n;
        chk.max <- chk.max + n;
        loop chk (off + n)
      end else
        ignore (Lwt_sequence.add_r chk seq : _ Lwt_sequence.node)
    in
    loop (Lwt_sequence.take_r seq) 0

  let pop (sz, seq) buf off len =
    let len0 = len in
    let rec loop chk off len =
      if len > 0 then
        if chk.max > 0 then begin
          let n = min len chk.max in
          Bytes.blit chk.data 0 buf off n;
          Bytes.blit chk.data n chk.data 0 (chk.max - n);
          chk.max <- chk.max - n;
          loop chk (off + n) (len - n)
        end else if Lwt_sequence.is_empty seq then begin
          ignore (Lwt_sequence.add_r chk seq : _ Lwt_sequence.node);
          len0 - len
        end else begin
          Printf.eprintf "debug: discarding bucket (curr=%d)\n%!" (Lwt_sequence.length seq);
          loop (Lwt_sequence.take_l seq) off len
        end
      else begin
        if chk.max > 0 || Lwt_sequence.is_empty seq then
          ignore (Lwt_sequence.add_l chk seq : _ Lwt_sequence.node)
        else
          Printf.eprintf "debug: discarding bucket (curr=%d)\n%!" (Lwt_sequence.length seq);
        len0
      end
    in
    loop (Lwt_sequence.take_l seq) off len

  let length (_, seq) =
    Lwt_sequence.fold_l (fun chk acc -> chk.max + acc) seq 0
end

type socket_info =
  {
    connected : unit Lwt.u;
    connecting : unit Lwt.t;
    closing : unit Lwt.t;
    closed : unit Lwt.u;
    readb : B.t;
    readm : Lwt_mutex.t;
    readc : unit Lwt_condition.t;
    writem : Lwt_mutex.t;
    writec : unit Lwt_condition.t;
  }

type _ option =
  | LOG_NORMAL : bool option
  | LOG_MTU : bool option
  | LOG_DEBUG : bool option
  | SNDBUF : int option
  | RCVBUF : int option
  | TARGET_DELAY : int option

external utp_init : int -> utp_context = "caml_utp_init"
external utp_destroy : utp_context -> unit = "caml_utp_destroy"
external utp_create_socket : utp_context -> socket = "caml_utp_create_socket"
external utp_get_userdata : socket -> socket_info = "caml_utp_get_userdata"
external utp_set_userdata : socket -> socket_info -> unit = "caml_utp_set_userdata"
external utp_write : socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_read_drained : socket -> unit = "caml_utp_read_drained"
external utp_issue_deferred_acks : utp_context -> unit = "caml_utp_issue_deferred_acks"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_process_udp : utp_context -> Lwt_bytes.t -> int -> Unix.sockaddr -> bool = "caml_utp_process_udp"
external utp_connect : socket -> Unix.sockaddr -> unit = "caml_utp_connect"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_close : socket -> unit = "caml_utp_close"
external utp_get_stats : socket -> socket_stats = "caml_utp_get_stats"
external utp_get_context : socket -> utp_context = "caml_utp_get_context"
external utp_context_get_userdata : utp_context -> context = "caml_utp_context_get_userdata"
external utp_context_set_userdata : utp_context -> context -> unit = "caml_utp_context_set_userdata"
external utp_get_context_stats : utp_context -> context_stats = "caml_utp_get_context_stats"
external utp_getsockopt : socket -> 'a option -> 'a = "caml_utp_getsockopt"
external utp_setsockopt : socket -> 'a option -> 'a -> unit = "caml_utp_setsockopt"
external utp_context_get_option : utp_context -> 'a option -> 'a = "caml_utp_context_get_option"
external utp_context_set_option : utp_context -> 'a option -> 'a -> unit = "caml_utp_context_set_option"
external utp_getpeername : socket -> Unix.inet_addr = "caml_utp_getpeername"

open Lwt.Infix

let rec check_timeouts ctx =
  Lwt_unix.sleep 0.5 >>= fun () ->
  utp_check_timeouts ctx.utp_ctx;
  check_timeouts ctx

let network_loop ctx =
  let socket_data = Lwt_bytes.create 4096 in
  let rec loop () =
    Lwt_bytes.recvfrom ctx.fd socket_data 0 4096 [] >>= fun (n, sa) ->
    let _ : bool = utp_process_udp ctx.utp_ctx socket_data n sa in
    if not (Lwt_unix.readable ctx.fd) then utp_issue_deferred_acks ctx.utp_ctx;
    loop ()
  in
  loop ()

let context () =
  let fd = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_DGRAM 0 in
  let utp_ctx = utp_init 2 in
  let ctx =
    {
      utp_ctx;
      fd;
      accepting = Lwt_sequence.create ();
    }
  in
  utp_context_set_userdata utp_ctx ctx;
  Lwt.ignore_result (check_timeouts ctx);
  Lwt.ignore_result (network_loop ctx);
  ctx

let bind ctx addr =
  Lwt_unix.bind ctx.fd addr

let create_info () =
  let connecting, connected = Lwt.wait () in
  let closing, closed = Lwt.wait () in
  {
    connected;
    connecting;
    closing;
    closed;
    readb = B.create 4096;
    readm = Lwt_mutex.create ();
    readc = Lwt_condition.create ();
    writem = Lwt_mutex.create ();
    writec = Lwt_condition.create ();
  }

let socket ctx =
  let sock = utp_create_socket ctx.utp_ctx in
  let info = create_info () in
  utp_set_userdata sock info;
  sock

let connect sock addr =
  let info = utp_get_userdata sock in
  utp_connect sock addr;
  info.connecting

let accept ctx =
  Lwt.add_task_l ctx.accepting >>= fun (sock, sa) ->
  let info = create_info () in
  utp_set_userdata sock info;
  Lwt.return (sock, sa)

let on_read sock buf =
  let info = utp_get_userdata sock in
  B.push info.readb buf;
  Lwt_condition.signal info.readc ();
  utp_read_drained sock

let read sock buf off len =
  let info = utp_get_userdata sock in
  let rec loop () =
    let n = B.pop info.readb buf off len in
    if n = 0 && len > 0 then
      Lwt_condition.wait info.readc >>= loop
    else
      Lwt.return n
  in
  Lwt_mutex.with_lock info.readm loop

let on_writeable sock =
  let info = utp_get_userdata sock in
  Printf.eprintf "on_writable\n%!";
  Lwt_condition.signal info.writec ()

let write sock buf off len =
  let info = utp_get_userdata sock in
  Printf.eprintf "write len=%d\n%!" len;
  let rec loop () =
    let n = utp_write sock buf off len in
    if n = 0 && len > 0 then
      Lwt_condition.wait info.writec >>= loop
    else
      Lwt.return n
  in
  Lwt_mutex.with_lock info.writem loop

type error =
  | ECONNREFUSED
  | ECONNRESET
  | ETIMEDOUT

let on_sendto utp_ctx addr buf =
  let ctx = utp_context_get_userdata utp_ctx in
  (* Lwt_unix.check_descriptor ctx.fd; *)
  (* Unix.sendto (Lwt_unix.unix_file_descr ctx.fd) buf 0 (Lwt_bytes.length buf) [] addr *)
  let t =
    Lwt_bytes.sendto ctx.fd buf 0 (Lwt_bytes.length buf) [] addr
  in
  Lwt.ignore_result t

let on_log _sock str =
  prerr_string "log: ";
  prerr_endline str

let cancel_io info =
  (* Q.iter (fun u -> Lwt.wakeup_exn u End_of_file) info.writers; *)
  (* Q.clear info.writers; *)
  Lwt.wakeup_exn info.connected End_of_file

let on_error sock err =
  let info = utp_get_userdata sock in
  cancel_io info
  (* info.got_error <- true *)
  (* match err with *)
  (* | ECONNREFUSED *)
  (* | ETIMEDOUT -> *)
  (*     Lwt.wakeup_exn info.connected (Failure "connection failed") *)
  (* | ECONNRESET -> *)
  (*     () (\* CHECK *\) *)

let on_accept sock addr =
  let utp_ctx = utp_get_context sock in
  let ctx = utp_context_get_userdata utp_ctx in
  match Lwt_sequence.take_opt_r ctx.accepting with
  | None -> ()
  | Some u -> Lwt.wakeup u (sock, addr)

type state =
  | STATE_CONNECT
  | STATE_WRITABLE
  | STATE_EOF
  | STATE_DESTROYING

let on_state_change sock st =
  let info = utp_get_userdata sock in
  match st with
  | STATE_CONNECT ->
      Lwt.wakeup info.connected ()
      (* on_writeable sock *)
  | STATE_WRITABLE ->
      on_writeable sock
  | STATE_EOF ->
      cancel_io info
  | STATE_DESTROYING ->
      Lwt.wakeup info.closed ()

let get_stats sock =
  utp_get_stats sock

let close sock =
  let info = utp_get_userdata sock in
  utp_close sock;
  info.closing

let get_context_stats ctx =
  utp_get_context_stats ctx.utp_ctx

let get_opt sock opt =
  utp_getsockopt sock opt

let set_opt sock opt v =
  utp_setsockopt sock opt v

let get_context_opt ctx opt =
  utp_context_get_option ctx.utp_ctx opt

let set_context_opt ctx opt v =
  utp_context_set_option ctx.utp_ctx opt v

let () =
  Callback.register "caml_utp_on_read" on_read;
  Callback.register "caml_utp_on_state_change" on_state_change;
  Callback.register "caml_utp_on_error" on_error;
  Callback.register "caml_utp_on_sendto" on_sendto;
  Callback.register "caml_utp_on_log" on_log;
  Callback.register "caml_utp_on_accept" on_accept
