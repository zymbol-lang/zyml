(* Closure compilation.

   Instead of walking the AST at run time, the whole program is compiled once
   into a tree of OCaml closures: an expression becomes a [frame -> value], a
   statement a [frame -> unit].  Every dispatch that a tree-walker repeats on
   each visit -- "which node is this?", "where does this name live?" -- happens
   here exactly once.

   Two decisions carry most of the speedup:

   * Lexical addressing.  Names are resolved at compile time to an integer slot
     in a flat frame, so a variable read is one array load instead of a hash
     lookup up a scope chain.
   * Structural specialisation.  Statement sequences, loop bodies that cannot
     break, and calls to a statically known function each get a shape that
     drops the work they do not need. *)

open Ast
open Value

(* --------------------------------------------------------------- contexts *)

type binding = { slot : int; is_const : bool }

(* One [ctx] per compilation unit: the top level, a named function body, or a
   lambda body.  [parent] is set only for lambdas -- named functions have
   isolated scope and never reach outward. *)
(* A loaded module.  Identity is the canonical file path, not the alias: two
   aliases for the same file, or two importers reaching it by different routes,
   share one [mstate] and therefore one counter, one cache, one anything. *)
type modul = {
  mname : string;
  mstate : value array;                                (* live, persistent *)
  mconsts : (string, int) Hashtbl.t;                   (* public name -> mstate slot *)
  mfuncs : (string, funcval) Hashtbl.t;                (* public name -> function *)
}

