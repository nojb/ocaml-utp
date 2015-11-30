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

type context =
  {
    utp_ctx : utp_context;
    fd : Lwt_unix.file_descr;
    accepting : (socket * Unix.sockaddr) Lwt.u Lwt_sequence.t;
  }

type socket_info =
  {
    connected : unit Lwt.u;
    connecting : unit Lwt.t;
    closing : unit Lwt.t;
    closed : unit Lwt.u;
    mutable read_off : int;
    mutable read_buf : Lwt_bytes.t;
    readers : unit Lwt.u Lwt_sequence.t;
    writers : unit Lwt.u Lwt_sequence.t;
  }

external utp_init : int -> utp_context = "caml_utp_init"
external utp_destroy : utp_context -> unit = "caml_utp_destroy"
external utp_create_socket : utp_context -> socket = "caml_utp_create_socket"
external utp_get_userdata : socket -> socket_info = "caml_utp_get_userdata"
external utp_set_userdata : socket -> socket_info -> unit = "caml_utp_set_userdata"
external utp_write : socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_read_drained : socket -> unit = "caml_utp_read_drained"
external utp_issue_deferred_acks : utp_context -> unit = "caml_utp_issue_deferred_acks"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_process_udp : utp_context -> Lwt_bytes.t -> int -> Unix.sockaddr -> int = "caml_utp_process_udp"
external utp_connect : socket -> Unix.sockaddr -> unit = "caml_utp_connect"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_close : socket -> unit = "caml_utp_close"
external utp_get_stats : socket -> socket_stats = "caml_utp_get_stats"
external utp_get_context : socket -> utp_context = "caml_utp_get_context"
external utp_context_get_userdata : utp_context -> context = "caml_utp_context_get_userdata"
external utp_context_set_userdata : utp_context -> context -> unit = "caml_utp_context_set_userdata"

open Lwt.Infix

let rec check_timeouts ctx =
  Lwt_unix.sleep 0.5 >>= fun () ->
  utp_check_timeouts ctx.utp_ctx;
  check_timeouts ctx

let network_loop ctx =
  let socket_data = Lwt_bytes.create 4096 in
  let rec loop () =
    Lwt_bytes.recvfrom ctx.fd socket_data 0 4096 [] >>= fun (n, sa) ->
    let _ : int = utp_process_udp ctx.utp_ctx socket_data n sa in
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
    read_off = 0;
    read_buf = Lwt_bytes.create 0;
    readers = Lwt_sequence.create ();
    writers = Lwt_sequence.create ();
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
  Lwt.add_task_l ctx.accepting

let read sock wbuf woff wlen =
  let info = utp_get_userdata sock in
  let rec try_read () =
    let len = Lwt_bytes.length info.read_buf - info.read_off in
    if len > 0 then begin
      let n = min len wlen in
      Lwt_bytes.blit_to_bytes info.read_buf info.read_off wbuf woff n;
      info.read_off <- info.read_off + n;
      if n < len then
        if Lwt_sequence.length info.readers > 0 then
          Lwt.wakeup_later (Lwt_sequence.take_r info.readers) ()
      else
        utp_read_drained sock;
      Lwt.return n
    end else
      Lwt.try_bind
        (fun () -> Lwt.add_task_r info.readers) try_read
        (function
          | End_of_file -> Lwt.return 0
          | exn -> Lwt.fail exn
        )
  in
  if Lwt_sequence.is_empty info.readers then
    try_read ()
  else
    Lwt.add_task_l info.readers >>= try_read

let on_read sock buf =
  let info = utp_get_userdata sock in
  assert (Lwt_bytes.length info.read_buf = info.read_off);
  info.read_off <- 0;
  info.read_buf <- buf;
  if Lwt_sequence.length info.readers > 0 then
    Lwt.wakeup_later (Lwt_sequence.take_r info.readers) ()

let on_writeable sock =
  let info = utp_get_userdata sock in
  if Lwt_sequence.length info.writers > 0 then
    Lwt.wakeup_later (Lwt_sequence.take_r info.writers) ()

let write sock buf off len =
  let info = utp_get_userdata sock in
  let rec try_write () =
    let n = utp_write sock buf off len in
    if n = 0 then
      Lwt.add_task_r info.writers >>= try_write
    else begin
      if Lwt_sequence.length info.writers > 0 then
        Lwt.wakeup_later (Lwt_sequence.take_r info.writers) ();
      Lwt.return n
    end
  in
  if Lwt_sequence.is_empty info.writers then
    try_write ()
  else
    Lwt.add_task_l info.writers >>= try_write

type error =
  | ECONNREFUSED
  | ECONNRESET
  | ETIMEDOUT

let on_sendto utp_ctx addr buf =
  let ctx = utp_context_get_userdata utp_ctx in
  let t =
    Lwt_bytes.sendto ctx.fd buf 0 (Lwt_bytes.length buf) [] addr
  in
  Lwt.ignore_result t

let on_log _sock str =
  Printf.eprintf "[UTP] %s" str

let cancel_io info =
  Lwt_sequence.iter_node_r (fun node ->
      Lwt_sequence.remove node;
      let u = Lwt_sequence.get node in
      Lwt.wakeup_later_exn u End_of_file
    ) info.readers;
  Lwt_sequence.iter_node_r (fun node ->
      Lwt_sequence.remove node;
      let u = Lwt_sequence.get node in
      Lwt.wakeup_later_exn u End_of_file
    ) info.writers;
  Lwt.wakeup_exn info.connected End_of_file

let on_error sock err =
  let info = utp_get_userdata sock in
  cancel_io info;
  match err with
  | ECONNREFUSED
  | ETIMEDOUT ->
      Lwt.wakeup_exn info.connected (Failure "connection failed")
  | ECONNRESET ->
      () (* CHECK *)

let on_accept sock addr =
  let utp_ctx = utp_get_context sock in
  let ctx = utp_context_get_userdata utp_ctx in
  match Lwt_sequence.take_opt_r ctx.accepting with
  | None -> ()
  | Some u ->
      let info = create_info () in
      utp_set_userdata sock info;
      Lwt.wakeup u (sock, addr)

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
      on_writeable sock
  | STATE_WRITABLE ->
      on_writeable sock
  | STATE_EOF ->
      utp_close sock;
      cancel_io info
  | STATE_DESTROYING ->
      Lwt.wakeup info.closed ()

let get_socket_stats sock =
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
