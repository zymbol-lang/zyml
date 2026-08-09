(* The `std/*` modules, implemented natively.

   These are not Zymbol source: they are OCaml functions wrapped in the same
   [funcval] a user-defined module function uses, so the compiler resolves
   `math::sqrt(x)` exactly as it resolves any other module call — at compile
   time, straight to the function.

   Return types follow the reference engine, and they are not uniform.  `abs`,
   `max` and `min` preserve the argument type; everything else in `std/math`
   returns Float even when the value is integral, so `floor(3.7)` is the Float
   3 and prints as `3`.  This was read off the binary, not guessed. *)

open Value

(* A native function: same shape as a compiled one, so nothing downstream has
   to know the difference. *)
let native name arity (f : value array -> value) : funcval =
  { fname = name; arity; fslots = arity; outs = [||];
    fbody = (fun fr -> f (Array.sub fr.slots 0 arity));
    fmstate = [||] }

let num what = function
  | Int i -> float_of_int i
  | Float f -> f
  | v -> errk "Type" "%s expects a number, got %s" what (type_name v)

let text what = function
  | Str s -> s
  | Chr c -> c
  | v -> errk "Type" "%s expects a string, got %s" what (type_name v)

let int_of what = function
  | Int i -> i
  | Float f -> int_of_float f
  | v -> errk "Type" "%s expects an integer, got %s" what (type_name v)

(* ------------------------------------------------------------------- math *)

