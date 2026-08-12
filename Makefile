# Build with ocamlopt directly — no dune, no opam switch, no external libraries.
# The only dependency beyond the compiler is `unix`, which ships with OCaml.

OCAMLOPT ?= ocamlopt
OCAMLFLAGS = -O3 -unsafe -inline 200 -w +a-4-9-40-41-42-44-45-70 -I src -I +unix
LIBS = unix.cmxa

# Order matters: this is the dependency chain.
MODULES = value ast lexer parser stdlib_zy compile main
CMX = $(addprefix src/,$(addsuffix .cmx,$(MODULES)))
BIN = zyml

.PHONY: all clean test corpus rejects tui bench

all: $(BIN)

$(BIN): $(CMX)
	$(OCAMLOPT) $(OCAMLFLAGS) $(LIBS) $(CMX) -o $(BIN)

src/%.cmx: src/%.ml
	$(OCAMLOPT) $(OCAMLFLAGS) -c $<

# `-O3` needs the flambda variant of the compiler; fall back silently if absent.
src/value.cmx: src/value.ml
src/ast.cmx: src/ast.ml
src/lexer.cmx: src/lexer.ml src/value.cmx
src/parser.cmx: src/parser.ml src/ast.cmx src/lexer.cmx
src/compile.cmx: src/compile.ml src/ast.cmx src/value.cmx src/parser.cmx src/lexer.cmx src/stdlib_zy.cmx
src/stdlib_zy.cmx: src/stdlib_zy.ml src/value.cmx
src/main.cmx: src/main.ml src/parser.cmx src/compile.cmx

# QA for this project lives in ZyQuality (../zyquality): one corpus, one set of
# exclusion rules, four engines graded on the same files.  These targets are
# thin wrappers over it.  `tests/cases/` moved there as `corpus/smoke/`, so the
# other three engines are graded on zyml's bring-up suite too.
test: $(BIN)
	@bash tests/parity.sh
	@bash tests/rejects.sh
	@bash tests/tui.sh

# The whole shared corpus.  Same thing as `test` now — the corpus is no longer
# a separate, larger mode, because there is only one corpus.
corpus: $(BIN)
	@bash tests/parity.sh

# Forms zyml must refuse, which parity.sh cannot see (a refused program is UNSUP)
rejects: $(BIN)
	@bash tests/rejects.sh

# Key input needs a real terminal, so it is driven through a pty rather than a
# pipe.  The driver and its cases moved to ../zyquality/tui/ with everything
# else; this target is a wrapper.
tui: $(BIN)
	@bash tests/tui.sh

# Benchmarks live with the rest of QA now.
bench: $(BIN)
	@bash tests/../../zyquality/bench/run_all.sh

clean:
	rm -f src/*.cmx src/*.cmi src/*.o $(BIN)
