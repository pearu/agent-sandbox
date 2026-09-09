#!/usr/bin/env bash
# Line coverage for agent-sandbox. Needs kcov and coverage (coverage.py) from
# environment.yml: `mamba env update -n agent-sandbox -f environment.yml`.
#
#   scripts/coverage.sh            engine (kcov) + addon (coverage.py)
#   scripts/coverage.sh addon      just the addon
#   scripts/coverage.sh engine     just the engine
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

run_engine() {
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
  local covdir="$OUT/engine-runs"
  rm -rf "$covdir" "$OUT/engine"
  mkdir -p "$covdir"
  # env -i in the test harness severs kcov's collection when kcov is outside it, so
  # each engine launch wraps itself with kcov as its INNERMOST parent (see run_engine
  # in tests/helpers/common.bash) and writes a per-launch data dir here; we merge them.
  # LD_LIBRARY_PATH lets a conda-built kcov resolve its libraries under env -i.
  local kcov_bin
  kcov_bin="$(command -v kcov)"
  AGENT_SANDBOX_KCOV="$kcov_bin" AGENT_SANDBOX_KCOV_DIR="$covdir" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-${CONDA_PREFIX:+$CONDA_PREFIX/lib}}" \
    bats tests/unit tests/integration >/dev/null || true
  echo "== engine (kcov) =="
  shopt -s nullglob
  local runs=("$covdir"/r.*)
  shopt -u nullglob
  if ((${#runs[@]} == 0)); then
    echo "   (no engine coverage collected)"
    return 0
  fi
  kcov --merge "$OUT/engine" "${runs[@]}" >/dev/null 2>&1 || true
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
case "$which" in
  all)
    run_engine || true
    run_addon
    ;;
  engine) run_engine ;;
  addon) run_addon ;;
  *)
    echo "usage: scripts/coverage.sh [all|engine|addon]" >&2
    exit 2
    ;;
esac
