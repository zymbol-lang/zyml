(* Tokenizer.

   Zymbol is keyword-free, so nearly every token is a symbol and many symbols
   share a prefix (`>` `>=` `>>`, `<` `<=` `<>` `<~` `<<`).  The scanner is a
   flat longest-match dispatch on the first byte; whitespace is never
   significant except inside `@:label`, which must not contain a space. *)

type token =
  (* literals *)
  | TInt of int
  | TFloat of float
  | TStr of string          (* interpolation markers still present *)
  | TChar of string
  | TIdent of string
  | TTrue | TFalse
  (* arithmetic / logic *)
  | TPlus | TMinus | TStar | TSlash | TPercent | TCaret
  | TEq | TNeq | TLt | TGt | TLe | TGe
  | TAnd | TOr | TNot
  (* assignment *)
  | TAssign | TConstAssign
  | TPlusEq | TMinusEq | TStarEq | TSlashEq | TPercentEq | TCaretEq
  | TInc | TDec
  (* structure *)
  | TLBrace | TRBrace | TLParen | TRParen | TLBracket | TRBracket
  | TComma | TColon | TDotDot | TDot
  (* control *)
  | TIf | TElseIf | TUnderscore
  | TArrow | TFatArrow | TRet
  | TAt | TAtBreak | TAtCont | TAtSleep
  | TAtLabel of string | TAtLabelBreak of string | TAtLabelCont of string
  (* io *)
  | TOut | TIn | TNewline
  (* collection *)
  | TLen | TAppend | TContains | TDollarBracket
  | TInsertAt | TRemove | TRemoveAll | TRemoveAt | TFindAll
  | TSortAsc | TSortDesc | TSortBy
  | TMap | TFilter | TReduce | TSplit | TRepeat | TReplace | TBuild | TUpdate
  | TIsErr | TPropErr
  (* meta *)
  | TTypeOf
  | TCastFloat | TCastRound | TCastTrunc
  | TFmtOpen of Ast.fmt_style * Ast.fmt_prec
  | TBar
  | TPipeOp
  | TBackslash
  | TSemi
  | TMatch
  | TBaseConv of char           (* 0x| 0b| 0o| 0d| *)
  | TTry | TCatch | TFinally
  | TImport | TExport | TModule | TColonColon
  | TShellOpen | TShellClose
  | TOutClear | TOutSize | TOutPos | TOutGate
  | TNumeralMode of int         (* #d0d9# — the script's zero code point *)
  | TErrType of string          (* ##Div, ##Index, ##_ *)
  | TEOF


type t = { tok : token; line : int }

exception Lex_error of string * int

(* Interpolation markers: the lexer resolves `\{` / `\}` to these private bytes
   so the parser can split on the remaining, genuine `{` `}`. *)
let mark_lbrace = '\001'
let mark_rbrace = '\002'

let show = function
  | TInt i -> string_of_int i
  | TFloat f -> string_of_float f
  | TStr s -> "\"" ^ s ^ "\""
  | TChar c -> "'" ^ c ^ "'"
  | TIdent s -> s
  | TTrue -> "#1" | TFalse -> "#0"
  | TPlus -> "+" | TMinus -> "-" | TStar -> "*" | TSlash -> "/"
  | TPercent -> "%" | TCaret -> "^"
  | TEq -> "==" | TNeq -> "<>" | TLt -> "<" | TGt -> ">" | TLe -> "<=" | TGe -> ">="
  | TAnd -> "&&" | TOr -> "||" | TNot -> "!"
  | TAssign -> "=" | TConstAssign -> ":="
  | TPlusEq -> "+=" | TMinusEq -> "-=" | TStarEq -> "*=" | TSlashEq -> "/="
  | TPercentEq -> "%=" | TCaretEq -> "^=" | TInc -> "++" | TDec -> "--"
  | TLBrace -> "{" | TRBrace -> "}" | TLParen -> "(" | TRParen -> ")"
  | TLBracket -> "[" | TRBracket -> "]"
  | TComma -> "," | TColon -> ":" | TDotDot -> ".." | TDot -> "."
  | TIf -> "?" | TElseIf -> "_?" | TUnderscore -> "_"
  | TArrow -> "->" | TFatArrow -> "=>" | TRet -> "<~"
  | TAt -> "@" | TAtBreak -> "@!" | TAtCont -> "@>" | TAtSleep -> "@~"
  | TAtLabel s -> "@:" ^ s | TAtLabelBreak s -> "@:" ^ s ^ "!"
  | TAtLabelCont s -> "@:" ^ s ^ ">"
  | TOut -> ">>" | TIn -> "<<" | TNewline -> "\xc2\xb6"
  | TLen -> "$#" | TAppend -> "$+" | TContains -> "$?" | TDollarBracket -> "$["
  | TInsertAt -> "$+[" | TRemove -> "$-" | TRemoveAll -> "$--" | TRemoveAt -> "$-["
  | TFindAll -> "$??" | TSortAsc -> "$^+" | TSortDesc -> "$^-" | TSortBy -> "$^"
  | TMap -> "$>" | TFilter -> "$|" | TReduce -> "$<" | TSplit -> "$/"
  | TRepeat -> "$*" | TReplace -> "$~~[" | TBuild -> "$++" | TUpdate -> "$~"
  | TIsErr -> "$!" | TPropErr -> "$!!"
  | TTypeOf -> "#?" | TCastFloat -> "##." | TCastRound -> "###" | TCastTrunc -> "##!"
  | TFmtOpen (st, pr) ->
    (match st with Ast.FPlain -> "#" | Ast.FComma -> "#," | Ast.FSci -> "#^")
    ^ (match pr with Ast.PNone -> "" | Ast.PRound n -> "." ^ string_of_int n
                                     | Ast.PTrunc n -> "!" ^ string_of_int n) ^ "|"
  | TBar -> "|" | TPipeOp -> "|>" | TBackslash -> "\\" | TSemi -> ";"
  | TMatch -> "??"
  | TBaseConv c -> Printf.sprintf "0%c|" c
  | TTry -> "!?" | TCatch -> ":!" | TFinally -> ":>"
  | TImport -> "<#" | TExport -> "#>" | TModule -> "#" | TColonColon -> "::"
  | TShellOpen -> "<\\" | TShellClose -> "\\>"
  | TOutClear -> ">>!" | TOutSize -> ">>?" | TOutPos -> ">>~" | TOutGate -> ">>|"
  | TNumeralMode b -> Printf.sprintf "#<%04X>#" b
  | TErrType t -> "##" ^ t
  | TEOF -> "<eof>"

(* An identifier byte: ASCII letter, digit, `_`, or any byte of a multi-byte
   UTF-8 character.  Zymbol allows identifiers in every script, and the only
   non-ASCII characters that are *operators* are handled before we get here. *)
let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' || Char.code c >= 0x80

let is_ident_char c = is_ident_start c || (c >= '0' && c <= '9')

let is_digit c = c >= '0' && c <= '9'

let tokenize (src : string) : t array =
  let n = String.length src in
  let i = ref 0 in
  let line = ref 1 in
  let toks = ref [] in
  let push tk = toks := { tok = tk; line = !line } :: !toks in
  let peek k = if !i + k < n then src.[!i + k] else '\000' in
  let fail msg = raise (Lex_error (msg, !line)) in

  (* `¶` is U+00B6 = C2 B6, `°` is U+00B0 = C2 B0. *)
  let is_pilcrow () = peek 0 = '\xc2' && peek 1 = '\xb6' in

  let read_ident () =
    let s = !i in
    while !i < n && is_ident_char src.[!i] do incr i done;
    String.sub src s (!i - s)
  in

  (* A base-prefixed literal is a *character* code, not an integer:
     0x41, 0b01000001, 0o0101 and 0d65 all denote 'A'. *)
  let utf8_encode = Value.utf8_encode in

  (* Decode the UTF-8 character starting at [k]; returns its code point and the
     index just past it. *)
  let decode_at k =
    if k >= n then (0, k + 1)
    else
      let b0 = Char.code src.[k] in
      if b0 < 0x80 then (b0, k + 1)
      else if b0 < 0xE0 && k + 1 < n then
        (((b0 land 0x1F) lsl 6) lor (Char.code src.[k+1] land 0x3F), k + 2)
      else if b0 < 0xF0 && k + 2 < n then
        (((b0 land 0x0F) lsl 12) lor ((Char.code src.[k+1] land 0x3F) lsl 6)
         lor (Char.code src.[k+2] land 0x3F), k + 3)
      else if k + 3 < n then
        (((b0 land 0x07) lsl 18) lor ((Char.code src.[k+1] land 0x3F) lsl 12)
         lor ((Char.code src.[k+2] land 0x3F) lsl 6)
         lor (Char.code src.[k+3] land 0x3F), k + 4)
      else (b0, k + 1)
  in

  (* A literal may be written in any supported digit script, but must use one
     script throughout: `४२` is 42. *)
  let native_digit_base k =
    if k >= n || Char.code src.[k] < 0x80 then None
    else let (cp, _) = decode_at k in
      match Value.base_of_cp cp with
      | Some b when b <> 0x30 -> Some b
      | _ -> None
  in

  let read_native_number base =
    let b = Buffer.create 8 in
    let take_digits () =
      let fin = ref false in
      let any = ref false in
      while not !fin do
        if !i >= n || Char.code src.[!i] < 0x80 then fin := true
        else begin
          let (cp, next) = decode_at !i in
          if cp >= base && cp <= base + 9 then begin
            Buffer.add_char b (Char.chr (48 + cp - base));
            i := next;
            any := true
          end else fin := true
        end
      done;
      !any
    in
    ignore (take_digits ());
    (* The decimal point stays ASCII in every script, so `𞥓.𞥕` is 3.5. *)
    let is_float =
      if !i < n && src.[!i] = '.'
         && (match native_digit_base (!i + 1) with Some b -> b = base | None -> false)
      then begin
        Buffer.add_char b '.';
        incr i;
        ignore (take_digits ());
        true
      end else false
    in
    let txt = Buffer.contents b in
    if is_float then TFloat (float_of_string txt) else TInt (int_of_string txt)
  in

  let read_number () =
    let s = !i in
    (* `0x|expr|` converts a number *to* a base string; `0x41` is a literal. *)
    if peek 0 = '0' && peek 2 = '|'
       && (match Char.lowercase_ascii (peek 1) with
           | 'x' | 'b' | 'o' | 'd' -> true | _ -> false) then begin
      let base = Char.lowercase_ascii (peek 1) in
      i := !i + 3;
      TBaseConv base
    end else if peek 0 = '0' && (peek 1 = 'x' || peek 1 = 'X') then begin
      i := !i + 2;
      while !i < n && (is_digit src.[!i] || (Char.lowercase_ascii src.[!i] >= 'a'
                                             && Char.lowercase_ascii src.[!i] <= 'f')) do incr i done;
      TChar (utf8_encode (int_of_string (String.sub src s (!i - s))))
    end else if peek 0 = '0' && (peek 1 = 'b' || peek 1 = 'B' || peek 1 = 'o'
                                 || peek 1 = 'O') then begin
      i := !i + 2;
      while !i < n && is_ident_char src.[!i] do incr i done;
      TChar (utf8_encode (int_of_string (String.sub src s (!i - s))))
    end else if peek 0 = '0' && (peek 1 = 'd' || peek 1 = 'D') then begin
      i := !i + 2;
      let ds = !i in
      while !i < n && is_digit src.[!i] do incr i done;
      TChar (utf8_encode (int_of_string (String.sub src ds (!i - ds))))
    end else begin
      while !i < n && is_digit src.[!i] do incr i done;
      let isf = ref false in
      (* `1..5` is a range, not a float: only consume `.` when a digit follows. *)
      if peek 0 = '.' && is_digit (peek 1) then begin
        isf := true; incr i;
        while !i < n && is_digit src.[!i] do incr i done
      end;
      if (peek 0 = 'e' || peek 0 = 'E')
         && (is_digit (peek 1) || ((peek 1 = '+' || peek 1 = '-') && is_digit (peek 2)))
      then begin
        isf := true; incr i;
        if peek 0 = '+' || peek 0 = '-' then incr i;
        while !i < n && is_digit src.[!i] do incr i done
      end;
      let txt = String.sub src s (!i - s) in
      if !isf then TFloat (float_of_string txt) else TInt (int_of_string txt)
    end
  in

  let read_string () =
    incr i;                                   (* opening quote *)
    let b = Buffer.create 32 in
    let fin = ref false in
    while not !fin do
      if !i >= n then fail "unterminated string literal";
      match src.[!i] with
      | '"' -> incr i; fin := true
      | '\\' ->
        incr i;
        if !i >= n then fail "unterminated escape";
        let c = src.[!i] in
        incr i;
        Buffer.add_string b
          (match c with
           | 'n' -> "\n" | 't' -> "\t" | 'r' -> "\r"
           | '"' -> "\"" | '\\' -> "\\"
           | '{' -> String.make 1 mark_lbrace
           | '}' -> String.make 1 mark_rbrace
           | c -> String.make 1 c)
      | '\n' -> incr line; Buffer.add_char b '\n'; incr i
      | c -> Buffer.add_char b c; incr i
    done;
    Buffer.contents b
  in

  let read_char () =
    incr i;                                   (* opening quote *)
    let s =
      if peek 0 = '\\' then begin
        incr i;
        let c = src.[!i] in
        incr i;
        match c with
        | 'n' -> "\n" | 't' -> "\t" | 'r' -> "\r" | '0' -> "\000"
        | c -> String.make 1 c
      end else begin
        (* one whole UTF-8 character *)
        let s = !i in
        incr i;
        while !i < n && Char.code src.[!i] land 0xC0 = 0x80 do incr i done;
        String.sub src s (!i - s)
      end
    in
    if peek 0 <> '\'' then fail "unterminated character literal";
    incr i;
    s
  in

  while !i < n do
    let c = src.[!i] in
    if c = '\n' then begin incr line; incr i end
    else if c = ' ' || c = '\t' || c = '\r' then incr i
    else if c = '/' && peek 1 = '/' then
      while !i < n && src.[!i] <> '\n' do incr i done
    else if c = '/' && peek 1 = '*' then begin
      let depth = ref 1 in
      i := !i + 2;
      while !depth > 0 do
        if !i >= n then fail "unterminated block comment";
        if src.[!i] = '\n' then incr line;
        if peek 0 = '/' && peek 1 = '*' then begin incr depth; i := !i + 2 end
        else if peek 0 = '*' && peek 1 = '/' then begin decr depth; i := !i + 2 end
        else incr i
      done
    end
    else if is_pilcrow () then begin push TNewline; i := !i + 2 end
    else if is_digit c then push (read_number ())
    else if native_digit_base !i <> None then
      push (read_native_number (Option.get (native_digit_base !i)))
    else if c = '"' then push (TStr (read_string ()))
    else if c = '\'' then push (TChar (read_char ()))
    else if is_ident_start c then begin
      (* `_?` is else-if; a bare `_` is the else / wildcard slot. *)
      if c = '_' && peek 1 = '?' then begin push TElseIf; i := !i + 2 end
      else if c = '_' && not (is_ident_char (peek 1)) then begin push TUnderscore; incr i end
      else push (TIdent (read_ident ()))
    end
    else begin
      match c with
      | '@' ->
        if peek 1 = '!' then begin push TAtBreak; i := !i + 2 end
        else if peek 1 = '>' then begin push TAtCont; i := !i + 2 end
        else if peek 1 = '~' then begin push TAtSleep; i := !i + 2 end
        else if peek 1 = ':' then begin
          i := !i + 2;
          let name = read_ident () in
          if name = "" then fail "expected a label name after '@:'";
          if peek 0 = '!' then begin push (TAtLabelBreak name); incr i end
          else if peek 0 = '>' then begin push (TAtLabelCont name); incr i end
          else push (TAtLabel name)
        end
        else begin push TAt; incr i end
      | '>' ->
        (* The TUI operators bind tightly: `>>!` is clear-screen, while
           `>> !flag` (with the space) is output of a negation. *)
        if peek 1 = '>' && peek 2 = '!' then begin push TOutClear; i := !i + 3 end
        else if peek 1 = '>' && peek 2 = '?' then begin push TOutSize; i := !i + 3 end
        else if peek 1 = '>' && peek 2 = '~' then begin push TOutPos; i := !i + 3 end
        else if peek 1 = '>' && peek 2 = '|' then begin push TOutGate; i := !i + 3 end
        else if peek 1 = '>' then begin push TOut; i := !i + 2 end
        else if peek 1 = '=' then begin push TGe; i := !i + 2 end
        else begin push TGt; incr i end
      | '<' ->
        if peek 1 = '<' then begin push TIn; i := !i + 2 end
        else if peek 1 = '>' then begin push TNeq; i := !i + 2 end
        else if peek 1 = '=' then begin push TLe; i := !i + 2 end
        else if peek 1 = '~' then begin push TRet; i := !i + 2 end
        else if peek 1 = '#' then begin push TImport; i := !i + 2 end
        else if peek 1 = '\\' then begin push TShellOpen; i := !i + 2 end
        else begin push TLt; incr i end
      | '=' ->
        if peek 1 = '=' then begin push TEq; i := !i + 2 end
        else if peek 1 = '>' then begin push TFatArrow; i := !i + 2 end
        else begin push TAssign; incr i end
      | '+' ->
        if peek 1 = '+' then begin push TInc; i := !i + 2 end
        else if peek 1 = '=' then begin push TPlusEq; i := !i + 2 end
        else begin push TPlus; incr i end
      | '-' ->
        if peek 1 = '>' then begin push TArrow; i := !i + 2 end
        else if peek 1 = '-' then begin push TDec; i := !i + 2 end
        else if peek 1 = '=' then begin push TMinusEq; i := !i + 2 end
        else begin push TMinus; incr i end
      | '*' ->
        if peek 1 = '=' then begin push TStarEq; i := !i + 2 end
        else begin push TStar; incr i end
      | '/' ->
        if peek 1 = '=' then begin push TSlashEq; i := !i + 2 end
        else begin push TSlash; incr i end
      | '%' ->
        if peek 1 = '=' then begin push TPercentEq; i := !i + 2 end
        else begin push TPercent; incr i end
      | '^' ->
        if peek 1 = '=' then begin push TCaretEq; i := !i + 2 end
        else begin push TCaret; incr i end
      | '&' -> if peek 1 = '&' then begin push TAnd; i := !i + 2 end
        else fail "single '&' is not an operator"
      | '|' ->
        if peek 1 = '|' then begin push TOr; i := !i + 2 end
        else if peek 1 = '>' then begin push TPipeOp; i := !i + 2 end
        (* A lone `|` only occurs as the closing fence of `#…|expr|`. *)
        else begin push TBar; incr i end
      | '!' ->
        (* `!?` opens a try block; a bare `!` is logical not. *)
        if peek 1 = '?' then begin push TTry; i := !i + 2 end
        else begin push TNot; incr i end
      | '?' ->
        if peek 1 = '?' then begin push TMatch; i := !i + 2 end
        else begin push TIf; incr i end
      | ';' -> push TSemi; incr i
      (* Collection operators: longest match first, since `$-`, `$--` and
         `$-[` all share a prefix (and so do `$?`/`$??`, `$+`/`$++`/`$+[`,
         `$^`/`$^+`/`$^-`, `$~`/`$~~[`, `$!`/`$!!`). *)
      | '$' ->
        (match peek 1, peek 2 with
         | '#', _ -> push TLen; i := !i + 2
         | '?', '?' -> push TFindAll; i := !i + 3
         | '?', _ -> push TContains; i := !i + 2
         | '+', '+' -> push TBuild; i := !i + 3
         | '+', '[' -> push TInsertAt; i := !i + 3
         | '+', _ -> push TAppend; i := !i + 2
         | '-', '-' -> push TRemoveAll; i := !i + 3
         | '-', '[' -> push TRemoveAt; i := !i + 3
         | '-', _ -> push TRemove; i := !i + 2
         | '~', '~' ->
           if peek 3 <> '[' then fail "expected '[' after '$~~'";
           push TReplace; i := !i + 4
         | '~', _ -> push TUpdate; i := !i + 2
         | '^', '+' -> push TSortAsc; i := !i + 3
         | '^', '-' -> push TSortDesc; i := !i + 3
         | '^', _ -> push TSortBy; i := !i + 2
         | '!', '!' -> push TPropErr; i := !i + 3
         | '!', _ -> push TIsErr; i := !i + 2
         | '[', _ -> push TDollarBracket; i := !i + 2
         | '>', _ -> push TMap; i := !i + 2
         | '|', _ -> push TFilter; i := !i + 2
         | '<', _ -> push TReduce; i := !i + 2
         | '/', _ -> push TSplit; i := !i + 2
         | '*', _ -> push TRepeat; i := !i + 2
         | c, _ -> fail (Printf.sprintf "unsupported collection operator '$%c'" c))

      (* `#` is the meta prefix: booleans, casts, type query, and the
         `#<style><precision>|expr|` number-formatting family. *)
      (* `#d0d9#`: the script's 0 and its 9, then a closing `#`.  Tested before
         `#0`/`#1`, because `#09#` starts with `#0`. *)
      | '#' when (let (c0, k1) = decode_at (!i + 1) in
                  k1 < n &&
                  (let (c9, k2) = decode_at k1 in
                   c9 = c0 + 9 && Value.base_of_cp c0 = Some c0
                   && k2 < n && src.[k2] = '#')) ->
        let (c0, k1) = decode_at (!i + 1) in
        let (_, k2) = decode_at k1 in
        i := k2 + 1;
        push (TNumeralMode c0)
      (* `#1`/`#0` may be written with any script's digit: `#१`, `#𝟷`, `#𞥑`. *)
      | '#' when (Char.code (peek 1) >= 0x80
                  && (let (cp, _) = decode_at (!i + 1) in
                      match Value.base_of_cp cp with
                      | Some b -> cp - b <= 1
                      | None -> false)) ->
        let (cp, k) = decode_at (!i + 1) in
        let b = Option.get (Value.base_of_cp cp) in
        i := k;
        push (if cp - b = 1 then TTrue else TFalse)
      | '#' ->
        (match peek 1, peek 2 with
         | '>', _ -> push TExport; i := !i + 2
         (* `# name {` declares a module; the space is what separates it from
            every other `#` operator, all of which bind tightly. *)
         | (' ' | '\t'), _ -> push TModule; incr i
         | '1', _ -> push TTrue; i := !i + 2
         | '0', _ -> push TFalse; i := !i + 2
         | '?', _ -> push TTypeOf; i := !i + 2
         | '#', '#' -> push TCastRound; i := !i + 3
         | '#', '.' -> push TCastFloat; i := !i + 3
         | '#', '!' -> push TCastTrunc; i := !i + 3
         (* `##Div`, `##Index`, `##_` name an error kind in a `:!` arm. *)
         | '#', c when is_ident_start c ->
           i := !i + 2;
           push (TErrType (read_ident ()))
         | _ ->
           incr i;
           let style =
             match peek 0 with
             | ',' -> incr i; Ast.FComma
             | '^' -> incr i; Ast.FSci
             | _ -> Ast.FPlain
           in
           let prec =
             match peek 0 with
             | '.' | '!' when is_digit (peek 1) ->
               let round = peek 0 = '.' in
               incr i;
               let s = !i in
               while !i < n && is_digit src.[!i] do incr i done;
               let d = int_of_string (String.sub src s (!i - s)) in
               if round then Ast.PRound d else Ast.PTrunc d
             | _ -> Ast.PNone
           in
           if peek 0 <> '|' then fail "unsupported '#' operator";
           incr i;
           push (TFmtOpen (style, prec)))
      | ':' ->
        if peek 1 = '=' then begin push TConstAssign; i := !i + 2 end
        else if peek 1 = '!' then begin push TCatch; i := !i + 2 end
        else if peek 1 = '>' then begin push TFinally; i := !i + 2 end
        else if peek 1 = ':' then begin push TColonColon; i := !i + 2 end
        else begin push TColon; incr i end
      | '.' ->
        if peek 1 = '.' then begin push TDotDot; i := !i + 2 end
        else begin push TDot; incr i end
      | '\\' ->
        (* `\\` emits a newline, `\>` closes a shell block, and a lone `\`
           ends a variable's lifetime. *)
        if peek 1 = '\\' then begin push TNewline; i := !i + 2 end
        else if peek 1 = '>' then begin push TShellClose; i := !i + 2 end
        else begin push TBackslash; incr i end
      | '{' -> push TLBrace; incr i
      | '}' -> push TRBrace; incr i
      | '(' -> push TLParen; incr i
      | ')' -> push TRParen; incr i
      | '[' -> push TLBracket; incr i
      | ']' -> push TRBracket; incr i
      | ',' -> push TComma; incr i
      | c -> fail (Printf.sprintf "unexpected character '%c'" c)
    end
  done;
  push TEOF;
  Array.of_list (List.rev !toks)