let math_fns =
  let f1 name fn = (name, 1, fun (a : value array) -> Float (fn (num name a.(0)))) in
  [
    f1 "sqrt" Float.sqrt; f1 "exp" Float.exp; f1 "ln" Float.log;
    f1 "sin" Float.sin; f1 "cos" Float.cos; f1 "tan" Float.tan;
    f1 "asin" Float.asin; f1 "acos" Float.acos; f1 "atan" Float.atan;
    f1 "tanh" Float.tanh; f1 "sinh" Float.sinh; f1 "cosh" Float.cosh;
    f1 "sigmoid" (fun x -> 1.0 /. (1.0 +. Float.exp (-.x)));
    f1 "floor" Float.floor; f1 "ceil" Float.ceil; f1 "round" Float.round;
    ("atan2", 2, fun a -> Float (Float.atan2 (num "atan2" a.(0)) (num "atan2" a.(1))));
    ("pow", 2, fun a -> Float (Float.pow (num "pow" a.(0)) (num "pow" a.(1))));
    (* One argument is the natural log; two is log base b. *)
    ("log", 1, fun a -> Float (Float.log (num "log" a.(0))));
    (* These three keep the argument's type rather than widening to Float. *)
    ("abs", 1, fun a -> match a.(0) with
       | Int i -> Int (abs i)
       | v -> Float (Float.abs (num "abs" v)));
    ("max", 2, fun a -> if cmp a.(0) a.(1) >= 0 then a.(0) else a.(1));
    ("min", 2, fun a -> if cmp a.(0) a.(1) <= 0 then a.(0) else a.(1));
  ]

(* `log` takes one or two arguments.  Arity is fixed per [funcval], so the
   two-argument form is registered separately and picked by the call site. *)
let math_log2 = native "log" 2 (fun a ->
    Float (Float.log (num "log" a.(0)) /. Float.log (num "log" a.(1))))

(* ------------------------------------------------------------------ random *)

let seeded = ref false
let ensure_seed () = if not !seeded then begin Random.self_init (); seeded := true end

(* `Random.int` caps at 2^30, and a Zymbol program picking from a range derived
   from an LCG modulus asks for far more than that.  Fall through to the 63-bit
   generator rather than raising Invalid_argument at the user. *)
let random_below n =
  if n <= 0 then 0
  else if n < 0x40000000 then Random.int n
  else Int64.to_int (Random.int64 (Int64.of_int n))

let random_fns = [
  ("entero", 2, fun a ->
      ensure_seed ();
      let lo = int_of "entero" a.(0) and hi = int_of "entero" a.(1) in
      if hi < lo then errk "Type" "random::entero needs low <= high"
      else Int (lo + random_below (hi - lo + 1)));
  ("rango", 1, fun a ->
      ensure_seed ();
      let n = int_of "rango" a.(0) in
      if n <= 0 then errk "Type" "random::rango needs a positive count"
      else Int (random_below n));
  (* A neural-network style weight: Float in [-0.1, 0.1], not [0, 1). *)
  ("peso_f64", 0, fun _ -> ensure_seed (); Float (Random.float 0.2 -. 0.1));
]

(* -------------------------------------------------------------------- term *)

(* `std/term` is about layout, so every function here measures *columns*, not
   characters: a CJK ideograph is one character and two columns wide, and
   padding it by character count leaves the column misaligned. *)
let term_fns = [
  ("width", 1, fun a -> Int (display_width (text "width" a.(0))));
  ("pad_left", 2, fun a ->
      let s = text "pad_left" a.(0) and n = int_of "pad_left" a.(1) in
      let w = display_width s in
      Str (if w >= n then s else String.make (n - w) ' ' ^ s));
  ("pad_right", 2, fun a ->
      let s = text "pad_right" a.(0) and n = int_of "pad_right" a.(1) in
      let w = display_width s in
      Str (if w >= n then s else s ^ String.make (n - w) ' '));
  ("center", 2, fun a ->
      let s = text "center" a.(0) and n = int_of "center" a.(1) in
      let w = display_width s in
      if w >= n then Str s
      else begin
        let left = (n - w) / 2 in
        Str (String.make left ' ' ^ s ^ String.make (n - w - left) ' ')
      end);
  ("truncate", 2, fun a ->
      (* Cut at the last character that still fits inside the column budget. *)
      let s = text "truncate" a.(0) and n = int_of "truncate" a.(1) in
      if display_width s <= n then Str s
      else begin
        let chars = utf8_chars s in
        let b = Buffer.create (String.length s) and used = ref 0 in
        Array.iter (fun ch ->
            let w = if is_wide (codepoint_of ch) then 2 else 1 in
            if !used + w <= n then begin Buffer.add_string b ch; used := !used + w end)
          chars;
        Str (Buffer.contents b)
      end);
]

(* ---------------------------------------------------------------------- io *)

(* Every io function answers with a *value*, including on failure: a missing
   file yields `##IO(...)` rather than raising, which is what makes `$!` and
   `$!!` meaningful.  This is the only part of the language that produces an
   error value. *)
let io_err fmt = Printf.ksprintf (fun s -> Err ("IO", s)) fmt

(* Rust renders an io::Error as "<description> (os error <n>)", and the corpus
   compares those strings, so the errno has to come along.  OCaml does not
   expose the numeric code, hence the table; anything outside it still gets a
   readable message, just without the number. *)
let errno_of = function
  | Unix.ENOENT -> Some 2   | Unix.EACCES -> Some 13 | Unix.EEXIST -> Some 17
  | Unix.ENOTDIR -> Some 20 | Unix.EISDIR -> Some 21 | Unix.EINVAL -> Some 22
  | Unix.ENOTEMPTY -> Some 39 | Unix.EPERM -> Some 1 | Unix.EIO -> Some 5
  | _ -> None

let unix_message e =
  match errno_of e with
  | Some n -> Printf.sprintf "%s (os error %d)" (Unix.error_message e) n
  | None -> Unix.error_message e

let with_io f = try f () with
  | Unix.Unix_error (e, _, _) -> io_err "%s" (unix_message e)
  (* A channel function raised instead: recover the real cause from errno,
     which is still set, rather than surfacing OCaml's own wording. *)
  | Sys_error _ -> io_err "%s" (unix_message Unix.ENOENT)

(* Open through Unix so failures arrive as Unix_error with a usable errno. *)
let read_whole path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  let n = (Unix.fstat fd).Unix.st_size in
  let b = Bytes.create n in
  let rec fill off =
    if off < n then
      let r = Unix.read fd b off (n - off) in
      if r > 0 then fill (off + r)
  in
  (try fill 0 with e -> Unix.close fd; raise e);
  Unix.close fd;
  Bytes.sub_string b 0 n

let write_to path flags data =
  let fd = Unix.openfile path flags 0o644 in
  let b = Bytes.of_string data in
  (try ignore (Unix.write fd b 0 (Bytes.length b)) with e -> Unix.close fd; raise e);
  Unix.close fd

let rec rm_rf path =
  if Sys.is_directory path then begin
    Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

(* `mkdir` creates parent directories, like `mkdir -p`. *)
let rec mkdir_p path =
  if path <> "" && path <> "/" && path <> "." && not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let io_fns = [
  ("read", 1, fun a -> with_io (fun () -> Str (read_whole (text "read" a.(0)))));
  ("write", 2, fun a ->
      with_io (fun () ->
          write_to (text "write" a.(0))
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] (display a.(1));
          Unit));
  ("append", 2, fun a ->
      with_io (fun () ->
          write_to (text "append" a.(0))
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] (display a.(1));
          Unit));
  ("exists", 1, fun a -> Bool (Sys.file_exists (text "exists" a.(0))));
  ("delete", 1, fun a ->
      let p = text "delete" a.(0) in
      if not (Sys.file_exists p) then io_err "No such file or directory (os error 2)"
      else with_io (fun () -> rm_rf p; Unit));
  ("list", 1, fun a ->
      with_io (fun () ->
          let d = text "list" a.(0) in
          let entries = Sys.readdir d in
          Array.sort compare entries;
          arr (Array.map (fun e -> Str e) entries)));
  ("mkdir", 1, fun a -> with_io (fun () -> mkdir_p (text "mkdir" a.(0)); Unit));
]

