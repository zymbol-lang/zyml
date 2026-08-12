#!/usr/bin/env bash
# parity.sh — zyml against the reference Rust engine.
#
# A wrapper over ZyQuality (../zyquality), the project's point of record for
# testing.  The corpus, the exclusion rules and the comparison live there.
#
#   bash tests/parity.sh              # the whole corpus
#   bash tests/parity.sh --corpus     # same thing; kept for old callers
#   bash tests/parity.sh -v           # show the files that agree too
#
# What this script used to be, and what changed:
#
#   * `tests/cases/*.zy` — 22 files that existed only here — are now
#     `corpus/smoke/` in zyquality, so the other three engines are graded on
#     them too.  They were zyml's bring-up suite and nothing else ever ran them.
#
#   * The exclusions were `input/`, `manual_check.zy` and `grep -L lib_time`,
#     written here and invisible to every other runner.  They are now rules in
#     zyquality/corpus.toml.  One of them was wrong: `input/` was excluded
#     because this script fed every engine /dev/null, but each of those 14 files
#     has a `.input` beside it and zyq feeds it.  Those files are compared now.
#
#   * UNSUP is unchanged in meaning: zyml declares its refusal prefixes in
#     engines.toml, and a refused program is reported apart from a wrong answer.
#     It is the phase-by-phase progress metric; a divergence must stay zero.
#
# Exit status: 0 no divergence, 1 a divergence, 2 could not run.

set -euo pipefail
cd "$(dirname "$0")/.."

ZYML_DIR="$(pwd)"

find_zyq() {
    if [[ -n "${ZYQ_ROOT:-}" ]]; then
        [[ -x "$ZYQ_ROOT/zyq" && -f "$ZYQ_ROOT/engines.toml" ]] && { echo "$ZYQ_ROOT"; return 0; }
        return 1
    fi
    local sibling="$ZYML_DIR/../zyquality"
    [[ -x "$sibling/zyq" && -f "$sibling/engines.toml" ]] && { (cd "$sibling" && pwd -P); return 0; }
    return 1
}

if ! ZYQ="$(find_zyq)"; then
    if [[ -n "${ZYQ_ROOT:-}" ]]; then
        echo "parity.sh: ZYQ_ROOT='$ZYQ_ROOT' is not a ZyQuality checkout." >&2
        echo "  Expected '$ZYQ_ROOT/zyq' and '$ZYQ_ROOT/engines.toml'." >&2
    else
        cat >&2 <<'EOF'
parity.sh: ZyQuality not found — QA for this project lives there.

  zyml is one of four engines, and they are all graded against the same corpus
  in the zyquality repository.  This script is a thin wrapper over it.

      git clone https://github.com/zymbol-lang/zyquality.git ../zyquality
      make -C ../zyquality

  Or:  ZYQ_ROOT=/path/to/zyquality bash tests/parity.sh
EOF
    fi
    exit 2
fi

[[ -x ./zyml ]] || { echo "parity.sh: build zyml first: make" >&2; exit 2; }

ARGS=()
for a in "$@"; do
    case "$a" in
        --corpus) ;;                       # the corpus is the only mode now
        --cases)  ARGS+=(--filter smoke/) ;;
        *)        ARGS+=("$a") ;;
    esac
done

# zyml is found through engines.toml's ${ZYML_BIN:-../zyml/zyml}; point it at
# this checkout so the wrapper tests the binary next to it, not whichever one
# happens to sit beside zyquality.
export ZYML_BIN="$ZYML_DIR/zyml"

echo "parity.sh: delegating to ZyQuality at $ZYQ"
echo "  → zyq consensus --engines zytw,zyml"
echo

exec "$ZYQ/zyq" --root "$ZYQ" consensus --engines zytw,zyml "${ARGS[@]}"
