#!/usr/bin/env bats
# The profile contract, for every profile with a test adapter (profiles/*/test.bash; the
# contract is at the top of profiles/claude/test.bash): what each profile states is read
# the engine's way and behaves the same. One test per adapter for each, named after it.
# The stub bwrap of tests/helpers/common.bash; the agent is the shared fake
# (tests/helpers/fake-agent.sh), planted the way its installer lays it out.

# The tests are functions registered with bats_test_function, which ShellCheck does not
# see as tests: SC2314 cannot flag a bare `! cmd` in them, so scripts/check.sh's grep for
# one is the guard (assert a failure with `run !`), and what `run` sets and the adapter
# defines is declared below for it.
load "$BATS_TEST_DIRNAME/../helpers/adapters"
declare status output test_base_layout

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
}

# contract_setup NAME -- the adapter in use, its fake planted in the harness's HOME, and
# its command found first on the launch's PATH (LPATH): the stub agent make_harness puts
# at $H/bin/claude is not what these launches run.
contract_setup() {
  use_adapter "$1"
  plant_fake_agent "$H/home"
  LPATH="${TEST_LAUNCHER%/*}:$H/bin:/usr/bin:/bin"
  cd "$H/proj" || return 1
  export HOME="$H/home" # profile_get and profile_facts read the profile under it
}

contract_plant() {
  contract_setup "$1"
  [ "${TEST_LAUNCHER##*/}" = "$TEST_CMD" ] # the command a user types is the profile's
  [[ "$TEST_BIN" == "$H/home/"* ]]         # planted in HOME, by the adapter
  [ -x "$TEST_BIN" ]
  run_engine PATH="$LPATH" -- asb "$TEST_CMD" args one
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$TEST_BIN" "$TEST_BIN" # what the command resolves to is bound
  [ "${JOINV[0]}" = "$TEST_BIN" ]            # and is what runs
}

contract_facts() {
  contract_setup "$1"
  local base
  base="$(profile_facts "$1" base)"
  [ -n "$base" ]
  [[ "$base" == "$H/home/"* ]] # under HOME, as a launch resolves it
  [ "$(profile_get "$1" profile_base)" = "$base" ]
  # every line is this profile's, and of a kind the facts know
  # shellcheck disable=SC2016 # for the inner bash
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c 'source "$1"; _as_profile_facts "$2"' _ \
    "$ENGINE" "$REPO_ROOT/profiles/$1/profile.sh" >"$H/facts"
  [ -s "$H/facts" ]
  [ -z "$(awk -F'\t' -v n="$1" '$2 != n' "$H/facts")" ]
  run ! grep -vE '^(channel|key|resume|clear|base|account-paths|login|account-expiry|login-renew|env-set|command|by-name-only|loaded)'$'\t' "$H/facts"
}

contract_keys() {
  contract_setup "$1"
  # a launch reads the dot-file and says nothing about it: every [agent] key is one the
  # engine reads, every value parses
  run_engine PATH="$LPATH" -- asb "$TEST_CMD" args one
  [ "$status" -eq 0 ]
  [[ "$output" != *"profile '$1': "* ]]
  # and the engine's reader, called alone, reads it without a message
  local msgs
  # shellcheck disable=SC2016 # for the inner bash
  msgs="$(env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '
    source "$1"; _as_msg() { printf "%s\n" "$*"; }
    profile=$2 profile_home=$3
    source "$3/profile.sh" >/dev/null 2>&1
    _as_profile_dotfile "$3/agent-sandbox"' _ "$ENGINE" "$1" "$REPO_ROOT/profiles/$1" 2>&1)"
  [ -z "$msgs" ] || {
    echo "$msgs"
    false
  }
}