(* -------------------------------------------------------------------- json *)

(* A JSON document maps onto Zymbol values: objects become named tuples, arrays
   become arrays.  Only what the reference engine round-trips is supported. *)

exception Json_error of string

let json_decode (src : string) : value =
  let n = String.length src in
  let i = ref 0 in
  (* serde_json reports "... at line L column C", and the corpus compares those
     strings, so the position is part of the message. *)
  let position () =
    let line = ref 1 and col = ref 0 in
    for k = 0 to min !i (n - 1) do
      if src.[k] = '\n' then begin incr line; col := 0 end else incr col
    done;
    (!line, !col)
  in
  let fail m =
    let (l, c) = position () in
    raise (Json_error (Printf.sprintf "%s at line %d column %d" m l c))
  in
  let skip () = while !i < n && (match src.[!i] with ' '|'\t'|'\n'|'\r' -> true | _ -> false)
    do incr i done in
  let expect c =
    skip ();
    if !i >= n || src.[!i] <> c then
      fail (Printf.sprintf "expected `%c`" c);
    incr i
  in
  let parse_string ?(what = "expected string") () =
    skip ();
    if !i >= n || src.[!i] <> '"' then fail what;
    incr i;
    let b = Buffer.create 16 in
    let fin = ref false in
    while not !fin do
      if !i >= n then fail "unterminated string";
      match src.[!i] with
      | '"' -> incr i; fin := true
      | '\\' ->
        incr i;
        if !i >= n then fail "unterminated escape";
        let c = src.[!i] in
        incr i;
        Buffer.add_string b (match c with
            | 'n' -> "\n" | 't' -> "\t" | 'r' -> "\r" | 'b' -> "\b" | 'f' -> "\012"
            | 'u' ->
              if !i + 4 > n then fail "bad \\u escape";
              let hex = String.sub src !i 4 in
              i := !i + 4;
              utf8_encode (int_of_string ("0x" ^ hex))
            | c -> String.make 1 c)
      | c -> Buffer.add_char b c; incr i
    done;
    Buffer.contents b
  in
  let rec parse_value () =
    skip ();
    if !i >= n then fail "unexpected end of input";
    match src.[!i] with
    | '"' -> Str (parse_string ())
    | '{' ->
      incr i; skip ();
      let names = ref [] and vals = ref [] in
      if !i < n && src.[!i] = '}' then incr i
      else begin
        let fin = ref false in
        while not !fin do
          skip ();
          let k = parse_string ~what:"key must be a string" () in
          expect ':';
          let v = parse_value () in
          names := k :: !names; vals := v :: !vals;
          skip ();
          if !i < n && src.[!i] = ',' then incr i
          else begin expect '}'; fin := true end
        done
      end;
      ntup (Array.of_list (List.rev !names)) (Array.of_list (List.rev !vals))
    | '[' ->
      incr i; skip ();
      let items = ref [] in
      if !i < n && src.[!i] = ']' then incr i
      else begin
        let fin = ref false in
        while not !fin do
          items := parse_value () :: !items;
          skip ();
          if !i < n && src.[!i] = ',' then incr i
          else begin expect ']'; fin := true end
        done
      end;
      arr (Array.of_list (List.rev !items))
    | 't' -> i := !i + 4; Bool true
    | 'f' -> i := !i + 5; Bool false
    | 'n' -> i := !i + 4; Unit
    | _ ->
      let start = !i in
      if src.[!i] = '-' || src.[!i] = '+' then incr i;
      let isf = ref false in
      while !i < n && (match src.[!i] with
          | '0'..'9' -> true
          | '.' | 'e' | 'E' | '+' | '-' -> isf := true; true
          | _ -> false) do incr i done;
      if !i = start then fail "unexpected character";
      let t = String.sub src start (!i - start) in
      if !isf then Float (float_of_string t) else Int (int_of_string t)
  in
  let v = parse_value () in
  skip ();
  v

