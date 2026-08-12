#!/usr/bin/env bash
# tui.sh — key input and raw mode, through a real pty.
#
# A wrapper over ZyQuality (../zyquality). The pty driver and its two cases used
# to live here, documented with a pair of commands to type by hand and the
# sentence "the two outputs must be byte-identical" — with nothing checking that
# they were, and only two of the four engines named. They are `tui/` there now,
# with a runner that actually compares, and `zyq suite` runs it.
#
# Exit status: 0 the engines agree, 1 they do not, 2 could not run.

set -uo pipefail
cd "$(dirname "$0")/.."
ZYML_DIR="$(pwd)"

if [[ -n "${ZYQ_ROOT:-}" ]]; then ZYQ="$ZYQ_ROOT"; else ZYQ="$ZYML_DIR/../zyquality"; fi
if [[ ! -x "$ZYQ/zyq" || ! -f "$ZYQ/engines.toml" ]]; then
    echo "tui.sh: ZyQuality not found — QA for this project lives there." >&2
    echo "  git clone https://github.com/zymbol-lang/zyquality.git ../zyquality" >&2
    echo "  make -C ../zyquality      (or set ZYQ_ROOT)" >&2
    exit 2
fi
ZYQ="$(cd "$ZYQ" && pwd -P)"
[[ -x ./zyml ]] || { echo "tui.sh: build zyml first: make" >&2; exit 2; }
export ZYML_BIN="$ZYML_DIR/zyml"

echo "tui.sh: delegating to ZyQuality at $ZYQ"
echo "  → bash tui/run.sh"
echo
cd "$ZYQ"
exec bash tui/run.sh "$@"
