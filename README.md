<p align="center">
  <img src="logo.png" alt="Zymbol-Lang" width="180"/>
</p>

<h1 align="center">zyml — Zymbol Closure-Compiling Engine</h1>

<p align="center">
  A third engine for Zymbol, written in OCaml.<br/>
  The whole program becomes native closures before a single statement runs.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.1.0-informational?style=flat-square"/>
  <img src="https://img.shields.io/badge/language-OCaml-e88b00?style=flat-square"/>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square"/>
  <img src="https://img.shields.io/badge/status-experimental-yellow?style=flat-square"/>
  <img src="https://img.shields.io/badge/parity-415%2F538-brightgreen?style=flat-square"/>
  <img src="https://img.shields.io/badge/vs%20tree--walker-5--7x-brightgreen?style=flat-square"/>
</p>

---

## What is zyml?

An experimental third engine for [Zymbol](https://github.com/zymbol-lang/interpreter),
alongside the Rust tree-walker and the Rust register VM.  It exists to test one
question: how fast can a Zymbol program go if the whole program is turned into
native closures before a single statement runs?

It is **not** a JIT — it emits no machine code.  It is a *closure compiler*:
the AST is compiled once into a tree of OCaml closures that `ocamlopt` has
already compiled to native code ahead of time.  See
[How it works](#how-it-works-closure-compilation-not-a-jit).

Measured on the same programs, same machine, best of 3, process start-up
included:

| program | what it stresses | rust tree-walker | rust vm | zyml | vs tw | vs vm |
| --- | --- | --- | --- | --- | --- | --- |
| `fib(30)` | recursive calls (2.7 M) | 1.103 s | 0.218 s | **0.159 s** | 6.9× | 1.4× |
| 10 M `@` loop | loop + variable update | 1.046 s | 0.698 s | **0.172 s** | 6.1× | 4.1× |
| nested array loop | indexing (4 M reads) | 14.002 s | 0.336 s | **0.109 s** | 128× | 3.1× |
| `$>` / `$<` over 2000 | higher-order operators | 0.446 s | 0.085 s | **0.081 s** | 5.5× | 1.1× |
| 200 k interpolations | string building | 0.098 s | 0.054 s | **0.048 s** | 2.0× | 1.1× |

Read the 128× as a fact about the tree-walker, not about zyml: array indexing
in a loop is pathological there.  The honest headline is **5–7× the
tree-walker, 1–4× the VM**, and near-parity with the VM on string-heavy work
where both are bound by allocation.

**Every program above fits in a few slots, which is why none of them caught the
engine's worst case.**  Copying a large aggregate did not appear in this table
at all, and it is what a real program does most: a Go board is copied once per
legality test.  Two programs that differ only in whether they write to the copy:

| 20 000 × copy a 361-cell array | rust vm | zyml before | zyml now |
| --- | --- | --- | --- |
| and never write to it | 0.014 s | 0.078 s | **0.008 s** |
| and write one cell | 0.044 s | 0.077 s | **0.046 s** |

The old engine charged the same either way — it copied on assignment, so the
read-only case paid for a copy nobody used.  That is the measurement that
motivated copy-on-write, and it is deterministic, which the Go harness below
is not.

`bash bench/run.sh` reproduces the table.  `./zyml bench FILE N` separates
compile time from run time — compilation of every program here is under 0.1 ms.

## Build and run

No dune, no opam switch, no external libraries.  The only dependency beyond the
OCaml compiler is `unix`, which ships with it.

```bash
make                      # produces ./zyml
./zyml run file.zy
./zyml check file.zy      # parse + compile, do not execute
./zyml tokens file.zy     # dump the token stream
./zyml bench file.zy 10   # compile time and run time, separately
```

## How it works: closure compilation, not a JIT

Executing a program means calling a tree of closures — there is no AST walk and
no bytecode dispatch loop, and nothing is generated at run time.

The speedup therefore does not come from code generation.  It comes from moving
work out of the hot path:

* **Lexical addressing.**  Every name is resolved at compile time to an integer
  slot in a flat frame.  A variable read is one array load, not a hash lookup
  walking a scope chain.
* **Node dispatch happens once.**  `Bin (Add, a, b)` becomes
  `fun fr -> add (ca fr) (cb fr)`.  The "which node is this?" match is paid
  during compilation, never again.
* **Structural specialisation.**  Statement sequences of 1–3 get unrolled
  shapes; `x < 5` against an integer literal gets a shape that skips generic
  comparison; a loop body with no `@!`/`@>` runs without a per-iteration
  exception handler; a call to a statically known function skips value
  dispatch and wires output parameters straight back into the caller's slots.
* **Constant folding.**  Literal arithmetic and interpolation-free strings are
  evaluated during compilation — except when folding would raise, so that
  `10 / 0` still fails at run time where a `!?` block can catch it.
* **Copy-on-write aggregates.**  Zymbol assignment has value semantics: after
  `b = a`, writing `a[1] = 99` must leave `b` alone.  This engine used to get
  that by deep-copying on assignment, which meant a Go board was copied in full
  once per legality test — 361 cells for a board most of those tests only read.
  An array now lives in a box that records whether it is shared, assignment
  shares it in O(1), and the first writer through a shared box detaches.
  Detaching also re-boxes the aggregate cells, so `b = a` followed by
  `a[1][2] = 99` cannot move `b`'s inner array; a write path detaches every
  level it passes through, not only the one it lands on.

Emitting real machine code (mmap + x86-64 via a small C stub) is possible from
OCaml and would be the natural next step for numeric inner loops.  That would
make it a JIT.  It is not implemented, and nothing here should be read as
claiming it is.

## Layout

```text
src/value.ml     runtime values, frames, UTF-8, primitive ops, display
src/ast.ml       the AST — no spans, it is consumed immediately
src/lexer.ml     tokenizer (longest-match on symbols; Zymbol has no keywords)
src/parser.ml    recursive descent; mirrors the Rust precedence chain
src/compile.ml   AST -> closures, with name resolution folded in
src/main.ml      CLI
tests/parity.sh  differential test against the reference `zymbol` binary
bench/run.sh     three-engine wall-clock comparison
```

## Correctness

Correctness is defined differentially: a program is correct when `zyml run`
produces byte-identical stdout to `zymbol run`.

```bash
make test        # this project's own corpus, plus the rejection cases
make corpus      # every .zy in ../interpreter/tests
make rejects     # only the forms zyml must refuse
bash tests/parity.sh --corpus -v    # ... and print each mismatch
```

`tests/rejects.sh` exists because `parity.sh` structurally cannot see one class
of bug: a program zyml accepts and the reference engine refuses is scored
`UNSUP` and skipped, so the divergence that matters most — code that runs here
and does not compile there — is exactly the one the differential test is blind
to.  It caught two: chained indexed assignment (`m[i][j] = v`) and `$~` used as
a statement.  Both are refused now; see D2 in the audit for why the language
does not want either.

Key input is the exception: `<<|` needs a real terminal, so it is tested
through a pty rather than a pipe — see [tests/tui/](tests/tui/).  The same
harness runs whole TUI applications: the Snake game in `../serpiente` renders
byte-identically under both engines, down to the escape sequences.

```bash
cd ../serpiente && ../zyml/zyml run serpiente.zy
```

`--corpus` expects a checkout of the Zymbol interpreter at `../interpreter`,
and the reference `zymbol` binary on `PATH`.

Three outcomes.  `DIFF` — both engines ran and disagreed — is a bug.  `UNSUP` —
zyml refused to compile — is a feature not built yet, and is the progress
metric.  `PASS` is byte-identical output.

**Status:** 20/20 on the local corpus.  On the reference corpus (538 files):
**415 identical, 11 differing, 112 not yet supported.**

Two groups are excluded from that count because their output is not a function
of the program: `input/`, which reads stdin, and anything importing `lib_time`,
which prints elapsed wall time and therefore differs between engines *because*
they differ in speed.

The 11 differences are all accounted for, and none is a wrong answer:

* **7** are diagnostics from the Rust *semantic analyser* — array homogeneity,
  argument type inference, undefined-variable detection inside lambdas,
  underscore-variable scope rules, `°` used in output position.  Those programs
  are rejected before running; zyml has no separate analysis pass, so it runs
  them.
* **4** are error-value edge cases and error *message* wording, where the kind
  matches but the text is this engine's own.

### `UNSUP` over-counts by five

`UNSUP` is decided by one test: zyml exited non-zero with a `Compile error:`
line.  That reads every refusal as "feature not built yet", which is wrong for
five of the six `tests/arity/` files it refuses (the sixth is a module file
invoked directly, which is `UNSUP` for the right reason).  zyml *has* the
arity check — it is
what caught `ZethyCLI/main.zy` — and **Rust adopted zyml's behaviour** in
v0.0.8: an argument-count mismatch is now a semantic error, fatal before
execution, in `check`, `run` and `build`, for `f()`, `alias::f()` and
`std::f()` alike (REFERENCE.md L28).

Both engines now refuse those programs with `rc=1` and no output, including the
one whose bad call sits on a branch that can never run.  Only the message
wording differs (`Compile error: 's::saluda' expects 1 argument(s), got 2` vs
`error: function 's::saluda' expects 1 argument(s), but 2 were provided`), which
is the same category as the four wording differences already listed above — not a
behavioural divergence.  They are counted as `UNSUP` only because the classifier
never gets as far as comparing.

Of the remaining 107, **54** are module files invoked directly, which zyml
refuses by design.

## Implemented

Variables and constants (`=`, `:=`, compound assignment, `++`, `--`, `\ x`) ·
juxtaposition concatenation in assignment (`full = first " " last`) · full
arithmetic, comparison and logic with Zymbol's Int/Float promotion and its
string-as-number ordering rule · strings with interpolation, escapes and UTF-8
indexing · `>>` output with juxtaposition, `¶` and `\\` · `<<` input · `?` /
`_?` / `_` · every `@` loop form with `@!`, `@>`, `@~` and `@:label` variants ·
named functions, recursion, `<~` return, `param<~` output parameters · lambdas,
block lambdas, closures capturing by value, lambdas as first-class values ·
arrays with 1-based and negative indexing, element assignment, value-semantics
copying · **the full `$` family** (`$#` `$+` `$+[i]` `$-` `$--` `$-[…]` `$?`
`$??` `$[…]` `$^+` `$^-` `$^` `$>` `$|` `$<` `$/` `$*` `$~~` `$~` `$++`) ·
**multi-dimensional navigation** (`arr[i>j>k]`, flat `arr[p ; q]`, structured
`arr[[a,b] ; [c,d]]`, ranges on any step) · **`??` match** with all six pattern
kinds and `||` alternatives · **positional and named tuples** with `.field`
access and `$~` by position or field name · **`!?` / `:!` / `:>` try, catch
(typed and generic) and finally**, with `_err` · casts `##.` `###` `##!` ·
number formatting `#|x|` `#.N|x|` `#!N|x|` `#,|x|` `#^|x|` and their inline
precision forms · base conversion `0x|n|` `0b|n|` `0o|n|` `0d|n|` · base-prefixed
character literals · `#?` type metadata · `|>` pipe with `_` placeholder · `;`
as a separator · **first-class error values** — `std/*` returns `##IO(…)` rather
than raising, and `$!` tests for one while `$!!` returns it to the caller
early · **`std/math`** (22 functions, `PI`, `E`, with the reference engine's
mixed return types: `abs`/`max`/`min` preserve the argument type, everything
else widens to Float) · **`std/io`**, **`std/json`** (decode, encode,
`decode_map` key renaming), **`std/random`**, **`std/term`** (which measures
terminal *columns*, so a CJK ideograph counts two) · **TUI primitives** —
`>>!` clear, `>>?` terminal size (answering the conventional `[24, 80]` with no
TTY so a piped layout still runs), `>>~` positioned output with sparse slots
and ANSI styling, `>>|` alternate-screen block, `<<|` / `<<|?` key input in raw mode with arrow
keys decoded to their glyphs (`↑`, `↓`, `←`, `→`) · **destructuring** — `[a, *rest]`,
`(x, y)`, `(name: n)`, overwriting rather than shadowing · `><` CLI argument
capture · juxtaposition inside call arguments · **`°` hot
definition** — `°x` anchors above the nearest loop and survives it, `x°`
anchors to the loop and dies with it, both auto-initialising to the operator's
neutral value on first use (0 for `+`, 1 for `*`, `[]` for `$+`, `""` for
juxtaposition — and 0 for `^`, which is why the reference warns that `x° ^= 3`
is always 0) · **modules** — `# name { }` declaration, `<#` import with
alias, `#>` export with renaming and re-export (`alias::fn`, `alias.CONST`),
`alias::fn()` calls resolved at compile time, `alias.CONST`, private mutable
module state that persists across calls, and state identity per *file path* so
two aliases to one file share one state · **numeral modes** — `#d0d9#` over 69
digit scripts, reaching `>>`, interpolation, juxtaposition, `$++` and the
inside of collections; native digit literals in any script, integer and float
(`४२`, `𞥓.𞥕`); booleans as `#` plus the active digit · `<\ cmd \>` shell
execution.

## Not implemented

No single large blocker is left.  Ranked by how many corpus files each blocks:

1. **`<<|` / `<<|?` key input** — needs raw mode; the rest of the TUI set is in.
2. **`std/net` and `std/db`** — both need an external dependency (HTTP, ODBC)
   rather than more OCaml.
4. **Typed input** (`<< ###(4) "p" v`), script exec `</ />`.

## The reference engines disagree with each other

Writing a fourth engine surfaced six cases where the tree-walker, the VM and
the JavaScript engine give **different answers to the same program** — none of
which the `vm_compare.sh` parity gate catches, because no test in the corpus
exercises them.  `#?` counts bytes in the tree-walker and characters
everywhere else; `==` over arrays is `#0` only in the VM; `10 ^ 20` produces
four different results in four engines.

They are written up, with reproductions and a recommendation each, in
[es/auditoria_motores.md](es/auditoria_motores.md) (Spanish).

One finding from that audit has since been fixed in Rust because zyml raised it.
zyml refused `ZethyCLI/main.zy` over `ui::show_error("...", host)` — two
arguments to a one-parameter function — which `zymbol check` accepted.  Chasing
it down turned up three gaps at once: neither `alias::fn` nor `std::fn` calls
were arity-checked, and the VM did not check at all, copying surplus arguments
over the callee's own registers and running on.  Fixed in v0.0.8, with
`interpreter/tests/arity/` as the regression corpus (audit item C2).

zyml deliberately reproduces two of those bugs, because its definition of
correctness is "byte-identical to `zymbol run`" and the tree-walker is what
`zymbol run` means.  When Rust is fixed, zyml follows, and the parity suite
verifies it.

## When something goes wrong

Runtime errors carry the line they happened on and the function they happened
in:

```
Runtime error: index 9 out of bounds (length 2) (line 3)
Runtime error: '@!' outside a loop (line 2)
Runtime error: stack overflow — infinite recursion? (line 1, in fib)
```

Position is tracked once per statement — a single integer store, folded into
the statement sequence rather than wrapped around each one, which measures at
about 4% on a tight loop.  Wrapping each statement in its own closure instead
cost 3.6×, which is why it is not done that way.

No control-flow exception escapes as a raw OCaml constructor.  `@!` that no
loop claimed, `<~` outside a function and stack overflow each get a sentence
saying what happened; so does anything unexpected, rather than printing
`Fatal error: exception …` at a user who did not write OCaml.

## Known limitations

* No semantic analysis pass, so the diagnostics in the section above are not
  reproduced and no `warning:` lines are emitted.
* Error *messages* are this engine's own wording, except in `std/io`, where
  the corpus compares them and they reproduce Rust's `io::Error` rendering
  (`No such file or directory (os error 2)`).  The error *kind* matches
  (`##Div`, `##Index`, `##Type`), which is what `:! ##Kind` selects on, and
  `_err` renders as `##Kind(message)`.
* Character values are Unicode **code points**, not grapheme clusters.  A
  combining sequence counts as more than one character where the Rust engine
  counts one.
* Numeric literals must use ASCII digits; `४२` lexes as an identifier.
* Assignment copies aggregates eagerly (`b = arr` is O(n)).  Correct, but
  copy-on-write would be cheaper — and the cost is visible: on the Go benchmark
  in `../GO` this engine is 1.3× the register VM on a 9×9 board and **5.7× on
  19×19**, where a board copy per legality test is 361 cells rather than 81.
  That gap is the eager copy, not the closure model.

## Licence

AGPL-3.0-only, matching the Zymbol interpreter.  This is a derivative work of
the Rust tree-walker: its semantics were read out of that implementation and are
verified against it on every run of `tests/parity.sh`.
