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
# and a stub bwrap on PATH. `claude` on PATH is the stub agent, linked from its
# versions/ directory as Claude Code's native installer links it; the engine is
# `asb` and `agent-sandbox` (#151). Sets H.
make_harness() {
  H="$BATS_TEST_TMPDIR/h"
  mkdir -p "$H/bin" "$H/home/.local/share/claude/versions/2.1.300" "$H/proj" "$H/base"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
# Not measured, so not traced: under coverage kcov traces every bash process the
# engine starts, and a stub's trace only slows it and pollutes what it captures.
set +x
# Stub bwrap: record argv, one token per line, then exit 0 (never sandboxes).
#
# It answers --help too, because the engine asks bwrap whether it can mount an
# overlay before deciding how to implement `cow`. A stub that said nothing made
# every overlay path fall back to copy, so the argv those tests exist to pin was
# never produced. AGENT_SANDBOX_TEST_NO_OVERLAY makes it report a bubblewrap too
# old for overlays, which is the other half of that decision.
if [[ "${1:-}" == --help ]]; then
  [[ -n "${AGENT_SANDBOX_TEST_NO_OVERLAY:-}" ]] \
    || printf '    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST\n'
  exit 0
fi
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
  # The end of every stub bwrap, this one and the ones suites write for themselves: a
  # keeper's launch (its payload is marked in its last argument) is played by running
  # that payload here, on the host -- something has to stay alive for the engine to
  # find and for the join to name. Any other launch, a wrapped worker, ends at once.
  # Sourced, with the stub's own "$@".
  cat >"$H/bin/keeper-tail" <<'STUB'
if [[ "${!#}" == agent-sandbox-keeper ]]; then
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
  shift
  exec "$@"
fi
exit 0
STUB
  # Stub join (AGENT_SANDBOX_JOIN): record its argv, one token per line, and run
  # nothing -- as the stub bwrap never ran the agent, this never runs the command. It
  # exits with $JOIN_EXIT, which stands for the joined command's exit status, and
  # while the file $JOIN_HOLD exists it stays joined (see engine_bg).
  cat >"$H/bin/join-stub.py" <<'STUB'
import os, sys
with open(os.environ["JOIN_DUMP"], "w") as fh:
    for a in sys.argv[1:]:
        fh.write(a + "\n")
hold = os.environ.get("JOIN_HOLD")
while hold and os.path.exists(hold):
    import time
    time.sleep(0.02)
sys.exit(int(os.environ.get("JOIN_EXIT", "0")))
STUB
  printf '#!/usr/bin/env bash\necho "stub-agent argv: $*"\n' >"$H/home/.local/share/claude/versions/2.1.300/claude"
  chmod +x "$H/home/.local/share/claude/versions/2.1.300/claude"
  ln -s "$H/home/.local/share/claude/versions/2.1.300/claude" "$H/bin/claude"
  ln -s "$ENGINE" "$H/bin/asb"
  ln -s "$ENGINE" "$H/bin/agent-sandbox"
  export H
}