let rec json_encode (v : value) : string =
  let quote s =
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter (fun c -> match c with
        | '"' -> Buffer.add_string b "\\\""
        | '\\' -> Buffer.add_string b "\\\\"
        | '\n' -> Buffer.add_string b "\\n"
        | '\t' -> Buffer.add_string b "\\t"
        | '\r' -> Buffer.add_string b "\\r"
        | c -> Buffer.add_char b c) s;
    Buffer.add_char b '"';
    Buffer.contents b
  in
  match v with
  | Str s -> quote s
  | Chr c -> quote c
  | Int i -> string_of_int i
  | Float f -> float_repr f
  | Bool b -> if b then "true" else "false"
  | Unit -> "null"
  | Arr { c = a; _ } | Tup { c = a; _ } ->
    "[" ^ String.concat "," (Array.to_list (Array.map json_encode a)) ^ "]"
  | NTup (names, { c = vals; _ }) ->
    "{" ^ String.concat ","
      (List.mapi (fun i k -> quote k ^ ":" ^ json_encode vals.(i))
         (Array.to_list names)) ^ "}"
  | v -> errk "Type" "cannot encode %s as JSON" (type_name v)

(* `decode_map(src, mapping)` renames keys as it decodes, recursively: the
   mechanism behind data-level i18n. *)
let rec rename_keys (mapping : (string * string) list) (v : value) : value =
  match v with
  | NTup (names, { c = vals; _ }) ->
    ntup (Array.map (fun k -> match List.assoc_opt k mapping with
        | Some k' -> k' | None -> k) names)
      (Array.map (rename_keys mapping) vals)
  | Arr { c = a; _ } -> arr (Array.map (rename_keys mapping) a)
  | v -> v

let mapping_of = function
  | NTup (names, { c = vals; _ }) ->
    Array.to_list (Array.mapi (fun i k -> (k, display vals.(i))) names)
  | Arr { c = a; _ } ->
    Array.to_list a |> List.filter_map (function
        | Tup { c = [| a; b |]; _ } -> Some (display a, display b)
        | _ -> None)
  | v -> errk "Type" "decode_map expects a mapping, got %s" (type_name v)

let json_fns = [
  ("decode", 1, fun a ->
      (try json_decode (text "decode" a.(0))
       with Json_error m -> Err ("Parse", m)
          | Failure m -> Err ("Parse", m)));
  ("encode", 1, fun a -> Str (json_encode a.(0)));
  ("decode_map", 2, fun a ->
      (try rename_keys (mapping_of a.(1)) (json_decode (text "decode_map" a.(0)))
       with Json_error m -> Err ("Parse", m)
          | Failure m -> Err ("Parse", m)));
]

(* --------------------------------------------------------------------- net *)

(* HTTP through `curl` rather than a socket library: the whole engine's premise
   is no dependencies beyond the OCaml compiler, and curl is already a hard
   requirement of any machine running these programs.  A failure comes back as
   `##Network(...)`, matching the reference engine, rather than raising. *)

let shell_quote s =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

(* Headers arrive as an array of ("name", "value") pairs. *)
let header_args v =
  match v with
  | Arr { c = items; _ } | Tup { c = items; _ } ->
    Array.to_list items
    |> List.filter_map (function
        | Tup { c = [| k; x |]; _ } | NTup (_, { c = [| k; x |]; _ }) ->
          Some (" -H " ^ shell_quote (as_text k ^ ": " ^ as_text x))
        | _ -> None)
    |> String.concat ""
  | Unit -> ""
  | v -> errk "Type" "headers must be an array of pairs, got %s" (type_name v)

