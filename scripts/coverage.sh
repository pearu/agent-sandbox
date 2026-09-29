#!/usr/bin/env bash
# Line coverage for agent-sandbox. Needs kcov and coverage (coverage.py) from
# environment.yml: `mamba env update -n agent-sandbox -f environment.yml`.
#
#   scripts/coverage.sh                     engine (kcov) + addon (coverage.py)
#   scripts/coverage.sh engine              the engine: unit, integration, merge
#   scripts/coverage.sh engine-unit         the unit suites under kcov
#   scripts/coverage.sh engine-integration  the integration suites under kcov
#   scripts/coverage.sh engine-merge        merge what the two collected, and report
#   scripts/coverage.sh addon               just the addon
#
# Each stage is its own command so that CI can time it as a step. The suites run one
# file at a time with `bats --timing`: every stage writes the wall time of each file
# to $OUT/timing-<stage>.tsv and each test's TAP line, with its duration, to
# $OUT/<stage>.tap, and prints the slowest files and tests -- which is where a slow
# coverage run shows what it spends its time on.
#
# Output (HTML + a printed summary) goes under coverage-out/ (git-ignored).
# The engine run drives the unit and integration suites; the integration ones
# need bwrap (and pasta for strict) or they skip, so run it where those work.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# OUT must be ABSOLUTE: the test harness pushd's into bats's per-test tmpdir before
# launching the engine, so a relative kcov output dir would land there and vanish
# with it (this bit CI: "no engine coverage collected").
OUT="${COVERAGE_OUT:-$PWD/coverage-out}"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
mkdir -p "$OUT"
which="${1:-all}"

run_addon() {
  command -v coverage >/dev/null || {
    echo "coverage.py not found; run: mamba env update -n agent-sandbox -f environment.yml" >&2
    return 2
  }
  command -v bats >/dev/null || {
    echo "bats not found (environment.yml)" >&2
    return 2
  }
  local cf="$OUT/.coverage.addon"
  rm -f "$cf"
  # The addon runs once per addon_driver subprocess; `coverage run -a` appends to
  # one data file so the report is the aggregate over the whole suite.
  COVERAGE_FILE="$cf" AGENT_SANDBOX_TEST_PYTHON="coverage run -a --source=$PWD/components" \
    bats tests/unit/addon.bats >/dev/null
  echo "== addon (coverage.py) =="
  COVERAGE_FILE="$cf" coverage report -m
  COVERAGE_FILE="$cf" coverage html -d "$OUT/addon" >/dev/null 2>&1 \
    && echo "   html: $OUT/addon/index.html"
  # XML for CI upload (Codecov ingests this).
  COVERAGE_FILE="$cf" coverage xml -o "$OUT/addon-coverage.xml" >/dev/null 2>&1 \
    && echo "   xml:  $OUT/addon-coverage.xml"
}

# _cov_one N FILE -- one worker of timed_bats: FILE's TAP to $COV_PARTS/N.tap, its wall
# time to $COV_PARTS/N.time, and $COV_PARTS/N.failed if it failed.
_cov_one() {
  local n="$1" f="$2" t0
  t0=$(date +%s.%N)
  bats --timing "$f" >"$COV_PARTS/$n.tap" 2>&1 || : >"$COV_PARTS/$n.failed"
  awk -v a="$(date +%s.%N)" -v b="$t0" -v f="$f" 'BEGIN { printf "%.1f\t%s\n", a - b, f }' >"$COV_PARTS/$n.time"
}
export -f _cov_one

