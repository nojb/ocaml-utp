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

type utp_socket

val socket : unit -> utp_socket
val connect : utp_socket -> Unix.sockaddr -> unit Lwt.t
val bind : Unix.sockaddr -> unit
val accept : unit -> (utp_socket * Unix.sockaddr) Lwt.t
val read : utp_socket -> bytes -> int -> int -> int Lwt.t
val write : utp_socket -> bytes -> int -> int -> int Lwt.t
val close : utp_socket -> unit Lwt.t

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

val get_stats : utp_socket -> utp_socket_stats
