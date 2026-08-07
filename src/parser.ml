(* Recursive-descent parser.

   Precedence, lowest to highest (mirrors crates/zymbol-parser/src/expressions.rs):
     |>  <  ||  <  &&  <  comparison  <  + -  <  * / %  <  ^ (right)  <  unary  <  postfix

   Two rules of the language shape this file more than anything else:

   * Statements are not terminated.  A statement ends where the next one can
     begin, so `>>` stops collecting items at a delimiter (`¶`, `}`, EOF) or at
     a token that can only start a new statement.
   * `>>` uses juxtaposition, so an output item is parsed at `+`/`-` precedence
     rather than full expression precedence: `>> "a" b` is two items, while
     `>> 10 + 5` is one. *)

open Ast
open Lexer

exception Parse_error of string * int

type t = { toks : Lexer.t array; mutable pos : int }

let peek p = p.toks.(p.pos).tok
let peek_at p k = if p.pos + k < Array.length p.toks then p.toks.(p.pos + k).tok else TEOF
let line p = p.toks.(p.pos).line
let advance p = let tk = p.toks.(p.pos).tok in p.pos <- p.pos + 1; tk

let fail p msg = raise (Parse_error (msg, line p))

let expect p tk what =
  if peek p = tk then ignore (advance p)
  else fail p (Printf.sprintf "expected %s, found '%s'" what (show (peek p)))

let ident p =
  match advance p with
  | TIdent s -> s
  | tk -> raise (Parse_error (Printf.sprintf "expected an identifier, found '%s'" (show tk),
                              p.toks.(p.pos - 1).line))

(* ------------------------------------------------- string interpolation *)

(* Split a lexed string literal on `{name}`.  The lexer already replaced the
   escaped forms `\{` and `\}` with private markers, so every brace still
   present here is a genuine interpolation delimiter. *)
let split_interp (s : string) : expr =
  let unmark str =
    String.map (fun c ->
        if c = Lexer.mark_lbrace then '{'
        else if c = Lexer.mark_rbrace then '}'
        else c) str
  in
  if not (String.contains s '{') then SLit (unmark s)
  else begin
    let parts = ref [] in
    let buf = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      (* `{...}` interpolates only when it holds an identifier.  A JSON literal
         such as {"model":"x"} passes through untouched. *)
      let is_name t =
        t <> "" && (let ok = ref true in
                    String.iter (fun c ->
                        if not (Lexer.is_ident_char c) then ok := false) t;
                    !ok)
      in
      if s.[!i] = '{' then
        match String.index_from_opt s !i '}' with
        | Some j when is_name (String.sub s (!i + 1) (j - !i - 1)) ->
          if Buffer.length buf > 0 then begin
            parts := ILit_text (unmark (Buffer.contents buf)) :: !parts;
            Buffer.clear buf
          end;
          parts := ILit_var (String.sub s (!i + 1) (j - !i - 1)) :: !parts;
          i := j + 1
        | _ -> Buffer.add_char buf s.[!i]; incr i
      else begin Buffer.add_char buf s.[!i]; incr i end
    done;
    if Buffer.length buf > 0 then parts := ILit_text (unmark (Buffer.contents buf)) :: !parts;
    Interp (List.rev !parts)
  end

(* -------------------------------------------------------- lookaheads *)

(* `name(a, b) {` is a function declaration; `name(a, b)` anywhere else is a
   call.  Both start identically, so we scan the parenthesised group: it must
   contain only parameter-shaped tokens and be followed by `{`. *)
let is_func_decl p =
  match peek p, peek_at p 1 with
  | TIdent _, TLParen ->
    let k = ref (p.pos + 2) in
    let ok = ref true in
    let fin = ref false in
    while not !fin do
      match (if !k < Array.length p.toks then p.toks.(!k).tok else TEOF) with
      | TRParen -> fin := true
      | TIdent _ | TComma | TRet -> incr k
      | _ -> ok := false; fin := true
    done;
    !ok && (if !k + 1 < Array.length p.toks then p.toks.(!k + 1).tok = TLBrace else false)
  | _ -> false

(* `(a, b) -> body` — a parenthesised group followed by `->`. *)
let is_lambda_params p =
  peek p = TLParen &&
  (let depth = ref 0 in
   let k = ref p.pos in
   let res = ref false in
   let fin = ref false in
   while not !fin do
     (match (if !k < Array.length p.toks then p.toks.(!k).tok else TEOF) with
      | TLParen -> incr depth
      | TRParen ->
        decr depth;
        if !depth = 0 then begin
          res := (if !k + 1 < Array.length p.toks then p.toks.(!k + 1).tok = TArrow else false);
          fin := true
        end
      | TEOF -> fin := true
      | _ -> ());
     incr k
   done;
   !res)

