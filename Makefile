# Build with ocamlopt directly — no dune, no opam switch, no external libraries.
# The only dependency beyond the compiler is `unix`, which ships with OCaml.

OCAMLOPT ?= ocamlopt
OCAMLFLAGS = -O3 -unsafe -inline 200 -w +a-4-9-40-41-42-44-45-70 -I src -I +unix
LIBS = unix.cmxa

# Order matters: this is the dependency chain.
MODULES = value ast lexer parser stdlib_zy compile main
CMX = $(addprefix src/,$(addsuffix .cmx,$(MODULES)))
BIN = zyml

.PHONY: all clean test corpus bench

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

test: $(BIN)
	@bash tests/parity.sh

# The full reference corpus: ../interpreter/tests/**/*.zy
corpus: $(BIN)
	@bash tests/parity.sh --corpus

bench: $(BIN)
	@bash bench/run.sh

clean:
	rm -f src/*.cmx src/*.cmi src/*.o $(BIN)
