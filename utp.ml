(* module type S = sig *)

(*   type context *)
(*   type socket *)

(*   val init : int -> context *)
(*   val socket : context -> socket *)
(*   val connect : socket -> Unix.sockaddr -> unit Lwt.t *)
(*   val write : socket -> bytes -> int -> int -> unit Lwt.t *)
(*   val write_string : socket -> string -> int -> int -> unit Lwt.t *)
(*   val read : socket -> bytes -> int -> int -> unit Lwt.t *)

(* end *)

(* type context *)
(* type socket *)

(* external utp_init : int -> utp_context = "caml_utp_init" *)
(* external utp_create_socket : context -> socket = "caml_utp_create_socket" *)
(* external *)

type utp_socket

external utp_create_socket : unit -> utp_socket = "caml_utp_create_socket"

let udp_fd = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0

type socket =
  {
    sock : utp_socket;
    mutable read_buf : bytes;
    mutable read_len : int;
    to_read : (bytes * int * int) Queue.t;
    readers : int Lwt.u Lwt_sequence.t;
    to_write : (bytes * int * int) Queue.t;
    writers : int Lwt.u Lwt_sequence.t;
  }

let read sock buf off len =
  if Queue.is_empty sock.to_read && sock.read_len > 0 then begin
    let n = min sock.read_len len in
    Bytes.blit sock.read_buf 0 buf off n;
    sock.read_len <- sock.read_len - n;
    Bytes.blit sock.read_buf n sock.read_buf 0 sock.read_len;
    Lwt.return n
  end else begin
    Queue.push sock.to_read (buf, off, len);
    Lwt.add_task_l sock.readers
  end

let write sock buf off len =
  Queue.push sock.to_write (buf, off, len);
  Lwt.add_task_l sock.writers

let on_read sock buf off len =
  if Queue.is_empty sock.to_read then begin
    let n = min (Bytes.length sock.read_buf - sock.read_len) len in
    Bytes.blit buf off sock.read_buf sock.read_len n;
    len - n
  end else begin
    let wbuf, woff, wlen = Queue.take sock.to_read in
    let n = min len wlen in
    Bytes.blit buf off wbuf woff n;
    let len = len - n in
    let off = off + n in
    let n = min len (Bytes.length sock.read_buf) in
    Bytes.blit buf off sock.read_buf 0 n;
    len - n
  end
