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

type utp_context
type 'a utp_socket

external utp_init : int -> utp_context = "caml_utp_init"
external utp_destroy : utp_context -> unit = "caml_utp_destroy"
external utp_create_socket : 'a -> 'a utp_socket = "caml_utp_create_socket"
external utp_get_userdata : 'a utp_socket -> 'a = "caml_utp_get_userdata"
external utp_write : 'a utp_socket -> bytes -> int -> int -> int = "caml_utp_write"
external utp_read_drained : 'a utp_socket -> unit = "caml_utp_read_drained"
external utp_issue_deferred_acks : utp_context -> unit = "caml_utp_issue_deferred_acks"
external utp_check_timeouts : utp_context -> unit = "caml_utp_check_timeouts"
external utp_process_udp : utp_context -> Lwt_bytes.t -> int -> Unix.sockaddr -> int = "caml_utp_process_udp"

type user_data =
  {
    file_descr : Lwt_unix.file_descr;
    ctx : utp_context;
    mutable read_buf : Lwt_bytes.t;
    to_read : (bytes * int * int) Queue.t;
    readers : int Lwt.u Lwt_sequence.t;
    to_write : (bytes * int * int) Queue.t;
    writers : int Lwt.u Lwt_sequence.t;
  }

type sock

let null = Lwt_bytes.create 0

let read sock wbuf woff wlen =
  let userdata = utp_get_userdata sock in
  let len = Lwt_bytes.length userdata.read_buf in
  if Queue.is_empty userdata.to_read && len > 0 then begin
    let n = min len wlen in
    Lwt_bytes.blit_to_bytes userdata.read_buf 0 wbuf woff n;
    if n < len then
      userdata.read_buf <- Lwt_bytes.proxy userdata.read_buf n (len - n)
    else begin
      userdata.read_buf <- null;
      utp_read_drained sock;
    end;
    Lwt.return n
  end else begin
    Queue.push (wbuf, woff, wlen) userdata.to_read;
    Lwt.add_task_l userdata.readers
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
  let info = utp_get_userdata sock in
  Queue.push (buf, off, len) info.to_write;
  Lwt.add_task_l info.writers

let on_read sock buf =
  let userdata = utp_get_userdata sock in
  assert (Lwt_bytes.length userdata.read_buf = 0);
  if Queue.is_empty userdata.to_read then
    userdata.read_buf <- buf
  else begin
    let off = ref 0 in
    let len = ref (Lwt_bytes.length buf) in
    while 0 < !len && Queue.length userdata.to_read > 0 do
      let wbuf, woff, wlen = Queue.take userdata.to_read in
      let n = min !len wlen in
      Lwt_bytes.blit_to_bytes buf 0 wbuf woff n;
      off := !off + n;
      len := !len - n;
      Lwt.wakeup_later (Lwt_sequence.take_r userdata.readers) n;
    done;
    if 0 < !len then
      userdata.read_buf <- Lwt_bytes.proxy buf !off !len
    else
      utp_read_drained sock
  end

let write_data sock =
  let userdata = utp_get_userdata sock in
  let n = ref max_int in
  while 0 < !n && 0 < Queue.length userdata.to_write do
    let wbuf, woff, wlen = Queue.top userdata.to_write in
    n := utp_write sock wbuf woff wlen;
    if 0 < !n then begin
      ignore (Queue.pop userdata.to_write);
      Lwt.wakeup_later (Lwt_sequence.take_r userdata.writers) !n
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
