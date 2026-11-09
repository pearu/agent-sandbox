#!/usr/bin/env bats
# The profile contract under the REAL bwrap, for every profile with a test adapter
# (profiles/*/test.bash; the contract is at the top of profiles/claude/test.bash): the
# profile's own dot-file, and the shared fake agent (tests/helpers/fake-agent.sh) planted
# the way its installer lays it out, reporting from inside the sandbox. No network, no
# real login: a fake one, of the agent's shape, where a test needs one. One test per
# adapter for each, named after it.

# shellcheck disable=SC2154,SC2016,SC2030,SC2031
# (file-wide: the tests are functions registered with bats_test_function, where `run`
# sets $status and $output out of ShellCheck's sight, and the adapter's test_* names are
# sourced at run time; the single-quoted scripts run in another shell)
load "$BATS_TEST_DIRNAME/../helpers/adapters"

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  I="$(mkdir -p "$BATS_TEST_TMPDIR/i" && cd "$BATS_TEST_TMPDIR/i" && pwd -P)"
  IHOME="$I/home"
  IWORK="$I/work"
  mkdir -p "$IHOME" "$IWORK"
}

teardown() {
  local f spid
  # Only keepers this test started, by the supervisor pid their record names.
  for f in "$IHOME"/.local/state/agent-sandbox/*/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# contract_setup NAME -- the adapter in use and its fake planted in the test's HOME; BASE
# is the agent's base there, as a launch from IWORK resolves it.
contract_setup() {
  use_adapter "$1"
  plant_fake_agent "$IHOME"
  cd "$IWORK" || return 1
  export HOME="$IHOME" # profile_get and profile_facts read the profile under it
  BASE="$(profile_facts "$1" base)"
  [ -n "$BASE" ]
}

# run_agent [ENGINE FLAGS] -- AGENT ARGS: the real engine from IWORK, in a clean
# environment, the planted command first on PATH, no network; TEST_PRESET as everywhere
# (shared unless set). Then $output holds what the fake printed, among the engine's lines.
run_agent() {
  engine_cmd
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  run env -i HOME="$IHOME" PATH="${TEST_LAUNCHER%/*}:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_KEEPER_GRACE=0 AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" "$@"
}

# said KEY VALUE -- the fake printed the line KEY=VALUE
said() {
  grep -qxF -- "$1=$2" <<<"$output" || {
    echo "no line '$1=$2' in:"
    echo "$output"
    false
  }
}

contract_base() {
  contract_setup "$1"
  local env
  env="$(profile_get "$1" profile_base_env)"
  mkdir -p "$BASE"
  printf 'CONTRACT-BASE\n' >"$BASE/contract-marker"
  local script
  printf -v script 'printf "marker=%%s\\n" "$(cat %q/contract-marker 2>/dev/null)"
printf "env=%%s\\n" "${%s-unset}"
printf "inside\\n" >%q/contract-written 2>/dev/null && echo wrote=yes' \
    "$BASE" "${env:-NO_BASE_ENV}" "$BASE"
  run_agent "$TEST_CMD" sh "$script"
  [ "$status" -eq 0 ]
  said marker CONTRACT-BASE # the host's base, at its own path inside
  said wrote yes            # read-write
  [ "$(cat "$BASE/contract-written")" = inside ]
  if [[ -n "$env" ]]; then
    said env "$BASE" # the agent's own variable names it
  fi
}

contract_hide() {
  contract_setup "$1"
  local -a hide=()
  mapfile -t hide < <(profile_get "$1" profile_hide)
  ((${#hide[@]})) || skip "the $1 profile hides nothing"
  local h script="" i=0
  for h in "${hide[@]}"; do
    mkdir -p "$BASE/$h"
    printf 'CANARY\n' >"$BASE/$h/canary"
    printf -v script '%sif [ -d %q ] && [ -z "$(ls -A %q)" ]; then echo hide%d=blank; else echo hide%d=seen; fi\n' \
      "$script" "$BASE/$h" "$BASE/$h" "$i" "$i"
    i=$((i + 1))
  done
  run_agent "$TEST_CMD" sh "$script"
  [ "$status" -eq 0 ]
  for ((i = 0; i < ${#hide[@]}; i++)); do
    said "hide$i" blank
    [ "$(cat "$BASE/${hide[i]}/canary")" = CANARY ] # left alone on the host
  done
}

contract_account() {
  contract_setup "$1"
  local -a paths=()
  IFS=$'\t' read -r -a paths <<<"$(profile_facts "$1" account-paths)"
  ((${#paths[@]})) || skip "the $1 profile has no accounts"
  test_login "$BASE" BASELOGINMARK
  # an account with no login yet: its directory exists, as a launch on it needs (#355)
  mkdir -p "$IHOME/.local/state/agent-sandbox/$1/accounts/contract"
  local p script="" i=0
  for p in "${paths[@]}"; do
    printf -v script '%sif [ -e %q ]; then echo path%d=present; else echo path%d=absent; fi\n' \
      "$script" "$BASE/$p" "$i" "$i"
    i=$((i + 1))
  done
  script+='if grep -rqs BASELOGIN""MARK "$HOME"; then echo login=seen; else echo login=nowhere; fi'
  # without an account, the base's login is the sandbox's: the probe sees it
  run_agent "$TEST_CMD" sh "$script"
  [ "$status" -eq 0 ]
  said path0 present
  said login seen
  # on the account, none of the account's files is there, and the base's login is nowhere
  run_agent --account contract "$TEST_CMD" sh "$script"
  [ "$status" -eq 0 ]
  for ((i = 0; i < ${#paths[@]}; i++)); do said "path$i" absent; done
  said login nowhere
}

contract_channels() {
  contract_setup "$1"
  local line name entry dir script="" i=0
  local -a f=() names=() dirs=()
  while IFS= read -r line; do
    IFS=$'\t' read -r -a f <<<"$line"
    name="${f[0]}" dir=""
    for entry in "${f[@]:1}"; do
      [[ "$entry" == dir:* ]] && dir="${entry#dir:}" && break
    done
    [[ -n "$dir" ]] || continue
    names+=("$name") dirs+=("$dir")
    printf -v script '%smkdir -p %q && printf "%%s\\n" %q >%q/contract-%s && echo ch%d=wrote\n' \
      "$script" "$dir" "$name" "$dir" "$name" "$i"
    i=$((i + 1))
  done < <(profile_facts "$1" channel)
  ((${#names[@]})) || skip "the $1 profile has no directory channel"
  TEST_PRESET=isolated run_agent --role contract "$TEST_CMD" sh "$script"
  [ "$status" -eq 0 ]
  local store="$IHOME/.local/state/agent-sandbox/$1"
  for ((i = 0; i < ${#names[@]}; i++)); do
    said "ch$i" wrote
    # never the native path, and in the role's store
    [ ! -e "${dirs[i]}/contract-${names[i]}" ] || {
      echo "channel ${names[i]}: the write reached the native ${dirs[i]}"
      false
    }
    [ -n "$(find "$store" -path "*/contract/*" -name "contract-${names[i]}" 2>/dev/null)" ] || {
      echo "channel ${names[i]}: the write is not in the role's store under $store"
      false
    }
  done
}

contract_resume() {
  contract_setup "$1"
  local -a words=()
  IFS=$'\t' read -r -a words <<<"$(profile_facts "$1" resume)"
  ((${#words[@]})) || skip "the $1 profile has no [agent] resume"
  run_agent --role contract --resume "$TEST_CMD" args one two
  [ "$status" -eq 0 ]
  # what the agent received, in order: its own arguments, then the resume words
  local want
  want="$(printf 'arg=%s\n' one two "${words[@]}")"
  [ "$(grep '^arg=' <<<"$output")" = "$want" ] || {
    echo "the agent received:"
    grep '^arg=' <<<"$output"
    false
  }
}

for a in $(test_adapters); do
  bats_test_function --description "$a: the base is bound at its own path, read-write, and its variable names it inside" -- contract_base "$a"
  bats_test_function --description "$a: the hide paths are blank inside, and left alone on the host" -- contract_hide "$a"
  bats_test_function --description "$a: on an account with no login, none of the account paths is inside, and the base login is nowhere" -- contract_account "$a"
  bats_test_function --description "$a: under isolated, a write to each directory channel lands in the role store, never the native path" -- contract_channels "$a"
  bats_test_function --description "$a: --resume hands the agent its own arguments, then the resume words" -- contract_resume "$a"
done
