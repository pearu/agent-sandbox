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
OUT="${COVERAGE_OUT:-coverage-out}"
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
}

run_engine() {
  command -v kcov >/dev/null || {
    echo "kcov not found. It is not on conda-forge nor in Ubuntu 24.04's repos; build" >&2
    echo "it from source: https://github.com/SimonKagstrom/kcov (INSTALL.md). Ubuntu deps:" >&2
    echo "  apt install binutils-dev build-essential cmake libssl-dev libcurl4-openssl-dev \\" >&2
    echo "              libelf-dev libstdc++-12-dev zlib1g-dev libdw-dev libiberty-dev" >&2
    echo "  then: git clone .../kcov && cd kcov && mkdir build && cd build && cmake .. && make && sudo make install" >&2
    return 2
  }
  command -v bats >/dev/null || {
    echo "bats not found (environment.yml)" >&2
    return 2
  }
  rm -rf "$OUT/engine"
  # kcov traces the agent-sandbox bash process the tests spawn (the harness
  # forwards BASH_ENV through its `env -i`, which is how kcov instruments the
  # child). Restrict the report to the engine file itself.
  kcov --include-path="$PWD/agent-sandbox" "$OUT/engine" \
    bats tests/unit tests/integration >/dev/null 2>&1 || true
  local j
  j="$(find "$OUT/engine" -name 'coverage.json' 2>/dev/null | head -1)"
  echo "== engine (kcov) =="
  if [[ -n "$j" ]]; then
    python3 - "$j" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pct = d.get("percent_covered", "?")
files = d.get("files", [])
tot = files[0].get("total_lines", "?") if files else "?"
cov = files[0].get("covered_lines", "?") if files else "?"
print(f"   agent-sandbox: {pct}% ({cov}/{tot} instrumented lines)")
PY
  else
    echo "   (no coverage.json produced; see $OUT/engine/index.html)"
  fi
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