(* A delimiter genuinely ends the current statement.  [starts_statement] is
   wider: it also lists tokens that can *begin* one, which is what stops `>>`
   from swallowing the next line -- but a leading `??` is still a valid first
   output item, so the two sets are not interchangeable. *)
let is_delimiter = function
  | TNewline | TRBrace | TEOF | TSemi -> true
  | _ -> false

(* Tokens that can only begin a new statement, so `>>` must stop before them. *)
let starts_statement = function
  | TOut | TIn | TIf | TMatch | TAt | TAtLabel _ | TAtBreak | TAtCont | TAtSleep
  | TAtLabelBreak _ | TAtLabelCont _ | TRet | TNewline | TRBrace | TEOF
  | TBackslash | TSemi -> true
  | _ -> false

(* Decide whether a postfix `[...]` is navigation or a plain 1-D index: it is
   navigation when a `>` or `;` appears at the group's own nesting level, or
   when the bracket opens another bracket (`arr[[...]]`).  A `>` nested inside
   parentheses stays a comparison, which is what makes `arr[(a > b)]` a 1-D
   index by construction. *)
let is_nav_index p =
  peek p = TLBracket
  && (peek_at p 1 = TLBracket
      || (let depth = ref 0 and k = ref p.pos and res = ref false and fin = ref false in
          while not !fin do
            (match (if !k < Array.length p.toks then p.toks.(!k).tok else TEOF) with
             | TLBracket | TLParen -> incr depth
             | TRParen -> decr depth
             | TRBracket -> decr depth; if !depth = 0 then fin := true
             | (TGt | TSemi) when !depth = 1 -> res := true; fin := true
             | TEOF -> fin := true
             | _ -> ());
            incr k
          done;
          !res))

(* `$^ (a, b -> body)` spells a two-argument comparator without the usual
   parentheses around the parameter list, so it needs its own lookahead. *)
let is_bare_pair_lambda p =
  peek p = TLParen
  && (match peek_at p 1, peek_at p 2, peek_at p 3, peek_at p 4 with
      | TIdent _, TComma, TIdent _, TArrow -> true
      | _ -> false)

(* ------------------------------------------------------------ expressions *)