type ctx = {
  mutable scopes : (string, binding) Hashtbl.t list;   (* innermost first *)
  mutable nslots : int;
  parent : ctx option;
  mutable capmap : (string * int) list;                (* name -> capture index *)
  mutable capget : code list;                          (* reversed; reads parent frame *)
  mutable ncaps : int;
  (* Set inside a module: the module's own names, and the modules it imported.
     Shared by reference with every function compiled in that module, which is
     how a module function sees state the module body declared. *)
  mscope : (string, int * bool) Hashtbl.t option;   (* name -> slot, is_const *)
  (* For `°`: each entry is (the loop's own scope, the scope just above it).
     `x°` anchors to the first, `°x` to the second, which is the whole
     difference between dying with the loop and surviving it. *)
  mutable loops : ((string, binding) Hashtbl.t * (string, binding) Hashtbl.t) list;
  mimports : (string, modul) Hashtbl.t;
}

type resolved =
  | RSlot of int
  | RCap of int
  | RMod of int                                        (* slot in fr.mstate *)
  | RConst of value ref
  | RFunc of funcval
  | RNone

exception Compile_error of string

let cerr fmt = Printf.ksprintf (fun s -> raise (Compile_error s)) fmt

(* Top-level constants are visible everywhere, including inside functions at
   any call depth; named functions live in their own table. *)
let globals : (string, value ref) Hashtbl.t = Hashtbl.create 32
let funcs : (string, funcval) Hashtbl.t = Hashtbl.create 32

(* Loaded modules, keyed by canonical path — the cache that makes module state
   per file rather than per import. *)
let modules : (string, modul) Hashtbl.t = Hashtbl.create 8

(* Directory of the file currently being compiled; import paths are relative
   to it, so it is saved and restored around each nested module. *)
let cur_dir = ref "."

let new_ctx ?mscope ?mimports parent = {
  scopes = [ Hashtbl.create 16 ]; nslots = 0; parent;
  capmap = []; capget = []; ncaps = 0;
  mscope;
  mimports = (match mimports with Some t -> t | None -> Hashtbl.create 4);
  loops = [];
}

let push_scope c = c.scopes <- Hashtbl.create 8 :: c.scopes
let pop_scope c = match c.scopes with _ :: t -> c.scopes <- t | [] -> ()

let declare ?(is_const = false) c name =
  let slot = c.nslots in
  c.nslots <- c.nslots + 1;
  Hashtbl.replace (List.hd c.scopes) name { slot; is_const };
  slot

(* Declare into a specific scope rather than the innermost one -- what `°`
   needs, since it names the scope it wants. *)
let declare_in c tbl name =
  match Hashtbl.find_opt tbl name with
  | Some b -> b.slot
  | None ->
    let slot = c.nslots in
    c.nslots <- c.nslots + 1;
    Hashtbl.replace tbl name { slot; is_const = false };
    slot

(* Where a hot variable lives.  Outside any loop both forms anchor to the
   function (or global) scope, which is the outermost one. *)
let hot_scope c prefix =
  match c.loops with
  | (own, above) :: _ -> if prefix then above else own
  | [] -> List.nth c.scopes (List.length c.scopes - 1)

let lookup_local c name =
  let rec go = function
    | [] -> None
    | h :: t -> (match Hashtbl.find_opt h name with Some b -> Some b | None -> go t)
  in
  go c.scopes

let rec resolve c name : resolved =
  match lookup_local c name with
  | Some b -> RSlot b.slot
  | None ->
    match List.assoc_opt name c.capmap with
    | Some i -> RCap i
    | None ->
      (* A lambda closes over its defining scope; a function does not. *)
      let from_parent =
        match c.parent with
        | None -> RNone
        | Some par ->
          (match resolve par name with
           | RSlot i -> Some (fun (fr : frame) -> Array.unsafe_get fr.slots i)
           | RCap i -> Some (fun (fr : frame) -> Array.unsafe_get fr.caps i)
           | _ -> None)
          |> (function
              | None -> RNone
              | Some getter ->
                let idx = c.ncaps in
                c.ncaps <- idx + 1;
                c.capmap <- (name, idx) :: c.capmap;
                c.capget <- getter :: c.capget;
                RCap idx)
      in
      match from_parent with
      | RNone ->
        (* Module state comes before the globals: inside a module, its own
           names win, and the importing script's constants are never visible. *)
        (match c.mscope with
         | Some ms when Hashtbl.mem ms name -> RMod (fst (Hashtbl.find ms name))
         | _ ->
           match Hashtbl.find_opt globals name with
           | Some r -> RConst r
           | None -> (match Hashtbl.find_opt funcs name with
               | Some f -> RFunc f
               | None -> RNone))
      | r -> r

(* ------------------------------------------------------------- copy rules *)

(* Assignment has value semantics, but most expressions already produce a fresh
   aggregate.  Only the ones that can hand back a value someone else still
   holds need a defensive copy. *)
let rec needs_copy = function
  | Var _ | Index _ | Call _ | Slice _ -> true
  | TupLit es | ArrLit es -> List.exists needs_copy es
  | _ -> false

(* ------------------------------------------------------------ expressions *)

let bin_fn = function
  | Add -> add | Sub -> sub | Mul -> mul | Div -> div | Mod -> md | Pow -> pow
  | Eq -> (fun a b -> Bool (eq a b))
  | Neq -> (fun a b -> Bool (not (eq a b)))
  | Lt -> (fun a b -> Bool (cmp a b < 0))
  | Gt -> (fun a b -> Bool (cmp a b > 0))
  | Le -> (fun a b -> Bool (cmp a b <= 0))
  | Ge -> (fun a b -> Bool (cmp a b >= 0))
  | And | Or -> assert false                            (* short-circuited below *)

(* A slice tolerates a start of 0 and reads it as 1 -- unlike `arr[0]`, which is
   an error.  Verified against the reference engine, which treats `s$[0..5]` and
   `s$[1..5]` as the same slice. *)
let slice_val v a b =
  let a = if a = 0 then 1 else a in
  match as_seq v with
  | Some (arr, rebuild) ->
    let n = Array.length arr in
    let norm i = if i < 0 then n + i + 1 else i in
    let a = norm a and b = norm b in
    if a < 1 || b > n || a > b then rebuild [||]
    else rebuild (Array.sub arr (a - 1) (b - a + 1))
  | None ->
    match v with
    | Str s -> Str (utf8_slice s a b)
    | v -> err "cannot slice %s" (type_name v)

let int_arg what = function
  | Int i -> i
  | v -> err "%s must be an integer, got %s" what (type_name v)

let contains_val coll v =
  match as_seq coll with
  | Some (a, _) -> Array.exists (fun x -> eq x v) a
  | None ->
  match coll with
  | Str s ->
    let needle = display v in
    let nl = String.length needle and sl = String.length s in
    nl <= sl && (let found = ref false in
                 for i = 0 to sl - nl do
                   if not !found && String.sub s i nl = needle then found := true
                 done; !found)
  | c -> err "cannot search %s" (type_name c)

(* The identity of the operator -- except for `^`, whose neutral is 0 and not
   1.  The reference engine agrees, and warns about it: `x° ^= 3` is 0^3, so
   the result is always 0. *)
let neutral_of_op = function
  | Mul | Div -> Int 1
  | _ -> Int 0

(* Resolve the slot a hot variable names.  If one is already visible, `°`
   reuses it -- `acc° = 0` outside a loop and `acc° += i` inside are the same
   variable.  Only a genuinely new name gets a slot, and then in the scope the
   sigil's position asks for. *)
let hot_slot (c : ctx) prefix name =
  match resolve c name with
  | RSlot i -> i
  | _ -> declare_in c (hot_scope c prefix) name

let rec comp_hot (c : ctx) prefix name (neutral : value) : code =
  let i = hot_slot c prefix name in
  fun fr -> (match Array.unsafe_get fr.slots i with Unit -> neutral | v -> v)

and comp_expr (c : ctx) (e : expr) : code =
  match e with
  | ILit i -> let v = Int i in fun _ -> v
  | FLit f -> let v = Float f in fun _ -> v
  | SLit s -> let v = Str s in fun _ -> v
  | CLit s -> let v = Chr s in fun _ -> v
  | BLit b -> let v = Bool b in fun _ -> v

  (* A hot variable reads as its neutral value until something writes to it.
     Resolving it lazily this way means no initialiser has to be emitted at the
     point where the scope opens. *)
  | Hot (prefix, name) -> comp_hot c prefix name (Int 0)

  | Var name ->
    (match resolve c name with
     | RSlot i -> fun fr -> Array.unsafe_get fr.slots i
     | RCap i -> fun fr -> Array.unsafe_get fr.caps i
     | RMod i -> fun fr -> Array.unsafe_get fr.mstate i
     | RConst r -> fun _ -> !r
     | RFunc f -> let v = Fun f in fun _ -> v
     | RNone -> cerr "undefined variable: '%s'" name)

  | Interp parts ->
    let ps = List.map (function
        | ILit_text t -> `T t
        | ILit_var n -> `V (comp_expr c (Var n))) parts in
    (* Constant-fold a string with no interpolation slots. *)
    if List.for_all (function `T _ -> true | _ -> false) ps then begin
      let s = String.concat "" (List.map (function `T t -> t | _ -> "") ps) in
      let v = Str s in fun _ -> v
    end else
      let ps = Array.of_list ps in
      fun fr ->
        let b = Buffer.create 32 in
        Array.iter (function
            | `T t -> Buffer.add_string b t
            | `V g -> Buffer.add_string b (display (g fr))) ps;
        Str (Buffer.contents b)

  | ArrLit items ->
    let cs = Array.of_list (List.map (comp_expr c) items) in
    fun fr -> Arr (Array.map (fun g -> copy_val (g fr)) cs)

  | TupLit items ->
    let cs = Array.of_list (List.map (comp_expr c) items) in
    fun fr -> Tup (Array.map (fun g -> copy_val (g fr)) cs)

  | Un (Neg, ILit i) -> let v = Int (-i) in fun _ -> v
  | Un (Neg, FLit f) -> let v = Float (-.f) in fun _ -> v
  | Un (Neg, x) -> let g = comp_expr c x in fun fr -> neg (g fr)
  | Un (Not, x) -> let g = comp_expr c x in fun fr -> Bool (not (as_bool (g fr)))

  (* The neutral value is the operator's identity, so it is known here and
     nowhere else: 0 for `+`, 1 for `*`, [] for `$+`, "" for juxtaposition. *)
  | Bin (op, Hot (px, n), b) when op <> And && op <> Or ->
    let ga = comp_hot c px n (neutral_of_op op) and gb = comp_expr c b in
    let f = bin_fn op in
    fun fr -> f (ga fr) (gb fr)
  | Append (Hot (px, n), v) ->
    let ga = comp_hot c px n (Arr [||]) and gv = comp_expr c v in
    fun fr -> append (ga fr) (gv fr)

  | Bin (And, a, b) ->
    let ga = comp_expr c a and gb = comp_expr c b in
    fun fr -> if as_bool (ga fr) then Bool (as_bool (gb fr)) else Bool false
  | Bin (Or, a, b) ->
    let ga = comp_expr c a and gb = comp_expr c b in
    fun fr -> if as_bool (ga fr) then Bool true else Bool (as_bool (gb fr))

  (* Specialised shapes for the overwhelmingly common `x <op> <int literal>`. *)
  | Bin (Add, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Int (x + k) | v -> add v (Int k))
  | Bin (Sub, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Int (x - k) | v -> sub v (Int k))
  | Bin (Lt, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Bool (x < k) | v -> Bool (cmp v (Int k) < 0))
  | Bin (Le, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Bool (x <= k) | v -> Bool (cmp v (Int k) <= 0))
  | Bin (Gt, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Bool (x > k) | v -> Bool (cmp v (Int k) > 0))
  | Bin (Ge, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Bool (x >= k) | v -> Bool (cmp v (Int k) >= 0))
  | Bin (Eq, a, ILit k) ->
    let ga = comp_expr c a in
    fun fr -> (match ga fr with Int x -> Bool (x = k) | v -> Bool (eq v (Int k)))

  | Bin (op, a, b) ->
    let ga = comp_expr c a and gb = comp_expr c b in
    let f = bin_fn op in
    (* Fold when both sides are constant -- but only when folding succeeds.
       `10 / 0` must still raise at run time, where a `!?` block can catch it,
       not while the program is being compiled. *)
    (match a, b with
     | (ILit _ | FLit _), (ILit _ | FLit _) ->
       let empty = { slots = [||]; caps = [||]; mstate = [||] } in
       (match f (ga empty) (gb empty) with
        | v -> fun _ -> v
        | exception Zy_error _ -> fun fr -> f (ga fr) (gb fr))
     | _ -> fun fr -> f (ga fr) (gb fr))

  | Index (base, idx) ->
    let gb = comp_expr c base and gi = comp_expr c idx in
    fun fr -> index_get (gb fr) (gi fr)

  | Len x -> let g = comp_expr c x in fun fr -> Int (length_of (g fr))
  | TypeOf x -> let g = comp_expr c x in fun fr -> type_meta (g fr)
  | Append (x, v) ->
    let gx = comp_expr c x and gv = comp_expr c v in
    fun fr -> append (gx fr) (gv fr)
  | Contains (x, v) ->
    let gx = comp_expr c x and gv = comp_expr c v in
    fun fr -> Bool (contains_val (gx fr) (gv fr))
  | Slice (x, a, b) ->
    let gx = comp_expr c x and ga = comp_expr c a and gb = comp_expr c b in
    let asint v = match v with Int i -> i | v -> err "slice bound must be an integer, got %s" (type_name v) in
    fun fr -> slice_val (gx fr) (asint (ga fr)) (asint (gb fr))

  | Lambda (params, body) -> comp_lambda c params body

  | Call (callee, args) -> comp_call c callee args

  (* ------------------------------------------- the rest of the `$` family *)

  | InsertAt (x, i, v) ->
    let gx = comp_expr c x and gi = comp_expr c i and gv = comp_expr c v in
    fun fr -> insert_at (gx fr) (int_arg "insert index" (gi fr)) (gv fr)
  | Remove (x, v) ->
    let gx = comp_expr c x and gv = comp_expr c v in
    fun fr -> remove_value (gx fr) (gv fr) ~all:false
  | RemoveAll (x, v) ->
    let gx = comp_expr c x and gv = comp_expr c v in
    fun fr -> remove_value (gx fr) (gv fr) ~all:true
  | RemoveAt (x, a, None) ->
    let gx = comp_expr c x and ga = comp_expr c a in
    fun fr -> let i = int_arg "remove index" (ga fr) in remove_range (gx fr) i i
  | RemoveAt (x, a, Some b) ->
    let gx = comp_expr c x and ga = comp_expr c a and gb = comp_expr c b in
    fun fr -> remove_range (gx fr) (int_arg "remove start" (ga fr))
                (int_arg "remove end" (gb fr))
  | FindAll (x, v) ->
    let gx = comp_expr c x and gv = comp_expr c v in
    fun fr -> find_all (gx fr) (gv fr)
  | Sort (x, asc) ->
    let gx = comp_expr c x in
    fun fr -> sort_coll (gx fr) ~asc
  | SortBy (x, f) ->
    let gx = comp_expr c x and gf = comp_expr c f in
    fun fr ->
      let cmpf = gf fr in
      (match gx fr with
       | Arr a ->
         let b = Array.copy a in
         (* The comparator answers "does x come before y?", so it yields only a
            strict order; ties keep their original position. *)
         Array.stable_sort (fun x y ->
             if as_bool (invoke cmpf [| x; y |]) then -1
             else if as_bool (invoke cmpf [| y; x |]) then 1
             else 0) b;
         Arr b
       | v -> err "cannot sort %s" (type_name v))
  | Map (x, f) ->
    let gx = comp_expr c x and gf = comp_expr c f in
    fun fr ->
      let fv = gf fr in
      (match gx fr with
       | Arr a -> Arr (Array.map (fun v -> invoke fv [| v |]) a)
       | Tup a -> Tup (Array.map (fun v -> invoke fv [| v |]) a)
       | Str s -> Arr (Array.map (fun ch -> invoke fv [| Chr ch |]) (utf8_chars s))
       | v -> err "cannot map over %s" (type_name v))
  | Filter (x, f) ->
    let gx = comp_expr c x and gf = comp_expr c f in
    fun fr ->
      let fv = gf fr in
      (match gx fr with
       | Arr a -> Arr (Array.of_list
                         (List.filter (fun v -> as_bool (invoke fv [| v |]))
                            (Array.to_list a)))
       | v -> err "cannot filter %s" (type_name v))
  | Reduce (x, init, f) ->
    let gx = comp_expr c x and gi = comp_expr c init and gf = comp_expr c f in
    fun fr ->
      let fv = gf fr and acc = ref (gi fr) in
      (match gx fr with
       | Arr a -> Array.iter (fun v -> acc := invoke fv [| !acc; v |]) a; !acc
       | v -> err "cannot reduce %s" (type_name v))
  | Split (x, sep) ->
    let gx = comp_expr c x and gs = comp_expr c sep in
    fun fr -> split_str (gx fr) (gs fr)
  | Repeat (x, n) ->
    let gx = comp_expr c x and gn = comp_expr c n in
    fun fr -> repeat_str (gx fr) (int_arg "repeat count" (gn fr))
  | Replace (x, pat, rep, lim) ->
    let gx = comp_expr c x and gp = comp_expr c pat and gr = comp_expr c rep in
    let gl = Option.map (comp_expr c) lim in
    fun fr ->
      let l = Option.map (fun g -> int_arg "replace limit" (g fr)) gl in
      replace_str (gx fr) (gp fr) (gr fr) l
  | Build (base, items) ->
    let gb = comp_expr c base and gs = Array.of_list (List.map (comp_expr c) items) in
    fun fr -> build (gb fr) (Array.to_list (Array.map (fun g -> g fr) gs))

  (* `arr[i]$~ v` is the functional update: it returns a modified copy and
     leaves the original alone, so the receiver must still be an index. *)
  | Update (Index (base, idx), v) ->
    let gb = comp_expr c base and gi = comp_expr c idx and gv = comp_expr c v in
    fun fr ->
      let target = copy_val (gb fr) in
      let key = gi fr in
      (match target, key with
       | Arr a, Int i -> a.(real_index i (Array.length a)) <- copy_val (gv fr); Arr a
       | Tup a, Int i -> a.(real_index i (Array.length a)) <- copy_val (gv fr); Tup a
       | NTup (n, a), Int i -> a.(real_index i (Array.length a)) <- copy_val (gv fr); NTup (n, a)
       (* A named tuple may also be addressed by field name, which is what makes
          `person["age"]$~ 26` work when the field is chosen at run time. *)
       | NTup (n, a), Str f ->
         (match Array.find_index (fun x -> String.equal x f) n with
          | Some k -> a.(k) <- copy_val (gv fr); NTup (n, a)
          | None -> errk "Index" "named tuple has no field '%s'" f)
       | x, _ -> err "cannot update %s" (type_name x))
  | Update _ -> cerr "'$~' needs an indexed target, as in arr[i]$~ value"

  (* ------------------------------------------------------- casts and format *)

  (* `>>?` — [rows, cols].  With no terminal attached there is nothing to
     measure, so it answers the conventional [24, 80] rather than failing: a
     layout written against `>>?` stays runnable when piped. *)
  | TermSize ->
    fun _ ->
      let default = Arr [| Int 24; Int 80 |] in
      if not (Unix.isatty Unix.stdout) then default
      else begin
        match int_of_string_opt (Sys.getenv_opt "LINES" |> Option.value ~default:""),
              int_of_string_opt (Sys.getenv_opt "COLUMNS" |> Option.value ~default:"") with
        | Some r, Some c when r > 0 && c > 0 -> Arr [| Int r; Int c |]
        | _ -> default
      end

  | Nav (base, spec) -> comp_nav c base spec

  (* `alias::fn(args)` resolves to the exported function at compile time, so a
     module call costs exactly what a local call costs. *)
  | ModCall (alias, fn, args) ->
    let m = find_module c alias in
    let n = List.length args in
    (* Overloads are rare but real (`math::log` takes one or two arguments), so
       the arity is part of the lookup, not a check after it. *)
    let candidates = Hashtbl.find_all m.mfuncs fn in
    (match List.find_opt (fun (f : funcval) -> f.arity = n) candidates, candidates with
     | None, [] -> cerr "module '%s' does not export a function '%s'" alias fn
     | None, (f :: _) ->
       cerr "'%s::%s' expects %d argument(s), got %d" alias fn f.arity n
     | Some f, _ ->
       let argc = Array.of_list (List.map (comp_expr c) args) in
       let writers = out_writers c f args (alias ^ "::" ^ fn) in
       fun fr ->
         let slots = Array.make (max f.fslots 1) Unit in
         for i = 0 to n - 1 do
           slots.(i) <- copy_val ((Array.unsafe_get argc i) fr)
         done;
         let r = (try f.fbody { slots; caps = [||]; mstate = f.fmstate }
                  with Zy_return v -> v) in
         List.iter (fun (i, w) -> w fr slots.(i)) writers;
         r)

  | ModConst (alias, name) ->
    let m = find_module c alias in
    (match Hashtbl.find_opt m.mconsts name with
     | None -> cerr "module '%s' has no constant '%s'" alias name
     | Some i -> let st = m.mstate in fun _ -> Array.unsafe_get st i)

  (* `alias.CONST` parses as a field access; only here can we tell whether the
     base is a module alias or a named tuple. *)
  | Field (Var base, name) when Hashtbl.mem c.mimports base ->
    comp_expr c (ModConst (base, name))

  | NTupLit fields ->
    let names = Array.of_list (List.map fst fields) in
    let cs = Array.of_list (List.map (fun (_, e) -> comp_expr c e) fields) in
    fun fr -> NTup (names, Array.map (fun g -> copy_val (g fr)) cs)
  | Field (e, name) ->
    let g = comp_expr c e in
    fun fr -> field_get (g fr) name
  | IsErr e ->
    let g = comp_expr c e in
    fun fr -> Bool (match g fr with Err _ -> true | _ -> false)
  (* `$!!` returns an error value to the caller immediately; a non-error passes
     straight through and execution continues. *)
  | PropE e ->
    let g = comp_expr c e in
    fun fr -> (match g fr with Err _ as v -> raise (Zy_return v) | v -> v)

  | Match (scrut, arms) ->
    let gs = comp_expr c scrut in
    let cs = Array.of_list (List.map (fun (pat, body) ->
        let test = comp_pattern c pat in
        let run = match body with
          | MExpr e -> let g = comp_expr c e in g
          | MBlock stmts ->
            push_scope c;
            let b = comp_block c stmts in
            pop_scope c;
            fun fr -> b fr; Unit
        in
        (test, run)) arms) in
    let n = Array.length cs in
    fun fr ->
      let v = gs fr in
      let rec go i =
        if i >= n then Unit
        else begin
          let (test, run) = Array.unsafe_get cs i in
          if test fr v then run fr else go (i + 1)
        end
      in
      go 0

  (* `<\ cmd \>` runs the command and yields its stdout, trailing newline
     stripped -- the shell's output flows inward as a string. *)
  | Shell e ->
    let g = comp_expr c e in
    fun fr ->
      let cmd = display (g fr) in
      let ic = Unix.open_process_in cmd in
      let b = Buffer.create 256 in
      (try
         while true do Buffer.add_channel b ic 1 done
       with End_of_file -> ());
      ignore (Unix.close_process_in ic);
      let out = Buffer.contents b in
      let len = String.length out in
      Str (if len > 0 && out.[len - 1] = '\n' then String.sub out 0 (len - 1) else out)

  | BaseConv (b, x) -> let g = comp_expr c x in fun fr -> base_conv b (g fr)
  | Concat items ->
    (* Juxtaposition builds a string, so a hot variable in it starts as "". *)
    let cs = Array.of_list (List.map (function
        | Hot (px, n) -> comp_hot c px n (Str "")
        | e -> comp_expr c e) items) in
    fun fr ->
      let buf = Buffer.create 64 in
      Array.iter (fun g -> Buffer.add_string buf (display (g fr))) cs;
      Str (Buffer.contents buf)

  | Cast (ToFloat, x) -> let g = comp_expr c x in fun fr -> to_float (g fr)
  | Cast (ToIntRound, x) -> let g = comp_expr c x in fun fr -> to_int_round (g fr)
  | Cast (ToIntTrunc, x) -> let g = comp_expr c x in fun fr -> to_int_trunc (g fr)

  | Fmt (FPlain, PNone, x) -> let g = comp_expr c x in fun fr -> numeric_eval (g fr)
  | Fmt (style, prec, x) ->
    let g = comp_expr c x in
    let apply f = match prec with
      | PNone -> f
      | PRound n -> round_to f n
      | PTrunc n -> trunc_to f n
    in
    (match style with
     | FPlain -> fun fr -> Float (apply (as_number "precision" (g fr)))
     (* `#,` renders a fixed number of decimals: #,.4|3141592.653| keeps the
        trailing zero as 3,141,592.6530. *)
     | FComma ->
       let render = match prec with
         | PNone -> fun f -> float_repr f
         | PRound n | PTrunc n -> fun f -> Printf.sprintf "%.*f" n f
       in
       fun fr -> Str (comma_group (render (apply (as_number "format" (g fr)))))
     | FSci ->
       let p = match prec with
         | PNone -> `None | PRound n -> `Round n | PTrunc n -> `Trunc n in
       fun fr -> Str (scientific (as_number "format" (g fr)) p))

(* -------------------------------------------------------------- modules *)

(* An output parameter writes back into the caller's variable after the call,
   so each one needs a store compiled against the *caller's* frame. *)
and out_writers c (f : funcval) args what =
  if Array.length f.outs = 0 then []
  else
    List.mapi (fun i a -> (i, a)) args
    |> List.filter (fun (i, _) -> Array.exists (fun s -> s = i) f.outs)
    |> List.map (fun (i, a) ->
        match a with
        | Var vn -> (i, comp_store c (LVar vn))
        | _ -> cerr "output parameter %d of '%s' needs a plain variable" (i + 1) what)

and find_module c alias =
  match Hashtbl.find_opt c.mimports alias with
  | Some m -> m
  | None -> cerr "no module is imported under the alias '%s'" alias

(* Resolve an import path against the importing file's directory and load it,
   reusing the cached module when the same file has already been loaded. *)
and load_module (path : string) : modul =
  if String.length path >= 4 && String.sub path 0 4 = "std/" then
    match Hashtbl.find_opt modules path with
    | Some m -> m
    | None ->
      (match Stdlib_zy.find path with
       | None ->
         cerr "the standard library module '%s' is not implemented in this engine" path
       | Some sm ->
         let mconsts = Hashtbl.create 4 and mfuncs = Hashtbl.create 32 in
         let mstate = Array.of_list (List.map snd sm.Stdlib_zy.sconsts) in
         List.iteri (fun i (n, _) -> Hashtbl.replace mconsts n i) sm.Stdlib_zy.sconsts;
         (* `add`, not `replace`: `math::log` exists at two arities and the call
            site picks by argument count. *)
         List.iter (fun (f : funcval) -> Hashtbl.add mfuncs f.fname f) sm.Stdlib_zy.sfuncs;
         let m = { mname = path; mstate; mconsts; mfuncs } in
         Hashtbl.replace modules path m;
         m)
  else
  let file =
    let p = if Filename.check_suffix path ".zy" then path else path ^ ".zy" in
    if Filename.is_relative p then Filename.concat !cur_dir p else p
  in
  let key =
    (* Canonicalise so `./a` and `../dir/a` reaching one file share its state. *)
    try Unix.realpath file with Unix.Unix_error _ ->
      cerr "module file not found: %s" file
  in
  match Hashtbl.find_opt modules key with
  | Some m -> m
  | None -> compile_module key

and compile_module (file : string) : modul =
  let src =
    let ic = open_in_bin file in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  in
  let prog =
    try Parser.parse (Lexer.tokenize src) with
    | Lexer.Lex_error (m, l) -> cerr "in %s: lex error: %s (line %d)" file m l
    | Parser.Parse_error (m, l) -> cerr "in %s: parse error: %s (line %d)" file m l
  in
  let name, body =
    match prog with
    | [ ModuleDecl (n, b) ] -> n, b
    | _ -> cerr "%s is not a module: a module file holds exactly one '# name { ... }'" file
  in
  let saved = !cur_dir in
  cur_dir := Filename.dirname file;

  let mscope = Hashtbl.create 16 in
  let mimports = Hashtbl.create 4 in
  let mconsts = Hashtbl.create 8 in
  let mfuncs = Hashtbl.create 8 in
  (* Registered before the body is compiled so a self-referential function, or
     one that runs during a nested import, sees the same module. *)
  let placeholder = { mname = name; mstate = [||]; mconsts; mfuncs } in
  Hashtbl.replace modules file placeholder;

  (* Pass 1: imports, and one mstate slot per declared name.  Declarations are
     collected before any body is compiled so that order inside the block does
     not matter -- the guide only *recommends* an ordering. *)
  let nstate = ref 0 in
  let declare_state ?(is_const = false) n =
    match Hashtbl.find_opt mscope n with
    | Some (i, _) -> i
    | None ->
      let i = !nstate in
      incr nstate;
      Hashtbl.replace mscope n (i, is_const);
      i
  in
  let exports = ref [] in
  List.iter (function
      | Import (path, alias) -> Hashtbl.replace mimports alias (load_module path)
      | Export items -> exports := !exports @ items
      | ConstDecl (n, _) -> ignore (declare_state ~is_const:true n)
      | Assign (LVar n, _) -> ignore (declare_state n)
      | _ -> ()) body;
  (* A re-exported constant needs a slot of its own, counted before the state
     array is sized. *)
  List.iter (fun it ->
      match it.esrc with
      | EReConst _ -> ignore (declare_state ("__re_" ^ it.epublic))
      | _ -> ()) !exports;

  let state = Array.make (max !nstate 1) Unit in
  let m = { mname = name; mstate = state; mconsts; mfuncs } in
  Hashtbl.replace modules file m;

  (* Pass 2: compile function bodies and the state initialisers. *)
  let mc = new_ctx ~mscope ~mimports None in
  let own_funcs : (string, funcval) Hashtbl.t = Hashtbl.create 8 in
  let inits = ref [] in
  List.iter (function
      | FuncDecl (fname, params, fbody) ->
        let arity = List.length params in
        let outs = List.mapi (fun i p -> (i, p.pout)) params
                   |> List.filter snd |> List.map fst |> Array.of_list in
        let fv = { fname; arity; fslots = arity; outs;
                   fbody = (fun _ -> Unit); fmstate = state } in
        Hashtbl.replace own_funcs fname fv;
        (* A module function is compiled against the module's scope, so it
           reads and writes module state directly. *)
        let fc = new_ctx ~mscope ~mimports None in
        (* Sibling functions must be visible regardless of definition order. *)
        Hashtbl.iter (fun k v -> Hashtbl.replace funcs k v) own_funcs;
        List.iter (fun p -> ignore (declare fc p.pname)) params;
        let b = comp_block fc fbody in
        fv.fslots <- fc.nslots;
        fv.fbody <- (fun fr -> b fr; Unit)
      | ConstDecl (n, e) | Assign (LVar n, e) ->
        let g = comp_expr mc e in
        let i = fst (Hashtbl.find mscope n) in
        inits := (fun () -> state.(i) <- copy_val (g { slots = [||]; caps = [||]; mstate = state })) :: !inits
      | Import _ | Export _ -> ()
      | _ -> cerr "in module '%s': only imports, exports, declarations and \
                   functions may appear at the module top level" name) body;
  List.iter (fun f -> f ()) (List.rev !inits);

  (* Pass 3: publish the exports.  A name not listed here stays private, and
     that includes mutable state, which is only reachable through getters. *)
  List.iter (fun it ->
      match it.esrc with
      | EOwn n ->
        (match Hashtbl.find_opt own_funcs n with
         | Some f -> Hashtbl.replace mfuncs it.epublic f
         | None ->
           match Hashtbl.find_opt mscope n with
           | Some (i, _) -> Hashtbl.replace mconsts it.epublic i
           | None -> cerr "module '%s' exports '%s', which it does not define" name n)
      | EReFun (alias, fn) ->
        (match Hashtbl.find_opt mimports alias with
         | None -> cerr "module '%s' re-exports from unknown alias '%s'" name alias
         | Some src ->
           match Hashtbl.find_opt src.mfuncs fn with
           | Some f -> Hashtbl.replace mfuncs it.epublic f
           | None -> cerr "'%s::%s' is not exported" alias fn)
      | EReConst (alias, cn) ->
        (match Hashtbl.find_opt mimports alias with
         | None -> cerr "module '%s' re-exports from unknown alias '%s'" name alias
         | Some src ->
           match Hashtbl.find_opt src.mconsts cn with
           (* A re-exported constant is copied: the two modules keep separate
              state arrays, and the value is immutable anyway. *)
           | Some i ->
             let j = fst (Hashtbl.find mscope ("__re_" ^ it.epublic)) in
             state.(j) <- src.mstate.(i);
             Hashtbl.replace mconsts it.epublic j
           | None -> cerr "'%s.%s' is not exported" alias cn))
    !exports;

  (* Module functions live in the module's own table, not the global one. *)
  Hashtbl.iter (fun k _ -> Hashtbl.remove funcs k) own_funcs;
  cur_dir := saved;
  m

(* ------------------------------------------------------------- patterns *)

(* A pattern compiles to a test `frame -> value -> bool` over the scrutinee.
   Two patterns change meaning with the scrutinee's runtime type, which is why
   the decision cannot be made here: an ident bound to an array tests
   containment rather than equality, and a list pattern matches structurally
   against an array but by containment against a scalar. *)
and comp_pattern (c : ctx) (pat : pattern) : (frame -> value -> bool) =
  match pat with
  | PWild -> fun _ _ -> true
  | PLit e -> let g = comp_expr c e in fun fr v -> eq v (g fr)
  | PRange (a, b) ->
    let ga = comp_expr c a and gb = comp_expr c b in
    fun fr v -> cmp v (ga fr) >= 0 && cmp v (gb fr) <= 0
  | PCmp (op, e) ->
    let g = comp_expr c e in
    let f = bin_fn op in
    fun fr v -> as_bool (f v (g fr))
  | PIdent name ->
    let g = comp_expr c (Var name) in
    fun fr v ->
      (match g fr with
       | Arr a -> Array.exists (fun x -> eq x v) a
       | bound -> eq v bound)
  | PList items ->
    let ts = Array.of_list (List.map (comp_pattern c) items) in
    let n = Array.length ts in
    fun fr v ->
      (match v with
       | Arr a ->
         Array.length a = n
         && (let ok = ref true in
             Array.iteri (fun i x -> if !ok && not ((Array.unsafe_get ts i) fr x) then ok := false) a;
             !ok)
       | scalar -> Array.exists (fun t -> t fr scalar) ts)
  | POr alts ->
    let ts = Array.of_list (List.map (comp_pattern c) alts) in
    fun fr v -> Array.exists (fun t -> t fr v) ts

(* --------------------------------------------------- multi-dim navigation *)

(* A compiled navigation step: read one index, or fan out over a range. *)
and comp_nav_step c = function
  | NIdx e -> let g = comp_expr c e in `I g
  | NRange (a, b) -> let ga = comp_expr c a and gb = comp_expr c b in `R (ga, gb)

(* Walk one path, pushing every reached value onto [acc].  Ranges fan out, and
   because the accumulator is flat, two ranges in one path yield four results
   side by side rather than a nested 2x2. *)
and walk_path fr steps v acc =
  match steps with
  | [] -> acc := v :: !acc
  | `I g :: rest -> walk_path fr rest (index_get v (g fr)) acc
  | `R (ga, gb) :: rest ->
    let a = int_arg "range start" (ga fr) and b = int_arg "range end" (gb fr) in
    (match slice_val v a b with
     | Arr xs -> Array.iter (fun x -> walk_path fr rest x acc) xs
     | x -> walk_path fr rest x acc)

and has_range steps = List.exists (function `R _ -> true | `I _ -> false) steps

(* A path with no range denotes exactly one value; with a range it denotes the
   collected sequence. *)
and run_path fr steps (v : value) : value =
  let acc = ref [] in
  walk_path fr steps v acc;
  if has_range steps then Arr (Array.of_list (List.rev !acc))
  else match !acc with [ x ] -> x | l -> Arr (Array.of_list (List.rev l))

(* Flat forms concatenate: a step that produced an array contributes its
   elements, a scalar contributes itself. *)
and flatten_into acc = function
  | Arr xs -> Array.iter (fun x -> acc := x :: !acc) xs
  | v -> acc := v :: !acc

and comp_nav c base spec : code =
  let gb = comp_expr c base in
  let path steps = List.map (comp_nav_step c) steps in
  match spec with
  | NPath steps ->
    let ss = path steps in
    fun fr -> run_path fr ss (gb fr)
  | NFlat paths ->
    let ps = List.map path paths in
    fun fr ->
      let v = gb fr and acc = ref [] in
      List.iter (fun s -> flatten_into acc (run_path fr s v)) ps;
      Arr (Array.of_list (List.rev !acc))
  | NStruct groups ->
    let gs = List.map (fun g -> List.map path g) groups in
    fun fr ->
      let v = gb fr in
      Arr (Array.of_list (List.map (fun g ->
          let acc = ref [] in
          List.iter (fun s -> flatten_into acc (run_path fr s v)) g;
          Arr (Array.of_list (List.rev !acc))) gs))

(* ---------------------------------------------------------------- lambdas *)

and comp_lambda (c : ctx) params body : code =
  let lc = new_ctx (Some c) in
  List.iter (fun p -> ignore (declare lc p)) params;
  let bodycode =
    match body with
    (* `$!!` inside an expression lambda raises a return; without this handler
       it would escape past the lambda to whatever called it. *)
    | LExpr e -> let g = comp_expr lc e in fun fr -> (try g fr with Zy_return v -> v)
    | LBlock stmts ->
      let s = comp_block lc stmts in
      fun fr -> (try s fr; Unit with Zy_return v -> v)
  in
  let nslots = lc.nslots in
  let nparams = List.length params in
  (* Captures are by value at creation time, so they are read out of the
     enclosing frame when the lambda value is built. *)
  let getters = Array.of_list (List.rev lc.capget) in
  fun fr ->
    Lam { lparams = nparams; lslots = nslots; lbody = bodycode;
          lcaps = Array.map (fun g -> copy_val (g fr)) getters;
          lmstate = fr.mstate }

(* ------------------------------------------------------------------ calls *)

and invoke (fv : value) (argv : value array) : value =
  match fv with
  | Fun f ->
    if Array.length argv <> f.arity then
      err "function '%s' expects %d argument(s), got %d" f.fname f.arity (Array.length argv);
    let slots = Array.make (max f.fslots 1) Unit in
    Array.blit argv 0 slots 0 (Array.length argv);
    let fr = { slots; caps = [||]; mstate = f.fmstate } in
    (try f.fbody fr with Zy_return v -> v)
  | Lam l ->
    if Array.length argv <> l.lparams then
      err "lambda expects %d argument(s), got %d" l.lparams (Array.length argv);
    let slots = Array.make (max l.lslots 1) Unit in
    Array.blit argv 0 slots 0 (Array.length argv);
    l.lbody { slots; caps = l.lcaps; mstate = l.lmstate }
  | v -> err "%s is not callable" (type_name v)

and comp_call (c : ctx) callee args : code =
  let argc = Array.of_list (List.map (comp_expr c) args) in
  let n = Array.length argc in
  match callee with
  (* Direct call to a statically known named function: no value dispatch, and
     output parameters are wired straight back into the caller's slots. *)
  | Var name when (match resolve c name with RFunc _ -> true | _ -> false) ->
    let f = (match resolve c name with RFunc f -> f | _ -> assert false) in
    if n <> f.arity then cerr "function '%s' expects %d argument(s), got %d" name f.arity n;
    let writers = out_writers c f args name in
    if writers = [] then
      fun fr ->
        let slots = Array.make (max f.fslots 1) Unit in
        for i = 0 to n - 1 do
          slots.(i) <- copy_val ((Array.unsafe_get argc i) fr)
        done;
        (try f.fbody { slots; caps = [||]; mstate = f.fmstate } with Zy_return v -> v)
    else
      fun fr ->
        let slots = Array.make (max f.fslots 1) Unit in
        for i = 0 to n - 1 do
          slots.(i) <- copy_val ((Array.unsafe_get argc i) fr)
        done;
        let r = (try f.fbody { slots; caps = [||]; mstate = f.fmstate } with Zy_return v -> v) in
        List.iter (fun (i, w) -> w fr slots.(i)) writers;
        r
  | _ ->
    let gf = comp_expr c callee in
    fun fr ->
      let argv = Array.map (fun g -> copy_val (g fr)) argc in
      invoke (gf fr) argv

(* ----------------------------------------------------------------- lvalues *)

(* An lvalue compiles to a store: `frame -> value -> unit`. *)
and comp_store (c : ctx) (lv : lvalue) : (frame -> value -> unit) =
  match lv with
  | LVar name ->
    (match lookup_local c name with
     | Some b when b.is_const -> cerr "cannot reassign constant '%s'" name
     | Some b -> let i = b.slot in fun fr v -> fr.slots.(i) <- v
     | None ->
       match resolve c name with
       | RSlot i -> fun fr v -> fr.slots.(i) <- v
       | RCap i -> fun fr v -> fr.caps.(i) <- v      (* writes stay local to the lambda *)
       (* A write to module state is the point of module state: it persists
          across calls and is seen by every function in the module -- unless the
          name was declared with `:=`, which stays immutable everywhere. *)
       | RMod i ->
         (match c.mscope with
          | Some ms when (match Hashtbl.find_opt ms name with
              | Some (_, true) -> true | _ -> false) ->
            cerr "cannot reassign module constant '%s'" name
          | _ -> fun fr v -> fr.mstate.(i) <- v)
       | RConst _ -> cerr "cannot reassign constant '%s'" name
       | RFunc _ -> cerr "cannot assign to function '%s'" name
       | RNone -> let i = declare c name in fun fr v -> fr.slots.(i) <- v)
  | LHot (prefix, name) ->
    let i = hot_slot c prefix name in
    fun fr v -> fr.slots.(i) <- v
  | LIndex (base, idx) ->
    let gb = comp_lvalue_read c base and gi = comp_expr c idx in
    fun fr v ->
      let container = gb fr in
      (match container, gi fr with
       | Arr a, Int i -> a.(real_index i (Array.length a)) <- v
       | Arr _, x -> err "index must be an integer, got %s" (type_name x)
       | x, _ -> err "cannot assign into %s" (type_name x))

(* Reading the container an indexed store writes through: it must be the live
   aggregate, never a copy. *)
and comp_lvalue_read (c : ctx) (lv : lvalue) : code =
  match lv with
  | LHot (prefix, name) -> comp_hot c prefix name (Int 0)
  | LVar name ->
    (match resolve c name with
     | RSlot i -> fun fr -> Array.unsafe_get fr.slots i
     | RCap i -> fun fr -> Array.unsafe_get fr.caps i
     | RMod i -> fun fr -> Array.unsafe_get fr.mstate i
     | RConst r -> fun _ -> !r
     | RFunc _ | RNone -> cerr "undefined variable: '%s'" name)
  | LIndex (base, idx) ->
    let gb = comp_lvalue_read c base and gi = comp_expr c idx in
    fun fr -> index_get (gb fr) (gi fr)

(* -------------------------------------------------------------- statements *)

and comp_stmt (c : ctx) (s : stmt) : (frame -> unit) =
  match s with
  | ExprStmt e -> let g = comp_expr c e in fun fr -> ignore (g fr)

  | Assign (LVar name, e) when lookup_local c name = None
                            && (match resolve c name with RNone -> true | _ -> false) ->
    (* First mention of a name declares it -- but the right-hand side is
       compiled first, because it may be what declares it: in
       `total = °total + item` the `°total` anchors the slot above the loop,
       and deciding before compiling would create a second one inside it. *)
    let g = comp_expr c e in
    let cp = needs_copy e in
    (match resolve c name with
     | RSlot i -> if cp then fun fr -> fr.slots.(i) <- copy_val (g fr)
       else fun fr -> fr.slots.(i) <- g fr
     | _ ->
       let i = declare c name in
       if cp then fun fr -> fr.slots.(i) <- copy_val (g fr)
       else fun fr -> fr.slots.(i) <- g fr)

  (* `°resultado = resultado ch` mentions the variable on both sides, so the
     slot has to exist before the right-hand side is compiled -- the opposite
     order to an ordinary assignment. *)
  | Assign (LHot (px, n), e) ->
    let st = comp_store c (LHot (px, n)) in
    let g = comp_expr c e in
    if needs_copy e then fun fr -> st fr (copy_val (g fr)) else fun fr -> st fr (g fr)

  | Assign (lv, e) ->
    let g = comp_expr c e in
    let st = comp_store c lv in
    if needs_copy e then fun fr -> st fr (copy_val (g fr)) else fun fr -> st fr (g fr)

  | ConstDecl (name, e) ->
    let g = comp_expr c e in
    (* A top-level constant is global; one inside a block is an immutable local. *)
    if c.parent = None && List.length c.scopes = 1 then begin
      if Hashtbl.mem globals name then cerr "constant '%s' is already declared" name;
      let r = ref Unit in
      Hashtbl.replace globals name r;
      fun fr -> r := copy_val (g fr)
    end else begin
      let i = declare ~is_const:true c name in
      fun fr -> fr.slots.(i) <- copy_val (g fr)
    end

  | OpAssign (LHot (px, n), op, e) ->
    let g = comp_expr c e in
    let rd = comp_hot c px n (neutral_of_op op) in
    let st = comp_store c (LHot (px, n)) in
    let f = bin_fn op in
    fun fr -> st fr (f (rd fr) (g fr))

  | OpAssign (LVar name, op, e) ->
    let g = comp_expr c e in
    let f = bin_fn op in
    (match resolve c name with
     | RSlot i -> fun fr -> fr.slots.(i) <- f (Array.unsafe_get fr.slots i) (g fr)
     | RCap i -> fun fr -> fr.caps.(i) <- f (Array.unsafe_get fr.caps i) (g fr)
     | RMod i -> fun fr -> fr.mstate.(i) <- f (Array.unsafe_get fr.mstate i) (g fr)
     | RConst _ -> cerr "cannot reassign constant '%s'" name
     | _ -> cerr "undefined variable: '%s'" name)

  | OpAssign (lv, op, e) ->
    let g = comp_expr c e in
    let rd = comp_lvalue_read c lv and st = comp_store c lv in
    let f = bin_fn op in
    fun fr -> st fr (f (rd fr) (g fr))

  | IncDec (LVar name, d) ->
    (match resolve c name with
     | RSlot i ->
       fun fr ->
         (match Array.unsafe_get fr.slots i with
          | Int x -> Array.unsafe_set fr.slots i (Int (x + d))
          | v -> fr.slots.(i) <- add v (Int d))
     | RCap i ->
       fun fr ->
         (match Array.unsafe_get fr.caps i with
          | Int x -> Array.unsafe_set fr.caps i (Int (x + d))
          | v -> fr.caps.(i) <- add v (Int d))
     | RMod i ->
       fun fr ->
         (match Array.unsafe_get fr.mstate i with
          | Int x -> Array.unsafe_set fr.mstate i (Int (x + d))
          | v -> fr.mstate.(i) <- add v (Int d))
     | RConst _ -> cerr "cannot reassign constant '%s'" name
     | _ -> cerr "undefined variable: '%s'" name)

  | IncDec (lv, d) ->
    let rd = comp_lvalue_read c lv and st = comp_store c lv in
    fun fr -> st fr (add (rd fr) (Int d))

  | Discard name ->
    (match c.scopes with h :: _ -> Hashtbl.remove h name | [] -> ());
    fun _ -> ()

  | Output items ->
    let cs = Array.of_list (List.map (comp_expr c) items) in
    (match Array.length cs with
     | 0 -> fun _ -> ()
     | 1 -> let g = cs.(0) in fun fr -> emit (display (g fr))
     | 2 -> let a = cs.(0) and b = cs.(1) in
       fun fr -> emit (display (a fr)); emit (display (b fr))
     | _ -> fun fr -> Array.iter (fun g -> emit (display (g fr))) cs)

  | Input (prompt, name) ->
    let gp = Option.map (comp_expr c) prompt in
    let st = comp_store c (LVar name) in
    fun fr ->
      (match gp with Some g -> emit (display (g fr)) | None -> ());
      flush_out ();
      let line = try input_line stdin with End_of_file -> "" in
      st fr (Str line)

  | Sleep e ->
    let g = comp_expr c e in
    fun fr ->
      (match g fr with
       | Int ms -> Unix.sleepf (float_of_int ms /. 1000.0)
       | Float ms -> Unix.sleepf (ms /. 1000.0)
       | v -> err "sleep expects a number of milliseconds, got %s" (type_name v))

  | Break l -> fun _ -> raise (Zy_break l)
  | Continue l -> fun _ -> raise (Zy_continue l)
  | Ret None -> fun _ -> raise (Zy_return Unit)
  | Ret (Some e) -> let g = comp_expr c e in fun fr -> raise (Zy_return (g fr))

  (* A runtime directive: it emits nothing and binds nothing, it just switches
     the script every later conversion to text goes through. *)
  (* TUI primitives are ANSI escape sequences on stdout; the corpus compares
     them literally, so the exact bytes matter. *)
  (* Destructuring overwrites an existing variable rather than shadowing it,
     and a `_` slot leaves whatever is there untouched. *)
  | Destructure (pat, e) ->
    let g = comp_expr c e in
    (match pat with
     | DSeq slots ->
       let stores = List.map (function
           | DSkip -> `Skip
           | DName n -> `One (comp_store c (LVar n))
           | DRest n -> `Rest (comp_store c (LVar n))) slots in
       fun fr ->
         let items = match g fr with
           | Arr a | Tup a | NTup (_, a) -> a
           | v -> errk "Type" "cannot destructure %s" (type_name v)
         in
         let i = ref 0 in
         List.iter (fun st ->
             match st with
             | `Skip -> incr i
             | `One store ->
               if !i < Array.length items then store fr (copy_val items.(!i));
               incr i
             | `Rest store ->
               let n = Array.length items - !i in
               store fr (Arr (Array.map copy_val
                                (Array.sub items !i (max n 0))));
               i := Array.length items)
           stores
     | DFields fields ->
       let stores = List.map (fun (f, n) -> (f, comp_store c (LVar n))) fields in
       fun fr ->
         let v = g fr in
         List.iter (fun (f, store) -> store fr (copy_val (field_get v f))) stores)

  | KeyInput (blocking, name) ->
    let st = comp_store c (LVar name) in
    fun fr ->
      (* Anything already buffered must reach the screen first: the prompt a
         program printed before waiting for a key is usually the point. *)
      flush_out ();
      st fr (read_key ~blocking)

  | ClearScreen -> fun _ -> emit "\027[2J\027[1;1H"

  | OutputPos (slots, items) ->
    let gs = List.map (Option.map (comp_expr c)) slots in
    let cs = Array.of_list (List.map (comp_expr c) items) in
    fun fr ->
      (* A single non-empty slot may hold a whole position tuple. *)
      let vals = match gs with
        | [ Some g ] ->
          (match g fr with
           | Tup a | NTup (_, a) -> Array.to_list (Array.map (fun v -> Some v) a)
           | v -> [ Some v ])
        | gs -> List.map (Option.map (fun g -> g fr)) gs
      in
      let nth k = match List.nth_opt vals k with Some (Some v) -> Some v | _ -> None in
      let as_i = function Some (Int i) -> Some i | Some (Float f) -> Some (int_of_float f) | _ -> None in
      (match as_i (nth 0), as_i (nth 1) with
       (* Row and column move the cursor only when both are present. *)
       | Some r, Some col -> emit (Printf.sprintf "\027[%d;%dH" r col)
       | _ -> ());
      (match as_i (nth 2) with
       | Some bks when bks > 0 ->
         if bks land 1 <> 0 then emit "\027[1m";
         if bks land 2 <> 0 then emit "\027[3m";
         if bks land 4 <> 0 then emit "\027[4m"
       | _ -> ());
      (match as_i (nth 3) with
       | Some fg when fg > 0 -> emit (Printf.sprintf "\027[38;5;%dm" fg)
       | _ -> ());
      (match as_i (nth 4) with
       | Some bg when bg > 0 -> emit (Printf.sprintf "\027[48;5;%dm" bg)
       | _ -> ());
      Array.iter (fun g -> emit (display (g fr))) cs

  | TuiBlock body ->
    push_scope c;
    let b = comp_block c body in
    pop_scope c;
    (* Alternate screen in, and out again on every path — including an error,
       or the terminal is left unusable. *)
    fun fr ->
      (* Raw mode is a property of the input side, so stdin is what has to be
         a terminal.  Message matches the reference engine's. *)
      if not (Unix.isatty Unix.stdin) then
        errk "IO" "failed to enable raw mode: No such device or address (os error 6)";
      (* Alternate screen, cursor home, cursor hidden — and the exact inverse
         on the way out.  These are the bytes the reference engine writes. *)
      emit "\027[?1049h\027[1;1H\027[?25l";
      flush_out ();
      let restore () =
        leave_raw ();
        emit "\027[?1049l\027[?25h";
        flush_out ()
      in
      (try b fr with e -> restore (); raise e);
      restore ()

  | NumeralMode b -> fun _ -> numeral_base := b

  | Import (path, alias) ->
    Hashtbl.replace c.mimports alias (load_module path);
    fun _ -> ()
  | Export _ -> cerr "'#>' is only valid inside a module block"
  | ModuleDecl (n, _) ->
    cerr "'# %s' declares a module; a module file may not be run directly" n

  | Try (body, catches, fin) -> comp_try c body catches fin
  | PropErr e -> let g = comp_expr c e in fun fr -> ignore (g fr)

  | If (branches, els) -> comp_if c branches els
  | Loop (label, head, body) -> comp_loop c label head body
  | FuncDecl (name, params, body) -> comp_func c name params body

(* Try/catch/finally.  The caught message is bound to `_err`, and the finally
   block runs on every path -- normal completion, a handled error, and an error
   that no arm matched. *)
and comp_try c body catches fin =
  push_scope c;
  let b = comp_block c body in
  pop_scope c;
  let hs = List.map (fun (kind, block) ->
      push_scope c;
      let slot = declare c "_err" in
      let h = comp_block c block in
      pop_scope c;
      (kind, slot, h)) catches in
  let f = match fin with
    | None -> None
    | Some block -> push_scope c; let g = comp_block c block in pop_scope c; Some g
  in
  fun fr ->
    let run_finally () = match f with Some g -> g fr | None -> () in
    (try b fr with
     | Zy_error (kind, msg) as e ->
       let rec pick = function
         | [] -> run_finally (); raise e
         | (want, slot, h) :: rest ->
           if want = None || want = Some kind then begin
             (* `_err` renders as `##Kind(message)`, matching how the reference
                engine displays an error value.  The message text itself is
                this engine's own -- see README. *)
             fr.slots.(slot) <-
               Str (Printf.sprintf "##%s(%s)" (if kind = "" then "_" else kind) msg);
             h fr
           end else pick rest
       in
       pick hs
     | e -> run_finally (); raise e);
    run_finally ()

and comp_if c branches els =
  let bs = Array.of_list (List.map (fun (cond, body) ->
      let g = comp_expr c cond in
      push_scope c;
      let b = comp_block c body in
      pop_scope c;
      (g, b)) branches) in
  let e = match els with
    | None -> None
    | Some body -> push_scope c; let b = comp_block c body in pop_scope c; Some b
  in
  match Array.length bs, e with
  | 1, None -> let (g, b) = bs.(0) in fun fr -> if as_bool (g fr) then b fr
  | 1, Some eb -> let (g, b) = bs.(0) in fun fr -> if as_bool (g fr) then b fr else eb fr
  | _ ->
    fun fr ->
      let n = Array.length bs in
      let rec go i =
        if i >= n then (match e with Some eb -> eb fr | None -> ())
        else begin
          let (g, b) = Array.unsafe_get bs i in
          if as_bool (g fr) then b fr else go (i + 1)
        end
      in
      go 0

(* Does this body need a per-iteration `try`?  A body with no `@>`/`@!` that
   targets this loop can run without one. *)
and body_jumps stmts =
  let rec ex_s : Ast.stmt -> bool = function
    | Ast.Break _ | Ast.Continue _ -> true
    | Ast.If (bs, e) ->
      List.exists (fun (_, b) -> List.exists ex_s b) bs
      || (match e with Some b -> List.exists ex_s b | None -> false)
    | Ast.Loop (_, _, body) ->
      (* A nested loop swallows its own unlabelled jumps, but a labelled jump
         inside it can still target us. *)
      List.exists (function
          | Ast.Break (Some _) | Ast.Continue (Some _) -> true
          | s -> ex_s s) body
    | _ -> false
  in
  List.exists ex_s stmts

and comp_loop c label head body =
  let above = List.hd c.scopes in
  push_scope c;
  c.loops <- (List.hd c.scopes, above) :: c.loops;
  (* The iterator reuses an existing outer variable when one exists, which is
     why it survives the loop in that case. *)
  let iter_slot name =
    match resolve c name with
    | RSlot i -> i
    | _ -> declare c name
  in
  let head' = match head with
    | Infinite -> `Inf
    | Count e -> `Count (comp_expr c e)
    | ForEach (v, e) -> let g = comp_expr c e in `Each (iter_slot v, g)
    | ForRange (v, a, b, st) ->
      let ga = comp_expr c a and gb = comp_expr c b in
      let gs = Option.map (comp_expr c) st in
      `Range (iter_slot v, ga, gb, gs)
  in
  let b = comp_block c body in
  c.loops <- (match c.loops with _ :: t -> t | [] -> []);
  pop_scope c;
  let jumps = body_jumps body in

  (* One iteration, with continue handling only where it is needed. *)
  let step : frame -> unit =
    if jumps then
      fun fr ->
        (try b fr with
         | Zy_continue None -> ()
         | Zy_continue (Some l) when Some l = label -> ())
    else b
  in
  let guard (run : frame -> unit) fr =
    if jumps then
      (try run fr with
       | Zy_break None -> ()
       | Zy_break (Some l) when Some l = label -> ())
    else run fr
  in
  let asint what v = match v with
    | Int i -> i
    | v -> err "%s must be an integer, got %s" what (type_name v)
  in
  match head' with
  | `Inf -> guard (fun fr -> while true do step fr done)
  | `Count g ->
    guard (fun fr ->
        (* `@ N` repeats N times and never re-evaluates; `@ cond` is a while. *)
        match g fr with
        | Int n -> for _ = 1 to n do step fr done
        | Bool _ -> while as_bool (g fr) do step fr done
        | v -> err "loop expects a count or a condition, got %s" (type_name v))
  | `Each (slot, g) ->
    guard (fun fr ->
        match g fr with
        | Arr a -> Array.iter (fun x -> fr.slots.(slot) <- x; step fr) a
        | Str s -> Array.iter (fun ch -> fr.slots.(slot) <- Chr ch; step fr) (utf8_chars s)
        | Tup a -> Array.iter (fun x -> fr.slots.(slot) <- x; step fr) a
        | v -> err "cannot iterate over %s" (type_name v))
  | `Range (slot, ga, gb, gs) ->
    guard (fun fr ->
        let a = asint "range start" (ga fr) and b = asint "range end" (gb fr) in
        let st = match gs with Some g -> abs (asint "range step" (g fr)) | None -> 1 in
        let st = if st = 0 then 1 else st in
        if a <= b then begin
          let i = ref a in
          while !i <= b do fr.slots.(slot) <- Int !i; step fr; i := !i + st done
        end else begin
          let i = ref a in
          while !i >= b do fr.slots.(slot) <- Int !i; step fr; i := !i - st done
        end)

and comp_func c name params body =
  let arity = List.length params in
  let outs = List.mapi (fun i p -> (i, p.pout)) params
             |> List.filter snd |> List.map fst |> Array.of_list in
  (* Register before compiling the body so the body can call itself. *)
  let fv = { fname = name; arity; fslots = arity; outs;
             fbody = (fun _ -> Unit); fmstate = [||] } in
  Hashtbl.replace funcs name fv;
  let fc = new_ctx None in
  List.iter (fun p -> ignore (declare fc p.pname)) params;
  let b = comp_block fc body in
  fv.fslots <- fc.nslots;
  fv.fbody <- (fun fr -> b fr; Unit);
  ignore c;
  fun _ -> ()

and comp_block (c : ctx) (stmts : stmt list) : (frame -> unit) =
  let cs = Array.of_list (List.map (comp_stmt c) stmts) in
  match Array.length cs with
  | 0 -> fun _ -> ()
  | 1 -> cs.(0)
  | 2 -> let a = cs.(0) and b = cs.(1) in fun fr -> a fr; b fr
  | 3 -> let a = cs.(0) and b = cs.(1) and d = cs.(2) in fun fr -> a fr; b fr; d fr
  | n -> fun fr -> for i = 0 to n - 1 do (Array.unsafe_get cs i) fr done

(* ------------------------------------------------------------------- entry *)

let compile ?(file = "") (prog : program) : (unit -> unit) =
  Hashtbl.reset globals;
  Hashtbl.reset funcs;
  Hashtbl.reset modules;
  cur_dir := (if file = "" then "." else Filename.dirname file);
  numeral_base := 0x30;
  let c = new_ctx None in
  let b = comp_block c prog in
  let nslots = c.nslots in
  fun () ->
    let fr = { slots = Array.make (max nslots 1) Unit; caps = [||]; mstate = [||] } in
    (try b fr with Zy_return _ -> ())
