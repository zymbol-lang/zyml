#!/usr/bin/env bash
# Forms zyml must refuse.
#
# parity.sh cannot cover these: it compares the stdout of programs that *run*,
# and a refused program is scored UNSUP and skipped. But a form zyml accepts and
# the reference engine rejects is the worst kind of divergence — the program
# works here and does not compile there, so the gate that is supposed to keep
# the engines interchangeable never sees it.
#
#   bash tests/rejects.sh
#
# Exit status: 0 when every case is refused by both engines, 1 otherwise.

set -uo pipefail
cd "$(dirname "$0")/.."

ZYML=./zyml
ZYMBOL=${ZYMBOL:-zymbol}

[[ -x $ZYML ]] || { echo "build first: make" >&2; exit 2; }
command -v "$ZYMBOL" >/dev/null || { echo "reference engine '$ZYMBOL' not found" >&2; exit 2; }

RED='\033[0;31m'; GREEN='\033[0;32m'; RESET='\033[0m'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# name | source | why
check() {
  local name="$1" src="$2" why="$3"
  printf '%s\n' "$src" > "$tmp/t.zy"

  "$ZYMBOL" run "$tmp/t.zy" >/dev/null 2>&1 </dev/null; local ref=$?
  "$ZYML"   run "$tmp/t.zy" >/dev/null 2>&1 </dev/null; local ml=$?

  if [[ $ref -eq 0 ]]; then
    echo -e "  ${RED}BAD TEST${RESET}  $name — the reference engine accepts it, so zyml should too"
    fail=1
  elif [[ $ml -eq 0 ]]; then
    echo -e "  ${RED}FAIL${RESET}      $name — zyml accepts it, reference rejects it"
    echo "            $why"
    fail=1
  else
    echo -e "  ${GREEN}ok${RESET}        $name"
  fi
}

echo "Forms both engines must refuse"
echo

check "nested indexed assignment" \
      'm = [[1,2],[3,4]]
m[1][2] = 77' \
      "nesting is navigated with '>', and a change must say so with '\$~': m = m[i>j]\$~ v"

check "deeper nested indexed assignment" \
      'c = [[[1,2]]]
c[1][1][1] = 5' \
      "same rule at any depth"

check "\$~ as a statement" \
      'a = [1,2,3]
a[1]$~ 9' \
      "'\$~' returns a new collection; dropping it makes the line a no-op"

check "deep \$~ as a statement" \
      'm = [[1,2],[3,4]]
m[1>2]$~ 9' \
      "same: the result has to be assigned"

echo
if [[ $fail -eq 0 ]]; then
  echo -e "${GREEN}All rejection cases hold.${RESET}"
else
  echo -e "${RED}Some forms are accepted here and not by the reference engine.${RESET}"
fi
exit $fail
