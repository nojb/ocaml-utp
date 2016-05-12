(* The MIT License (MIT)

   Copyright (c) 2016 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

(** [Lwt] bindings to [libutp]. *)

type socket
(** The type of UTP sockets. *)

type context
(** The type of UTP contexts.  A UTP context corresponds one-to-one to
    underlying UDP sockets.  A context may spawn any number of sockets. *)

val init: Unix.sockaddr -> context
(** [init addr] create a context and binds it to [addr]. *)

val connect: context -> Unix.sockaddr -> socket Lwt.t
(** [connect ctx addr] connects to [addr] and returns the resulting connected
    socket. *)

val accept: context -> (Unix.sockaddr * socket) Lwt.t
(** [accept ctx] waits for an incoming connection and, on receipt, returns the
    connected socket and the source address. *)

val read: socket -> bytes Lwt.t
(** [read sock] returns the next chunk of data read from [sock]. *)

val write: socket -> bytes -> int -> int -> unit Lwt.t
(** [write sock buf off len] writes bytes from [buf] between [off] and [off+len]
    to [sock]. *)

val close: socket -> unit Lwt.t
(** [close sock] closes [sock]. *)

val destroy: context -> unit Lwt.t
(** [destroy ctx] signals that the context [ctx] is no longer useful.  It will
    be destroyed once all dependant sockets are closed. *)
