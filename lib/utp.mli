(* The MIT License (MIT)

   Copyright (c) 2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

type _ option =
  | LOG_NORMAL : bool option
  | LOG_MTU : bool option
  | LOG_DEBUG : bool option
  | SNDBUF : int option
  | RCVBUF : int option
  | TARGET_DELAY : int option

val context : unit -> context
val socket : context -> socket
val connect : socket -> Unix.sockaddr -> unit Lwt.t
val bind : context -> Unix.sockaddr -> unit
val accept : context -> (socket * Unix.sockaddr) Lwt.t
val read : socket -> bytes -> int -> int -> int Lwt.t
val write : socket -> bytes -> int -> int -> int Lwt.t
val close : socket -> unit Lwt.t
val get_stats : socket -> socket_stats
val get_context_stats : context -> context_stats
val get_opt : socket -> 'a option -> 'a
val set_opt : socket -> 'a option -> 'a -> unit
val get_context_opt : context -> 'a option -> 'a
val set_context_opt : context -> 'a option -> 'a -> unit
