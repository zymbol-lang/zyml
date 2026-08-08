(* Runtime values, frames and the primitive operations of the Zymbol runtime.
   This module is the bottom of the dependency chain: everything else builds on it.

   Design note — why [code] lives here.  The execution engine compiles the AST into
   OCaml closures ([frame -> value]).  A lambda value therefore holds a closure, so
   the closure type has to be defined together with the value type. *)

(* ------------------------------------------------------------------ values *)

type value =
  | Int of int
  | Float of float
  | Bool of bool
  | Str of string                   (* UTF-8 *)
  | Chr of string                   (* exactly one UTF-8 character *)
  | Arr of value array
  | Tup of value array
  | NTup of string array * value array   (* named tuple: (x: 1, y: 2) *)
  | Fun of funcval
  | Lam of lamval
  (* A first-class error value: kind and message.  Only `std/*` produces these
     -- there is no way to build one from the language itself -- but once one
     exists it flows like any other value, which is what `$!` and `$!!` are
     for. *)
  | Err of string * string
  | Unit

(* A named function.  Zymbol named functions have *isolated* scope: the body sees
   its parameters and nothing from the caller, so a function needs no captures --
   only a flat slot frame. [fbody] is mutable so a function can be registered
   before its body is compiled, which is what makes recursion work. *)
and funcval = {
  fname : string;
  arity : int;
  mutable fslots : int;             (* frame size decided by the compiler *)
  mutable outs : int array;         (* slot indices of `param<~` output params *)
  mutable fbody : code;
  (* A module function is *not* isolated: it reads and writes its module's
     persistent state, which is why the state array travels with the function
     rather than with the call site.  Empty for an ordinary function. *)
  mutable fmstate : value array;
}

(* A lambda captures its free variables *by value at creation time*, so the
   captured values are copied into [lcaps] when the lambda is built. *)
and lamval = {
  lparams : int;
  lslots : int;
  lbody : code;
  lcaps : value array;
  lmstate : value array;            (* module state live where it was created *)
}

