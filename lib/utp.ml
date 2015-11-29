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
type utp_socket

type user_data =
  {
    connected : unit Lwt.u;
    connecting : unit Lwt.t;
    closing : unit Lwt.t;
    closed : unit Lwt.u;
    mutable read_buf : Lwt_bytes.t;
    to_read : (bytes * int * int) Queue.t;
    readers : int Lwt.u Lwt_sequence.t;
    to_write : (bytes * int * int) Queue.t;
    writers : int Lwt.u Lwt_sequence.t;
  }

external utp_init : int -> utp_context = "caml_utp_init"
external utp_destroy : utp_context -> unit = "caml_utp_destroy"
external utp_create_socket : utp_context -> utp_socket = "caml_utp_create_socket"
external utp_get_userdata : utp_socket -> user_data = "caml_utp_get_userdata"
external utp_set_userdata : utp_socket -> user_data -> unit = "caml_utp_set_userdata"
external utp_write : utp_socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_read_drained : utp_socket -> unit = "caml_utp_read_drained"
external utp_issue_deferred_acks : utp_context -> unit = "caml_utp_issue_deferred_acks"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_process_udp : utp_context -> Lwt_bytes.t -> int -> Unix.sockaddr -> int = "caml_utp_process_udp"
external utp_connect : utp_socket -> Unix.sockaddr -> unit = "caml_utp_connect"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_close : utp_socket -> unit = "caml_utp_close"

let the_socket = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_DGRAM 0
let the_context = utp_init 2
let accepting : (utp_socket * Unix.sockaddr) Lwt.u Lwt_sequence.t = Lwt_sequence.create ()

let null = Lwt_bytes.create 0

let bind addr =
  Lwt_unix.bind the_socket addr

let create_info () =
  let connecting, connected = Lwt.wait () in
  let closing, closed = Lwt.wait () in
  {
    connected;
    connecting;
    closing;
    closed;
    read_buf = null;
    to_read = Queue.create ();
    readers = Lwt_sequence.create ();
    to_write = Queue.create ();
    writers = Lwt_sequence.create ();
  }

let socket () =
  let sock = utp_create_socket the_context in
  let info = create_info () in
  utp_set_userdata sock info;
  sock

let connect sock addr =
  let info = utp_get_userdata sock in
  utp_connect sock addr;
  info.connecting

let accept () =
  Lwt.add_task_l accepting

let read sock wbuf woff wlen =
  Printf.eprintf "[utp] read: woff = %d wlen = %d\n%!" woff wlen;
  let userdata = utp_get_userdata sock in
  let len = Lwt_bytes.length userdata.read_buf in
  if Queue.is_empty userdata.to_read && len > 0 then begin
    let n = min len wlen in
    Lwt_bytes.blit_to_bytes userdata.read_buf 0 wbuf woff n;
    if n < len then
      userdata.read_buf <- Lwt_bytes.proxy userdata.read_buf n (len - n)
    else begin
      userdata.read_buf <- null;
      utp_read_drained sock;
    end;
    Lwt.return n
  end else begin
    Printf.eprintf "[utp] read: waiting for data\n%!";
    Queue.push (wbuf, woff, wlen) userdata.to_read;
    Lwt.add_task_l userdata.readers
  end

let rec check_timeouts ctx =
  let open Lwt.Infix in
  Lwt_unix.sleep 0.5 >>= fun () ->
  utp_check_timeouts ctx;
  check_timeouts ctx

let network_loop ctx =
  let open Lwt.Infix in
  let socket_data = Lwt_bytes.create 4096 in
  Lwt.ignore_result (check_timeouts ctx);
  let rec loop () =
    Lwt_bytes.recvfrom the_socket socket_data 0 4096 [] >>= fun (n, sa) ->
    let _ : int = utp_process_udp ctx socket_data n sa in
    if not (Lwt_unix.readable the_socket) then utp_issue_deferred_acks ctx;
    loop ()
  in
  loop ()

