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

let debug_mode = ref 0
let listen_mode = ref false
let local_port = ref 0
let source_ip = ref "0.0.0.0"
let buffer_size = ref 4096
let do_not_resolve_hostnames = ref false

let spec =
  let open Arg in
  align
    [
      "-d", Unit (fun () -> incr debug_mode), "Debug mode; use multiple times to increase verbosity";
      "-l", Set listen_mode, "Listen mode";
      "-p", Set_int local_port, "Local port";
      "-s", Set_string source_ip, "Source IP";
      "-B", Set_int buffer_size, "Buffer size";
      "-n", Set do_not_resolve_hostnames, "Don't resolve hostnames";
    ]

let usage_msg =
  Printf.sprintf
    "Usage:\n\
    \    %s [options] <destination-IP> <destination-port>\n\
    \    %s [options] -l -p <listening-port>" Sys.argv.(0) Sys.argv.(0)

let main () =
  Arg.parse spec (fun _ -> ()) usage_msg

let () =
  main ()