and frame = {
  slots : value array;              (* locals of the current call *)
  caps : value array;               (* values a lambda captured at creation *)
  mstate : value array;             (* the enclosing module's live state *)
}

and code = frame -> value

(* ------------------------------------------------------------- control flow *)

(* A runtime error carries a kind so `:! ##Div` can select on it.  The empty
   kind means "unclassified", which only the untyped `:!` arm catches. *)
exception Zy_error of string * string        (* kind, message *)
exception Zy_return of value
exception Zy_break of string option
exception Zy_continue of string option

(* Where execution is.  Updated once per statement, which is one integer store
   -- cheap enough to leave on always, and the difference between a message a
   user can act on and one they cannot. *)
let cur_line = ref 0
let cur_fn = ref ""

let err fmt = Printf.ksprintf (fun s -> raise (Zy_error ("", s))) fmt
let errk kind fmt = Printf.ksprintf (fun s -> raise (Zy_error (kind, s))) fmt

(* ------------------------------------------------------------------- UTF-8 *)

let is_cont c = Char.code c land 0xC0 = 0x80

let utf8_length s =
  let n = ref 0 in
  String.iter (fun c -> if not (is_cont c) then incr n) s;
  !n

(* Byte offsets of every character start, plus String.length as a sentinel. *)
let utf8_offsets s =
  let n = String.length s in
  let acc = ref [] in
  for i = n - 1 downto 0 do
    if not (is_cont (String.unsafe_get s i)) then acc := i :: !acc
  done;
  Array.of_list (!acc @ [ n ])

let utf8_chars s =
  let o = utf8_offsets s in
  let n = Array.length o - 1 in
  Array.init n (fun i -> String.sub s o.(i) (o.(i + 1) - o.(i)))

(* 1-based character access, with negative indices mirroring from the end. *)
let utf8_nth s i =
  let o = utf8_offsets s in
  let n = Array.length o - 1 in
  let i = if i < 0 then n + i + 1 else i in
  if i = 0 then errk "Index" "index 0 is invalid - Zymbol uses 1-based indexing";
  if i < 1 || i > n then errk "Index" "index %d out of bounds (length %d)" i n;
  String.sub s o.(i - 1) (o.(i) - o.(i - 1))

let utf8_slice s a b =
  let o = utf8_offsets s in
  let n = Array.length o - 1 in
  let norm i = if i < 0 then n + i + 1 else i in
  let a = norm a and b = norm b in
  if a < 1 || b > n || a > b then "" else String.sub s o.(a - 1) (o.(b) - o.(a - 1))

(* ----------------------------------------------------------- float display *)

(* Rust's `{}` for f64 prints the shortest representation that round-trips, and
   never uses exponent notation.  We reproduce both halves: find the shortest
   precision that round-trips, then flatten any exponent the C formatter emitted. *)

let expand_exponent s =
  match String.index_opt s 'e' with
  | None -> s
  | Some ei ->
    let mant = String.sub s 0 ei in
    let ex = int_of_string (String.sub s (ei + 1) (String.length s - ei - 1)) in
    let neg = String.length mant > 0 && mant.[0] = '-' in
    let mant = if neg then String.sub mant 1 (String.length mant - 1) else mant in
    let ip, fp =
      match String.index_opt mant '.' with
      | None -> mant, ""
      | Some di ->
        String.sub mant 0 di, String.sub mant (di + 1) (String.length mant - di - 1)
    in
    let digits = ip ^ fp in
    let point = String.length ip + ex in       (* decimal point position in [digits] *)
    let body =
      if point <= 0 then "0." ^ String.make (-point) '0' ^ digits
      else if point >= String.length digits then
        digits ^ String.make (point - String.length digits) '0'
      else String.sub digits 0 point ^ "." ^
           String.sub digits point (String.length digits - point)
    in
    (* strip trailing zeros in the fractional part *)
    let body =
      if String.contains body '.' then begin
        let n = ref (String.length body) in
        while !n > 0 && body.[!n - 1] = '0' do decr n done;
        if !n > 0 && body.[!n - 1] = '.' then decr n;
        String.sub body 0 !n
      end else body
    in
    if neg then "-" ^ body else body

let float_repr f =
  if Float.is_nan f then "NaN"
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.0f" f
  else begin
    let out = ref (Printf.sprintf "%.17g" f) in
    (try
       for p = 1 to 17 do
         let c = Printf.sprintf "%.*g" p f in
         if float_of_string c = f then begin out := c; raise Exit end
       done
     with Exit -> ());
    expand_exponent !out
  end

(* ---------------------------------------------------------- numeral modes *)

(* Every Unicode decimal-digit block is ten contiguous code points starting at
   its own zero, so a script is fully described by that one number.  `#d0d9#`
   names a script by writing its 0 and its 9; these are the bases that spelling
   can select, plus pIqaD in the ConScript private-use area. *)
let digit_bases = [|
  0x0030; 0x0660; 0x06F0; 0x07C0; 0x0966; 0x09E6; 0x0A66; 0x0AE6; 0x0B66;
  0x0BE6; 0x0C66; 0x0CE6; 0x0D66; 0x0DE6; 0x0E50; 0x0ED0; 0x0F20; 0x1040;
  0x1090; 0x17E0; 0x1810; 0x1946; 0x19D0; 0x1A80; 0x1A90; 0x1B50; 0x1BB0;
  0x1C40; 0x1C50; 0xA620; 0xA8D0; 0xA900; 0xA9D0; 0xA9F0; 0xAA50; 0xABF0;
  0xF8F0; 0xFF10; 0x104A0; 0x10D30; 0x11066; 0x110F0; 0x11136; 0x111D0;
  0x112F0; 0x11450; 0x114D0; 0x11650; 0x116C0; 0x11730; 0x118E0; 0x11950;
  0x11C50; 0x11D50; 0x11DA0; 0x16A60; 0x16AC0; 0x16B50; 0x1D7CE; 0x1D7D8;
  0x1D7E2; 0x1D7EC; 0x1D7F6; 0x1E140; 0x1E2F0; 0x1E4F0; 0x1E950; 0x1FBF0;
|]

let base_of_cp cp =
  let found = ref None in
  Array.iter (fun b -> if !found = None && cp >= b && cp <= b + 9 then found := Some b)
    digit_bases;
  !found

(* The script `>>` and every other text-building path currently formats through.
   0x30 is ASCII, and is never display-affected. *)
let numeral_base = ref 0x30

let utf8_encode cp =
  let b = Buffer.create 4 in
  if cp < 0x80 then Buffer.add_char b (Char.chr cp)
  else if cp < 0x800 then begin
    Buffer.add_char b (Char.chr (0xC0 lor (cp lsr 6)));
    Buffer.add_char b (Char.chr (0x80 lor (cp land 0x3F)))
  end else if cp < 0x10000 then begin
    Buffer.add_char b (Char.chr (0xE0 lor (cp lsr 12)));
    Buffer.add_char b (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (cp land 0x3F)))
  end else begin
    Buffer.add_char b (Char.chr (0xF0 lor (cp lsr 18)));
    Buffer.add_char b (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (cp land 0x3F)))
  end;
  Buffer.contents b

(* Render an ASCII numeral through the active script.  Only the digits change:
   the sign, the decimal point, brackets and separators stay ASCII. *)
let to_script s =
  if !numeral_base = 0x30 then s
  else begin
    let b = Buffer.create (String.length s * 2) in
    String.iter (fun c ->
        if c >= '0' && c <= '9' then
          Buffer.add_string b (utf8_encode (!numeral_base + (Char.code c - 48)))
        else Buffer.add_char b c) s;
    Buffer.contents b
  end

(* The inverse: fold any script's digits back to ASCII so a literal or a
   `#|"४२"|` parses like its ASCII spelling. *)
