# shellcheck shell=bash
# The profiles' test adapters (profiles/<name>/test.bash; the contract is at the top of
# profiles/claude/test.bash), for the shared tests: tests/<layer>/profile-contract.bats,
# tests/live/agent.bats and the agent block of tests/e2e/install.bats. Load it at the top
# level of a suite -- the tests are registered there, one per adapter
# (bats_test_function), so the names are needed before any setup runs:
#
#   load "$BATS_TEST_DIRNAME/../helpers/adapters"
#   for a in $(test_adapters); do
#     bats_test_function --description "$a: what it pins" -- my_test "$a"
#   done
#   my_test() { use_adapter "$1"; ... }
#
# Adapters define the same names, so one test uses one: use_adapter sources it in the
# test's own process.

_ADAPTERS_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${REPO_ROOT:=$_ADAPTERS_REPO}"
# AGENT_SANDBOX_TEST_ENGINE lets a mutated copy of the engine be tested (common.bash).
: "${ENGINE:=${AGENT_SANDBOX_TEST_ENGINE:-$REPO_ROOT/agent-sandbox}}"

# test_adapters -- the profiles that have a test adapter, one name per line, sorted.
test_adapters() {
  local f
  for f in "$_ADAPTERS_REPO"/profiles/*/test.bash; do
    [[ -r "$f" ]] || continue
    f="${f%/test.bash}"
    printf '%s\n' "${f##*/}"
  done
}

# use_adapter NAME -- source NAME's adapter; set TEST_AGENT (the profile's name) and
# TEST_CMD (the command a user types after asb: the profile's profile_command).
use_adapter() {
  TEST_AGENT="$1"
  # shellcheck disable=SC1090 # the adapter named
  source "$REPO_ROOT/profiles/$1/test.bash"
  TEST_CMD="$(profile_get "$1" profile_command)"
  export TEST_AGENT TEST_CMD
}

# profile_get NAME VAR... -- each VAR, one element per line, as a launch of profile NAME
# sets it from its profile.sh and its dot-file: the engine's own reading
# (_as_profile_dotfile), with a clean environment but HOME and the working directory
# (the base expands under HOME, {slug} from the directory). For what _as_profile_facts
# does not emit: the command, the base's variable, the hide list, the daemon's argv.
profile_get() {
  local name="$1"
  shift
  # shellcheck disable=SC2016 # for the inner bash
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '
    engine=$1 dir=$2 name=$3
    shift 3
    source "$engine"
    _as_msg() { :; }
    profile=$name profile_command=$name profile_home=$dir
    source "$dir/profile.sh" >/dev/null 2>&1 || exit 1
    _as_profile_dotfile "$dir/agent-sandbox" >/dev/null 2>&1 || exit 1
    for v; do
      declare -n r=$v
      if ((${#r[@]})); then printf "%s\n" "${r[@]}"; fi
      unset -n r
    done
  ' _ "$ENGINE" "$REPO_ROOT/profiles/$name" "$name" "$@"
}

# profile_facts NAME KIND -- the fields after the profile's name of each
# `KIND<TAB>NAME<TAB>...` line _as_profile_facts emits for NAME, tab-separated, one line
# each (HOME and the working directory as for profile_get).
profile_facts() {
  # shellcheck disable=SC2016 # for the inner bash
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c 'source "$1"; _as_profile_facts "$2"' _ \
    "$ENGINE" "$REPO_ROOT/profiles/$1/profile.sh" | awk -F'\t' -v k="$2" -v n="$1" '
      $1 == k && $2 == n { s = ""; for (i = 3; i <= NF; i++) s = s (i > 3 ? "\t" : "") $i; print s }'
}

# fake_agent_file OUT -- write the shared fake agent (tests/helpers/fake-agent.sh) for
# the adapter in use to OUT, executable: its header carries the profile's daemon argv and
# status verb (from the dot-file) and the adapter's test_root_options.
fake_agent_file() {
  local out="$1"
  local -a daemon=() status=()
  mapfile -t daemon < <(profile_get "$TEST_AGENT" profile_daemon_argv)
  mapfile -t status < <(profile_get "$TEST_AGENT" profile_status_argv)
  {
    printf '#!/usr/bin/env bash\n'
    printf '# The shared fake agent (tests/helpers/fake-agent.sh), planted for the %s profile.\n' "$TEST_AGENT"
    printf 'FAKE_AGENT=%q\n' "$TEST_AGENT"
    printf 'FAKE_ROOT_OPTIONS=('
    # shellcheck disable=SC2154 # the adapter's
    printf ' %q' ${test_root_options[@]+"${test_root_options[@]}"}
    printf ' )\n'
    if ((${#daemon[@]})); then
      printf 'FAKE_DAEMON=('
      printf ' %q' "${daemon[@]}"
      printf ' )\n'
    fi
    ((${#status[@]} == 0)) || printf 'FAKE_STATUS=%q\n' "${status[0]}"
    tail -n +2 "$REPO_ROOT/tests/helpers/fake-agent.sh"
  } >"$out"
  chmod +x "$out"
}

# plant_fake_agent HOME -- the shared fake, planted under HOME by the adapter in use the
# way its agent's installer lays it out; sets TEST_LAUNCHER (the command on a user's
# PATH) and TEST_BIN (the binary it resolves to).
plant_fake_agent() {
  mkdir -p "$1"
  fake_agent_file "$1/.fake-agent.$TEST_AGENT"
  TEST_LAUNCHER="$(test_plant "$1" "$1/.fake-agent.$TEST_AGENT")"
  rm -f "$1/.fake-agent.$TEST_AGENT"
  TEST_BIN="$(realpath -- "$TEST_LAUNCHER")"
  export TEST_LAUNCHER TEST_BIN
}
