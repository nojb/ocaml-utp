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

type socket =
  {
    file_descr : Lwt_unix.file_descr;
    sock : utp_socket;
    mutable read_buf : Lwt_bytes.t;
    to_read : (bytes * int * int) Queue.t;
    readers : int Lwt.u Lwt_sequence.t;
    to_write : (bytes * int * int) Queue.t;
    writers : int Lwt.u Lwt_sequence.t;
  }

let read sock wbuf woff wlen =
  let len = Lwt_bytes.length sock.read_buf in
  if Queue.is_empty sock.to_read && len > 0 then begin
    let n = min len wlen in
    Lwt_bytes.blit_to_bytes sock.read_buf 0 wbuf woff n;
    if n < len then
      sock.read_buf <- Lwt_bytes.proxy sock.read_buf n (len - n)
    else begin
      sock.read_buf <- Lwt_bytes.empty;
      utp_read_drained sock;
    end;
    Lwt.return n
  end else begin
    Queue.push sock.to_read (wbuf, woff, wlen);
    Lwt.add_task_l sock.readers
  end

let write sock buf off len =
  Queue.push sock.to_write (buf, off, len);
  Lwt.add_task_l sock.writers

let on_read sock buf =
  assert (Lwt_bytes.length sock.read_buf = 0);
  if Queue.is_empty sock.to_read then
    sock.read_buf <- buf
  else begin
    let off = ref 0 in
    let len = ref (Lwt_bytes.length buf) in
    while 0 < !len && Queue.length sock.to_read > 0 do
      let wbuf, woff, wlen = Queue.take sock.to_read in
      let n = min !len wlen in
      Lwt_bytes.blit_to_bytes buf 0 wbuf woff n;
      off := !off + n;
      len := !len - n;
      Lwt.wakeup_later (Lwt_sequence.take_r sock.readers) n;
    done;
    if 0 < !len then
      sock.read_buf <- Lwt_bytes.proxy buf !off !len
    else
      utp_read_drained sock
  end

let write_data sock =
  let n = ref max_int in
  while 0 < !n && 0 < Queue.length sock.to_write then begin
    let wbuf, woff, wlen = Queue.top sock.to_write in
    let n := utp_write sock.sock wbuf woff wlen in
    if 0 < !n then begin
      ignore (Queue.pop sock.to_write);
      Lwt.wakeup_later (Lwt_sequence.take_r sock.writers) !n
    end
  end

type state =
  | STATE_CONNECT
  | STATE_WRITABLE
  | STATE_EOF
  | STATE_DESTROYING

let on_state_change sock st =
  match st with
  | STATE_WRITABLE ->
      write_data sock