let normalize_digits s =
  let n = String.length s in
  if n = 0 then s
  else begin
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      let c = String.unsafe_get s !i in
      if Char.code c < 0x80 then begin Buffer.add_char b c; incr i end
      else begin
        let start = !i in
        incr i;
        while !i < n && is_cont (String.unsafe_get s !i) do incr i done;
        let ch = String.sub s start (!i - start) in
        let cp =
          let b0 = Char.code ch.[0] in
          if b0 < 0xE0 then ((b0 land 0x1F) lsl 6) lor (Char.code ch.[1] land 0x3F)
          else if b0 < 0xF0 then
            ((b0 land 0x0F) lsl 12) lor ((Char.code ch.[1] land 0x3F) lsl 6)
            lor (Char.code ch.[2] land 0x3F)
          else
            ((b0 land 0x07) lsl 18) lor ((Char.code ch.[1] land 0x3F) lsl 12)
            lor ((Char.code ch.[2] land 0x3F) lsl 6) lor (Char.code ch.[3] land 0x3F)
        in
        match base_of_cp cp with
        | Some base when base <> 0x30 -> Buffer.add_char b (Char.chr (48 + cp - base))
        | _ -> Buffer.add_string b ch
      end
    done;
    Buffer.contents b
  end

(* Display width in terminal columns, which is not the character count: CJK
   ideographs, Hangul and most emoji occupy two columns each.  `std/term` is
   about layout, so it measures this rather than `$#`. *)
let is_wide cp =
  (cp >= 0x1100 && cp <= 0x115F)      (* Hangul Jamo                *)
  || (cp >= 0x2E80 && cp <= 0x303E)   (* CJK radicals, punctuation  *)
  || (cp >= 0x3041 && cp <= 0x33FF)   (* kana, CJK compatibility    *)
  || (cp >= 0x3400 && cp <= 0x4DBF)   (* CJK ext A                  *)
  || (cp >= 0x4E00 && cp <= 0x9FFF)   (* CJK unified                *)
  || (cp >= 0xA000 && cp <= 0xA4CF)   (* Yi                         *)
  || (cp >= 0xAC00 && cp <= 0xD7A3)   (* Hangul syllables           *)
  || (cp >= 0xF900 && cp <= 0xFAFF)   (* CJK compatibility ideogr.  *)
  || (cp >= 0xFE30 && cp <= 0xFE6F)   (* CJK compatibility forms    *)
  || (cp >= 0xFF00 && cp <= 0xFF60)   (* fullwidth forms            *)
  || (cp >= 0xFFE0 && cp <= 0xFFE6)
  || (cp >= 0x1F300 && cp <= 0x1F64F) (* emoji                      *)
  || (cp >= 0x1F900 && cp <= 0x1F9FF)
  || (cp >= 0x20000 && cp <= 0x3FFFD) (* CJK ext B and beyond       *)

(* ----------------------------------------------------------------- display *)

(* Inside a collection, Unit renders as `()`; on its own it renders as nothing.
   `>> ()` prints an empty line, but `[1, (), 3]` shows the hole. *)
let rec display_nested v =
  match v with Unit -> "()" | v -> display v

and display v =
  match v with
  | Int i -> to_script (string_of_int i)
  | Float f -> to_script (float_repr f)
  (* `#` stays ASCII so `#0` never looks like the integer zero. *)
  | Bool b -> "#" ^ to_script (if b then "1" else "0")
  | Str s -> s
  | Chr c -> c
  | Unit -> ""
  | Arr a ->
    let b = Buffer.create 32 in
    Buffer.add_char b '[';
    Array.iteri (fun i x ->
        if i > 0 then Buffer.add_string b ", ";
        Buffer.add_string b (display_nested x)) a;
    Buffer.add_char b ']';
    Buffer.contents b
  | Tup a ->
    let b = Buffer.create 32 in
    Buffer.add_char b '(';
    Array.iteri (fun i x ->
        if i > 0 then Buffer.add_string b ", ";
        Buffer.add_string b (display_nested x)) a;
    Buffer.add_char b ')';
    Buffer.contents b
  | NTup (names, vals) ->
    let b = Buffer.create 32 in
    Buffer.add_char b '(';
    Array.iteri (fun i x ->
        if i > 0 then Buffer.add_string b ", ";
        Buffer.add_string b names.(i);
        Buffer.add_string b ": ";
        Buffer.add_string b (display_nested x)) vals;
    Buffer.add_char b ')';
    Buffer.contents b
  | Err (kind, msg) -> Printf.sprintf "##%s(%s)" kind msg
  | Fun f -> Printf.sprintf "<funct/%d>" f.arity
  | Lam l -> Printf.sprintf "<lambd/%d>" l.lparams

let type_name = function
  | Int _ -> "integer" | Float _ -> "float" | Bool _ -> "bool"
  | Str _ -> "string" | Chr _ -> "char" | Arr _ -> "array"
  | Tup _ | NTup _ -> "tuple"
  | Fun _ -> "function" | Lam _ -> "lambda" | Err _ -> "error" | Unit -> "unit"

