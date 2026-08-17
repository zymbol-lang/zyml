# zyml is discontinued

**Date: 2026-08-17. Final commit: `5167b0e`. Status: archived, read-only.**

zyml was an experimental third engine for [Zymbol](https://github.com/zymbol-lang/interpreter),
written in OCaml, which compiled the whole program to native closures before
running a statement. It worked, it was fast, and it is no longer maintained.

Zymbol now has three engines: the Rust tree-walker (`zytw`), the Rust register
VM (`zyvm`), and the JavaScript engine that runs the playground (`zyjs`).

This repository stays online because the code compiles and the measurements in
[`README.md`](README.md) and [`es/auditoria_motores.md`](es/auditoria_motores.md)
are still true. Nothing here is a lie; it is simply finished.

---

## Why it was discontinued

Two reasons, both measured against the shared corpus in
[ZyQuality](https://github.com/zymbol-lang/zyquality) on 2026-08-17.

### It never reached correctness parity

`zyq consensus` over the 599-file corpus:

| engines asked | agree | diverge | zyml declined |
|---|---|---|---|
| `zytw`, `zyvm` | 597 | **0** | — |
| `zytw`, `zyvm`, `zyml` | 582 | **15** | **131 of 599** |

zyml could not run 131 of the corpus files at all — 22% of it — and gave a
different answer on 15 more. The two Rust engines agree on every file either of
them can run. Adding zyml to a gate meant adding 15 divergences and a 131-file
blind spot to a comparison that was otherwise clean, and closing that gap was
open-ended work on an engine nothing depended on.

### The speed advantage did not survive real load

On microbenchmarks zyml beat both Rust engines — 5–7× the tree-walker, 1–4× the
register VM. Those programs all fit in a few slots, and none of them copied a
large aggregate, which is what a real program does most.

The go engine at 19×19, after zyml implemented copy-on-write
([`GO/BENCHMARK.md`](https://github.com/zymbol-lang/interpreter)):

| board | `zyvm` | zyml before COW | zyml after COW |
|---|---|---|---|
| 9×9 | 1.5 · 1.5 · 1.8 s | 1.4 · 1.8 · 1.3 s | 1.2 · 1.6 · 1.2 s |
| 13×13 | 8.4 · 7.9 · 11.1 s | 14.3 · 9.4 · 6.7 s | **3.7 · 4.2 · 4.5 s** |
| 19×19 | 41.6 · 41.6 · 36.2 s | 255.7 · 277.0 s | 132.6 · 133.0 · 137.2 s |

Copy-on-write halved 19×19 and won 13×13 outright. It still left zyml **3.4×
slower than the register VM on the largest board**, because the legality test
writes to the board it copies and a write still copies. Closing the rest needed
a persistent structure or a board representation that can be probed without
copying — a redesign, for an engine that was already behind on correctness.

So: faster than the VM on small and mid-sized real work, 3.4× slower on the
largest, and 22% of the corpus unimplemented. That is not a case for keeping a
fourth engine alive.

---

## What it accomplished

zyml was not wasted, and this is the part worth keeping.

**A third independent implementation forces decisions no specification fixes.**
Writing zyml meant deciding, one case at a time, things `GUIDE.md` did not say.
When the guide was silent the only authority was the `zymbol` binary; when the
binary contradicted the guide, or the tree-walker contradicted the VM, that was
a finding. Those 13 findings are [`es/auditoria_motores.md`](es/auditoria_motores.md)
(Spanish, at the project author's request).

Concretely, in the interpreter's own record:

- **The call-arity gap (REFERENCE.md L28).** zyml had the rule and rejected
  `ZethyCLI/main.zy` over a call the Rust tooling accepted. Both programs it
  caught had the bad call on a rarely taken branch — ZethyCLI's "Ollama not
  reachable" arm, and a surplus argument in ZyAudit's `测试/test_析答.zy` that
  was broken under the tree-walker and worked by accident under the VM. Now
  `crates/zymbol-semantic/src/call_arity.rs`.
- **Unlabelled and unknown loop jumps (REFERENCE.md L29).** Four engines, four
  behaviours, and `zymbol check` reported nothing in any of the seven cases.
  Every *pair* of engines was covered by some suite; the four together never
  were. zyml being the fourth answer is what made the disagreement visible, and
  the rule is now static in `crates/zymbol-semantic/src/loop_context.rs`.
- **The eager-copy measurement itself.** `GO/BENCHMARK.md`'s copy-on-write
  section exists because zyml's design paid for value semantics in a place the
  VM did not, which is a fact about aggregate copying in Zymbol, not just about
  OCaml.
- **`zyq` inherited its build approach** — `ocamlopt` directly, no dune, no opam
  switch, no external libraries beyond `unix`. ZyQuality's Makefile says so.

The differential-audit method outlived the engine. Its successor is
`Divergente_ES/` in the main workspace: 84 probes written against what the
industry takes for granted, run on every engine, 30 surviving as real
divergences. `es/auditoria_motores.md` is where that method started.

---

## What was removed elsewhere

zyml is gone from everything that used to run it:

- `zyquality/engines.toml` — the `zyml` engine entry
- `zyquality/src/suite.ml` — the `ZYML_BIN` availability check
- `zyquality/project/run.sh`, `zyquality/tui/run.sh` — dropped from the engine sets
- `interpreter/tests/scripts/engine_compare.sh` — the `ml` → `zyml` alias
- `GO/benchmark_go.sh`, `Divergente_ES/probar.sh` — dropped from the engine lists

Historical references were **kept on purpose**. A rejection rule whose comment
says "zyml counted this as a divergence" explains why the rule exists; deleting
that leaves a rule with no reason. Anything claiming zyml is a live or pending
engine was corrected.

## If you want to resurrect it

```bash
git clone https://github.com/zymbol-lang/zyml && cd zyml
make                     # ocamlopt only; needs the flambda variant for -O3
./zyml run file.zy
```

The engine is `src/compile.ml` (AST → closures), `src/value.ml` (the value
model, including copy-on-write), `src/stdlib_zy.ml` (the standard library).
`tests/` holds wrappers over ZyQuality that will need `ZYML_BIN` and a
re-added `engines.toml` entry to mean anything.

It targeted `zymbol 0.0.9`. The language has moved on since.
