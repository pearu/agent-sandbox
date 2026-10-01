#!/usr/bin/env bash
# Run the test suites. bats comes from environment.yml (conda-forge bats-core).
#   tests/run.sh                 unit + integration
#   tests/run.sh unit|integration|live|e2e|all
#   AGENT_SANDBOX_LIVE=1 tests/run.sh live     real network and your credentials; opt-in, never in CI
#   AGENT_SANDBOX_E2E=1  tests/run.sh e2e      install.sh for real against a throwaway HOME; opt-in, CI runs it
# Extra arguments after the suite name go to bats (e.g. --filter NAME).
# The run fails if it leaves a role keeper running (tests/helpers/keeper-leaks.sh).
#
# The unit and integration suites run in parallel, test by test, when GNU parallel is
# on PATH (environment.yml): one job per physical core, or AGENT_SANDBOX_TEST_JOBS (1 is
# serial). Measured on 18 cores: unit 609 s -> 43 s, integration 109 s -> 15 s. A file
# whose tests must not run beside each other says so in its setup_file
# (BATS_NO_PARALLELIZE_WITHIN_FILE=true), and still runs beside other files. e2e and
# live stay serial: e2e shares one install and port 8888, live your credentials.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
command -v bats >/dev/null || {
  echo "tests/run.sh: bats not found. Install the dev env: mamba env update -n agent-sandbox -f environment.yml" >&2
  exit 2
}
suite="${1:-default}"
[[ $# -gt 0 ]] && shift
case "$suite" in
  default) set -- tests/unit tests/integration "$@" ;;
  unit | integration) set -- "tests/$suite" "$@" ;;
  live)
    [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || {
      echo "tests/run.sh: live tests need AGENT_SANDBOX_LIVE=1 (they use the real network and your credentials)" >&2
      exit 2
    }
    set -- tests/live "$@"
    ;;
  e2e)
    [[ "${AGENT_SANDBOX_E2E:-0}" == 1 ]] || {
      echo "tests/run.sh: the end-to-end installer test needs AGENT_SANDBOX_E2E=1 (network; installs mitmproxy into a throwaway HOME)" >&2
      exit 2
    }
    set -- tests/e2e "$@"
    ;;
  all) set -- tests/unit tests/integration tests/live tests/e2e "$@" ;;
  *) set -- "$suite" "$@" ;; # a file or directory
esac
jobs=()
case "$suite" in
  default | unit | integration)
    n="${AGENT_SANDBOX_TEST_JOBS:-}"
    if [[ -z "$n" ]]; then
      n="$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
      [[ "$n" -gt 0 ]] || n="$(nproc 2>/dev/null || echo 1)"
    fi
    if [[ "$n" -gt 1 ]]; then
      if command -v parallel >/dev/null; then
        jobs=(--jobs "$n")
      else
        echo "tests/run.sh: GNU parallel is not on PATH, so the suites run serially (mamba env update -n agent-sandbox -f environment.yml)" >&2
      fi
    fi
    ;;
esac
# Run bats, then fail the run if it left role keepers behind (tests/helpers/keeper-leaks.sh):
# a leaked keeper passes every test and is only ever noticed by counting.
before="$(tests/helpers/keeper-leaks.sh snapshot)"
status=0
bats --recursive ${jobs[@]+"${jobs[@]}"} "$@" || status=$?
# shellcheck disable=SC2086 # a list of pids
tests/helpers/keeper-leaks.sh check $before || status=1
exit "$status"
