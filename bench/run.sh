#!/usr/bin/env bash
# Wall-clock comparison of the three engines on the same programs.
# Reports the best of N runs, so a noisy machine inflates nothing.
#
#   bash bench/run.sh [runs]

set -uo pipefail
cd "$(dirname "$0")/.."

RUNS=${1:-3}
ZYMBOL=${ZYMBOL:-zymbol}

now() { date +%s.%N; }

best() {   # best <label> <cmd...>
  local label=$1; shift
  local b=""
  for _ in $(seq "$RUNS"); do
    local t0 t1 d
    t0=$(now); "$@" >/dev/null 2>&1; t1=$(now)
    d=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    if [[ -z $b ]] || (( $(awk -v x="$d" -v y="$b" 'BEGIN{print (x<y)}') )); then b=$d; fi
  done
  printf '  %-22s %8ss\n' "$label" "$b" >&2
  echo "$b"
}

for f in bench/*.zy; do
  echo "== $(basename "$f")"
  tw=$(best "rust tree-walker" "$ZYMBOL" run "$f")
  vm=$(best "rust vm" "$ZYMBOL" run --vm "$f")
  ml=$(best "ocaml zyml" ./zyml run "$f")
  awk -v tw="$tw" -v vm="$vm" -v ml="$ml" 'BEGIN{
    printf "  -> zyml is %.2fx the tree-walker, %.2fx the vm\n", tw/ml, vm/ml }'
  echo
done