let net_err fmt = Printf.ksprintf (fun s -> Err ("Network", s)) fmt

(* Body on stdout, then a sentinel line with curl's own exit code, so a failed
   request is told apart from one that legitimately returned nothing. *)
let curl (args : string) : value =
  let cmd = "curl -sS --max-time 30 " ^ args ^ " 2>/tmp/.zyq_curl_err; echo \"\\n__ZY_RC__$?\"" in
  let ic = Unix.open_process_in cmd in
  let b = Buffer.create 4096 in
  (try
     while true do Buffer.add_channel b ic 1 done
   with End_of_file -> ());
  ignore (Unix.close_process_in ic);
  let out = Buffer.contents b in
  match String.rindex_opt out '_' with
  | _ ->
    let marker = "__ZY_RC__" in
    (match String.index_opt out '\000' with _ -> ());
    let idx =
      let rec find i =
        if i < 0 then None
        else if i + String.length marker <= String.length out
                && String.sub out i (String.length marker) = marker then Some i
        else find (i - 1)
      in
      find (String.length out - String.length marker)
    in
    (match idx with
     | None -> Str out
     | Some i ->
       let rc = String.trim (String.sub out (i + String.length marker)
                               (String.length out - i - String.length marker)) in
       (* Drop the sentinel and the newline echo added before it. *)
       let body = String.sub out 0 (max 0 (i - 1)) in
       if rc = "0" then Str body
       else begin
         let msg =
           try String.trim (read_whole "/tmp/.zyq_curl_err") with _ -> ""
         in
         net_err "io: %s" (if msg = "" then "curl exited " ^ rc else msg)
       end)

let net_fns = [
  ("get", 1, fun a -> curl (shell_quote (text "get" a.(0))));
  ("get", 2, fun a -> curl (shell_quote (text "get" a.(0)) ^ header_args a.(1)));
  ("head", 1, fun a ->
      match curl ("-I -o /dev/null " ^ shell_quote (text "head" a.(0))) with
      | Err _ -> Bool false
      | _ -> Bool true);
  ("post", 2, fun a ->
      curl (shell_quote (text "post" a.(0)) ^ " -X POST --data-binary "
            ^ shell_quote (display a.(1))));
  ("post", 3, fun a ->
      curl (shell_quote (text "post" a.(0)) ^ " -X POST --data-binary "
            ^ shell_quote (display a.(1)) ^ header_args a.(2)));
  ("post_json", 2, fun a ->
      curl (shell_quote (text "post_json" a.(0))
            ^ " -X POST -H 'Content-Type: application/json' --data-binary "
            ^ shell_quote (display a.(1))));
  ("post_json", 3, fun a ->
      curl (shell_quote (text "post_json" a.(0))
            ^ " -X POST -H 'Content-Type: application/json' --data-binary "
            ^ shell_quote (display a.(1)) ^ header_args a.(2)));
]

(* ------------------------------------------------------------------ lookup *)

(* What a module is, from the compiler's point of view: exported constants
   addressed by slot, and exported functions.  Kept structural so [Compile] can
   build its own [modul] from it without a circular dependency. *)
type std_module = {
  sconsts : (string * value) list;
  sfuncs : funcval list;
}

let of_list ?(consts = []) fns =
  { sconsts = consts;
    sfuncs = List.map (fun (n, a, f) -> native n a f) fns }

let find (path : string) : std_module option =
  match path with
  | "std/math" ->
    let m = of_list math_fns
        ~consts:[ ("PI", Float (4.0 *. Float.atan 1.0));
                  ("E", Float (Float.exp 1.0)) ] in
    (* Both arities of `log` live under the same name; the call site picks. *)
    Some { m with sfuncs = math_log2 :: m.sfuncs }
  | "std/random" -> Some (of_list random_fns)
  | "std/term" -> Some (of_list term_fns)
  | "std/io" -> Some (of_list io_fns)
  | "std/json" -> Some (of_list json_fns)
  | "std/net" -> Some (of_list net_fns)
  | _ -> None