contract_check() {
  contract_setup "$1"
  local base e kind name
  base="$(profile_facts "$1" base)"
  mkdir -p "$base"
  for e in "${test_base_layout[@]}"; do
    kind="${e%% *}" name="${e#* }"
    case "$kind" in
      d) mkdir -p "$base/$name" ;;
      f) : >"$base/$name" ;;
      *) false ;;
    esac
  done
  run_engine PATH="$LPATH" -- asb --check "$TEST_CMD"
  [ "$status" -eq 0 ]
  # nothing unclassified: every entry is a channel's, hidden, an account's, or visible
  # on purpose (the profile's [agent] visible, with its reason)
  [[ "$output" != *"Unclassified in"* ]] || {
    sed -n '/^Unclassified in/,/^$/p' <<<"$output"
    false
  }
}

contract_resume() {
  contract_setup "$1"
  local -a words=()
  IFS=$'\t' read -r -a words <<<"$(profile_facts "$1" resume)"
  ((${#words[@]})) || skip "the $1 profile has no [agent] resume"
  run_engine PATH="$LPATH" -- asb --resume "$TEST_CMD" args one two
  [ "$status" -eq 0 ]
  # the agent's own arguments, then the resume words, last on the line
  local n=$((${#words[@]} + 3))
  [ "${JOINV[*]: -$n}" = "args one two ${words[*]}" ]
}

contract_declared() {
  contract_setup "$1"
  # what the dot-file's [agent] section declares, read as text, has its facts line
  local key
  # shellcheck disable=SC2016 # for the inner bash
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c 'source "$1"; _as_profile_facts "$2"' _ \
    "$ENGINE" "$REPO_ROOT/profiles/$1/profile.sh" >"$H/facts"
  for key in resume clear login account-paths account-expiry login-renew; do
    awk -v k="$key" '/^\[/ { s = ($0 == "[agent]") } s && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { f = 1 } END { exit !f }' \
      "$REPO_ROOT/profiles/$1/agent-sandbox" || continue
    awk -F'\t' -v k="$key" -v n="$1" '$1 == k && $2 == n { f = 1 } END { exit !f }' "$H/facts" || {
      echo "[agent] $key is declared, and _as_profile_facts emits no $key line"
      false
    }
  done
}

contract_login() {
  contract_setup "$1"
  local -a paths=() expiry=()
  IFS=$'\t' read -r -a paths <<<"$(profile_facts "$1" account-paths)"
  ((${#paths[@]})) || skip "the $1 profile has no accounts"
  test_login "$H/acct" CONTRACTMARK
  # the login is the file account-paths names first, with the mark in it
  [ -f "$H/acct/${paths[0]}" ]
  grep -q CONTRACTMARK "$H/acct/${paths[0]}"
  # and it has the shape the profile reads its expiry from: a number of epoch ms, far off
  IFS=$'\t' read -r -a expiry <<<"$(profile_facts "$1" account-expiry)"
  ((${#expiry[@]})) || return 0
  python3 - "$H/acct/${expiry[0]}" "${expiry[1]}" <<'PY'
import json, sys, time
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v[k]
assert isinstance(v, (int, float)) and v > (time.time() + 365 * 86400) * 1000, v
PY
}

for a in $(test_adapters); do
  bats_test_function --description "$a: the adapter plants the agent as the profile's command, and a launch binds and runs that binary" -- contract_plant "$a"
  bats_test_function --description "$a: _as_profile_facts emits the profile's facts, its base among them" -- contract_facts "$a"
  bats_test_function --description "$a: every [agent] key of the profile's dot-file is one the engine reads" -- contract_keys "$a"
  bats_test_function --description "$a: --check on the agent's base layout lists nothing unclassified" -- contract_check "$a"
  bats_test_function --description "$a: --resume puts the profile's resume words after the agent's own arguments" -- contract_resume "$a"
  bats_test_function --description "$a: the resume, clear, login and account facts are emitted where the dot-file declares them" -- contract_declared "$a"
  bats_test_function --description "$a: the adapter's fake login is the profile's login file, with the expiry where the profile reads it" -- contract_login "$a"
done
