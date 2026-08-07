(* Abstract syntax tree.

   The tree is deliberately small: it exists only long enough for [Compile] to
   turn it into closures, so it carries no spans and no analysis results. *)

type binop =
  | Add | Sub | Mul | Div | Mod | Pow
  | Eq | Neq | Lt | Gt | Le | Ge
  | And | Or

type unop = Not | Neg

(* The `#<style><precision>|expr|` formatting family.  Declared here rather than
   in the lexer because both the lexer and the AST carry it. *)
type fmt_style = FPlain | FComma | FSci
type fmt_prec = PNone | PRound of int | PTrunc of int

type expr =
  | ILit of int
  | FLit of float
  | SLit of string
  | CLit of string
  | BLit of bool
  | Interp of ipart list          (* "text {name} text" *)
  | ArrLit of expr list
  | TupLit of expr list
  | Var of string
  | Bin of binop * expr * expr
  | Un of unop * expr
  | Call of expr * expr list
  | Index of expr * expr
  | Lambda of string list * lbody
  | Len of expr                   (* x$#     *)
  | Append of expr * expr         (* x$+ v   *)
  | Contains of expr * expr       (* x$? v   *)
  | TypeOf of expr                (* x#?     *)
  | Slice of expr * expr * expr   (* x$[a..b] *)
  (* collection family *)
  | InsertAt of expr * expr * expr        (* x$+[i] v      *)
  | Remove of expr * expr                 (* x$- v         *)
  | RemoveAll of expr * expr              (* x$-- v        *)
  | RemoveAt of expr * expr * expr option (* x$-[i] / $-[a..b] *)
  | FindAll of expr * expr                (* x$?? v        *)
  | Sort of expr * bool                   (* x$^+ / x$^-   *)
  | SortBy of expr * expr                 (* x$^ cmp       *)
  | Map of expr * expr                    (* x$> f         *)
  | Filter of expr * expr                 (* x$| f         *)
  | Reduce of expr * expr * expr          (* x$< (init, f) *)
  | Split of expr * expr                  (* x$/ sep       *)
  | Repeat of expr * expr                 (* x$* n         *)
  | Replace of expr * expr * expr * expr option  (* x$~~[p:r:n] *)
  | Build of expr * expr list             (* x$++ a b c    *)
  | Update of expr * expr                 (* arr[i]$~ v    *)
  (* meta family *)
  | Cast of cast * expr                   (* ##. ### ##!   *)
  | Fmt of fmt_style * fmt_prec * expr     (* #…|x|         *)
  | BaseConv of char * expr               (* 0x|n| 0b| 0o| 0d| *)
  | Concat of expr list                   (* juxtaposed items on one line *)
  | Nav of expr * navspec                 (* arr[i>j], arr[p ; q], arr[[g] ; [g]] *)
  | Match of expr * (pattern * mbody) list
  | NTupLit of (string * expr) list       (* (x: 1, y: 2)  *)
  | Field of expr * string                (* tuple.field   *)
  | IsErr of expr                         (* x$!           *)
  | PropE of expr                         (* x$!! — early-return if error *)
  | Shell of expr                         (* <\ cmd \>    *)
  | TermSize                              (* >>?  -> [rows, cols] *)
  (* `°x` / `x°`: auto-initialised to the neutral value on first use.  The
     position decides the scope it is anchored to, not the value. *)
  | Hot of bool * string                  (* true = prefix `°x` *)
  | ModCall of string * string * expr list  (* alias::fn(args) *)
  | ModConst of string * string             (* alias.CONST     *)

(* Match patterns.  `??` is pure pattern matching -- it never evaluates a
   boolean condition, which is what `?`/`_?` are for. *)
and pattern =
  | PWild                                 (* _            *)
  | PLit of expr                          (* 90, "red", 'A' *)
  | PRange of expr * expr                 (* 90..100      *)
  | PCmp of binop * expr                  (* < 0, >= x    *)
  | PIdent of string                      (* scalar: equality; array: containment *)
  | PList of pattern list                 (* array: structural; scalar: containment *)
  | POr of pattern list                   (* p || q       *)

and mbody = MExpr of expr | MBlock of stmt list

(* Inside a postfix `[...]`, `>` is a depth separator, never a comparison.
   A step may be a single index or a range that fans out along that axis. *)
and navstep = NIdx of expr | NRange of expr * expr

and navspec =
  | NPath of navstep list                 (* arr[i>j]        -> one value    *)
  | NFlat of navstep list list            (* arr[p ; q]      -> flat array   *)
  | NStruct of navstep list list list     (* arr[[a,b];[c]]  -> array of arrays *)

and cast = ToFloat | ToIntRound | ToIntTrunc

and dslot = DName of string | DRest of string | DSkip
and dpat =
  | DSeq of dslot list                    (* [a, b] or (a, b) *)
  | DFields of (string * string) list     (* (name: n, age: a) *)

and ipart = ILit_text of string | ILit_var of string

and lbody = LExpr of expr | LBlock of stmt list

and lvalue =
  | LVar of string
  | LHot of bool * string
  | LIndex of lvalue * expr

and param = { pname : string; pout : bool }

and loop_head =
  | Infinite
  | Count of expr                        (* @ N  /  @ cond — decided at runtime *)
  | ForEach of string * expr             (* @ x:collection *)
  | ForRange of string * expr * expr * expr option  (* @ x:a..b[:step] *)

and stmt =
  | Assign of lvalue * expr
  | ConstDecl of string * expr
  | OpAssign of lvalue * binop * expr
  | IncDec of lvalue * int
  | Output of expr list
  | Input of expr option * string        (* optional prompt, target variable *)
  | If of (expr * stmt list) list * stmt list option
  | Loop of string option * loop_head * stmt list
  | Break of string option
  | Continue of string option
  | Ret of expr option
  | FuncDecl of string * param list * stmt list
  | Sleep of expr
  | Discard of string                    (* \ x — explicit lifetime end *)
  (* `[a, *rest] = arr` / `(x, y) = tup` / `(name: n) = nt`.  A slot is a
     variable name, a rest collector, or `_` to discard the position. *)
  | Destructure of dpat * expr
  | ClearScreen                           (* >>!              *)
  | OutputPos of expr option list * expr list  (* >>~ (r,c,…) > items *)
  | TuiBlock of stmt list                 (* >>| { … }        *)
  | NumeralMode of int                    (* #d0d9#           *)
  | Import of string * string             (* <# path => alias *)
  | ModuleDecl of string * stmt list      (* # name { ... }   *)
  | Export of exportitem list             (* #> { ... }       *)
  | Try of stmt list * (string option * stmt list) list * stmt list option
  | PropErr of expr                       (* x$!! — early-return an error *)
  | ExprStmt of expr

(* An export entry names something the module publishes, optionally under a
   different public name.  `alias::fn` and `alias.CONST` re-export from an
   imported module. *)
and exportitem = {
  esrc : esource;
  epublic : string;
}

and esource =
  | EOwn of string                        (* fn / CONST defined here *)
  | EReFun of string * string             (* alias::fn               *)
  | EReConst of string * string           (* alias.CONST             *)

type program = stmt list
