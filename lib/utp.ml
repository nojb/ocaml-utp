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

type buffer =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type error =
  | ECONNREFUSED
  | ECONNRESET
  | ETIMEDOUT

type _ callback =
  | ON_SENDTO : (Unix.sockaddr -> Lwt_bytes.t -> unit) callback
  | ON_ACCEPT : (socket -> Unix.sockaddr -> unit) callback
  | ON_ERROR : (socket -> error -> unit) callback
  | ON_READ : (socket -> Lwt_bytes.t -> unit) callback
  | ON_CONNECT : (socket -> unit) callback
  | ON_WRITABLE : (socket -> unit) callback
  | ON_EOF : (socket -> unit) callback
  | ON_CLOSE : (socket -> unit) callback

external init: unit -> context = "stub_utp_init"
external set_callback: context -> 'a callback -> 'a -> unit = "stub_utp_set_callback"
external set_debug: context -> bool -> unit = "stub_utp_set_debug"
external create_socket: context -> socket = "stub_utp_create_socket"
external write: socket -> buffer -> int -> int -> int = "stub_utp_write"
external connect: socket -> Unix.sockaddr -> unit = "stub_utp_connect"
external close: socket -> unit = "stub_utp_close"
external process_udp: context -> Unix.sockaddr -> buffer -> int -> int -> bool = "stub_utp_process_udp"
external issue_deferred_acks: context -> unit = "stub_utp_issue_deferred_acks"
external check_timeouts: context -> unit = "stub_utp_check_timeouts"
external get_id: socket -> int = "stub_utp_get_id"