# run_engine [VAR=value ...] -- CMD ARGS...
# Runs CMD (asb | agent-sandbox | a path) from $H/proj with a clean
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
  : >"$H/join"
  pushd "${RUN_CWD:-$H/proj}" >/dev/null || return 1
  # Coverage: when AGENT_SANDBOX_KCOV is set (scripts/coverage.sh), wrap the engine
  # with kcov as its DIRECT parent, INSIDE env -i -- env -i severs kcov's collection
  # if kcov is outside it, but works when kcov is the innermost wrapper. Each launch
  # writes its own kcov dir; coverage.sh merges them. LD_LIBRARY_PATH is forwarded so
  # kcov finds its libs. Empty on a normal run.
  local -a kc=()
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] && kc=("$AGENT_SANDBOX_KCOV" --include-path="$ENGINE" "$AGENT_SANDBOX_KCOV_DIR/r.$$.$RANDOM")
  # seccomp is ON by default in the engine. The harness points its filter
  # directory at an empty one rather than forcing AGENT_SANDBOX_SECCOMP=off:
  # setting the knob would override the .agent-sandbox value that the dot-file
  # tests exist to check. With no filter present the engine warns and runs on,
  # so every other suite sees the argv it saw before, plus that warning.
  run env -i ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
    BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" AGENT_SANDBOX_VERBOSE=on "${envs[@]}" "${kc[@]}" "$cmd" "$@"
  popd >/dev/null || return 1
  mapfile -t ARGV <"$H/argv"
  # What was joined into the keeper: JOIN is the join's whole argv, JOINV the command
  # after its `--` (what bwrap's argv used to end with).
  mapfile -t JOIN <"$H/join"
  JOINV=()
  local _i
  for ((_i = 0; _i < ${#JOIN[@]}; _i++)); do
    [[ "${JOIN[_i]}" == -- ]] && {
      JOINV=("${JOIN[@]:_i+1}")
      break
    }
  done
}

# run_engine_tty ANSWERS [VAR=value ...] -- CMD ARGS... -- run_engine, but at a terminal:
# the engine's stdin and stderr are a pty (script(1)), and ANSWERS (printf %b) is what is
# typed into it. For the reviews a launch runs only when someone can answer (#143).
run_engine_tty() {
  local answers="$1"
  shift
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
  : >"$H/join"
  local -a line=(env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8
    BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0
    AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp"
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" AGENT_SANDBOX_VERBOSE=on "${envs[@]}" "$cmd" "$@")
  printf 'cd %q && exec' "${RUN_CWD:-$H/proj}" >"$H/tty.sh"
  printf ' %q' "${line[@]}" >>"$H/tty.sh"
  run bash -c 'printf "%b" "$1" | script -qec "bash $2" /dev/null' _ "$answers" "$H/tty.sh"
  mapfile -t ARGV <"$H/argv"
}

# engine_bg [VAR=value ...] -- CMD ARGS... -- start the engine in the background as
# run_engine would, joined into its keeper and HELD there until release_bg, so that a
# test can act while a role is running. Returns once the join is on the record; sets
# BG_PID. Its argv goes to $H/argv.bg, its join to $H/join.bg, its output to $H/bg.out.
engine_bg() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  local cmd=$1 i
  shift
  [[ "$cmd" == */* ]] || cmd="$H/bin/$cmd"
  : >"$H/hold"
  rm -f "$H/join.bg"
  (
    cd "${RUN_CWD:-$H/proj}" || exit 1
    exec env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
      BWRAP_DUMP="$H/argv.bg" JOIN_DUMP="$H/join.bg" JOIN_HOLD="$H/hold" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" \
      AGENT_SANDBOX_KEEPER_GRACE=0 AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" AGENT_SANDBOX_VERBOSE=on "${envs[@]}" "$cmd" "$@"
  ) </dev/null >"$H/bg.out" 2>&1 3>&- &
  BG_PID=$!
  for ((i = 0; i < 500; i++)); do
    [[ -s "$H/join.bg" ]] && return 0
    kill -0 "$BG_PID" 2>/dev/null || break
    sleep 0.02
  done
  echo "engine_bg: the background launch did not join:" >&2
  cat "$H/bg.out" >&2
  return 1
}

# release_bg -- let the engine_bg launch's join end, and wait for it; sets BG_STATUS.
# shellcheck disable=SC2034 # BG_STATUS is for the suites
release_bg() {
  rm -f "$H/hold"
  BG_STATUS=0
  wait "$BG_PID" || BG_STATUS=$?
}

# EVERY RUN IS VERBOSE: the suites assert on the routine status lines (the session
# allowlist, what the dot-file applied), which a launch prints only with --verbose. A
# test of the quiet default passes AGENT_SANDBOX_VERBOSE= (empty: the default).
#
# WHY EVERY RUN PINS A PRESET. The engine's default preset puts the declared
# channels at `copy-on-write`, so without this every launch in every suite would be
# measuring the sandbox with overlays layered over its state. The suites that are not about
# connections should see what they always saw, which is `shared`; the ones that
# are set TEST_PRESET or pass the knob themselves. A test that wants the engine's
# real default must say so, which is the right way round: a default that changes
# should not silently change what every other test is measuring.
#
# `${TEST_PRESET-shared}` and not `:-`: a test that sets TEST_PRESET to the EMPTY
# string is asking for the engine's own default, and `:-` would have quietly
# handed it `shared` instead -- so the two tests that exist to pin that default
# would have been testing the pin.

# `run ! cmd` is how this suite asserts that a command fails. A bare `! cmd`
# cannot: bash suppresses errexit -- and the ERR trap bats fails on -- for a
# negated command, so a test body of `! true` is reported ok (measured, bats
# 1.14.0; ShellCheck reports it as SC2314). `run !` needs bats 1.5.0, and
# declaring that here, in the helper every suite loads, is what makes bats
# honour the `!` flag instead of warning BW02 and running `!` as a command.
# Mind that `run` replaces $status and $output: check a message BEFORE the
# `run !` line that follows it, not after.
bats_require_minimum_version 1.5.0

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

# True if the tokens appear consecutively in JOINV, the command joined into the keeper.
join_has() {
  local -a want=("$@")
  local i j n=${#want[@]}
  for ((i = 0; i + n <= ${#JOINV[@]}; i++)); do
    for ((j = 0; j < n; j++)); do
      [[ "${JOINV[i + j]}" == "${want[j]}" ]] || break
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
