#!/usr/bin/env bash
# Line coverage for agent-sandbox. Needs kcov and coverage (coverage.py) from
# environment.yml: `mamba env update -n agent-sandbox -f environment.yml`.
#
#   scripts/coverage.sh                     engine (kcov) + addon (coverage.py)
#   scripts/coverage.sh engine              the engine: unit, integration, merge
#   scripts/coverage.sh engine-unit         the unit suites under kcov
#   scripts/coverage.sh engine-integration  the integration suites under kcov
#   scripts/coverage.sh engine-merge        merge what the two collected, and report
#
# COVERAGE_SHARD=K/N runs only shard K of N of a stage's files (tests/shard.sh), into
# engine-runs/<stage>-K, for a CI matrix: each shard merges its own runs (engine-merge)
# and passes on that merged directory, a few MB rather than a GB of per-launch runs, and
# the final merge takes every directory under engine-parts/ as well. Merging merges
# gives the same coverage as one merge (measured: 77.41% either way).
#   scripts/coverage.sh addon               just the addon
#   scripts/coverage.sh failures            the tests that failed in the stages run, as
#                                           Markdown (CI's step summary)
#
# A test that fails under kcov fails its stage (#462), once the stage has collected its
# coverage: CI's coverage jobs are informational (not in ci-ok's needs), so it shows
# red without blocking a merge. A test that only tracing breaks (timing) skips under
# kcov (AGENT_SANDBOX_KCOV), saying why.
#
# Each stage is its own command so that CI can time it as a step. The suites run as one
# pool of tests (see timed_bats) with `bats --timing`: every stage writes each file's
# test time to $OUT/timing-<stage>.tsv and each test's TAP line, with its duration, to
# $OUT/<stage>.tap, and prints the slowest files and tests -- which is where a slow
# coverage run shows what it spends its time on.
#
# The engine's Python components (components/join.py, connect-sync.py) are measured by
# coverage.py in the engine stages, where they run: the engine runs them with
# AGENT_SANDBOX_TEST_PYTHON's words (its _as_python; the harness's python_cmd for tests
# that run one directly), which the stages set to tests/helpers/coverage_run.py. Each run
# leaves a data file in engine-runs/<stage>/py/; engine-merge combines them, and every
# shard's under engine-parts/*/py/, into coverage-out/components-coverage.xml.
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
  COVERAGE_FILE="$cf" AGENT_SANDBOX_TEST_PYTHON="coverage run -a --source=$PWD/components,$PWD/profiles" \
    bats tests/unit/addon.bats tests/unit/profile-py.bats >/dev/null
  echo "== addon (coverage.py) =="
  COVERAGE_FILE="$cf" coverage report -m
  COVERAGE_FILE="$cf" coverage html -d "$OUT/addon" >/dev/null 2>&1 \
    && echo "   html: $OUT/addon/index.html"
  # XML for CI upload (Codecov ingests this).
  COVERAGE_FILE="$cf" coverage xml -o "$OUT/addon-coverage.xml" >/dev/null 2>&1 \
    && echo "   xml:  $OUT/addon-coverage.xml"
}

