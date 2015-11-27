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

type utp_context
type utp_socket

external utp_init : int -> utp_context = "caml_utp_init"
external utp_destroy : utp_context -> unit = "caml_utp_destroy"
external utp_create_socket : unit -> utp_socket = "caml_utp_create_socket"
external utp_write : utp_socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_read_drained : utp_socket -> unit = "caml_utp_read_drained"
external utp_issue_deferred_acks : utp_context -> unit = "caml_utp_issue_deferred_acks"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_process_udp : utp_context -> Lwt_bytes.t -> int -> Unix.sockaddr -> int = "caml_utp_process_udp"

type socket =
  {
    file_descr : Lwt_unix.file_descr;
    ctx : utp_context;
    sock : utp_socket;
    mutable read_buf : Lwt_bytes.t;
    to_read : (bytes * int * int) Queue.t;
    readers : int Lwt.u Lwt_sequence.t;
    to_write : (bytes * int * int) Queue.t;
    writers : int Lwt.u Lwt_sequence.t;
  }

let null = Lwt_bytes.create 0

let read sock wbuf woff wlen =
  let len = Lwt_bytes.length sock.read_buf in
  if Queue.is_empty sock.to_read && len > 0 then begin
    let n = min len wlen in
    Lwt_bytes.blit_to_bytes sock.read_buf 0 wbuf woff n;
    if n < len then
      sock.read_buf <- Lwt_bytes.proxy sock.read_buf n (len - n)
    else begin
      sock.read_buf <- null;
      utp_read_drained sock.sock;
    end;
    Lwt.return n
  end else begin
    Queue.push (wbuf, woff, wlen) sock.to_read;
    Lwt.add_task_l sock.readers
  end

let network_loop sock =
  let open Lwt.Infix in
  let socket_data = Lwt_bytes.create 4096 in
  let rec loop () =
    Lwt_bytes.recvfrom sock.file_descr socket_data 0 4096 [] >>= fun (n, sa) ->
    let _ : int = utp_process_udp sock.ctx socket_data n sa in
    if not (Lwt_unix.readable sock.file_descr) then utp_issue_deferred_acks sock.ctx;
    loop ()
  in
  loop ()

let write sock buf off len =
  Queue.push (buf, off, len) sock.to_write;
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
      utp_read_drained sock.sock
  end

let write_data sock =
  let n = ref max_int in
  while 0 < !n && 0 < Queue.length sock.to_write do
    let wbuf, woff, wlen = Queue.top sock.to_write in
    n := utp_write sock.sock wbuf woff wlen;
    if 0 < !n then begin
      ignore (Queue.pop sock.to_write);
      Lwt.wakeup_later (Lwt_sequence.take_r sock.writers) !n
    end
  done

type state =
  | STATE_CONNECT
  | STATE_WRITABLE
  | STATE_EOF
  | STATE_DESTROYING

let on_state_change sock st =
  match st with
  | STATE_WRITABLE ->
      write_data sock

let () =
  Callback.register "caml_utp_on_read" on_read;
  Callback.register "caml_utp_on_state_change" on_state_change
