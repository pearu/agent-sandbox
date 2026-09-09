# shellcheck shell=bash
# Shared harness for the bats suites. Load with:
#   load "$BATS_TEST_DIRNAME/../helpers/common"
#
# The standard harness is a stub `bwrap` that records the argv it receives:
# the argv the engine produces for a given input is the contract under test.

REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)"
# AGENT_SANDBOX_TEST_ENGINE lets a mutated copy of the engine be tested (mutation checks).
ENGINE="${AGENT_SANDBOX_TEST_ENGINE:-$REPO_ROOT/agent-sandbox}"
export REPO_ROOT ENGINE

# Source the engine. When sourced it only defines its functions (the run guard
# compares BASH_SOURCE to $0), so helpers can be called directly.
source_engine() {
  # shellcheck disable=SC1090
  source "$ENGINE"
}

# A fake HOME with a stub Claude install, a stub agent binary, a project dir,
# and a stub bwrap on PATH; the engine is reachable as `claude` (argv[0]
# inference) and as `agent-sandbox`. Sets H.
make_harness() {
  H="$BATS_TEST_TMPDIR/h"
  mkdir -p "$H/bin" "$H/home/.local/share/claude/versions/2.1.300" "$H/proj" "$H/base"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
# Stub bwrap: record argv, one token per line, then exit 0 (never sandboxes).
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
exit 0
STUB
  chmod +x "$H/bin/bwrap"
  printf '#!/usr/bin/env bash\necho "stub-agent argv: $*"\n' >"$H/home/.local/share/claude/versions/2.1.300/claude"
  chmod +x "$H/home/.local/share/claude/versions/2.1.300/claude"
  ln -s "$ENGINE" "$H/bin/claude"
  ln -s "$ENGINE" "$H/bin/agent-sandbox"
  export H
}

# run_engine [VAR=value ...] -- CMD ARGS...
# Runs CMD (claude | agent-sandbox | a path) from $H/proj with a clean
# environment plus the given variables, the stub bwrap first on PATH, and the
# argv recorded in $H/argv. Uses bats' `run`, so $status and $output are set.
run_engine() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local cmd=$1
  shift
  [[ "$cmd" == */* ]] || cmd="$H/bin/$cmd"
  : >"$H/argv"
  pushd "${RUN_CWD:-$H/proj}" >/dev/null || return 1
  # Forward the coverage instrumentation (kcov: BASH_ENV + KCOV_BASH_* + LD_PRELOAD)
  # through env -i so the engine SUBPROCESS is measured, not just code that runs in
  # bats's own shell; harmless when unset (normal test runs).
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} ${KCOV_BASH_USE_DEBUG_TRAP:+KCOV_BASH_USE_DEBUG_TRAP="$KCOV_BASH_USE_DEBUG_TRAP"} ${KCOV_BASH_COMMAND:+KCOV_BASH_COMMAND="$KCOV_BASH_COMMAND"} ${KCOV_BASH_XTRACEFD:+KCOV_BASH_XTRACEFD="$KCOV_BASH_XTRACEFD"} ${LD_PRELOAD:+LD_PRELOAD="$LD_PRELOAD"} HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
    BWRAP_DUMP="$H/argv" AGENT_SANDBOX_SESSION_BASE="$H/base" "${envs[@]}" "$cmd" "$@"
  popd >/dev/null || return 1
  mapfile -t ARGV <"$H/argv"
}

# True if the tokens appear consecutively in ARGV.
argv_has() {
  local -a want=("$@")
  local i j n=${#want[@]}
  for ((i = 0; i + n <= ${#ARGV[@]}; i++)); do
    for ((j = 0; j < n; j++)); do
      [[ "${ARGV[i + j]}" == "${want[j]}" ]] || break
    done
    ((j == n)) && return 0
  done
  return 1
}

# Print the value of `--setenv NAME` in ARGV; fail if absent.
setenv_value() {
  local i
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    if [[ "${ARGV[i]}" == "--setenv" && "${ARGV[i + 1]}" == "$1" ]]; then
      printf '%s' "${ARGV[i + 2]}"
      return 0
    fi
  done
  return 1
}

# 0-based index of the first occurrence of a token (for ordering assertions).
argv_index() {
  local i
  for ((i = 0; i < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == "$1" ]] && {
      printf '%s' "$i"
      return 0
    }
  done
  return 1
}

# A short session base: unix socket paths are limited to ~108 bytes and
# BATS_TEST_TMPDIR can be long. Sets SHORT_BASE; remove it in teardown.
make_short_base() {
  SHORT_BASE="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/as-test.XXXXXX")"
  export SHORT_BASE
}

# Write a self-signed CA certificate (PEM) to $1, for CA-bundle tests.
make_fake_ca() {
  openssl req -x509 -newkey ed25519 -nodes -subj '/CN=agent-sandbox test CA' \
    -keyout "$1.key" -out "$1" -days 1 >/dev/null 2>&1
}
