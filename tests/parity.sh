#!/usr/bin/env bash
# Differential test: run the same .zy program through the reference Rust engine
# and through zyml, and compare stdout byte for byte.
#
#   bash tests/parity.sh                  # the OCaml/tests/cases corpus
#   bash tests/parity.sh --corpus         # ../interpreter/tests/**/*.zy
#   bash tests/parity.sh --corpus -v      # ... and print every mismatch
#
# Three outcomes per file:
#   PASS   identical output
#   DIFF   both engines ran, output differs        -> a real bug
#   UNSUP  zyml refused the program (lex/parse/compile error, exit 1 with a
#          "... error:" line and no output)        -> a feature not built yet
#
# UNSUP is reported separately on purpose: it is the phase-by-phase progress
# metric, while DIFF must always be zero.

set -uo pipefail
cd "$(dirname "$0")/.."

ZYML=./zyml
ZYMBOL=${ZYMBOL:-zymbol}
VERBOSE=0
MODE=cases

for a in "$@"; do
  case "$a" in
    --corpus) MODE=corpus ;;
    -v|--verbose) VERBOSE=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[[ -x $ZYML ]] || { echo "build first: make" >&2; exit 2; }
command -v "$ZYMBOL" >/dev/null || { echo "reference engine '$ZYMBOL' not found" >&2; exit 2; }

if [[ $MODE == cases ]]; then
  mapfile -t FILES < <(find tests/cases -name '*.zy' | sort)
else
  # Two groups are excluded because their output is not a function of the
  # program, so comparing it would be meaningless rather than informative:
  #   - `input/`  reads stdin, and both engines are fed /dev/null here.
  #   - anything importing `lib_time` prints elapsed wall time, which differs
  #     between engines *because* they differ in speed.
  #   - `scripts/manual_check.zy` shells out to ./target/release/zymbol by
  #     relative path, so what it prints depends on the caller's directory,
  #     not on the engine.
  mapfile -t FILES < <(find ../interpreter/tests -name '*.zy' \
                        -not -path '*/input/*' \
                        -not -name 'manual_check.zy' \
                       | xargs grep -L lib_time \
                       | sort)
fi

pass=0; diff=0; unsup=0
declare -a diff_list=() unsup_list=()

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for f in "${FILES[@]}"; do
  # The reference engine prints analysis warnings to stderr; only stdout counts.
  timeout 10 "$ZYMBOL" run "$f" >"$tmp/ref.out" 2>"$tmp/ref.err" </dev/null
  ref_rc=$?
  timeout 10 "$ZYML" run "$f" >"$tmp/ml.out" 2>"$tmp/ml.err" </dev/null
  ml_rc=$?

  if [[ $ml_rc -ne 0 ]] && grep -qE '^(Lex|Parse|Compile) error:' "$tmp/ml.err"; then
    unsup=$((unsup+1)); unsup_list+=("$f: $(head -1 "$tmp/ml.err")")
    continue
  fi

  if cmp -s "$tmp/ref.out" "$tmp/ml.out"; then
    pass=$((pass+1))
  else
    diff=$((diff+1))
    diff_list+=("$f")
    if [[ $VERBOSE == 1 ]]; then
      echo "--- DIFF $f (ref rc=$ref_rc, zyml rc=$ml_rc)"
      diff <(cat "$tmp/ref.out") <(cat "$tmp/ml.out") | head -12
    fi
  fi
done

total=${#FILES[@]}
echo
echo "parity: $pass/$total identical, $diff differing, $unsup unsupported"

if [[ $VERBOSE == 1 && $unsup -gt 0 ]]; then
  echo
  echo "unsupported:"
  printf '  %s\n' "${unsup_list[@]}" | sort -t: -k2 | head -60
fi

if [[ $diff -gt 0 && $VERBOSE == 0 ]]; then
  echo
  echo "differing files:"
  printf '  %s\n' "${diff_list[@]}"
fi

# Only a real behavioural divergence is a failure.
[[ $diff -eq 0 ]]
