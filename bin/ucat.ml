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

let main () =
  Arg.parse spec anon_fun usage_msg;

  if !o_listen && (!o_remote_port <> 0 || !o_remote_address <> "") then
    raise Exit;

  if not !o_listen && (!o_remote_port = 0 || !o_remote_address = "") then
    raise Exit;

  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in

  let ctx = Utp.init () in

  if !o_debug >= 2 then
    Utp.set_debug ctx true;

  let the_buf = Lwt_bytes.create !o_buf_size in
  let rec read_loop () =
    Lwt_bytes.recvfrom fd the_buf 0 (Lwt_bytes.length the_buf) [] >>= fun (n, addr) ->
    debug "received packet";
    if Utp.process_udp ctx addr the_buf 0 n then begin
      if not (Lwt_unix.readable fd) then begin
        debug "issue deferred acks";
        Utp.issue_deferred_acks ctx
      end;
      read_loop ()
    end else begin
      debug "received a non-utp message";
      read_loop ()
    end
  in
  let rec periodic_loop () =
    Lwt_unix.sleep 0.5 >>= fun () ->
    (* debug "check_timeouts"; *)
    Utp.check_timeouts ctx;
    periodic_loop ()
  in
  let _event_loop = Lwt.join [read_loop (); periodic_loop ()] in
  let mut = Lwt_mutex.create () in
  let on_sendto addr buf =
    debug "on_sendto";
    let buf = Lwt_bytes.to_bytes buf in
    let _ =
      Lwt_mutex.with_lock mut (fun () ->
          Lwt_unix.sendto fd buf 0 (Bytes.length buf) [] addr
        )
    in
    ()
  in
  Utp.set_callback ctx Utp.ON_SENDTO on_sendto;
  Utp.set_callback ctx Utp.ON_ERROR (fun _ _ -> debug "on_error");
  match !o_listen with
  | false ->
      lookup !o_remote_address !o_remote_port >>= fun addr ->
      let connected, connect = Lwt.wait () in
      let writable = Lwt_condition.create () in
      let closed = Lwt_condition.create () in
      Utp.set_callback ctx Utp.ON_WRITABLE
        (fun sock -> debug "on_writable"; Lwt_condition.signal writable sock);
      Utp.set_callback ctx Utp.ON_CLOSE
        (fun sock -> debug "on_close"; Lwt_condition.signal closed sock);
      Utp.set_callback ctx Utp.ON_CONNECT (fun sock ->
          debug "Connected to %s" (string_of_sockaddr addr);
          Lwt.wakeup connect sock
        );
      let sock = Utp.create_socket ctx in
      let rec write buf off len =
        if len = 0 then
          Lwt.return_unit
        else
          let n = Utp.write sock buf off len in
          if n = 0 then
            Lwt_condition.wait writable >>= fun _ ->
            write buf off len
          else
            write buf (off + n) (len - n)
      in
      let read_buf = Lwt_bytes.create !o_buf_size in
      let rec echo_loop () =
        match%lwt Lwt_bytes.read Lwt_unix.stdin read_buf 0 (Lwt_bytes.length read_buf) with
        | 0 ->
            debug "Read EOF from stdin; closing socket";
            let t = Lwt_condition.wait closed in
            Utp.close sock;
            t >>= fun _ -> Lwt.return_unit
        | n ->
            write read_buf 0 n >>= echo_loop
      in
      Utp.connect sock addr;
      connected >>= fun _ -> echo_loop ()
  | true ->
      lookup !o_local_address !o_local_port >>= fun addr ->
      Lwt_unix.bind fd addr;
      let incoming = Hashtbl.create 0 in
      let mut = Lwt_mutex.create () in
      let on_read sock buf =
        debug "on_read";
        let id = Hashtbl.find incoming sock in
        let buf = Lwt_bytes.to_bytes buf in
        let _ =
          Lwt_mutex.with_lock mut (fun () ->
              really_debug "Received %d bytes from #%d:" (Bytes.length buf) id;
              Lwt_unix.write Lwt_unix.stdout buf 0 (Bytes.length buf)
            )
        in
        ()
      in
      let on_eof sock =
        debug "on_eof";
        let id = Hashtbl.find incoming sock in
        debug "Socket #%d eof'd" id;
        Utp.close sock
      in
      let on_close sock =
        (* Gc.compact (); *)
        debug "on_close";
        let id = Hashtbl.find incoming sock in
        debug "Socket #%d (%d) closed" id (Utp.get_id sock);
        Hashtbl.remove incoming sock
      in
      let id = ref (-1) in
      let on_accept sock addr =
        debug "on_accept";
        incr id;
        Hashtbl.add incoming sock !id;
        debug "Connection #%d accepted from %s" !id (string_of_sockaddr addr);
      in
      Utp.set_callback ctx Utp.ON_READ on_read;
      Utp.set_callback ctx Utp.ON_EOF on_eof;
      Utp.set_callback ctx Utp.ON_CLOSE on_close;
      Utp.set_callback ctx Utp.ON_ACCEPT on_accept;
      let t, _ = Lwt.wait () in
      t

let () =
  try
    Lwt_main.run (main ())
  with
  | Exit ->
      Arg.usage spec usage_msg
  | Failure s ->
      Printf.printf "Fatal error: %s\n%!" s;
  | e ->
      Printf.printf "Fatal error: %s\n%!" (Printexc.to_string e)
