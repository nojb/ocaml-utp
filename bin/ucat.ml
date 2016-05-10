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

let o_debug = ref 0
let o_listen = ref false
let o_local_port = ref 0
let o_local_address = ref ""
let o_buf_size = ref 65536
let o_numeric = ref false
let o_remote_port = ref 0
let o_remote_address = ref ""

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

let spec =
  let open Arg in
  align
    [
      "-d", Unit (fun () -> incr o_debug), "Debug mode; use multiple times to increase verbosity";
      "-l", Set o_listen, "Listen mode";
      "-p", Set_int o_local_port, "Local port";
      "-s", Set_string o_local_address, "Source IP";
      "-B", Set_int o_buf_size, "Buffer size";
      "-n", Set o_numeric, "Don't resolve hostnames";
    ]

let usage_msg =
  Printf.sprintf
    "Usage:\n\
    \    %s [options] <destination-IP> <destination-port>\n\
    \    %s [options] -l -p <listening-port>" Sys.argv.(0) Sys.argv.(0)

let anon_fun =
  let i = ref (-1) in
  fun s ->
    incr i;
    try
      match !i with
      | 0 -> o_remote_address := s
      | 1 -> o_remote_port := int_of_string s
      | _ -> raise Exit
    with _ ->
      raise Exit

let die fmt =
  Printf.ksprintf failwith fmt

module U = Lwt_unix

open Lwt.Infix

let lookup addr port =
  let hints = [U.AI_FAMILY U.PF_INET; U.AI_SOCKTYPE U.SOCK_DGRAM] in
  let hints = if !o_numeric then U.AI_NUMERICHOST :: hints else hints in
  let hints = if !o_listen then U.AI_PASSIVE :: hints else hints in
  match%lwt U.getaddrinfo addr (string_of_int port) hints with
  | [] ->
      [%lwt die "getaddrinfo"]
  | res :: _ ->
      Lwt.return res.U.ai_addr

let string_of_sockaddr = function
  | U.ADDR_UNIX s ->
      s
  | U.ADDR_INET (ip, port) ->
      Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ip) port

module Utp_lwt : sig
  exception Closed
  exception Timed_out
  exception Connection_reset
  exception Connection_refused

  type socket
  type context

  val init: Unix.sockaddr -> context
  val connect: context -> Unix.sockaddr -> socket Lwt.t
  val accept: context -> (Unix.sockaddr * socket) Lwt.t
  val read: socket -> bytes Lwt.t
  val write: socket -> bytes -> int -> int -> unit Lwt.t
  val close: socket -> unit Lwt.t
  val destroy: context -> unit Lwt.t
