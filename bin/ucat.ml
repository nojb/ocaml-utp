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
  U.getaddrinfo addr (string_of_int port) hints >>= function
  | [] ->
      Lwt.fail (Failure "getaddrinfo")
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

  lookup !o_local_address !o_local_port >>= fun addr ->

  Utp_lwt.init addr >>= fun ctx ->

  (* if !o_debug >= 2 then *)
  (*   Utp.set_debug ctx true; *)

  let t =
    match !o_listen with
    | false ->
        lookup !o_remote_address !o_remote_port >>= fun addr ->
        Utp_lwt.connect ctx addr >>= fun sock ->
        let read_buf = Bytes.create !o_buf_size in
        let rec echo_loop () =
          Lwt_unix.read Lwt_unix.stdin read_buf 0 (Bytes.length read_buf) >>= function
          | 0 ->
              debug "Read EOF from stdin; closing socket";
              Utp_lwt.close sock
          | n ->
              Utp_lwt.write sock read_buf 0 n >>= echo_loop
        in
        echo_loop ()
    | true ->
        lookup !o_local_address !o_local_port >>= fun _addr ->
        Utp_lwt.accept ctx >>= fun (_addr, sock) ->
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
                  Utp_lwt.close sock
              | e ->
                  debug "foo: %s" (Printexc.to_string e);
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