let type_symbol = function
  | Int _ -> "###" | Float _ -> "##." | Str _ -> "##\"" | Chr _ -> "##'"
  | Bool _ -> "##?" | Arr _ -> "##]" | Tup _ | NTup _ -> "##)"
  | Fun _ -> "##()" | Lam _ -> "##->" | Unit -> "##_"
  (* The type of an error *is* its kind: ##IO, ##Index, ##Div. *)
  | Err (kind, _) -> "##" ^ kind

(* `x#?` yields the triple (type symbol, size, value).  "Size" means whatever
   counts for that type: the rendered length for numbers and strings, the
   element count for aggregates, 1 for the single-valued types. *)
let type_meta v =
  let size = match v with
    (* Measured on the ASCII spelling: the size is a property of the number,
       not of the script it is currently displayed in. *)
    | Int i -> String.length (string_of_int i)
    | Float f -> String.length (float_repr f)
    | Str s -> String.length s
    | Chr _ | Bool _ -> 1
    | Arr a | Tup a -> Array.length a
    | NTup (_, v) -> Array.length v
    | Fun f -> f.arity
    | Lam l -> l.lparams
    (* Documented as "length of the error message" -- the message alone, not
       the ##Kind(...) rendering. *)
    | Err (_, msg) -> String.length msg
    | Unit -> 0
  in
  Tup [| Str (type_symbol v); Int size; v |]

(* ------------------------------------------------------------ value copying *)

(* Zymbol assignment has value semantics: `b = arr` copies, so a later
   `arr[1] = 99` leaves `b` untouched.  Scalars are immutable already, so only
   the aggregate constructors need a real copy. *)
let rec copy_val v =
  match v with
  | Arr a -> Arr (Array.map copy_val a)
  | Tup a -> Tup (Array.map copy_val a)
  | NTup (n, a) -> NTup (n, Array.map copy_val a)
  | _ -> v

(* ------------------------------------------------------------- truthiness *)

let as_bool = function
  | Bool b -> b
  | v -> err "expected bool, got %s" (type_name v)

(* --------------------------------------------------------------- numerics *)

(* A string that consists of digits participates in numeric comparison. *)
let numeric_of_string s =
  let s = normalize_digits s in
  match int_of_string_opt (String.trim s) with
  | Some i -> Some (Int i)
  | None -> (match float_of_string_opt (String.trim s) with
      | Some f -> Some (Float f)
      | None -> None)

let arith op_name fi ff a b =
  match a, b with
  | Int x, Int y -> fi x y
  | Int x, Float y -> ff (float_of_int x) y
  | Float x, Int y -> ff x (float_of_int y)
  | Float x, Float y -> ff x y
  | _ -> err "cannot apply %s to %s and %s" op_name (type_name a) (type_name b)

let add a b = arith "+" (fun x y -> Int (x + y)) (fun x y -> Float (x +. y)) a b
let sub a b = arith "-" (fun x y -> Int (x - y)) (fun x y -> Float (x -. y)) a b
let mul a b = arith "*" (fun x y -> Int (x * y)) (fun x y -> Float (x *. y)) a b

let div a b =
  match a, b with
  | _, Int 0 -> errk "Div" "division by zero"
  | Int x, Int y -> Int (x / y)
  | _ -> arith "/" (fun x y -> Int (x / y))
           (fun x y -> if y = 0.0 then errk "Div" "division by zero" else Float (x /. y)) a b

let md a b =
  match a, b with
  | _, Int 0 -> errk "Div" "modulo by zero"
  | Int x, Int y -> Int (x mod y)
  | _ -> arith "%" (fun x y -> Int (x mod y))
           (fun x y -> if y = 0.0 then errk "Div" "modulo by zero" else Float (Float.rem x y)) a b

let pow a b =
  match a, b with
  | Int x, Int y when y >= 0 ->
    let rec go acc b e = if e = 0 then acc else go (if e land 1 = 1 then acc * b else acc) (b * b) (e lsr 1) in
    Int (go 1 x y)
  | _ -> arith "^" (fun x y -> Int (int_of_float (Float.pow (float_of_int x) (float_of_int y))))
           (fun x y -> Float (Float.pow x y)) a b

let neg = function
  | Int i -> Int (-i)
  | Float f -> Float (-.f)
  | v -> err "cannot negate %s" (type_name v)

(* ------------------------------------------------------------- comparison *)

(* `==` never coerces across the string/number boundary, but Int and Float do
   compare numerically with each other. *)
let rec eq a b =
  match a, b with
  | Int x, Int y -> x = y
  | Float x, Float y -> x = y
  | Int x, Float y -> float_of_int x = y
  | Float x, Int y -> x = float_of_int y
  | Bool x, Bool y -> x = y
  | Str x, Str y -> String.equal x y
  | Chr x, Chr y -> String.equal x y
  (* A Char is never equal to a String, not even a one-character one:
     `"a" == 'a'` is `#0` in all three reference engines. *)
  | Unit, Unit -> true
  | Arr x, Arr y | Tup x, Tup y | NTup (_, x), NTup (_, y) ->
    Array.length x = Array.length y &&
    (let ok = ref true in
     Array.iteri (fun i v -> if !ok && not (eq v y.(i)) then ok := false) x;
     !ok)
  | _ -> false

(* Ordering: numeric when both sides are numbers (a digit-only string counts as
   a number), lexicographic when both sides are non-numeric text, an error when
   a number meets text that is not a number. *)
let cmp a b =
  let norm v = match v with
    | Str s -> (match numeric_of_string s with Some n -> `N n | None -> `T s)
    | Chr c -> `C c
    | Int _ | Float _ -> `N v
    | Bool x -> `B x
    | _ -> `X v
  in
  match norm a, norm b with
  | `N x, `N y ->
    (match x, y with
     | Int p, Int q -> compare p q
     | _ ->
       let f = function Int i -> float_of_int i | Float f -> f | _ -> 0.0 in
       compare (f x) (f y))
  | `T x, `T y -> compare x y
  | `C x, `C y -> compare x y
  | `T x, `C y | `C x, `T y -> compare x y
  | `B x, `B y -> compare x y
  | `N _, `T t | `T t, `N _ -> err "cannot compare string '%s' with a number" t
  | _ -> err "cannot compare %s with %s" (type_name a) (type_name b)

(* ----------------------------------------------------------- collections *)

(* Normalise a 1-based, possibly negative index against a length. *)
let real_index i len =
  let i = if i < 0 then len + i + 1 else i in
  if i = 0 then errk "Index" "index 0 is invalid - Zymbol uses 1-based indexing";
  if i < 1 || i > len then errk "Index" "index %d out of bounds (length %d)" i len;
  i - 1

let index_get container idx =
  match container, idx with
  | Arr a, Int i -> a.(real_index i (Array.length a))
  | Tup a, Int i -> a.(real_index i (Array.length a))
  | NTup (_, a), Int i -> a.(real_index i (Array.length a))
  | NTup (names, a), Str f ->
    (match Array.find_index (fun n -> String.equal n f) names with
     | Some k -> a.(k)
     | None -> errk "Index" "named tuple has no field '%s'" f)
  | Str s, Int i -> Chr (utf8_nth s i)
  | (Arr _ | Str _ | Tup _), v -> err "index must be an integer, got %s" (type_name v)
  | v, _ -> err "cannot index %s" (type_name v)

let length_of = function
  | Arr a | Tup a -> Array.length a
  | NTup (_, a) -> Array.length a
  | Str s -> utf8_length s
  | v -> err "cannot take length of %s" (type_name v)

(* `$+` — append for arrays, concatenation for strings. *)
let append coll v =
  match coll with
  | Arr a -> Arr (Array.append a [| copy_val v |])
  | Tup a -> Tup (Array.append a [| copy_val v |])
  | NTup (_, a) -> Tup (Array.append a [| copy_val v |])
  | Str s -> Str (s ^ display v)
  | c -> err "cannot append to %s" (type_name c)

(* --------------------------------------------------- collection primitives *)

(* Zymbol treats a string as a collection of characters, so every operator in
   this family has an array form and a string form. *)

let as_text v = match v with Str s -> s | Chr c -> c | v -> display v

(* Arrays and tuples share every element-wise operator; the rebuild function
   keeps each one in its own constructor. *)
let as_seq = function
  | Arr a -> Some (a, fun x -> Arr x)
  | Tup a -> Some (a, fun x -> Tup x)
  (* A named tuple keeps its labels only while the shape is unchanged; any
     operator that adds or drops elements degrades it to a positional tuple. *)
  | NTup (n, a) -> Some (a, fun x -> if Array.length x = Array.length n then NTup (n, x) else Tup x)
  | _ -> None

let str_find_all hay needle =
  if needle = "" then [] else begin
    let offs = utf8_offsets hay in
    let n = Array.length offs - 1 in
    let nl = String.length needle in
    let acc = ref [] in
    for k = n - 1 downto 0 do
      let b = offs.(k) in
      if b + nl <= String.length hay && String.sub hay b nl = needle then
        acc := (k + 1) :: !acc
    done;
    !acc
  end

let find_all coll v =
  match as_seq coll with
  | Some (a, _) ->
    let acc = ref [] in
    for i = Array.length a - 1 downto 0 do
      if eq a.(i) v then acc := Int (i + 1) :: !acc
    done;
    Arr (Array.of_list !acc)
  | None ->
    match coll with
    | Str s -> Arr (Array.of_list (List.map (fun i -> Int i) (str_find_all s (as_text v))))
    | c -> err "cannot search %s" (type_name c)

let insert_at coll i v =
  match as_seq coll with
  | Some (a, rebuild) ->
    let n = Array.length a in
    let i = if i < 0 then n + i + 2 else i in
    if i < 1 || i > n + 1 then err "insert index %d out of bounds (length %d)" i n;
    rebuild (Array.concat [ Array.sub a 0 (i - 1); [| copy_val v |];
                            Array.sub a (i - 1) (n - i + 1) ])
  | None ->
  match coll with
  | Str s ->
    let offs = utf8_offsets s in
    let n = Array.length offs - 1 in
    let i = if i < 0 then n + i + 2 else i in
    if i < 1 || i > n + 1 then err "insert index %d out of bounds (length %d)" i n;
    Str (String.sub s 0 offs.(i - 1) ^ as_text v
         ^ String.sub s offs.(i - 1) (String.length s - offs.(i - 1)))
  | c -> err "cannot insert into %s" (type_name c)

(* `$-` removes the first match, `$--` every match. *)
let remove_value coll v ~all =
  match as_seq coll with
  | Some (a, rebuild) ->
    let done_ = ref false in
    rebuild (Array.of_list (List.filter (fun x ->
        if (all || not !done_) && eq x v then begin done_ := true; false end else true)
        (Array.to_list a)))
  | None ->
  match coll with
  | Str s ->
    let needle = as_text v in
    if needle = "" then Str s
    else begin
      let b = Buffer.create (String.length s) in
      let nl = String.length needle in
      let i = ref 0 and stop = ref false in
      while !i < String.length s do
        if (not !stop) && !i + nl <= String.length s && String.sub s !i nl = needle then begin
          i := !i + nl;
          if not all then stop := true
        end else begin Buffer.add_char b s.[!i]; incr i end
      done;
      Str (Buffer.contents b)
    end
  | c -> err "cannot remove from %s" (type_name c)

let remove_range coll a b =
  match as_seq coll with
  | Some (arr, rebuild) ->
    let n = Array.length arr in
    let norm i = if i < 0 then n + i + 1 else i in
    let a = norm a and b = norm b in
    (* A count of 0 yields an empty range, which removes nothing. *)
    if a > b then rebuild (Array.copy arr)
    else begin
      if a < 1 || b > n then err "remove range %d..%d out of bounds (length %d)" a b n;
      rebuild (Array.append (Array.sub arr 0 (a - 1)) (Array.sub arr b (n - b)))
    end
  | None ->
  match coll with
  | Str s ->
    let offs = utf8_offsets s in
    let n = Array.length offs - 1 in
    let norm i = if i < 0 then n + i + 1 else i in
    let a = norm a and b = norm b in
    if a > b then Str s
    else begin
      if a < 1 || b > n then err "remove range %d..%d out of bounds (length %d)" a b n;
      Str (String.sub s 0 offs.(a - 1) ^ String.sub s offs.(b) (String.length s - offs.(b)))
    end
  | c -> err "cannot remove from %s" (type_name c)

let sort_coll v ~asc =
  match v with
  | Arr a ->
    let b = Array.copy a in
    Array.stable_sort (fun x y -> if asc then cmp x y else cmp y x) b;
    Arr b
  | c -> err "cannot sort %s" (type_name c)

let split_str v sep =
  let s = as_text v and sep = as_text sep in
  if sep = "" then err "split separator must not be empty";
  let parts = ref [] and b = Buffer.create 16 in
  let sl = String.length sep in
  let i = ref 0 in
  while !i < String.length s do
    if !i + sl <= String.length s && String.sub s !i sl = sep then begin
      parts := Buffer.contents b :: !parts; Buffer.clear b; i := !i + sl
    end else begin Buffer.add_char b s.[!i]; incr i end
  done;
  parts := Buffer.contents b :: !parts;
  Arr (Array.of_list (List.rev_map (fun x -> Str x) !parts))

let repeat_str v n =
  if n < 0 then err "repeat count must not be negative";
  let s = as_text v in
  let b = Buffer.create (String.length s * n) in
  for _ = 1 to n do Buffer.add_string b s done;
  Str (Buffer.contents b)

let replace_str v pat rep limit =
  let s = as_text v and pat = as_text pat and rep = as_text rep in
  if pat = "" then Str s
  else begin
    let b = Buffer.create (String.length s) in
    let pl = String.length pat in
    let i = ref 0 and count = ref 0 in
    while !i < String.length s do
      let can = match limit with Some k -> !count < k | None -> true in
      if can && !i + pl <= String.length s && String.sub s !i pl = pat then begin
        Buffer.add_string b rep; i := !i + pl; incr count
      end else begin Buffer.add_char b s.[!i]; incr i end
    done;
    Str (Buffer.contents b)
  end

(* `$++` grows a base: a string collects rendered items, an array collects
   elements. *)
let build base items =
  match base with
  | Arr a -> Arr (Array.append a (Array.of_list (List.map copy_val items)))
  | b ->
    let buf = Buffer.create 64 in
    Buffer.add_string buf (display b);
    List.iter (fun v -> Buffer.add_string buf (display v)) items;
    Str (Buffer.contents buf)

(* --------------------------------------------------------- casts and format *)

let to_float = function
  | Int i -> Float (float_of_int i)
  | Float f -> Float f
  | Str s -> (match numeric_of_string s with
      | Some (Int i) -> Float (float_of_int i)
      | Some (Float f) -> Float f
      | _ -> err "cannot convert '%s' to float" s)
  | v -> err "cannot convert %s to float" (type_name v)

(* Zymbol rounds half *away from zero*, which is what Float.round does. *)
let to_int_round = function
  | Int i -> Int i
  | Float f -> Int (int_of_float (Float.round f))
  | Str s -> (match numeric_of_string s with
      | Some (Int i) -> Int i
      | Some (Float f) -> Int (int_of_float (Float.round f))
      | _ -> err "cannot convert '%s' to integer" s)
  | v -> err "cannot convert %s to integer" (type_name v)

(* Decode the first UTF-8 character of [s] to its code point. *)
let codepoint_of s =
  if String.length s = 0 then err "empty character";
  let b0 = Char.code s.[0] in
  if b0 < 0x80 then b0
  else if b0 < 0xE0 then ((b0 land 0x1F) lsl 6) lor (Char.code s.[1] land 0x3F)
  else if b0 < 0xF0 then
    ((b0 land 0x0F) lsl 12) lor ((Char.code s.[1] land 0x3F) lsl 6)
    lor (Char.code s.[2] land 0x3F)
  else
    ((b0 land 0x07) lsl 18) lor ((Char.code s.[1] land 0x3F) lsl 12)
    lor ((Char.code s.[2] land 0x3F) lsl 6) lor (Char.code s.[3] land 0x3F)

(* Total display width of a string, in terminal columns. *)
let display_width s =
  Array.fold_left (fun acc ch ->
      acc + (if is_wide (codepoint_of ch) then 2 else 1)) 0 (utf8_chars s)

let to_int_trunc = function
  | Int i -> Int i
  | Float f -> Int (int_of_float (Float.trunc f))
  | Chr c -> Int (codepoint_of c)          (* the only Char -> Int route *)
  | Str s -> (match numeric_of_string s with
      | Some (Int i) -> Int i
      | Some (Float f) -> Int (int_of_float (Float.trunc f))
      | _ -> err "cannot convert '%s' to integer" s)
  | v -> err "cannot convert %s to integer" (type_name v)

(* `#|x|` — parse a string to a number, returning the input untouched on
   failure rather than raising. *)
let numeric_eval = function
  | Str s -> (match numeric_of_string s with Some n -> n | None -> Str s)
  | Chr c -> (match numeric_of_string c with Some n -> n | None -> Chr c)
  | v -> v

let as_number what = function
  | Int i -> float_of_int i
  | Float f -> f
  | Str s -> (match numeric_of_string s with
      | Some (Int i) -> float_of_int i
      | Some (Float f) -> f
      | _ -> err "%s expects a number, got '%s'" what s)
  | v -> err "%s expects a number, got %s" what (type_name v)

let round_to f n =
  let m = Float.pow 10.0 (float_of_int n) in
  Float.round (f *. m) /. m

let trunc_to f n =
  let m = Float.pow 10.0 (float_of_int n) in
  Float.trunc (f *. m) /. m

(* Group the integer part in threes: 1234567 -> "1,234,567". *)
let comma_group s =
  let neg = String.length s > 0 && s.[0] = '-' in
  let s = if neg then String.sub s 1 (String.length s - 1) else s in
  let ip, fp = match String.index_opt s '.' with
    | None -> s, ""
    | Some i -> String.sub s 0 i, String.sub s i (String.length s - i)
  in
  let b = Buffer.create (String.length ip + 8) in
  let n = String.length ip in
  String.iteri (fun i c ->
      if i > 0 && (n - i) mod 3 = 0 then Buffer.add_char b ',';
      Buffer.add_char b c) ip;
  (if neg then "-" else "") ^ Buffer.contents b ^ fp

(* `#^|x|` — mantissa in [1,10) and a bare exponent: 12345.678 -> 1.2345678e4. *)
let scientific f prec =
  if f = 0.0 then "0e0"
  else begin
    (* log10 is off by one at exact powers of ten (log10 1e5 = 4.999...), so the
       mantissa is renormalised into [1,10) afterwards. *)
    let e = ref (int_of_float (Float.floor (Float.log10 (Float.abs f)))) in
    let m = ref (f /. Float.pow 10.0 (float_of_int !e)) in
    if Float.abs !m >= 10.0 then begin incr e; m := f /. Float.pow 10.0 (float_of_int !e) end
    else if Float.abs !m < 1.0 then begin decr e; m := f /. Float.pow 10.0 (float_of_int !e) end;
    let m = match prec with
      | `None -> !m
      | `Round n -> round_to !m n
      | `Trunc n -> trunc_to !m n
    in
    (* Rounding can push the mantissa back out of range: #^.1|99999.0| rounds
       9.9999 to 10.0, which must be reported as 1.0e5, not 10.0e4. *)
    let m = if Float.abs m >= 10.0 then begin incr e; m /. 10.0 end else m in
    (* The mantissa is rendered like Rust's `{:?}`, which always keeps a
       fractional part: 1.0e5, never 1e5. *)
    let ms = float_repr m in
    let ms = if String.contains ms '.' then ms else ms ^ ".0" in
    ms ^ "e" ^ string_of_int !e
  end

(* `0x|255|` renders a number as a base-prefixed string.  Hex and decimal are
   zero-padded to at least four digits; binary and octal are not. *)
let base_conv base v =
  let n = match v with
    | Int i -> i
    | Float f -> int_of_float f
    | Chr c -> codepoint_of c
    | Str s -> (match numeric_of_string s with
        | Some (Int i) -> i | Some (Float f) -> int_of_float f
        | _ -> err "cannot convert '%s' to a number" s)
    | v -> err "cannot convert %s to a number" (type_name v)
  in
  let digits =
    match base with
    | 'x' -> Printf.sprintf "%04X" n
    | 'd' -> Printf.sprintf "%04d" n
    | 'o' -> Printf.sprintf "%o" n
    | 'b' ->
      if n = 0 then "0"
      else begin
        let b = Buffer.create 64 in
        let rec go k = if k > 0 then begin go (k lsr 1); Buffer.add_char b (if k land 1 = 1 then '1' else '0') end in
        go n; Buffer.contents b
      end
    | c -> err "unknown base '%c'" c
  in
  Str (Printf.sprintf "0%c%s" base digits)

(* `person.name` -- the only way to read a named tuple by label. *)
let field_get v name =
  match v with
  | NTup (names, vals) ->
    (match Array.find_index (fun n -> String.equal n name) names with
     | Some k -> vals.(k)
     | None -> errk "Index" "named tuple has no field '%s'" name)
  | v -> errk "Type" "cannot read field '%s' of %s" name (type_name v)

(* `>>?` — the terminal's [rows, cols].

   OCaml exposes no ioctl, so the size comes from `stty size`, which reads
   TIOCGWINSZ for us.  With no terminal there is nothing to measure and the
   answer is the conventional [24, 80]: a layout written against `>>?` stays
   runnable when its output is piped, it just lays itself out for 80 columns. *)
let term_size () =
  let default = Arr [| Int 24; Int 80 |] in
  if not (Unix.isatty Unix.stdout) then default
  else
    match Unix.open_process_in "stty size 2>/dev/null" with
    | ic ->
      let line = try input_line ic with End_of_file -> "" in
      ignore (Unix.close_process_in ic);
      (match String.split_on_char ' ' (String.trim line) with
       | [ r; c ] ->
         (match int_of_string_opt r, int_of_string_opt c with
          | Some r, Some c -> Arr [| Int r; Int c |]
          | _ -> default)
       | _ -> default)
    | exception _ -> default

(* ------------------------------------------------------------- key input *)

(* `<<|` and `<<|?` read a single keypress, which needs the terminal out of
   canonical mode: no line buffering, no echo.  The saved attributes are
   restored on every path, because leaving a shell in raw mode makes it appear
   to have hung. *)

let saved_termios : Unix.terminal_io option ref = ref None

let enter_raw () =
  if not (Unix.isatty Unix.stdin) then
    errk "IO" "Failed to initialize input reader";
  if !saved_termios = None then begin
    let t = Unix.tcgetattr Unix.stdin in
    saved_termios := Some t;
    let raw = { t with Unix.c_icanon = false; c_echo = false;
                       c_vmin = 1; c_vtime = 0 } in
    Unix.tcsetattr Unix.stdin Unix.TCSANOW raw
  end

let leave_raw () =
  match !saved_termios with
  | Some t -> Unix.tcsetattr Unix.stdin Unix.TCSANOW t; saved_termios := None
  | None -> ()

(* Arrow keys arrive as `ESC [ A`..`D` and come back as the arrow glyphs
   themselves — which is what leaves every ASCII letter free for commands. *)
let arrow_of = function
  | 'A' -> "\xe2\x86\x91"        (* ↑ *)
  | 'B' -> "\xe2\x86\x93"        (* ↓ *)
  | 'C' -> "\xe2\x86\x92"        (* → *)
  | 'D' -> "\xe2\x86\x90"        (* ← *)
  | c -> String.make 1 c

let byte_ready () =
  match Unix.select [ Unix.stdin ] [] [] 0.0 with
  | [ _ ], _, _ -> true
  | _ -> false

let read_byte () =
  let b = Bytes.create 1 in
  if Unix.read Unix.stdin b 0 1 = 1 then Some (Bytes.get b 0) else None

(* One keypress as a Char.  [blocking] false polls and yields '\000' when
   nothing is pending. *)
let read_key ~blocking : value =
  enter_raw ();
  let finish s = Chr s in
  if (not blocking) && not (byte_ready ()) then finish "\000"
  else
    match read_byte () with
    | None -> finish "\000"
    | Some '\027' ->
      (* Escape alone, or the start of an arrow sequence: only a byte that is
         already waiting continues it, so a bare Escape does not block. *)
      if byte_ready () then begin
        match read_byte () with
        | Some '[' ->
          (match read_byte () with
           | Some c -> finish (arrow_of c)
           | None -> finish "\027")
        | _ -> finish "\027"
      end else finish "\027"
    | Some '\r' -> finish "\n"
    | Some c when Char.code c < 0x80 -> finish (String.make 1 c)
    | Some c ->
      (* A multi-byte character: pull its continuation bytes. *)
      let b = Buffer.create 4 in
      Buffer.add_char b c;
      let extra =
        let x = Char.code c in
        if x land 0xE0 = 0xC0 then 1 else if x land 0xF0 = 0xE0 then 2 else 3
      in
      for _ = 1 to extra do
        match read_byte () with Some k -> Buffer.add_char b k | None -> ()
      done;
      finish (Buffer.contents b)

(* ---------------------------------------------------------------- output *)

let out_buf = Buffer.create 65536

let emit s =
  Buffer.add_string out_buf s;
  if Buffer.length out_buf > 32768 then begin
    print_string (Buffer.contents out_buf);
    Buffer.clear out_buf
  end

let flush_out () =
  if Buffer.length out_buf > 0 then begin
    print_string (Buffer.contents out_buf);
    Buffer.clear out_buf
  end;
  flush stdout
