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

external utp_init: int -> context = "caml_utp_init"
external set_context_callback: context -> 'a context_callback -> 'a -> unit = "caml_utp_set_callback"
external set_socket_callback: socket -> 'a callback -> 'a -> unit = "caml_socket_set_callback"
external set_debug: context -> bool -> unit = "caml_utp_set_debug"
external utp_destroy: context -> unit = "caml_utp_destroy"
external socket: context -> socket = "caml_utp_create_socket"
external write: socket -> bytes -> int -> int -> int = "caml_utp_write"
external connect: socket -> Unix.sockaddr -> unit = "caml_utp_connect"
external close: socket -> unit = "caml_utp_close"
external utp_getpeername: socket -> Unix.sockaddr = "caml_utp_getpeername"
external file_descr: context -> Unix.file_descr = "caml_utp_file_descr"
external bind: context -> Unix.sockaddr -> unit = "caml_utp_bind"
external readable: context -> unit = "caml_utp_readable"
external periodic: context -> unit = "caml_utp_periodic"

let context () =
  utp_init 2