end = struct
  exception Closed
  exception Timed_out
  exception Connection_reset
  exception Connection_refused

  type socket =
    {
      id: Utp.socket;
      buffers: bytes Lwt_sequence.t;
      readers: bytes Lwt.u Lwt_sequence.t;
      writable: unit Lwt_condition.t;
      connected: unit Lwt.u;
      on_connected: unit Lwt.t;
      closed: unit Lwt.u;
      close: unit Lazy.t;
      on_closed: unit Lwt.t;
      eof: unit Lwt.u;
      on_eof: unit Lwt.t;
      write_mutex: Lwt_mutex.t;
      write_buffer: Lwt_bytes.t;
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

  let safe_wakeup w x =
    try Lwt.wakeup w x with Invalid_argument _ -> ()

  let safe_wakeup_exn w exn =
    try Lwt.wakeup_exn w exn with Invalid_argument _ -> ()

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
    Lwt.wakeup sock.connected ()

  let on_close id =
    debug "on_close";
    let sock = Hashtbl.find sockets id in
    Lwt.wakeup_later sock.closed (); (* CHECK: _later is important here *)
    safe_wakeup_exn sock.connected Closed;
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
    Lazy.force sock.close;
    Lwt.wakeup_later sock.eof ();
    Lwt_sequence.iter_node_l (fun node ->
        let w = Lwt_sequence.get node in
        Lwt_sequence.remove node;
        Lwt.wakeup_exn w End_of_file
      ) sock.readers

  let create_socket id =
    let buffers = Lwt_sequence.create () in
    let readers = Lwt_sequence.create () in
    let writable = Lwt_condition.create () in
    let on_connected, connected = Lwt.wait () in
    let on_closed, closed = Lwt.wait () in
    let close = lazy (Utp.close id) in
    let on_eof, eof = Lwt.wait () in
    let write_mutex = Lwt_mutex.create () in
    let write_buffer = Lwt_bytes.create 4096 in
    {
      id;
      buffers;
      readers;
      writable;
      connected;
      on_connected;
      closed;
      close;
      on_closed;
      eof;
      on_eof;
      write_mutex;
      write_buffer;
    }

  let on_accept id sid addr =
    debug "on_accept";
    let ctx = Hashtbl.find contexts id in
    let sock = create_socket sid in
    Hashtbl.add sockets sid sock;
    ctx.sockets <- ctx.sockets + 1;
    Lwt_condition.signal ctx.accept (addr, sock)

  let on_sendto id addr buf =
    really_debug "on_sendto";
    let ctx = Hashtbl.find contexts id in
    let buf = Lwt_bytes.to_bytes buf in
    let _ =
      Lwt_mutex.with_lock ctx.send_mutex (fun () ->
          Lwt_unix.sendto ctx.fd buf 0 (Bytes.length buf) [] addr
        )
    in
    ()

  let on_error id error =
    debug "on_error";
    let sock = Hashtbl.find sockets id in
    let exn =
      match error with
      | Utp.ECONNREFUSED -> Connection_refused
      | Utp.ECONNRESET -> Connection_reset
      | Utp.ETIMEDOUT -> Timed_out
    in
    Lwt_sequence.iter_node_l (fun node ->
        let w = Lwt_sequence.get node in
        Lwt_sequence.remove node;
        Lwt.wakeup_exn w exn
      ) sock.readers;
    Lwt.wakeup_exn sock.connected exn
    (* Lwt_condition.broadcast_exn sock.writable exn *)

  let init addr =
    let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
    Lwt_unix.bind fd addr;
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
    ctx

  let connect ctx addr =
    let id = Utp.create_socket ctx.id in
    let sock = create_socket id in
    Hashtbl.add sockets id sock;
    ctx.sockets <- ctx.sockets + 1;
    Utp.connect sock.id addr;
    sock.on_connected >>= fun () -> Lwt.return sock

  let close (sock : socket) =
    Lazy.force sock.close;
    sock.on_closed

  let accept ctx =
    Lwt_condition.wait ctx.accept

  let read sock =
    if Lwt_sequence.is_empty sock.readers && not (Lwt_sequence.is_empty sock.buffers) then
      Lwt.return (Lwt_sequence.take_l sock.buffers)
    else
      Lwt.add_task_r sock.readers

  let rec write sock buf off len =
    let rec loop off len =
      if len = 0 then
        Lwt.return_unit
      else begin
        let to_write = min len (Lwt_bytes.length sock.write_buffer) in
        Lwt_bytes.blit_from_bytes buf off sock.write_buffer 0 to_write;
        let rec loop1 off1 len1 =
          let n = Utp.write sock.id sock.write_buffer off1 len1 in
          if n < len1 then
            Lwt_condition.wait sock.writable >>= fun () ->
            loop1 (off1 + n) (len1 - n)
          else
            loop (off + to_write) (len - to_write)
        in
        loop1 0 to_write
      end
    in
    Lwt_mutex.with_lock sock.write_mutex (fun () -> loop off len)

  let destroy ctx =
    if ctx.sockets = 0 then begin
      Lwt.wakeup ctx.stop ();
      Utp.destroy ctx.id;
      Hashtbl.remove contexts ctx.id
    end else begin
      ctx.destroyed <- true;
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
end

let main () =
  Arg.parse spec anon_fun usage_msg;

  if !o_listen && (!o_remote_port <> 0 || !o_remote_address <> "") then
    raise Exit;

  if not !o_listen && (!o_remote_port = 0 || !o_remote_address = "") then
    raise Exit;

  lookup !o_local_address !o_local_port >>= fun addr ->

  let ctx = Utp_lwt.init addr in

  (* if !o_debug >= 2 then *)
  (*   Utp.set_debug ctx true; *)

  let t =
    match !o_listen with
    | false ->
        lookup !o_remote_address !o_remote_port >>= fun addr ->
        Utp_lwt.connect ctx addr >>= fun sock ->
        let read_buf = Bytes.create !o_buf_size in
        let rec echo_loop () =
          match%lwt Lwt_unix.read Lwt_unix.stdin read_buf 0 (Bytes.length read_buf) with
          | 0 ->
              debug "Read EOF from stdin; closing socket";
              Utp_lwt.close sock
          | n ->
              Utp_lwt.write sock read_buf 0 n >>= echo_loop
        in
        echo_loop ()
    | true ->
        lookup !o_local_address !o_local_port >>= fun addr ->
        Utp_lwt.accept ctx >>= fun (addr, sock) ->
        let rec loop: 'a. 'a -> _ Lwt.t = fun _ ->
          Lwt.try_bind
            (fun () ->
               Utp_lwt.read sock >>= fun bytes ->
               Lwt_unix.write Lwt_unix.stdout bytes 0 (Bytes.length bytes)
            )
            loop
            (function
              | End_of_file ->
                  debug "got End_of_file";
                  Lwt.return_unit
              | e ->
                  Lwt.fail e
            )
        in
        loop () >>= fun () -> Utp_lwt.close sock
  in
  t >>= fun () -> Utp_lwt.destroy ctx

let () =
  try
    Lwt_main.run (main ());
    Gc.compact ()
  with
  | Exit ->
      Arg.usage spec usage_msg
  | Failure s ->
      Printf.eprintf "Fatal error: %s\n%!" s;
  | e ->
      Printf.eprintf "Fatal error: %s\n%!" (Printexc.to_string e)
