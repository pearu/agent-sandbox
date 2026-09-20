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

# Sets I (dir), IHOME, IWORK, IPROFILES; writes the probe script from stdin.
make_integration() {
  I="$BATS_TEST_TMPDIR/i"
  IHOME="$I/home"
  IWORK="$I/work"
  IPROFILES="$I/profiles"
  # The probe profile's state directory and its channel paths: the engine
  # refuses a state bind whose source is missing, and a channel needs somewhere
  # to be. Cheap, and it means every integration test can ask for a connection.
  mkdir -p "$IHOME" "$IWORK" "$IPROFILES" "$IHOME/.probe/docs" "$IHOME/.probe/extra"
  cp "$BATS_TEST_DIRNAME/../helpers/probe-profile.sh" "$IPROFILES/probe.sh"
  cat >"$I/probe.sh"
  chmod +x "$I/probe.sh"
  export I IHOME IWORK IPROFILES
}

# Like run_engine, every launch here pins a preset. The engine's default puts the
# declared channels at `cow`, so without this every integration suite -- conda,
# memory, isolation, ssh -- would silently be testing the sandbox with overlays
# layered over its state, which is not what any of them is about. A suite that
# wants the real default sets TEST_PRESET to the empty string.

# run_sandboxed [VAR=value ...] -- engine args (after --profile probe)
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
  # Coverage: wrap the engine with kcov as its direct parent, inside env -i (see
  # run_engine in common.bash). Empty on a normal run.
  local -a kc=()
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] && kc=("$AGENT_SANDBOX_KCOV" --include-path="$ENGINE" "$AGENT_SANDBOX_KCOV_DIR/r.$$.$RANDOM")
  run env -i ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
    AGENT_SANDBOX_SESSION_BASE="${SESSION_BASE:-$I/base}" \
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" "${envs[@]}" "${kc[@]}" "$ENGINE" --profile probe "$@"
  popd >/dev/null || return 1
  declare -gA REPORT=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && REPORT["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

# report KEY -> value (fails if missing)
report() { [[ -v "REPORT[$1]" ]] && printf '%s' "${REPORT[$1]}"; }