let () =
  Lwt.ignore_result (network_loop the_context)

let write_data sock =
  let userdata = utp_get_userdata sock in
  let n = ref max_int in
  while 0 < !n && 0 < Queue.length userdata.to_write do
    let wbuf, woff, wlen = Queue.top userdata.to_write in
    n := utp_write sock wbuf woff wlen;
    if 0 < !n then begin
      ignore (Queue.pop userdata.to_write);
      Lwt.wakeup_later (Lwt_sequence.take_r userdata.writers) !n
    end
  done

let write sock buf off len =
  let info = utp_get_userdata sock in
  Queue.push (buf, off, len) info.to_write;
  let t = Lwt.add_task_l info.writers in
  write_data sock;
  t

type error =
  | ECONNREFUSED
  | ECONNRESET
  | ETIMEDOUT

let on_sendto sock addr buf =
  let open Lwt.Infix in
  let t =
    Lwt_bytes.sendto the_socket buf 0 (Lwt_bytes.length buf) [] addr >>= fun n ->
    Printf.eprintf "[utp] wrote %d bytes via sendto\n%!" n;
    Lwt.return n
  in
  Lwt.ignore_result t

let on_log _sock str =
  Printf.eprintf "[UTP] %s" str

let on_error sock err =
  let info = utp_get_userdata sock in
  match err with
  | ECONNREFUSED ->
      Lwt.wakeup_exn info.connected (Failure "connection refused")
  | ECONNRESET ->
      prerr_endline "ECONNRESET"
  | ETIMEDOUT ->
      prerr_endline "ETIMEDOUT"

let on_read sock buf =
  Printf.eprintf "[utp] on_read\n%!";
  let userdata = utp_get_userdata sock in
  assert (Lwt_bytes.length userdata.read_buf = 0);
  if Queue.is_empty userdata.to_read then
    userdata.read_buf <- buf
  else begin
    let off = ref 0 in
    let len = ref (Lwt_bytes.length buf) in
    while 0 < !len && Queue.length userdata.to_read > 0 do
      let wbuf, woff, wlen = Queue.take userdata.to_read in
      let n = min !len wlen in
      Lwt_bytes.blit_to_bytes buf 0 wbuf woff n;
      off := !off + n;
      len := !len - n;
      Lwt.wakeup_later (Lwt_sequence.take_r userdata.readers) n;
    done;
    if 0 < !len then
      userdata.read_buf <- Lwt_bytes.proxy buf !off !len
    else
      utp_read_drained sock
  end

let on_accept sock addr =
  match Lwt_sequence.take_opt_r accepting with
  | None -> ()
  | Some u ->
      let info = create_info () in
      utp_set_userdata sock info;
      Lwt.wakeup u (sock, addr)
  (* write_data sock *)

type state =
  | STATE_CONNECT
  | STATE_WRITABLE
  | STATE_EOF
  | STATE_DESTROYING

let on_state_change sock st =
  let info = utp_get_userdata sock in
  match st with
  | STATE_CONNECT ->
      Lwt.wakeup info.connected ();
      write_data sock
  | STATE_WRITABLE ->
      write_data sock
  | STATE_EOF ->
      utp_close sock
  | STATE_DESTROYING ->
      Lwt.wakeup info.closed ()

type utp_socket_stats =
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

external utp_get_stats : utp_socket -> utp_socket_stats = "caml_utp_get_stats"

let get_stats sock =
  utp_get_stats sock

let close sock =
  let info = utp_get_userdata sock in
  utp_close sock;
  info.closing

let () =
  Callback.register "caml_utp_on_read" on_read;
  Callback.register "caml_utp_on_state_change" on_state_change;
  Callback.register "caml_utp_on_error" on_error;
  Callback.register "caml_utp_on_sendto" on_sendto;
  Callback.register "caml_utp_on_log" on_log;
  Callback.register "caml_utp_on_accept" on_accept
