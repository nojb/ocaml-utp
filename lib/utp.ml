(* The MIT License (MIT)

   Copyright (c) 2015-2016 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. *)

type context
type socket

type _ context_callback =
  | ON_ERROR : (unit -> unit) context_callback
  | ON_SENDTO : (context -> Unix.sockaddr -> Lwt_bytes.t -> unit) context_callback
  | ON_ACCEPT : (socket -> Unix.sockaddr -> unit) context_callback
  | ON_MESSAGE : (Unix.sockaddr -> Lwt_bytes.t -> unit) context_callback

type error =
  | ECONNREFUSED
  | ECONNRESET
  | ETIMEDOUT

type _ callback =
  | ON_ERROR : (error -> unit) callback
  | ON_READ : (Lwt_bytes.t -> unit) callback
  | ON_CONNECT : (unit -> unit) callback
  | ON_WRITABLE : (unit -> unit) callback
  | ON_EOF : (unit -> unit) callback
  | ON_CLOSE : (unit -> unit) callback

type socket_stats =
  {
    nbytes_recv: int;
    nbytes_xmit: int;
    rexmit: int;
    fastrexmit: int;
    nxmit: int;
    nrecv: int;
    nduprecv: int;
    mtu_guess: int;
  }

type context_stats =
  {
    nraw_recv_empty: int;
    nraw_recv_small: int;
    nraw_recv_mid: int;
    nraw_recv_big: int;
    nraw_recv_huge: int;
    nraw_send_empty: int;
    nraw_send_small: int;
    nraw_send_mid: int;
    nraw_send_big: int;
    nraw_send_huge: int;
  }

type _ option =
  | LOG_NORMAL : bool option
  | LOG_MTU : bool option
  | LOG_DEBUG : bool option
  | SNDBUF : int option
  | RCVBUF : int option
  | TARGET_DELAY : int option

external utp_init: int -> context = "caml_utp_init"
external set_context_callback: context -> 'a context_callback -> 'a -> unit = "caml_utp_set_callback"
external set_socket_callback: socket -> 'a callback -> 'a -> unit = "caml_socket_set_callback"
external utp_destroy: context -> unit = "caml_utp_destroy"
external socket: context -> socket = "caml_utp_create_socket"
external write: socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_check_timeouts: context -> unit = "caml_utp_check_timeouts"
external connect: socket -> Unix.sockaddr -> unit = "caml_utp_connect"
external utp_check_timeouts: context -> unit = "caml_utp_check_timeouts"
external close: socket -> unit = "caml_utp_close"
external get_stats: socket -> socket_stats = "caml_utp_get_stats"
external utp_get_context: socket -> context = "caml_utp_get_context"
external get_context_stats: context -> context_stats = "caml_utp_get_context_stats"
external get_opt: socket -> 'a option -> 'a = "caml_utp_getsockopt"
external set_opt: socket -> 'a option -> 'a -> unit = "caml_utp_setsockopt"
external get_context_opt: context -> 'a option -> 'a = "caml_utp_context_get_option"
external set_context_opt: context -> 'a option -> 'a -> unit = "caml_utp_context_set_option"
external utp_getpeername: socket -> Unix.inet_addr = "caml_utp_getpeername"
external utp_file_descr: context -> Unix.file_descr = "caml_utp_file_descr"
external bind: context -> Unix.sockaddr -> unit = "caml_utp_bind"
external readable: context -> unit = "caml_utp_readable"

let rec check_timeouts utp_ctx =
  let open Lwt.Infix in
  Lwt_unix.sleep 0.5 >>= fun () ->
  utp_check_timeouts utp_ctx;
  check_timeouts utp_ctx

let network_loop ctx =
  let open Lwt.Infix in
  let fd = Lwt_unix.of_unix_file_descr (utp_file_descr ctx) in
  let rec loop () =
    Lwt_unix.wait_read fd >>= fun () ->
    readable ctx;
    loop ()
  in
  loop ()

external sendto_bytes: Unix.file_descr -> Lwt_bytes.t -> int -> int -> Unix.sockaddr -> unit = "caml_sendto_bytes" "noalloc"

let on_sendto ctx addr buf =
  let fd = Lwt_unix.of_unix_file_descr (utp_file_descr ctx) in
  Lwt_unix.check_descriptor fd;
  sendto_bytes (Lwt_unix.unix_file_descr fd) buf 0 (Lwt_bytes.length buf) addr

let context () =
  let ctx = utp_init 2 in

  set_context_callback ctx ON_SENDTO on_sendto;

  Lwt.ignore_result (check_timeouts ctx);
  Lwt.ignore_result (network_loop ctx);
  ctx
