#!/usr/bin/env bash
# Run the test suites. bats comes from environment.yml (conda-forge bats-core).
#   tests/run.sh                 unit + integration
#   tests/run.sh unit|integration|live|e2e|all
#   AGENT_SANDBOX_LIVE=1 tests/run.sh live     real network and your credentials; opt-in, never in CI
#   AGENT_SANDBOX_E2E=1  tests/run.sh e2e      install.sh for real against a throwaway HOME; opt-in, CI runs it
# Extra arguments after the suite name go to bats (e.g. --filter NAME).
# The run fails if it leaves an overlay holder running (tests/helpers/holder-leaks.sh).
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
# Run bats, then fail the run if it left overlay holders behind (tests/helpers/holder-leaks.sh):
# a leaked holder passes every test and is only ever noticed by counting.
before="$(tests/helpers/holder-leaks.sh snapshot)"
status=0
bats --recursive "$@" || status=$?
# shellcheck disable=SC2086 # a list of pids
tests/helpers/holder-leaks.sh check $before || status=1
exit "$status"
