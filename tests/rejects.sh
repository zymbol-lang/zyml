#!/usr/bin/env bash
# rejects.sh — forms every engine must refuse.
#
# A wrapper over ZyQuality (../zyquality), the project's point of record for
# testing.  The four cases that used to be shell heredocs in this file are now
# `reject/assignment/*.zy` there, each carrying its own `// @reject:` reason.
#
#   bash tests/rejects.sh
#   bash tests/rejects.sh -v          # name the forms that are correctly refused
#
# Why this had to move rather than stay local: it compared zyml against the
# Rust reference and asked no one else.  Run against all four engines, the very
# first sweep found that the browser engine *accepts* all four forms — it runs
# `m[1][2] = 77`, changes nothing, and exits 0.  A silent no-op is worse than a
# program that does not compile, and no suite in the project could see it,
# because consensus compares what programs print and a refused program prints
# nothing.
#
# This wrapper still asks only about zyml and the reference engine, on purpose:
# it is zyml's gate, and a gate that goes red for a defect in another repository
# is a gate its owner learns to ignore.  The whole-project question is
# `zyq reject` (all four engines), which `zyq suite` runs.
#
# Exit status: 0 refused by both, 1 accepted by one, 2 could not run.

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
    echo "rejects.sh: ZyQuality not found — QA for this project lives there." >&2
    echo "  git clone https://github.com/zymbol-lang/zyquality.git ../zyquality" >&2
    echo "  make -C ../zyquality" >&2
    echo "  (or set ZYQ_ROOT)" >&2
    exit 2
fi

[[ -x ./zyml ]] || { echo "rejects.sh: build zyml first: make" >&2; exit 2; }
export ZYML_BIN="$ZYML_DIR/zyml"

echo "rejects.sh: delegating to ZyQuality at $ZYQ"
echo "  → zyq reject --engines zytw,zyml"
echo "  (the four-engine question is 'zyq reject'; see the note above)"
echo

exec "$ZYQ/zyq" --root "$ZYQ" reject --engines zytw,zyml "$@"