let rec parse_expr p =
  (* A lambda binds looser than anything on its right, so it is recognised
     before the precedence chain is entered. *)
  match peek p, peek_at p 1 with
  | TIdent name, TArrow ->
    p.pos <- p.pos + 2;
    Lambda ([ name ], parse_lambda_body p)
  | TUnderscore, TArrow ->
    p.pos <- p.pos + 2;
    Lambda ([ "_" ], parse_lambda_body p)
  | _ when is_lambda_params p ->
    ignore (advance p);                                  (* ( *)
    let ps = ref [] in
    if peek p <> TRParen then begin
      ps := [ ident p ];
      while peek p = TComma do ignore (advance p); ps := ident p :: !ps done
    end;
    expect p TRParen ")";
    expect p TArrow "'->'";
    Lambda (List.rev !ps, parse_lambda_body p)
  | TMatch, _ -> parse_match p
  | _ -> parse_pipe p

(* `?? scrutinee { pattern => value ... }`.  Usable as an expression
   (`grade = ?? score { ... }`) or as a statement. *)
and parse_match p =
  expect p TMatch "'??'";
  let scrut = parse_add p in
  expect p TLBrace "'{'";
  let arms = ref [] in
  while peek p <> TRBrace && peek p <> TEOF do
    let pat = parse_pattern p in
    expect p TFatArrow "'=>'";
    let body =
      if peek p = TLBrace then MBlock (parse_block p) else MExpr (parse_arm_value p)
    in
    arms := (pat, body) :: !arms
  done;
  expect p TRBrace "'}'";
  Match (scrut, List.rev !arms)

(* An arm value stops short of a bare comparison operator: the `<` that follows
   would otherwise be read as part of this value rather than as the next arm's
   comparison pattern. *)
and parse_arm_value p =
  let l = ref (parse_arm_and p) in
  while peek p = TOr do ignore (advance p); l := Bin (Or, !l, parse_arm_and p) done;
  !l

and parse_arm_and p =
  let l = ref (parse_add p) in
  while peek p = TAnd do ignore (advance p); l := Bin (And, !l, parse_add p) done;
  !l

and parse_pattern p =
  let alts = ref [ parse_pattern_atom p ] in
  while peek p = TOr do ignore (advance p); alts := parse_pattern_atom p :: !alts done;
  match List.rev !alts with [ x ] -> x | l -> POr l

and parse_pattern_atom p =
  match peek p with
  | TUnderscore -> ignore (advance p); PWild
  | TLt -> ignore (advance p); PCmp (Lt, parse_add p)
  | TGt -> ignore (advance p); PCmp (Gt, parse_add p)
  | TLe -> ignore (advance p); PCmp (Le, parse_add p)
  | TGe -> ignore (advance p); PCmp (Ge, parse_add p)
  | TEq -> ignore (advance p); PCmp (Eq, parse_add p)
  | TNeq -> ignore (advance p); PCmp (Neq, parse_add p)
  | TLBracket ->
    ignore (advance p);
    let items = ref [] in
    if peek p <> TRBracket then begin
      items := [ parse_pattern_atom p ];
      while peek p = TComma do ignore (advance p); items := parse_pattern_atom p :: !items done
    end;
    expect p TRBracket "']'";
    PList (List.rev !items)
  | _ ->
    let e = parse_add p in
    if peek p = TDotDot then begin ignore (advance p); PRange (e, parse_add p) end
    else (match e with
        (* A lone name is an ident pattern, whose meaning depends on the
           variable's runtime type. *)
        | Var n -> PIdent n
        | e -> PLit e)

and parse_lambda_body p =
  if peek p = TLBrace then LBlock (parse_block p) else LExpr (parse_expr p)

and parse_pipe p =
  let left = ref (parse_or p) in
  while peek p = TPipeOp do
    ignore (advance p);
    let callable = parse_primary p in
    let args =
      if peek p = TLParen then begin
        ignore (advance p);
        let acc = ref [] in
        if peek p <> TRParen then begin
          acc := [ (if peek p = TUnderscore then (ignore (advance p); Var "_") else parse_or p) ];
          while peek p = TComma do
            ignore (advance p);
            acc := (if peek p = TUnderscore then (ignore (advance p); Var "_") else parse_or p) :: !acc
          done
        end;
        expect p TRParen ")";
        List.rev !acc
      end else [ Var "_" ]
    in
    (* `x |> f(a, _)` substitutes the piped value at the placeholder. *)
    let piped = !left in
    left := Call (callable, List.map (fun a -> if a = Var "_" then piped else a) args)
  done;
  !left

and parse_or p =
  let l = ref (parse_and p) in
  while peek p = TOr do ignore (advance p); l := Bin (Or, !l, parse_and p) done;
  !l

and parse_and p =
  let l = ref (parse_cmp p) in
  while peek p = TAnd do ignore (advance p); l := Bin (And, !l, parse_cmp p) done;
  !l

and parse_cmp p =
  let l = ref (parse_add p) in
  let rec go () =
    let op = match peek p with
      | TEq -> Some Eq | TNeq -> Some Neq | TLt -> Some Lt
      | TGt -> Some Gt | TLe -> Some Le | TGe -> Some Ge
      | _ -> None
    in
    match op with
    | Some o -> ignore (advance p); l := Bin (o, !l, parse_add p); go ()
    | None -> ()
  in
  go (); !l

and parse_add p =
  let l = ref (parse_mul p) in
  let rec go () =
    match peek p with
    | TPlus -> ignore (advance p); l := Bin (Add, !l, parse_mul p); go ()
    | TMinus -> ignore (advance p); l := Bin (Sub, !l, parse_mul p); go ()
    | _ -> ()
  in
  go (); !l

and parse_mul p =
  let l = ref (parse_pow p) in
  let rec go () =
    match peek p with
    | TStar -> ignore (advance p); l := Bin (Mul, !l, parse_pow p); go ()
    | TSlash -> ignore (advance p); l := Bin (Div, !l, parse_pow p); go ()
    | TPercent -> ignore (advance p); l := Bin (Mod, !l, parse_pow p); go ()
    | _ -> ()
  in
  go (); !l

(* `^` is right-associative: 2^3^2 = 2^(3^2). *)
and parse_pow p =
  let l = parse_unary p in
  if peek p = TCaret then begin ignore (advance p); Bin (Pow, l, parse_pow p) end else l

and parse_unary p =
  match peek p with
  | TNot -> ignore (advance p); Un (Not, parse_unary p)
  | TMinus -> ignore (advance p); Un (Neg, parse_unary p)
  | TPlus -> ignore (advance p); parse_unary p
  (* Casts are prefix operators over a unary operand: `###(7 / 2.0)`. *)
  | TCastFloat -> ignore (advance p); Cast (ToFloat, parse_unary p)
  | TCastRound -> ignore (advance p); Cast (ToIntRound, parse_unary p)
  | TCastTrunc -> ignore (advance p); Cast (ToIntTrunc, parse_unary p)
  | TShellOpen ->
    ignore (advance p);
    let e = parse_expr p in
    expect p TShellClose "'\\>'";
    parse_postfix p (Shell e)
  | TFmtOpen (st, pr) ->
    ignore (advance p);
    let e = parse_expr p in
    expect p TBar "'|'";
    parse_postfix p (Fmt (st, pr, e))
  | TBaseConv b ->
    ignore (advance p);
    let e = parse_expr p in
    expect p TBar "'|'";
    parse_postfix p (BaseConv (b, e))
  | _ -> parse_postfix p (parse_primary p)

(* Every `$`-family and `#?` postfix operator, shared by expression context and
   `>>` output-item context. Returns [None] when the next token is not one. *)
and parse_coll_postfix p (e : expr) : expr option =
  (* The right operand binds as tightly as possible and, crucially, never
     absorbs another `$` operator -- that is what makes `arr$+ 4$+ 5` chain to
     the left instead of parsing as `arr$+ (4$+ 5)`. *)
  let operand () = parse_coll_operand p in
  match peek p with
  | TLen -> ignore (advance p); Some (Len e)
  | TAppend -> ignore (advance p); Some (Append (e, operand ()))
  | TContains -> ignore (advance p); Some (Contains (e, operand ()))
  | TFindAll -> ignore (advance p); Some (FindAll (e, operand ()))
  | TTypeOf -> ignore (advance p); Some (TypeOf e)
  | TRemove -> ignore (advance p); Some (Remove (e, operand ()))
  | TRemoveAll -> ignore (advance p); Some (RemoveAll (e, operand ()))
  | TMap -> ignore (advance p); Some (Map (e, operand ()))
  | TFilter -> ignore (advance p); Some (Filter (e, operand ()))
  | TSplit -> ignore (advance p); Some (Split (e, operand ()))
  | TRepeat -> ignore (advance p); Some (Repeat (e, operand ()))
  | TUpdate -> ignore (advance p); Some (Update (e, operand ()))
  | TSortAsc -> ignore (advance p); Some (Sort (e, true))
  | TSortDesc -> ignore (advance p); Some (Sort (e, false))
  | TSortBy ->
    ignore (advance p);
    if is_bare_pair_lambda p then begin
      ignore (advance p);                                  (* ( *)
      let a = ident p in
      expect p TComma ",";
      let b = ident p in
      expect p TArrow "'->'";
      let body = parse_lambda_body p in
      expect p TRParen ")";
      Some (SortBy (e, Lambda ([ a; b ], body)))
    end else Some (SortBy (e, operand ()))
  | TReduce ->
    (* `$< (initial, (acc, x) -> expr)` *)
    ignore (advance p);
    expect p TLParen "'('";
    let init = parse_expr p in
    expect p TComma ",";
    let f = parse_expr p in
    expect p TRParen ")";
    Some (Reduce (e, init, f))
  | TInsertAt ->
    ignore (advance p);                                    (* `$+[` consumed *)
    let i = parse_expr p in
    expect p TRBracket "']'";
    Some (InsertAt (e, i, operand ()))
  | TRemoveAt ->
    ignore (advance p);                                    (* `$-[` consumed *)
    let a = parse_add p in
    let b =
      if peek p = TDotDot then Some (ignore (advance p); parse_add p)
      else if peek p = TColon then begin
        ignore (advance p);
        let c = parse_add p in
        Some (Bin (Sub, Bin (Add, a, c), ILit 1))
      end else None
    in
    expect p TRBracket "']'";
    Some (RemoveAt (e, a, b))
  | TReplace ->
    ignore (advance p);                                    (* `$~~[` consumed *)
    let pat = parse_add p in
    expect p TColon ":";
    let rep = parse_add p in
    let lim = if peek p = TColon then Some (ignore (advance p); parse_add p) else None in
    expect p TRBracket "']'";
    Some (Replace (e, pat, rep, lim))
  | TBuild ->
    (* `$++` collects juxtaposed items, all on the same source line. *)
    ignore (advance p);
    let ln = line p in
    let items = ref [ parse_out_item p ] in
    while line p = ln && not (starts_statement (peek p))
          && (match peek p, peek_at p 1 with
              | TIdent _, (TAssign | TPlusEq | TMinusEq | TStarEq | TSlashEq
                          | TPercentEq | TCaretEq | TInc | TDec) -> false
              | _ -> true)
    do items := parse_out_item p :: !items done;
    Some (Build (e, List.rev !items))
  | TDot ->
    ignore (advance p);
    Some (Field (e, ident p))
  | TIsErr -> ignore (advance p); Some (IsErr e)
  (* `$!!` propagates an error value to the caller.  Errors in this engine
     travel as exceptions rather than as values, so there is nothing to
     propagate here and the operator is the identity — see README. *)
  | TPropErr -> ignore (advance p); Some e
  | TDollarBracket ->
    ignore (advance p);
    let a = parse_add p in
    let b =
      if peek p = TDotDot then begin ignore (advance p); parse_add p end
      else if peek p = TColon then begin
        (* `$[start:count]` is the count-based spelling of `$[start..start+count-1]` *)
        ignore (advance p);
        let c = parse_add p in
        Bin (Sub, Bin (Add, a, c), ILit 1)
      end else fail p "expected '..' or ':' in slice"
    in
    expect p TRBracket "']'";
    Some (Slice (e, a, b))
  | _ -> None

(* An operand for a collection operator: unary and structural postfix only. *)
and parse_coll_operand p =
  match peek p with
  | TMinus -> ignore (advance p); Un (Neg, parse_coll_operand p)
  | TNot -> ignore (advance p); Un (Not, parse_coll_operand p)
  | TCastFloat -> ignore (advance p); Cast (ToFloat, parse_coll_operand p)
  | TCastRound -> ignore (advance p); Cast (ToIntRound, parse_coll_operand p)
  | TCastTrunc -> ignore (advance p); Cast (ToIntTrunc, parse_coll_operand p)
  | TFmtOpen (st, pr) ->
    ignore (advance p);
    let e = parse_expr p in
    expect p TBar "'|'";
    Fmt (st, pr, e)
  | TBaseConv b ->
    ignore (advance p);
    let e = parse_expr p in
    expect p TBar "'|'";
    BaseConv (b, e)
  | _ ->
    let e = ref (parse_primary p) in
    let fin = ref false in
    while not !fin do
      match peek p with
      | TLBracket ->
        ignore (advance p);
        let idx = parse_expr p in
        expect p TRBracket "']'";
        e := Index (!e, idx)
      | TLParen ->
        ignore (advance p);
        let args = ref [] in
        if peek p <> TRParen then begin
          args := [ parse_expr p ];
          while peek p = TComma do ignore (advance p); args := parse_expr p :: !args done
        end;
        expect p TRParen ")";
        e := Call (!e, List.rev !args)
      | _ -> fin := true
    done;
    !e

(* One navigation step: an index, or `a..b` to fan out along that axis. *)
and parse_nav_step p =
  let a = parse_add p in
  if peek p = TDotDot then begin ignore (advance p); NRange (a, parse_add p) end
  else NIdx a

and parse_nav_path p =
  let steps = ref [ parse_nav_step p ] in
  while peek p = TGt do ignore (advance p); steps := parse_nav_step p :: !steps done;
  List.rev !steps

and parse_nav p base =
  expect p TLBracket "'['";
  let group () =
    ignore (advance p);                                  (* [ *)
    let ps = ref [ parse_nav_path p ] in
    while peek p = TComma do ignore (advance p); ps := parse_nav_path p :: !ps done;
    expect p TRBracket "']'";
    List.rev !ps
  in
  let items = ref [ (if peek p = TLBracket then `G (group ()) else `P (parse_nav_path p)) ] in
  while peek p = TSemi do
    ignore (advance p);
    items := (if peek p = TLBracket then `G (group ()) else `P (parse_nav_path p)) :: !items
  done;
  expect p TRBracket "']'";
  let items = List.rev !items in
  let spec =
    match items with
    (* A single group flattens (`m[[2>3]]` is `[6]`); several groups nest. *)
    | [ `G g ] -> NFlat g
    | [ `P path ] -> NPath path
    | _ when List.for_all (function `G _ -> true | _ -> false) items ->
      NStruct (List.map (function `G g -> g | `P p -> [ p ]) items)
    | _ -> NFlat (List.concat_map (function `G g -> g | `P p -> [ p ]) items)
  in
  Nav (base, spec)

and parse_postfix p e =
  let e = ref e in
  let fin = ref false in
  while not !fin do
    (* `[` and `(` only continue the current expression when they sit on the
       same source line.  Statements are not terminated in Zymbol, so the line
       is what separates `"low"` from the `[3, 4]` that opens the next match
       arm on the line below. *)
    let same_line = p.pos = 0 || line p = p.toks.(p.pos - 1).line in
    match peek p with
    | (TLBracket | TLParen) when not same_line -> fin := true
    | TLBracket when is_nav_index p -> e := parse_nav p !e
    | TLBracket ->
      ignore (advance p);
      let idx = parse_expr p in
      expect p TRBracket "']'";
      e := Index (!e, idx)
    | TLParen ->
      ignore (advance p);
      let args = ref [] in
      if peek p <> TRParen then begin
        args := [ parse_expr p ];
        while peek p = TComma do ignore (advance p); args := parse_expr p :: !args done
      end;
      expect p TRParen ")";
      e := Call (!e, List.rev !args)
    | _ ->
      (match parse_coll_postfix p !e with
       | Some e' -> e := e'
       | None -> fin := true)
  done;
  !e

and parse_primary p =
  match advance p with
  | TInt i -> ILit i
  | TFloat f -> FLit f
  | TStr s -> split_interp s
  | TChar c -> CLit c
  | TTrue -> BLit true
  | TFalse -> BLit false
  | TIdent s when peek p = TColonColon ->
    ignore (advance p);
    let fn = ident p in
    expect p TLParen "'('";
    let args = ref [] in
    if peek p <> TRParen then begin
      args := [ parse_expr p ];
      while peek p = TComma do ignore (advance p); args := parse_expr p :: !args done
    end;
    expect p TRParen ")";
    ModCall (s, fn, List.rev !args)
  | TIdent s -> Var s
  | TUnderscore -> Var "_"
  | TMatch -> p.pos <- p.pos - 1; parse_match p
  (* `(name: expr, ...)` is a named tuple; a `:` right after the first
     identifier is what distinguishes it from a parenthesised expression. *)
  | TLParen when (match peek p, peek_at p 1 with TIdent _, TColon -> true | _ -> false) ->
    let fields = ref [] in
    let one () =
      let n = ident p in
      expect p TColon ":";
      (n, parse_expr p)
    in
    fields := [ one () ];
    while peek p = TComma do ignore (advance p); fields := one () :: !fields done;
    expect p TRParen ")";
    NTupLit (List.rev !fields)
  | TLParen ->
    let first = parse_expr p in
    if peek p = TComma then begin
      let items = ref [ first ] in
      while peek p = TComma do ignore (advance p); items := parse_expr p :: !items done;
      expect p TRParen ")";
      TupLit (List.rev !items)
    end else begin expect p TRParen ")"; first end
  | TLBracket ->
    let items = ref [] in
    if peek p <> TRBracket then begin
      items := [ parse_expr p ];
      while peek p = TComma do ignore (advance p); items := parse_expr p :: !items done
    end;
    expect p TRBracket "']'";
    ArrLit (List.rev !items)
  | tk ->
    p.pos <- p.pos - 1;
    fail p (Printf.sprintf "unexpected token '%s' in expression" (show tk))

(* ---------------------------------------------------------- output items *)

(* Output items bottom out at `+`/`-`: everything looser is juxtaposition. *)
and parse_out_item p =
  let l = ref (parse_out_mul p) in
  let rec go () =
    match peek p with
    | TPlus -> ignore (advance p); l := Bin (Add, !l, parse_out_mul p); go ()
    | TMinus -> ignore (advance p); l := Bin (Sub, !l, parse_out_mul p); go ()
    | _ -> ()
  in
  go (); !l

and parse_out_mul p =
  match peek p with
  | TNot | TMinus -> parse_unary p
  | _ ->
    let l = ref (parse_out_term p) in
    let rec go () =
      match peek p with
      | TStar -> ignore (advance p); l := Bin (Mul, !l, parse_out_term p); go ()
      | TSlash -> ignore (advance p); l := Bin (Div, !l, parse_out_term p); go ()
      | TPercent -> ignore (advance p); l := Bin (Mod, !l, parse_out_term p); go ()
      | _ -> ()
    in
    go (); !l

and parse_out_term p =
  match peek p with
  | TMinus | TCastFloat | TCastRound | TCastTrunc | TFmtOpen _ | TBaseConv _
  | TShellOpen -> parse_unary p
  | _ ->
    let start_line = line p in
    let base = parse_primary p in
    (* Literals are not callable: `>> "label" (x)` is two items, not a call. *)
    let is_lit = match base with
      | ILit _ | FLit _ | SLit _ | CLit _ | BLit _ | Interp _ -> true | _ -> false in
    let e = ref base in
    let fin = ref false in
    while not !fin do
      (* A postfix operator on the next source line belongs to the next
         statement, not to this item. *)
      if line p <> start_line then fin := true
      else match peek p with
        | TLBracket when is_nav_index p -> e := parse_nav p !e
        | TLBracket ->
          ignore (advance p);
          let idx = parse_expr p in
          expect p TRBracket "']'";
          e := Index (!e, idx)
        | TLParen when not is_lit ->
          ignore (advance p);
          let args = ref [] in
          if peek p <> TRParen then begin
            args := [ parse_expr p ];
            while peek p = TComma do ignore (advance p); args := parse_expr p :: !args done
          end;
          expect p TRParen ")";
          e := Call (!e, List.rev !args)
        | _ ->
          (match parse_coll_postfix p !e with
           | Some e' -> e := e'
           | None -> fin := true)
    done;
    if peek p = TCaret then begin ignore (advance p); Bin (Pow, !e, parse_out_term p) end
    else !e

(* ------------------------------------------------------------- statements *)

and parse_block p =
  expect p TLBrace "'{'";
  let acc = ref [] in
  while peek p <> TRBrace && peek p <> TEOF do acc := parse_stmt p :: !acc done;
  expect p TRBrace "'}'";
  List.rev !acc

and parse_lvalue p =
  let base = LVar (ident p) in
  let lv = ref base in
  while peek p = TLBracket do
    ignore (advance p);
    let idx = parse_expr p in
    expect p TRBracket "']'";
    lv := LIndex (!lv, idx)
  done;
  !lv

and parse_stmt p =
  match peek p with
  | TNewline -> ignore (advance p); Output [ SLit "\n" ]
  | TSemi -> ignore (advance p); Output []          (* a separator, not a statement *)
  | TOut -> parse_output p
  | TIn -> parse_input p
  | TIf -> parse_if p
  | TAt | TAtLabel _ -> parse_loop p
  | TAtBreak -> ignore (advance p); Break None
  | TAtCont -> ignore (advance p); Continue None
  | TAtLabelBreak l -> ignore (advance p); Break (Some l)
  | TAtLabelCont l -> ignore (advance p); Continue (Some l)
  | TAtSleep -> ignore (advance p); Sleep (parse_expr p)
  | TBackslash -> ignore (advance p); Discard (ident p)
  | TTry -> parse_try p
  | TNumeralMode b -> ignore (advance p); NumeralMode b
  | TImport -> parse_import p
  | TExport -> parse_export p
  | TModule -> parse_module p
  | TRet ->
    ignore (advance p);
    if is_delimiter (peek p) || starts_statement (peek p) && peek p <> TMatch then Ret None
    (* `<~ param " [processed]"` concatenates, exactly as `=` and `>>` do. *)
    else Ret (Some (parse_assign_rhs p))
  | TIdent _ when is_func_decl p -> parse_func p
  | TIdent _ ->
    let save = p.pos in
    let lv = parse_lvalue p in
    (match peek p with
     | TAssign -> ignore (advance p); Assign (lv, parse_assign_rhs p)
     | TConstAssign ->
       (match lv with
        | LVar n -> ignore (advance p); ConstDecl (n, parse_assign_rhs p)
        | _ -> fail p "only a plain name can be declared as a constant")
     | TPlusEq -> ignore (advance p); OpAssign (lv, Add, parse_expr p)
     | TMinusEq -> ignore (advance p); OpAssign (lv, Sub, parse_expr p)
     | TStarEq -> ignore (advance p); OpAssign (lv, Mul, parse_expr p)
     | TSlashEq -> ignore (advance p); OpAssign (lv, Div, parse_expr p)
     | TPercentEq -> ignore (advance p); OpAssign (lv, Mod, parse_expr p)
     | TCaretEq -> ignore (advance p); OpAssign (lv, Pow, parse_expr p)
     | TInc -> ignore (advance p); IncDec (lv, 1)
     | TDec -> ignore (advance p); IncDec (lv, -1)
     | _ -> p.pos <- save; ExprStmt (parse_expr p))
  | _ -> ExprStmt (parse_expr p)

(* The right-hand side of an assignment uses the same juxtaposition rule as
   `>>`: `full = first " " last` concatenates three items.  Items must sit on
   the same source line as the one before them, which is what keeps the next
   statement out. *)
and parse_assign_rhs p =
  let first = parse_expr p in
  let more = ref [] in
  let continues () =
    p.pos > 0 && line p = p.toks.(p.pos - 1).line
    && not (starts_statement (peek p))
    && (match peek p, peek_at p 1 with
        | TIdent _, (TAssign | TConstAssign | TPlusEq | TMinusEq | TStarEq
                    | TSlashEq | TPercentEq | TCaretEq | TInc | TDec) -> false
        | (TStr _ | TInt _ | TFloat _ | TChar _ | TIdent _ | TTrue | TFalse
          | TLParen | TLBracket), _ -> true
        | _ -> false)
  in
  while continues () do more := parse_out_item p :: !more done;
  if !more = [] then first else Concat (first :: List.rev !more)

(* `<# ./lib/utils => u` — the alias is required. *)
and parse_import p =
  expect p TImport "'<#'";
  let b = Buffer.create 32 in
  (* A path is a run of `.`, `/` and name tokens; it ends at `=>`. *)
  let fin = ref false in
  while not !fin do
    match peek p with
    | TDot -> ignore (advance p); Buffer.add_char b '.'
    | TDotDot -> ignore (advance p); Buffer.add_string b ".."
    | TSlash -> ignore (advance p); Buffer.add_char b '/'
    | TIdent n -> ignore (advance p); Buffer.add_string b n
    | TInt n -> ignore (advance p); Buffer.add_string b (string_of_int n)
    | TMinus -> ignore (advance p); Buffer.add_char b '-'
    | TStr s -> ignore (advance p); Buffer.add_string b s
    | _ -> fin := true
  done;
  expect p TFatArrow "'=>'";
  Import (Buffer.contents b, ident p)

(* `#> { name, other => public, alias::fn, alias.CONST }` — entries are
   separated by commas or just by whitespace. *)
and parse_export p =
  expect p TExport "'#>'";
  expect p TLBrace "'{'";
  let items = ref [] in
  while peek p <> TRBrace && peek p <> TEOF do
    if peek p = TComma then ignore (advance p)
    else begin
      let n = ident p in
      let src =
        if peek p = TColonColon then begin ignore (advance p); EReFun (n, ident p) end
        else if peek p = TDot then begin ignore (advance p); EReConst (n, ident p) end
        else EOwn n
      in
      let public =
        if peek p = TFatArrow then begin ignore (advance p); ident p end
        else (match src with
            | EOwn x -> x | EReFun (_, x) -> x | EReConst (_, x) -> x)
      in
      items := { esrc = src; epublic = public } :: !items
    end
  done;
  expect p TRBrace "'}'";
  Export (List.rev !items)

(* `# name { ... }` — a module file holds exactly one of these. *)
and parse_module p =
  expect p TModule "'#'";
  let b = Buffer.create 32 in
  (* `# .subfolder_file` is the subdirectory convention. *)
  if peek p = TDot then begin ignore (advance p); Buffer.add_char b '.' end;
  Buffer.add_string b (ident p);
  ModuleDecl (Buffer.contents b, parse_block p)

(* `!? { } :! ##Kind { } :! { } :> { }` — typed catches first, then the
   untyped catch-all, then an optional finally. *)
and parse_try p =
  expect p TTry "'!?'";
  let body = parse_block p in
  let catches = ref [] in
  while peek p = TCatch do
    ignore (advance p);
    let kind = match peek p with
      | TErrType t -> ignore (advance p); if t = "_" then None else Some t
      | _ -> None
    in
    catches := (kind, parse_block p) :: !catches
  done;
  let fin = if peek p = TFinally then begin ignore (advance p); Some (parse_block p) end
    else None in
  Try (body, List.rev !catches, fin)

and parse_output p =
  ignore (advance p);                                    (* >> *)
  let items = ref [] in
  (* Only a real delimiter suppresses the first item: `>> ?? x { ... }` prints
     the result of a match. *)
  if not (is_delimiter (peek p)) then begin
    items := [ parse_out_item p ];
    let fin = ref false in
    while not !fin do
      if starts_statement (peek p) then fin := true
      else match peek p, peek_at p 1 with
        (* `name =` after an item begins the next statement. *)
        | TIdent _, (TAssign | TConstAssign | TPlusEq | TMinusEq | TStarEq
                    | TSlashEq | TPercentEq | TCaretEq | TInc | TDec) -> fin := true
        | _ -> items := parse_out_item p :: !items
    done
  end;
  Output (List.rev !items)

and parse_input p =
  ignore (advance p);                                    (* << *)
  match peek p with
  | TStr s -> ignore (advance p); Input (Some (split_interp s), ident p)
  | _ -> Input (None, ident p)

and parse_if p =
  ignore (advance p);                                    (* ? *)
  let cond = parse_expr p in
  let body = parse_block p in
  let branches = ref [ (cond, body) ] in
  let els = ref None in
  let fin = ref false in
  while not !fin do
    match peek p with
    | TElseIf ->
      ignore (advance p);
      let c = parse_expr p in
      branches := (c, parse_block p) :: !branches
    | TUnderscore -> ignore (advance p); els := Some (parse_block p); fin := true
    | _ -> fin := true
  done;
  If (List.rev !branches, !els)

and parse_loop p =
  let label = match advance p with
    | TAtLabel l -> Some l
    | _ -> None
  in
  let head =
    if peek p = TLBrace then Infinite
    else match peek p, peek_at p 1 with
      | TIdent v, TColon ->
        p.pos <- p.pos + 2;
        let a = parse_add p in
        if peek p = TDotDot then begin
          ignore (advance p);
          let b = parse_add p in
          let step = if peek p = TColon then begin ignore (advance p); Some (parse_add p) end
            else None in
          ForRange (v, a, b, step)
        end else ForEach (v, a)
      | _ -> Count (parse_expr p)
  in
  Loop (label, head, parse_block p)

and parse_func p =
  let name = ident p in
  expect p TLParen "'('";
  let ps = ref [] in
  if peek p <> TRParen then begin
    let one () =
      let n = ident p in
      let out = peek p = TRet in
      if out then ignore (advance p);
      { pname = n; pout = out }
    in
    ps := [ one () ];
    while peek p = TComma do ignore (advance p); ps := one () :: !ps done
  end;
  expect p TRParen ")";
  FuncDecl (name, List.rev !ps, parse_block p)

(* ------------------------------------------------------------------ entry *)

let parse (toks : Lexer.t array) : program =
  let p = { toks; pos = 0 } in
  let acc = ref [] in
  while peek p <> TEOF do acc := parse_stmt p :: !acc done;
  List.rev !acc