# timed_bats STAGE FILE... -- run the bats FILEs as ONE pool of COVERAGE_JOBS tests at a
# time (default: one per physical core); write their TAP lines to $OUT/STAGE.tap and
# `seconds<TAB>file` -- the sum of a file's test times, from bats's JUnit report -- to
# $OUT/timing-STAGE.tsv; print the slowest.
#
# TESTS RUN IN PARALLEL, across and within files, in one pool. Every test builds its own
# HOME, and a role's keeper is keyed inside that HOME, so tests share no state (a file
# whose tests must not run beside each other says so in its setup_file); each launch
# writes its own kcov directory, and the merge takes them in any order. Tracing is CPU
# work, so one pool sized to the cores is the point: measured on 18 cores, the unit
# stage went from 260 s (18 files at a time, connect.bats alone 260 s) to 58 s, with the
# same coverage; 18 files each running 18 tests was slower than either. Returns non-zero
# if any test failed.
timed_bats() {
  local stage="$1" jobs
  shift
  jobs="${COVERAGE_JOBS:-}"
  if [[ -z "$jobs" ]]; then
    jobs="$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
    [[ "$jobs" -gt 0 ]] || jobs="$(nproc 2>/dev/null || echo 1)"
  fi
  local -a pool=()
  if ((jobs > 1)); then
    if command -v parallel >/dev/null; then
      pool=(--jobs "$jobs")
    else
      echo "   (GNU parallel is not on PATH: one test at a time)" >&2
      jobs=1
    fi
  fi
  local rep="$OUT/junit-$stage"
  rm -rf "$rep"
  mkdir -p "$rep"
  local t_all=$SECONDS rc=0
  # A test that hangs fails after COVERAGE_TEST_TIMEOUT seconds (empty: no limit) instead
  # of holding the job for hours (#462: kcov's stdout relay hung tests until
  # tests/helpers/kcov-exec.sh). 600 s is far above the slowest test under kcov (77 s on
  # 16 cores, ~2x that expected on a 4-vCPU runner) and far below a runner's job limit
  # (6 h). bats 1.14 leaves a failed test's countdown running to its end: harmless under
  # --jobs, but a one-at-a-time run waits it out after each failure -- so a test that
  # runs a bats of its own runs it with `env -u BATS_TEST_TIMEOUT` (harness.bats).
  BATS_TEST_TIMEOUT="${COVERAGE_TEST_TIMEOUT-600}" bats --timing --print-output-on-failure ${pool[@]+"${pool[@]}"} --report-formatter junit --output "$rep" "$@" >"$OUT/$stage.tap" 2>&1 || rc=1
  # The report names a file relative to the first file's directory (profile-claude/x.bats
  # for tests/unit/profile-claude/x.bats); the .tsv names it as it was given, the path
  # tests/shard.sh is given, so scripts/shard-times.sh can make its table from it.
  python3 - "$rep/report.xml" "$@" >"$OUT/timing-$stage.tsv" <<'PY' || : >"$OUT/timing-$stage.tsv"
import os, sys, xml.etree.ElementTree as ET
given = sys.argv[2:]
base = os.path.dirname(given[0]) if given else ""
for s in ET.parse(sys.argv[1]).getroot().iter("testsuite"):
    name = s.get("name")
    # relative to the first file's directory, or (a file elsewhere) as bats was given it
    cands = [os.path.normpath(os.path.join(base, name)), os.path.relpath(name)]
    path = next((c for c in cands if c in given), name)
    print(f"{float(s.get('time', 0)):.1f}\t{path}")
PY
  echo "== $stage: $((SECONDS - t_all)) s wall, $(awk -F'\t' '{s += $1} END {printf "%.0f", s}' "$OUT/timing-$stage.tsv") s of tests, $# files, $jobs tests at a time =="
  echo "   slowest files:"
  sort -rn "$OUT/timing-$stage.tsv" | head -8 | awk -F'\t' '{printf "   %8.1f s  %s\n", $1, $2}'
  echo "   slowest tests:"
  # `# in N ms` from bats 1.10 (environment.yml's), `in Nms` before it
  sed -nE 's/^(not )?ok [0-9]+ (.*) (# in ([0-9]+) ms|in ([0-9]+)ms)$/\4\5\t\2/p' "$OUT/$stage.tap" \
    | sort -rn | head -8 | awk -F'\t' '{printf "   %8.1f s  %s\n", $1 / 1000, substr($2, 1, 90)}'
  local failed
  failed="$(grep -c '^not ok' "$OUT/$stage.tap" || true)"
  if ((failed > 0)); then
    echo "   FAILED: $failed test(s); the .tap file has their output:"
    grep '^not ok' "$OUT/$stage.tap" | sed 's/^/   /'
  fi
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

# py_setup -- the coverage.py rcfile for the engine's Python components, written to
# $OUT/coveragerc. Shared by the stages (which run the components through it) and the
# merge (which reports what it includes: components/ only).
py_setup() {
  cat >"$OUT/coveragerc" <<EOF
[run]
include = $PWD/components/*
disable_warnings = no-data-collected, module-not-measured, module-not-imported
EOF
}

# run_engine_suite STAGE DIR -- one suite directory under kcov, into its own run dir.
# Returns 1 if a test failed (#462: CI's coverage job then fails, with the failed tests
# in its step summary), 2 if a tool is missing.
run_engine_suite() {
  local stage="$1" dir="$2" rc=0
  need_kcov || return 2
  local covdir="$OUT/engine-runs/$stage" k
  # the layer's shared suites and each profile's own, tests/<layer>/profile-<name>/
  shopt -s nullglob
  local -a files=("$dir"/*.bats "$dir"/profile-*/*.bats)
  shopt -u nullglob
  if [[ -n "${COVERAGE_SHARD:-}" ]]; then
    k="${COVERAGE_SHARD%/*}"
    covdir="$covdir-$k"
    mapfile -t files < <(tests/shard.sh "$COVERAGE_SHARD" "${files[@]}")
    ((${#files[@]})) || {
      echo "== $stage: shard $COVERAGE_SHARD has no files =="
      return 0
    }
  fi
  rm -rf "$covdir"
  mkdir -p "$covdir"
  # env -i in the test harness severs kcov's collection when kcov is outside it, so
  # each engine launch wraps itself with kcov as its INNERMOST parent (see run_engine
  # in tests/helpers/common.bash) and writes a per-launch data dir here; the merge
  # stage combines them. AGENT_SANDBOX_KCOV_LIBS is kcov's own LD_LIBRARY_PATH, so that a
  # conda-built kcov resolves its libraries under env -i; only kcov gets it
  # (tests/helpers/kcov-exec.sh), not the tests nor the engine: the system's tools they run
  # would load the conda environment's libraries (curl: "no version information
  # available", #469's CI run).
  local kcov_bin
  kcov_bin="$(command -v kcov)"
  # The Python components run through coverage.py wherever they run (the engine's
  # _as_python, the harness's python_cmd): AGENT_SANDBOX_TEST_PYTHON is
  # tests/helpers/coverage_run.py under this python3 -- by absolute path, since the
  # harness's PATH under env -i has no coverage.py -- and each run's data lands in
  # $covdir/py as .coverage.<pid>.<random>.dump (why not `coverage run`: see that file).
  py_setup
  mkdir -p "$covdir/py"
  AGENT_SANDBOX_KCOV="$kcov_bin" AGENT_SANDBOX_KCOV_DIR="$covdir" \
    AGENT_SANDBOX_TEST_PYTHON="$(command -v python3) $PWD/tests/helpers/coverage_run.py $covdir/py $OUT/coveragerc" \
    AGENT_SANDBOX_KCOV_LIBS="${LD_LIBRARY_PATH:-${CONDA_PREFIX:+$CONDA_PREFIX/lib}}" \
    timed_bats "$stage" "${files[@]}" || rc=$?
  shopt -s nullglob
  local runs=("$covdir"/r.*) pys=("$covdir"/py/.coverage.*.dump)
  shopt -u nullglob
  echo "   kcov runs collected: ${#runs[@]}"
  echo "   coverage.py data files collected: ${#pys[@]}"
  return "$rc"
}

run_engine_merge() {
  need_kcov || return 2
  shopt -s nullglob
  local runs=("$OUT"/engine-runs/*/r.* "$OUT"/engine-parts/*/)
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
  run_py_merge
}

# run_py_merge -- combine the components' coverage.py data: every run of this machine's
# stages (engine-runs/*/py/.coverage.*.dump) and every shard's merge
# (engine-parts/*/py/components.coverage) into $OUT/engine/py/components.coverage --
# which a shard passes on with its kcov merge, in coverage-out/engine; not a dot-file,
# which upload-artifact leaves out -- and report it.
run_py_merge() {
  command -v coverage >/dev/null || {
    echo "coverage.py not found; run: mamba env update -n agent-sandbox -f environment.yml" >&2
    return 2
  }
  shopt -s nullglob
  local pys=("$OUT"/engine-runs/*/py/.coverage.*.dump "$OUT"/engine-parts/*/py/components.coverage)
  # (counted here; the files are globbed in Python, as there may be thousands)
  shopt -u nullglob
  echo "== components (coverage.py) =="
  if ((${#pys[@]} == 0)); then
    echo "   (no component coverage collected)"
    return 0
  fi
  py_setup
  mkdir -p "$OUT/engine/py"
  local cf="$OUT/engine/py/components.coverage"
  rm -f "$cf"
  python3 - "$cf" "$OUT" <<'PY'
import glob, sys
from coverage import CoverageData
out = CoverageData(basename=sys.argv[1])
o = sys.argv[2]
for p in glob.glob(f"{o}/engine-runs/*/py/.coverage.*.dump") + glob.glob(f"{o}/engine-parts/*/py/components.coverage"):
    if p.endswith(".dump"):
        d = CoverageData(no_disk=True)
        with open(p, "rb") as fh:
            d.loads(fh.read())
    else:
        d = CoverageData(basename=p)
        d.read()
    out.update(d)
out.write()
PY
  echo "   combined ${#pys[@]} data files"
  COVERAGE_FILE="$cf" coverage report --rcfile="$OUT/coveragerc" \
    --include="*/components/join.py,*/components/connect-sync.py" | sed 's/^/   /'
  COVERAGE_FILE="$cf" coverage xml --rcfile="$OUT/coveragerc" -o "$OUT/components-coverage.xml" >/dev/null 2>&1 \
    && echo "   xml:  $OUT/components-coverage.xml"
}

# run_engine -- both stages and the merge; a failed test fails it, once all three ran
run_engine() {
  local rc=0 r s
  rm -rf "$OUT/engine-runs"
  for s in unit integration; do
    run_engine_suite "engine-$s" "tests/$s" || {
      r=$?
      ((r == 1)) || return "$r"
      rc=1
    }
  done
  run_engine_merge || return $?
  return "$rc"
}

# run_failures -- the tests that failed in the stages run here ($OUT/*.tap), as Markdown
# for CI's step summary; nothing when none did.
run_failures() {
  local t n
  shopt -s nullglob
  for t in "$OUT"/*.tap; do
    n="$(grep -c '^not ok' "$t" || true)"
    ((n > 0)) || continue
    printf '### %s: %s test(s) failed\n\n```\n' "$(basename -- "$t" .tap)" "$n"
    grep '^not ok' "$t"
    printf '```\n\n'
  done
  shopt -u nullglob
}

# run_all -- the engine, then the addon. The addon's coverage is measured whatever the
# engine's did; a failed test, or a failed addon, fails the run, and an engine that
# can't run here (no kcov: 2) doesn't.
run_all() {
  local rc=0 r
  run_engine || {
    r=$?
    ((r == 2)) || rc=$r
  }
  run_addon || rc=$?
  return "$rc"
}

# Sourced (tests/unit/coverage.bats), it only defines the functions.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "$which" in
  all) run_all ;;
  engine) run_engine ;;
  engine-unit) run_engine_suite engine-unit tests/unit ;;
  engine-integration) run_engine_suite engine-integration tests/integration ;;
  engine-merge) run_engine_merge ;;
  addon) run_addon ;;
  failures) run_failures ;;
  *)
    echo "usage: scripts/coverage.sh [all|engine|engine-unit|engine-integration|engine-merge|addon|failures]" >&2
    exit 2
    ;;
esac
