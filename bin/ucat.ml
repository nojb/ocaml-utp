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

let o_debug = ref 0
let o_listen = ref false
let o_local_port = ref 0
let o_local_address = ref ""
let o_buf_size = ref 4096
let o_numeric = ref false
let o_remote_port = ref 0
let o_remote_address = ref ""

let fatal fmt =
  Printf.printf ("fatal: " ^^ fmt ^^ "\n%!")

let debug fmt =
  if !o_debug > 0 then
    Printf.eprintf ("debug: " ^^ fmt ^^ "\n%!")
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

let complete f buf off len =
  let rec loop off len =
    if len <= 0 then
      Lwt.return_unit
    else
      let%lwt n = f buf off len in
      loop (off + n) (len - n)
  in
  loop off len

module U = Lwt_unix

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

let print_stats stats =
  debug "Socket Statistics:";
  debug "    Bytes sent:          %d" stats.Utp.nbytes_xmit;
  debug "    Bytes received:      %d" stats.Utp.nbytes_recv;
  debug "    Packets received:    %d" stats.Utp.nrecv;
  debug "    Packets sent:        %d" stats.Utp.nxmit;
  debug "    Duplicate receives:  %d" stats.Utp.nduprecv;
  debug "    Retransmits:         %d" stats.Utp.rexmit;
  debug "    Fast Retransmits:    %d" stats.Utp.fastrexmit;
  debug "    Best guess at MTU:   %d" stats.Utp.mtu_guess

let print_context_stats stats =
  debug "           Bucket size:    <23    <373    <723    <1400    >1400\n";
  debug "Number of packets sent:  %5d   %5d   %5d    %5d    %5d\n"
    stats.Utp.nraw_send_empty stats.Utp.nraw_send_small stats.Utp.nraw_send_mid
    stats.Utp.nraw_send_big stats.Utp.nraw_send_huge;
  debug "Number of packets recv:  %5d   %5d   %5d    %5d    %5d\n"
    stats.Utp.nraw_recv_empty stats.Utp.nraw_recv_small stats.Utp.nraw_recv_mid
    stats.Utp.nraw_recv_big stats.Utp.nraw_recv_huge

let main () =
  Arg.parse spec anon_fun usage_msg;

  if !o_listen && (!o_remote_port <> 0 || !o_remote_address <> "") then
    raise Exit;

  if not !o_listen && (!o_remote_port = 0 || !o_remote_address = "") then
    raise Exit;

  let buf = Bytes.create !o_buf_size in
  debug "Allocated %d buffer" !o_buf_size;

  let ctx = Utp.context () in

  if !o_debug >= 2 then begin
    Utp.set_context_opt ctx Utp.LOG_NORMAL true;
    Utp.set_context_opt ctx Utp.LOG_DEBUG true;
    Utp.set_context_opt ctx Utp.LOG_MTU true
  end;

  match !o_listen with
  | false ->
      let%lwt addr = lookup !o_remote_address !o_remote_port in
      debug "Connecting to %s..." (string_of_sockaddr addr);
      let sock = Utp.socket ctx in
      let%lwt () = Utp.connect sock addr in
      debug "Connected to %s" (string_of_sockaddr addr);
      let rec loop () =
        match%lwt Lwt_io.read_into Lwt_io.stdin buf 0 (Bytes.length buf) with
        | 0 ->
            debug "Read EOF from stdin; closing socket";
            Utp.close sock
        | len ->
            debug "Read %d bytes from stdin" len;
            complete (Utp.write sock) buf 0 len >> loop ()
      in
      loop ()
  | true ->
      let quitting, quit = Lwt.wait () in
      let rec echo id sock =
        match%lwt Utp.read sock buf 0 (Bytes.length buf) with
        | 0 ->
            Lwt_io.eprintlf ">>>%d EOF" id
        | len ->
            Lwt_io.printlf ">>>%d" id >>
            Lwt_io.write_from_exactly Lwt_io.stdout buf 0 len >>
            Lwt_io.printlf ">>>" >>
            echo id sock
      in
      Lwt.async (fun () ->
          match%lwt Lwt_io.read Lwt_io.stdin with
          | "" ->
              Lwt.wakeup_later quit ();
              Lwt.return_unit
          | _ ->
              Lwt.return_unit
        );
      let%lwt addr = lookup !o_local_address !o_local_port in
      Utp.bind ctx addr;
      let id = ref (-1) in
      let rec loop () =
        incr id;
        let%lwt sock, addr = Utp.accept ctx in
        debug "Connection accepted from %s" (string_of_sockaddr addr);
        Lwt.async (fun () -> Lwt.async (fun () -> quitting >> Utp.close sock); echo !id sock);
        loop ()
      in
      loop ()

let () =
  try
    Lwt_main.run (main ())
  with
  | Exit ->
      Arg.usage spec usage_msg;
      exit 2
  | Failure s ->
      fatal "%s" s;
      exit 1
