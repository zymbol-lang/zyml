(* CLI entry point.

   Usage:
     zyml run FILE.zy        compile to closures and execute (default)
     zyml tokens FILE.zy     dump the token stream
     zyml check FILE.zy      parse and compile without running
     zyml bench FILE.zy [N]  run N times and report compile/run timings *)

let version = "0.1.0"

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let die msg =
  (* Raw mode outlives the process unless it is undone, and a shell left in it
     looks hung.  Every exit path goes through here or through the normal end
     of cmd_run. *)
  Value.leave_raw ();
  Value.flush_out ();
  prerr_endline msg;
  exit 1

let load path =
  let src = read_file path in
  let toks = Lexer.tokenize src in
  Parser.parse toks

let guard f =
  try f () with
  | Lexer.Lex_error (m, l) -> die (Printf.sprintf "Lex error: %s (line %d)" m l)
  | Parser.Parse_error (m, l) -> die (Printf.sprintf "Parse error: %s (line %d)" m l)
  | Compile.Compile_error m -> die (Printf.sprintf "Compile error: %s" m)
  | Value.Zy_error (_, m) -> die (Printf.sprintf "Runtime error: %s" m)
  | Sys_error m -> die (Printf.sprintf "error: %s" m)

let cmd_run ?(args = []) path =
  guard (fun () ->
      Compile.script_args := args;
      let prog = load path in
      let run = Compile.compile ~file:path prog in
      run ();
      Value.leave_raw ();
      Value.flush_out ())

let cmd_check path =
  guard (fun () ->
      let prog = load path in
      let _run : unit -> unit = Compile.compile ~file:path prog in
      print_endline "ok")

let cmd_tokens path =
  guard (fun () ->
      let toks = Lexer.tokenize (read_file path) in
      Array.iter (fun (t : Lexer.t) ->
          Printf.printf "%4d  %s\n" t.line (Lexer.show t.tok)) toks)

let cmd_bench path n =
  guard (fun () ->
      let src = read_file path in
      let t0 = Unix.gettimeofday () in
      let prog = Parser.parse (Lexer.tokenize src) in
      let run = Compile.compile ~file:path prog in
      let t1 = Unix.gettimeofday () in
      let devnull = open_out "/dev/null" in
      let saved = Unix.dup Unix.stdout in
      Unix.dup2 (Unix.descr_of_out_channel devnull) Unix.stdout;
      let t2 = Unix.gettimeofday () in
      for _ = 1 to n do run (); Value.flush_out () done;
      let t3 = Unix.gettimeofday () in
      Unix.dup2 saved Unix.stdout;
      Printf.printf "compile: %.3f ms\nrun x%d: %.3f ms  (%.3f ms/iter)\n"
        ((t1 -. t0) *. 1000.) n ((t3 -. t2) *. 1000.) ((t3 -. t2) *. 1000. /. float_of_int n))

let usage () =
  prerr_endline "zyml — a Zymbol engine in OCaml";
  prerr_endline "";
  prerr_endline "  zyml run FILE.zy";
  prerr_endline "  zyml check FILE.zy";
  prerr_endline "  zyml tokens FILE.zy";
  prerr_endline "  zyml bench FILE.zy [N]";
  exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: ("-v" | "--version") :: _ -> Printf.printf "zyml %s\n" version
  | _ :: "run" :: path :: rest -> cmd_run ~args:rest path
  | _ :: "check" :: path :: _ -> cmd_check path
  | _ :: "tokens" :: path :: _ -> cmd_tokens path
  | _ :: "bench" :: path :: rest ->
    cmd_bench path (match rest with n :: _ -> int_of_string n | [] -> 10)
  | [ _; path ] when Filename.check_suffix path ".zy" -> cmd_run path
  | _ -> usage ()