# timed_bats STAGE FILE... -- run each bats FILE on its own, timed, COVERAGE_JOBS at a time
# (default: the number of CPUs, at most 4); append the TAP lines to $OUT/STAGE.tap and
# `seconds<TAB>file` to $OUT/timing-STAGE.tsv, in file order; print the slowest.
#
# FILES RUN IN PARALLEL, not tests within a file. Every test builds its own HOME, and a
# role's keeper is keyed inside that HOME, so two files share no state; each launch
# writes its own kcov directory, and the merge takes them in any order. Tracing is CPU
# work, so this is where the time goes. Returns non-zero if any file failed.
timed_bats() {
  local stage="$1" jobs
  shift
  jobs="${COVERAGE_JOBS:-$(nproc 2>/dev/null || echo 1)}"
  ((jobs > 4 && ${COVERAGE_JOBS:-0} == 0)) && jobs=4
  local parts="$OUT/parts-$stage"
  rm -rf "$parts"
  mkdir -p "$parts"
  local t_all=$SECONDS
  # One file per worker: its TAP to parts/N.tap, its wall time to parts/N.time.
  local i=0 f
  # shellcheck disable=SC2016 # the worker's "$1" "$2" are expanded by its bash, not here
  for f in "$@"; do
    printf '%s\n%s\n' "$i" "$f"
    i=$((i + 1))
  done | COV_PARTS="$parts" xargs -P "$jobs" -n 2 bash -c '_cov_one "$1" "$2"' _
  : >"$OUT/$stage.tap"
  : >"$OUT/timing-$stage.tsv"
  local rc=0
  for ((i = 0; i < $#; i++)); do
    cat "$parts/$i.tap" >>"$OUT/$stage.tap" 2>/dev/null
    cat "$parts/$i.time" >>"$OUT/timing-$stage.tsv" 2>/dev/null
    [[ -e "$parts/$i.failed" ]] && rc=1
  done
  rm -rf "$parts"
  echo "== $stage: $((SECONDS - t_all)) s wall, $(awk -F'\t' '{s += $1} END {printf "%.0f", s}' "$OUT/timing-$stage.tsv") s of files, $# files, $jobs at a time =="
  echo "   slowest files:"
  sort -rn "$OUT/timing-$stage.tsv" | head -8 | awk -F'\t' '{printf "   %8.1f s  %s\n", $1, $2}'
  echo "   slowest tests:"
  sed -n 's/^\(not \)\{0,1\}ok [0-9]* \(.*\) in \([0-9]*\)ms$/\3\t\2/p' "$OUT/$stage.tap" \
    | sort -rn | head -8 | awk -F'\t' '{printf "   %8.1f s  %s\n", $1 / 1000, substr($2, 1, 90)}'
  grep -c '^not ok' "$OUT/$stage.tap" | awk '$1 > 0 {print "   FAILED: " $1 " test(s); see the .tap file"}'
  return "$rc"
}

need_kcov() {
  command -v kcov >/dev/null || {
    echo "kcov not found. It is not on conda-forge nor in Ubuntu 24.04's repos; build" >&2
    echo "it from source with scripts/install-kcov.sh (its conda-forge build deps:" >&2
    echo "  cmake make pkg-config cxx-compiler openssl libcurl elfutils zlib)." >&2
    return 2
  }
  command -v bats >/dev/null || {
    echo "bats not found (environment.yml)" >&2
    return 2
  }
}

# run_engine_suite STAGE DIR -- one suite directory under kcov, into its own run dir.
run_engine_suite() {
  local stage="$1" dir="$2"
  need_kcov || return 2
  local covdir="$OUT/engine-runs/$stage"
  rm -rf "$covdir"
  mkdir -p "$covdir"
  # env -i in the test harness severs kcov's collection when kcov is outside it, so
  # each engine launch wraps itself with kcov as its INNERMOST parent (see run_engine
  # in tests/helpers/common.bash) and writes a per-launch data dir here; the merge
  # stage combines them. LD_LIBRARY_PATH lets a conda-built kcov resolve its libraries
  # under env -i.
  local kcov_bin
  kcov_bin="$(command -v kcov)"
  AGENT_SANDBOX_KCOV="$kcov_bin" AGENT_SANDBOX_KCOV_DIR="$covdir" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-${CONDA_PREFIX:+$CONDA_PREFIX/lib}}" \
    timed_bats "$stage" "$dir"/*.bats || true
  shopt -s nullglob
  local runs=("$covdir"/r.*)
  shopt -u nullglob
  echo "   kcov runs collected: ${#runs[@]}"
}

run_engine_merge() {
  need_kcov || return 2
  shopt -s nullglob
  local runs=("$OUT"/engine-runs/*/r.*)
  shopt -u nullglob
  echo "== engine (kcov) =="
  if ((${#runs[@]} == 0)); then
    echo "   (no engine coverage collected)"
    return 0
  fi
  local t0
  t0=$(date +%s)
  rm -rf "$OUT/engine"
  kcov --merge "$OUT/engine" "${runs[@]}" >/dev/null 2>&1 || true
  echo "   merged ${#runs[@]} runs in $(($(date +%s) - t0)) s"
  local j x
  j="$(find "$OUT/engine" -name 'coverage.json' 2>/dev/null | head -1)"
  x="$(find "$OUT/engine" -name 'cobertura.xml' 2>/dev/null | head -1)"
  if [[ -n "$j" ]]; then
    python3 - "$j" <<'PYJSON'
import json, sys
d = json.load(open(sys.argv[1]))
f = d.get("files", [{}])[0]
print(f"   agent-sandbox: {d.get('percent_covered','?')}% ({f.get('covered_lines','?')}/{f.get('total_lines','?')} instrumented lines)")
PYJSON
  fi
  [[ -n "$x" ]] && cp -f "$x" "$OUT/engine-cobertura.xml" && echo "   xml:  $OUT/engine-cobertura.xml"
  echo "   html: $OUT/engine/index.html"
}

run_engine() {
  rm -rf "$OUT/engine-runs"
  run_engine_suite engine-unit tests/unit || return $?
  run_engine_suite engine-integration tests/integration || return $?
  run_engine_merge
}

case "$which" in
  all)
    run_engine || true
    run_addon
    ;;
  engine) run_engine ;;
  engine-unit) run_engine_suite engine-unit tests/unit ;;
  engine-integration) run_engine_suite engine-integration tests/integration ;;
  engine-merge) run_engine_merge ;;
  addon) run_addon ;;
  *)
    echo "usage: scripts/coverage.sh [all|engine|engine-unit|engine-integration|engine-merge|addon]" >&2
    exit 2
    ;;
esac
