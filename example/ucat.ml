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
let o_local_address = ref "0.0.0.0"
let o_buf_size = ref 4096
let o_remote_port = ref 0
let o_remote_address = ref ""

let spec =
  let open Arg in
  align
    [
      "-d", Unit (fun () -> incr o_debug), "Debug mode; use multiple times to increase verbosity";
      "-l", Set o_listen, "Listen mode";
      "-p", Set_int o_local_port, "Local port";
      "-s", Set_string o_local_address, "Source IP";
      "-B", Set_int o_buf_size, "Buffer size";
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

open Lwt.Infix

let complete f buf off len =
  let rec loop off len =
    if len <= 0 then
      Lwt.return_unit
    else
      f buf off len >>= fun n ->
      loop (off + n) (len - n)
  in
  loop off len

let main () =
  Arg.parse spec anon_fun usage_msg;
  if !o_listen && (!o_remote_port <> 0 || !o_remote_address <> "") then raise Exit;
  if not !o_listen && (!o_remote_port = 0 || !o_remote_address = "") then raise Exit;
  let buf = Bytes.create !o_buf_size in
  match !o_listen with
  | false ->
      let addr = Unix.ADDR_INET (Unix.inet_addr_of_string !o_remote_address, !o_remote_port) in
      let sock = Utp.socket () in
      Utp.connect sock addr >>= fun () ->
      let rec loop () =
        Lwt_unix.read Lwt_unix.stdin buf 0 (Bytes.length buf) >>= fun len ->
        complete (Utp.write sock) buf 0 len >>=
        loop
      in
      loop ()
  | true ->
      let rec loop sock =
        Utp.read sock buf 0 (Bytes.length buf) >>= fun len ->
        complete (Lwt_unix.write Lwt_unix.stdout) buf 0 len >>= fun () ->
        loop sock
      in
      Utp.accept () >>= fun (sock, _) ->
      loop sock

let () =
  try
    Lwt_main.run (main ())
  with Exit ->
    Arg.usage spec usage_msg;
    exit 2
