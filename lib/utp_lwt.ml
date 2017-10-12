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

let o_debug = ref 0

let debug fmt =
  if !o_debug > 0 then
    Printf.eprintf ("[debug] " ^^ fmt ^^ "\n%!")
  else
    Printf.ifprintf stderr fmt

let really_debug fmt =
  if !o_debug > 1 then
    Printf.eprintf ("[debug] " ^^ fmt ^^ "\n%!")
  else
    Printf.ifprintf stderr fmt

open Lwt.Infix

type state =
  | Connecting
  | Connected
  | Eof
  | Error
  | Closing
  | Closed

type socket =
  {
    id: Utp.socket;
    buffers: bytes Lwt_sequence.t;
    readers: bytes Lwt.u Lwt_sequence.t;
    writable: unit Lwt_condition.t;
    state_changed: unit Lwt_condition.t;
    write_mutex: Lwt_mutex.t;
    write_buffer: Lwt_bytes.t;
    mutable state: state;
  }

type context =
  {
    id: Utp.context;
    fd: Lwt_unix.file_descr;
    accept: (Unix.sockaddr * socket) Lwt_condition.t;
    send_mutex: Lwt_mutex.t;
    loop: unit Lwt.t;
    mutable sockets: int;
    mutable destroyed: bool;
    stop: unit Lwt.u;
  }

let sockets = Hashtbl.create 5
let contexts = Hashtbl.create 2

let safe s f x =
  Lwt.catch f (fun e -> debug "%s: unexpected exn: %s" s (Printexc.to_string e); x)

let read_loop stopper fd id =
  let buf = Lwt_bytes.create 4096 in
  let rec loop () =
    Lwt.pick [stopper >>= (fun () -> Lwt.fail Exit); Lwt_bytes.recvfrom fd buf 0 (Lwt_bytes.length buf) []] >>= fun (n, addr) ->
    really_debug "received packet";
    if Utp.process_udp id addr buf 0 n then begin
      if not (Lwt_unix.readable fd) then begin
        really_debug "issue deferred acks";
        Utp.issue_deferred_acks id
      end;
    end else begin
      debug "received a non-utp message";
    end;
    loop ()
  in
  safe "read_loop" loop Lwt.return_unit

let periodic_loop stopper id =
  let rec loop () =
    Lwt.pick [stopper >>= (fun () -> Lwt.fail Exit); Lwt_unix.sleep 0.5] >>= fun () ->
    Utp.check_timeouts id;
    loop ()
  in
  safe "periodic_loop" loop Lwt.return_unit

let on_read id buf =
  really_debug "on_read";
  let sock = Hashtbl.find sockets id in
  let buf = Lwt_bytes.to_bytes buf in
  match Lwt_sequence.take_l sock.readers with
  | w ->
      Lwt.wakeup w buf
  | exception Lwt_sequence.Empty ->
      ignore (Lwt_sequence.add_r buf sock.buffers)

let on_writable id =
  really_debug "on_writable";
  let sock = Hashtbl.find sockets id in
  Lwt_condition.signal sock.writable ()

let on_connect id =
  debug "on_connect";
  let sock = Hashtbl.find sockets id in
  sock.state <- Connected;
  Lwt_condition.broadcast sock.state_changed ()

let cancel_readers sock exn =
  let readers = Lwt_sequence.fold_l (fun x l -> x :: l) sock.readers [] in
  List.iter (fun w -> Lwt.wakeup_exn w exn) readers;
  Lwt_sequence.iter_node_l Lwt_sequence.remove sock.readers

let on_close id =
  debug "on_close";
  let sock = Hashtbl.find sockets id in
  sock.state <- Closed;
  cancel_readers sock End_of_file;
  Lwt_condition.broadcast sock.state_changed ();
  Hashtbl.remove sockets id;
  let cid = Utp.get_context id in
  let ctx = Hashtbl.find contexts cid in
  ctx.sockets <- ctx.sockets - 1;
  if ctx.sockets = 0 && ctx.destroyed then begin
    Lwt.wakeup ctx.stop ();
    Utp.destroy ctx.id;
    Hashtbl.remove contexts ctx.id
  end

let on_eof id =
  debug "on_eof";
  let sock = Hashtbl.find sockets id in
  sock.state <- Eof;
  cancel_readers sock End_of_file;
  Lwt_condition.broadcast sock.state_changed ()

let create_socket id state =
  let buffers = Lwt_sequence.create () in
  let readers = Lwt_sequence.create () in
  let writable = Lwt_condition.create () in
  let state_changed = Lwt_condition.create () in
  let write_mutex = Lwt_mutex.create () in
  let write_buffer = Lwt_bytes.create 4096 in
  {
    id;
    buffers;
    readers;
    writable;
    state_changed;
    write_mutex;
    write_buffer;
    state;
  }

let on_accept id sid addr =
  debug "on_accept";
  let ctx = Hashtbl.find contexts id in
  let sock = create_socket sid Connected in
  Hashtbl.add sockets sid sock;
  ctx.sockets <- ctx.sockets + 1;
  Lwt_condition.signal ctx.accept (addr, sock)

external stub_sendto : Unix.file_descr -> Utp.buffer -> int -> int -> Unix.msg_flag list -> Unix.sockaddr -> int = "lwt_unix_bytes_sendto_byte" "lwt_unix_bytes_sendto"

let total_queued = ref 0

