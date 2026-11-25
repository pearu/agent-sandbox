# shellcheck shell=bash
# Integration harness: the REAL bwrap, a test profile whose "agent" is a probe
# script that runs inside the sandbox and writes key=value lines to
# $PWD/report (the CWD is bound read-write). Load after common.bash.

# Skip the test unless unprivileged user namespaces work here.
require_bwrap() {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  bwrap --ro-bind / / --unshare-user --unshare-pid -- /bin/true 2>/dev/null \
    || skip "unprivileged user namespaces unavailable (AppArmor/sysctl)"
}

# Sets I (dir), IHOME, IWORK, IPROFILES; writes the probe script from stdin. I's
# name holds a ".", a character Claude Code's slug and the engine's convert, so every
# run, under any TMPDIR, has a project path whose slug is not just "/" turned into
# "-" (#454).
make_integration() {
  I="$BATS_TEST_TMPDIR/i.x"
  IHOME="$I/home"
  IWORK="$I/work"
  IPROFILES="$I/profiles"
  # The probe profile's state directory and its channel paths: the engine
  # refuses a state bind whose source is missing, and a channel needs somewhere
  # to be. Cheap, and it means every integration test can ask for a connection.
  mkdir -p "$IHOME" "$IWORK" "$IPROFILES" "$IHOME/.probe/docs" "$IHOME/.probe/extra"
  mkdir -p "$IPROFILES/probe" && cp "$REPO_ROOT/tests/helpers/probe-profile.sh" "$IPROFILES/probe/profile.sh"
  cat >"$I/probe.sh"
  chmod +x "$I/probe.sh"
  # The probe is the agent, and a launch names it as a user names theirs (#151):
  # `probe` on PATH, whose basename selects the probe profile.
  mkdir -p "$I/bin"
  ln -sfn "$I/probe.sh" "$I/bin/probe"
  export I IHOME IWORK IPROFILES
}

# claude_slug PATH -- PATH's directory under ~/.claude/projects/, from the claude
# profile's own _claude_project_slug rather than a copy of its rule (#454), so a test
# follows the engine, the 200-character truncation and its hash included. Sourced in
# a subshell: the profile's variables and functions never reach the test.
claude_slug() { (source "$REPO_ROOT/profiles/claude/profile.sh" && _claude_project_slug "$1"); }

# state_slug PATH -- the engine's own name for PATH's state directory, from its
# _as_path_slug, the same way. Not claude_slug: the two differ past 200 characters.
state_slug() { (source "$REPO_ROOT/agent-sandbox" && _as_path_slug "$1"); }

# Like run_engine, every launch here pins a preset. The engine's default puts the
# declared channels at `cow`, so without this every integration suite -- conda,
# memory, isolation, ssh -- would silently be testing the sandbox with overlays
# layered over its state, which is not what any of them is about. A suite that
# wants the real default sets TEST_PRESET to the empty string.

# run_sandboxed [VAR=value ...] -- [ENGINE FLAGS] probe [PROBE ARGS]
# (or -- [ENGINE FLAGS] --profile probe --exec CMD...)
# Runs the real engine from $IWORK with a clean environment; REPORT holds the
# probe's key=value output afterwards. $status/$output from bats' run.
run_sandboxed() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  rm -f "$IWORK/report"
  pushd "$IWORK" >/dev/null || return 1
  engine_cmd # traced under coverage (common.bash)
  run env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" \
    AGENT_SANDBOX_SESSION_BASE="${SESSION_BASE:-$I/base}" AGENT_SANDBOX_KEEPER_GRACE="${KEEPER_GRACE:-0}" \
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" AGENT_SANDBOX_VERBOSE=on \
    ${AGENT_SANDBOX_PROXY_PORT:+AGENT_SANDBOX_PROXY_PORT="$AGENT_SANDBOX_PROXY_PORT"} \
    "${envs[@]}" "${ENGINE_CMD[@]}" "$@"
  popd >/dev/null || return 1
  declare -gA REPORT=()
  local k v
  # Braced: an --exec run writes no report, and bash reports a failed redirection
  # before a 2> on the same command is in place.
  { while IFS='=' read -r k v; do [[ -n "$k" ]] && REPORT["$k"]="$v"; done <"$IWORK/report"; } 2>/dev/null || true
}

# report KEY -> value (fails if missing)
report() { [[ -v "REPORT[$1]" ]] && printf '%s' "${REPORT[$1]}"; }