let on_sendto id addr buf =
  really_debug "on_sendto";
  let ctx = Hashtbl.find contexts id in
  if Lwt_unix.writable ctx.fd then
    ignore (stub_sendto (Lwt_unix.unix_file_descr ctx.fd) buf 0 (Lwt_bytes.length buf) [] addr)
  else begin
    total_queued := !total_queued + (Lwt_bytes.length buf);
    debug "queueing buffer: %d" !total_queued;
    let buf = Lwt_bytes.to_bytes buf in
    let _ =
      Lwt_mutex.with_lock ctx.send_mutex (fun () ->
          Lwt_unix.sendto ctx.fd buf 0 (Bytes.length buf) [] addr >>= fun _ ->
          total_queued := !total_queued - (Bytes.length buf);
          Lwt.return_unit
        )
    in
    ()
  end

let on_error id error =
  debug "on_error";
  let sock = Hashtbl.find sockets id in
  let err =
    match error with
    | Utp.ECONNREFUSED -> "connect: connection refused"
    | Utp.ECONNRESET -> "connection reset"
    | Utp.ETIMEDOUT -> "connection timeout"
  in
  let exn = Failure err in
  sock.state <- Error;
  cancel_readers sock exn;
  Lwt_condition.broadcast sock.state_changed ()
(* Lwt_condition.broadcast_exn sock.writable exn *)

let init addr =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
  Lwt_unix.bind fd addr >>= fun () ->
  let send_mutex = Lwt_mutex.create () in
  let accept = Lwt_condition.create () in
  let id = Utp.init () in
  let starter, start = Lwt.wait () in
  let stopper, stop = Lwt.wait () in
  let stopper = stopper >>= fun () -> debug "stopping"; Lwt.return_unit in
  let loop =
    let safe_close () = safe "loop" (fun () -> Lwt_unix.close fd) Lwt.return_unit in
    starter >>= fun () -> Lwt.join [read_loop stopper fd id; periodic_loop stopper id] >>= safe_close
  in
  let ctx = {id; fd; accept; send_mutex; loop; sockets = 0; destroyed = false; stop} in
  Hashtbl.add contexts id ctx;
  Lwt.wakeup start ();
  Lwt.return ctx

let connect ctx addr =
  let id = Utp.create_socket ctx.id in
  let sock = create_socket id Connecting in
  Hashtbl.add sockets id sock;
  ctx.sockets <- ctx.sockets + 1;
  Utp.connect sock.id addr;
  let t, w = Lwt.wait () in
  let _ =
    Lwt_condition.wait sock.state_changed >|= fun () ->
    match sock.state with
    | Connected -> Lwt.wakeup w ()
    | _ -> Lwt.wakeup_exn w (Failure "Could not connect")
  in
  t >>= fun () -> Lwt.return sock

let close (sock : socket) =
  let rec wait w =
    Lwt_condition.wait sock.state_changed >>= fun () ->
    match sock.state with
    | Closed -> Lwt.wrap2 Lwt.wakeup w ()
    | _ -> wait w
  in
  match sock.state with
  | Connecting | Error | Connected | Eof ->
      sock.state <- Closing;
      Lwt_condition.broadcast sock.state_changed ();
      let t, w = Lwt.wait () in
      let _ = wait w in
      Utp.close sock.id;
      t
  | Closed ->
      Lwt.return_unit
  | Closing ->
      let t, w = Lwt.wait () in
      let _ = wait w in
      t

let accept ctx =
  Lwt_condition.wait ctx.accept

let read sock =
  match sock.state, Lwt_sequence.is_empty sock.buffers with
  | _, false ->
      Lwt.return (Lwt_sequence.take_l sock.buffers)
  | (Connected | Closing), true ->
      Lwt.add_task_r sock.readers
  | (Closed | Eof), true ->
      Lwt.fail End_of_file
  | _, true ->
      Lwt.fail (Failure "read: not connected")

let write_bytes (sock : socket) buf off len =
  let rec loop off len =
    if len = 0 then
      Lwt.return_unit
    else
      let n = Utp.write sock.id buf off len in
      if n = 0 then
        Lwt_condition.wait sock.writable >>= fun () ->
        loop off len
      else
        loop (off + n) (len - n)
  in
  loop off len

let write sock buf off len =
  let rec loop off len =
    if len = 0 then
      Lwt.return_unit
    else
      let n = min len (Lwt_bytes.length sock.write_buffer) in
      Lwt_bytes.blit_from_bytes buf off sock.write_buffer 0 n;
      write_bytes sock sock.write_buffer 0 n >>= fun () ->
      loop (off + n) (len - n)
  in
  Lwt_mutex.with_lock sock.write_mutex (fun () -> loop off len)

let destroy ctx =
  if not ctx.destroyed then begin
    ctx.destroyed <- true;
    if ctx.sockets = 0 then begin
      Lwt.wakeup ctx.stop ();
      Utp.destroy ctx.id;
      Hashtbl.remove contexts ctx.id
    end
  end;
  ctx.loop

let () =
  Callback.register "utp_on_error" (on_error : Utp.socket -> Utp.error -> unit);
  Callback.register "utp_on_read" (on_read : Utp.socket -> Utp.buffer -> unit);
  Callback.register "utp_on_connect" (on_connect : Utp.socket -> unit);
  Callback.register "utp_on_writable" (on_writable : Utp.socket -> unit);
  Callback.register "utp_on_eof" (on_eof : Utp.socket -> unit);
  Callback.register "utp_on_close" (on_close : Utp.socket -> unit);
  Callback.register "utp_on_accept" (on_accept : Utp.context -> Utp.socket -> Unix.sockaddr -> unit);
  Callback.register "utp_on_sendto" (on_sendto : Utp.context -> Unix.sockaddr -> Utp.buffer -> unit)
