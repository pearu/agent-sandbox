#!/usr/bin/env bats
# Accounts (#355, P6): `[agent] account = NAME`, `[agent:<glob>] account = NAME` and
# `--account [ROLE=]NAME` name a directory under the agent's state,
# <state>/<profile>/accounts/NAME/, which is bound at the base's inside path in place of
# the base: {base}, CLAUDE_CONFIG_DIR and every channel's store slot stay what they are,
# the channels layer on top, and nothing else of the base is in the sandbox -- the base's
# login above all, which is the security assertion here. `-` names the base. The
# fixtures are fake files in a fake HOME, never a real login.
# shellcheck disable=SC2088 # a `~` in a [connect] line is the engine's to expand

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  C="$H/home/.claude"
  ST="$H/home/.local/state/agent-sandbox"
  ACC="$ST/claude/accounts"
  SLUG="${PROJ//[^A-Za-z0-9-]/-}"
  SBOX="$ST/claude/$SLUG/default"
  mkdir -p "$C/ide" "$C/skills" "$ACC/work" "$ACC/personal"
  printf 'BASE-LOGIN\n' >"$C/.credentials.json"
  printf 'echo hook\n' >"$C/response-hook.py"
  printf 'WORK-LOGIN\n' >"$ACC/work/.credentials.json"
  printf 'PERSONAL-LOGIN\n' >"$ACC/personal/.credentials.json"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

# dotfile LINE... -- the project's .agent-sandbox is these lines, approved.
dotfile() {
  printf '%s\n' "$@" >"$PROJ/.agent-sandbox"
  engine_cmd
  (cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  cmp -s "$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1).approved" "$PROJ/.agent-sandbox"
}

# connect_refused WORDS... -- a launch with these engine words is refused before anything
# is built, with the exit status of every other [connect] refusal (1).
connect_refused() {
  run_engine -- asb "$@" claude --version
  [ "$status" -eq 1 ]
  [ ! -s "$H/argv" ]
}

# base_is_only_channels SBOX -- THE SECURITY ASSERTION: of the base, the argv names only
# its inside path as the account's destination and the channels' paths, each a path the
# role's record lists (the record is what the channels bound); the base's login, and
# every other entry of it, appear nowhere.
base_is_only_channels() {
  local sb="$1" i a
  local -a known=()
  mapfile -t known < <(
    cut -f3 "$sb/record.tsv"
    cut -f4 "$sb/record.tsv"
  )
  run ! grep -qF "$C/.credentials.json" "$H/argv"
  run ! grep -qF "$C/response-hook.py" "$H/argv"
  run ! grep -qxF "$C/ide" "$H/argv"
  for ((i = 0; i < ${#ARGV[@]}; i++)); do
    a="${ARGV[i]}"
    if [[ "$a" == "$C" ]]; then
      # the account's destination, and CLAUDE_CONFIG_DIR's value: never a source
      [[ "${ARGV[i - 2]}" == --bind && "${ARGV[i - 1]}" == "$ACC"/* ]] \
        || [[ "${ARGV[i - 2]}" == --setenv && "${ARGV[i - 1]}" == CLAUDE_CONFIG_DIR ]] || {
        echo "argv names the base $a after ${ARGV[i - 2]} ${ARGV[i - 1]}"
        return 1
      }
      continue
    fi
    [[ "$a" == "$C"/* ]] || continue
    case "${ARGV[i - 1]}" in
      --tmpfs) continue ;; # the hide list
    esac
    [[ " ${known[*]} " == *" $a "* ]] || {
      echo "argv names $a (after ${ARGV[i - 1]}), which is no channel path of the role"
      return 1
    }
  done
}

@test "an account: its directory is bound at the base's inside path in place of the base; CLAUDE_CONFIG_DIR, the channels and the hide tmpfs as before; nothing else of the base, its login least of all" {
  dotfile '[agent]' 'account = work'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run ! argv_has --bind "$C" "$C"
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$C" ]
  argv_has --tmpfs "$C/daemon"
  # a read-write channel at its own source is bound back, over the account's directory
  argv_has --bind "$C/skills" "$C/skills"
  [ "$(argv_index "$ACC/work")" -lt "$(argv_index "$C/skills")" ]
  base_is_only_channels "$SBOX"
  # the base and its login are untouched; the record says the account
  [ "$(cat "$C/.credentials.json")" = BASE-LOGIN ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
  # the same under isolated, where the channels are the role's own stores
  TEST_PRESET=isolated run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run ! argv_has --bind "$C" "$C"
  base_is_only_channels "$SBOX"
}

@test "no account: the base is bound at itself, as before, and the record says the base" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! grep -qF "$ACC" "$H/argv"
  run ! argv_has --bind "$C/skills" "$C/skills" # the base covers it
  [ "$(cat "$SBOX/account")" = "claude"$'\t' ]
}

@test "--account: bare, ROLE=, a quoted glob and the = form name the account; the line beats [agent:r], which beats [agent]; '-' is the base, over a file's account" {
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run_engine -- asb --role r --account r=work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run_engine -- asb --role r1 --account 'r*=personal' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/personal" "$C"
  run_engine -- asb --role r --account=r=work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  # an exact role beats a glob, which beats a bare one
  run_engine -- asb --role r --account personal --account 'r*=personal' --account r=work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  # precedence across the line and the file
  dotfile '[agent]' 'account = personal' '[agent:r]' 'account = work' '[agent:q]' 'command = claude'
  run_engine -- asb --role q claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/personal" "$C"
  run_engine -- asb --role r claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run_engine -- asb --role r --account personal claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/personal" "$C"
  # '-': the base, on the line over the file
  run_engine -- asb --role r --account - claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! grep -qF "$ACC" "$H/argv"
  run_engine -- asb --role r --account r=- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  # and in the file: [agent:q] account = - over [agent] account = personal
  dotfile '[agent]' 'account = personal' '[agent:q]' 'account = -'
  run_engine -- asb --role q claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! grep -qF "$ACC" "$H/argv"
}

@test "--account: a bad NAME, a role matching no launched role, two that disagree, and the verbs it cannot go with are refused, before anything is built" {
  run_engine -- asb --account 'a/b' claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account 'a/b': 'a/b' is not an account name"* ]]
  run_engine -- asb --account .hidden claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not an account name"* ]]
  run_engine -- asb --account 'r/x=work' claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"'r/x' is not a role or a glob of roles"* ]]
  run_engine -- asb --account
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account needs an account"* ]]
  run_engine -- asb --role r --account q=work claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account q=work: 'q' matches no role of this launch (its role is 'r')"* ]]
  run_engine -- asb --role r --account r=work --account r=personal claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account: role 'r' is given two accounts, 'work' (--account r=work) and 'personal' (--account r=personal); name it once"* ]]
  run_engine -- asb --account work --account personal claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account: two accounts for every role"* ]]
  run_engine -- asb --account work --list
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account names a role's account for a launch, a role verb or --check; it is not combined with --list"* ]]
  [ ! -s "$H/argv" ]
}

@test "an account's directory missing, a symlink, or a file refuses the launch, naming what to do; nothing is built" {
  rm -r "$ACC/work"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (--account): there is no $ACC/work for the agent claude: log it in with asb --account-login work claude"* ]]
  [ ! -s "$H/argv" ]
  dotfile '[agent]' 'account = work'
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (.agent-sandbox [agent] account): there is no $ACC/work"*"asb --account-login work claude"* ]]
  # a symlink, even to a directory that is a fine account
  ln -s "$ACC/personal" "$ACC/work"
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"$ACC/work is a symlink"* ]]
  [ ! -s "$H/argv" ]
  rm "$ACC/work"
  : >"$ACC/work"
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"$ACC/work is not a directory"* ]]
  rm "$ACC/work"
  # an `accounts` that is a symlink: resolves elsewhere
  mkdir -p "$H/elsewhere/work"
  mv "$ACC" "$ACC.real"
  ln -s "$H/elsewhere" "$ACC"
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"resolves to $H/elsewhere/work, not where it is named; refusing to bind it"* ]]
  [ ! -s "$H/argv" ]
}

@test "an account under --preset native or --preset none is refused; --account - runs it on the base (D11)" {
  run_engine -- asb --preset native --account work claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (--account): preset native binds the agent's own base"* ]]
  [ ! -s "$H/argv" ]
  dotfile '[agent]' 'account = work'
  run_engine -- asb --preset native claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (.agent-sandbox [agent] account): preset native"* ]]
  run_engine -- asb --preset native --account - claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ]
  # none: no sandbox to bind it in, from the line or the file
  run_engine -- asb --preset none --account work claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (--account): --preset none runs the agent with no sandbox"* ]]
  run_engine -- asb --preset none claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"(.agent-sandbox [agent] account): --preset none"* ]]
  run_engine -- asb --preset none --account - claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-agent argv: --version"* ]]
}

@test "a profile that declares no [agent] account-paths has no accounts: naming one is refused" {
  mkdir -p "$H/profiles2"
  cp -r "$REPO_ROOT/profiles/claude" "$H/profiles2/claude"
  sed -i '/^account-paths = /d' "$H/profiles2/claude/agent-sandbox"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --account work claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (--account): profile 'claude' says nothing of which of its agent's files are an account's ([agent] account-paths), so it has no accounts; run it on its base: --account -"* ]]
  [ ! -s "$H/argv" ]
}

@test "the account resolves under the role's agent: a codex role's 'work' is accounts/codex/work" {
  mkdir -p "$H/profiles2/codex"
  ln -sfn "$REPO_ROOT/profiles/claude" "$H/profiles2/claude"
  printf 'profile_command=codex\n' >"$H/profiles2/codex/profile.sh"
  printf '[agent]\nbase = ~/.codex\naccount-paths = auth.json\n' >"$H/profiles2/codex/agent-sandbox"
  printf '#!/bin/sh\n' >"$H/bin/codex"
  chmod +x "$H/bin/codex"
  dotfile '[agent]' 'account = work' '[agent:c]' 'command = codex' '[agent:k]' 'command = claude'
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --role c
  [ "$status" -eq 2 ]
  [[ "$output" == *"there is no $ST/codex/accounts/work for the agent codex: log it in with asb --account-login work codex"* ]]
  mkdir -p "$ST/codex/accounts/work"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --role c
  [ "$status" -eq 0 ]
  argv_has --bind "$ST/codex/accounts/work" "$H/home/.codex"
  run ! grep -qF "$ACC" "$H/argv"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --role k
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
}

@test "--exec counts: its sandbox is the role's, on the account" {
  run_engine -- asb --profile claude --account work --exec true
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  run ! argv_has --bind "$C" "$C"
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
}

# A stub bwrap that makes, as the real one does, an empty mount point in the directory
# bound at the base for each file bound under it that is not there.
mountpoint_bwrap() {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
if [[ "${1:-}" == --help ]]; then printf '    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST\n'; exit 0; fi
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
root="" base="$HOME/.claude"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == --bind && "${args[i + 2]:-}" == "$base" ]] && root="${args[i + 1]}"
done
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --bind | --ro-bind)
      src="${args[i + 1]}" dst="${args[i + 2]}"
      if [[ -n "$root" && -f "$src" && "$dst" == "$base"/* && ! -e "$root/${dst#"$base"/}" ]]; then
        : >"$root/${dst#"$base"/}"
      fi
      ;;
  esac
done
# a native session elsewhere makes an empty file in the real base while this one runs
[[ -z "${MAKE_IN_BASE:-}" ]] || : >"$base/$MAKE_IN_BASE"
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
}

@test "mount points: those made in the account's directory are removed after the launch; an empty file of the same name in the real base is the user's and stays" {
  mountpoint_bwrap
  : >"$C/CLAUDE.md" # the user's own, empty
  run_engine -- asb --account work --connect 'instructions=own' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  argv_has "$C/CLAUDE.md"        # the own store bound there
  [ ! -e "$ACC/work/CLAUDE.md" ] # the mount point, gone
  [ -e "$C/CLAUDE.md" ]          # the user's, kept
  # a file the base did not have at launch, made empty there by something else while
  # the role ran: not the cleanup's
  rm "$C/CLAUDE.md"
  run_engine MAKE_IN_BASE=CLAUDE.md -- asb --account work --connect 'instructions=own' claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$ACC/work/CLAUDE.md" ]
  [ -e "$C/CLAUDE.md" ]
  # the config file's mount point too (the profile's own channel)
  TEST_PRESET=isolated run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$ACC/work/.claude.json" ]
}

@test "a join asking for another account than the running role's is refused; the same one joins" {
  engine_bg -- asb --account work claude --version
  grep -qx $'account\tclaude/work\t--account' "$SBOX/keeper/policy"
  run_engine -- asb --account personal claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'default' is running with account = claude/work, and --account asks for 'claude/personal'. A running role's policy cannot change"* ]]
  [ ! -s "$H/join" ]
  run_engine -- asb --account - claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"running with account = claude/work, and --account asks for '-'"* ]]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/join" ]
  release_bg
  [ "$BG_STATUS" -eq 0 ]
}

@test "the account record: a launch writes PROFILE<TAB>NAME, empty for the base; an engine turn (AGENT_SANDBOX_SERVE_TURN) leaves it" {
  run_engine -- asb --account work claude --version
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
  run_engine AGENT_SANDBOX_SERVE_TURN=1 -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
  run_engine -- asb claude --version
  [ "$(cat "$SBOX/account")" = "claude"$'\t' ]
}

@test "the review says each [agent] account line; a bad name is said and ignored; --check shows the account and its directory" {
  printf '[agent]\naccount = work\n[agent:r]\naccount = -\n[agent:q]\naccount = a/b\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [agent] account = work: every role run on the account 'work'"*"log it in with asb --account-login work AGENT"* ]]
  [[ "$output" == *".agent-sandbox: [agent:r] account = -: the roles r run on the agent's base, your own login"* ]]
  [[ "$output" == *"[agent] account = a/b: not an account name"*"ignoring"* ]]
  dotfile '[agent]' 'account = work' '[agent:r]' 'account = -' '[agent:q]' 'command = claude'
  run_engine -- asb --check --role q claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"  account: work -- .agent-sandbox [agent] account; its directory ~/.local/state/agent-sandbox/claude/accounts/work is the state directory"* ]]
  [[ "$output" == *"account work: ~/.local/state/agent-sandbox/claude/accounts/work (its state directory)"* ]]
  run_engine -- asb --check --role r claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"  account: the base (-, .agent-sandbox [agent:r] account)"* ]]
  [[ "$output" == *"the agent's base"* ]]
}

@test "--check counts the profile's account-paths as classified: the base's login is not unclassified" {
  : >"$C/.oauth_refresh.lock"
  run_engine -- asb --check claude
  [ "$status" -eq 0 ]
  local un
  un="$(sed -n '/^Unclassified in/,/^$/p' <<<"$output")"
  [[ "$un" != *".credentials.json"* && "$un" != *".oauth_refresh.lock"* ]]
  [[ "$un" == *"response-hook.py"* ]] # an unclassified entry is still listed
}

@test "a [connect] path can never be the base, a parent of it, or its login, in a key or an outside: source, with an account or without; refused before anything is built" {
  local -a acct
  local a
  for a in none work; do
    acct=()
    [[ "$a" == none ]] || acct=(--account "$a")
    dotfile '[connect]' '~/.claude/ = read-write'
    connect_refused ${acct[@]+"${acct[@]}"}
    [[ "$output" == *"refusing '~/.claude/': '$C' is the agent's state directory '$C': what a role sees of it is the profile's channels and hide list, and its login is the account's (--account); not a [connect] path."* ]]
    dotfile '[connect]' '~/.claude/.credentials.json = read-only'
    connect_refused ${acct[@]+"${acct[@]}"}
    [[ "$output" == *"refusing '~/.claude/.credentials.json': '$C/.credentials.json' is the agent's login ('.credentials.json' in its state directory): the account's, never a [connect] path."* ]]
    rm "$PROJ/.agent-sandbox" "$H/home/.config/agent-sandbox/trust/"*
    connect_refused ${acct[@]+"${acct[@]}"} --connect '~/.claude/.credentials.json=read-only'
    [[ "$output" == *"is the agent's login"* ]]
    connect_refused ${acct[@]+"${acct[@]}"} --connect 'config=read-only outside:~/.claude/.credentials.json'
    [[ "$output" == *"refusing 'outside:~/.claude/.credentials.json' for 'config': '$C/.credentials.json' is the agent's login"* ]]
    # a declaration's outside: source at the base; the refresh lock, even as own
    connect_refused ${acct[@]+"${acct[@]}"} --connect "$H/home/.mirror/=read-only outside:~/.claude"
    [[ "$output" == *"refusing 'outside:~/.claude': '$C' is the agent's state directory"* ]]
    connect_refused ${acct[@]+"${acct[@]}"} --connect '~/.claude/.oauth_refresh.lock=own'
    [[ "$output" == *"is the agent's login ('.oauth_refresh.lock' in its state directory)"* ]]
  done
  # resolved too: a symlink elsewhere that points at the base, or a parent of it
  ln -s "$C" "$H/home/base-link"
  connect_refused --connect "$H/home/base-link/=read-only"
  [[ "$output" == *"is the agent's state directory"* ]]
  mkdir -p "$H/outer/inner"
  mv "$C" "$H/outer/inner/claude"
  ln -s "$H/outer/inner/claude" "$C"
  connect_refused --connect "$H/home/.mirror/=read-only outside:$H/outer/inner"
  [[ "$output" == *"contains the agent's state directory"* ]]
  rm "$C"
  mv "$H/outer/inner/claude" "$C"
  # the review says it, where the file is read
  printf '[connect]\n~/.claude/ = read-write\n~/.claude/.credentials.json = read-only\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"connect: '~/.claude/ = read-write': '$C' is the agent's state directory"*"(profile claude); a launch refuses the line."* ]]
  [[ "$output" == *"connect: '~/.claude/.credentials.json = read-only': '$C/.credentials.json' is the agent's login"* ]]
}

@test "a [connect] path under the base that is not its login is a declaration like any other: a share's memory, a sub-path" {
  local other="$H/other-proj" sl
  sl="${other//[^A-Za-z0-9-]/-}"
  mkdir -p "$C/projects/$sl/memory" "$C/rules"
  dotfile '[share-memory]' "$other"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/projects/$sl/memory" "$C/projects/$sl/memory"
  run_engine -- asb --account work --connect '~/.claude/rules/=read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "a join says the running role's account, not the file's, and does not need the file's account directory" {
  dotfile '[agent]' 'account = personal'
  engine_bg -- asb --account work claude --version
  rm -r "$ACC/personal"
  run_engine -- asb claude -p again
  [ "$status" -eq 0 ]
  [ -s "$H/join" ]
  [[ "$output" == *"account: work, the running role's (~/.local/state/agent-sandbox/claude/accounts/work)"* ]]
  [[ "$output" != *"accounts/personal"* ]]
  release_bg
  [ "$BG_STATUS" -eq 0 ]
  # a cold start reads the file, and refuses the missing directory
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"there is no $ACC/personal"* ]]
}

@test "--check with an account whose directory is missing prints the plan, says so, and exits 1" {
  dotfile '[agent]' 'account = gone'
  run_engine -- asb --check claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"there is no $ACC/gone for the agent claude: log it in with asb --account-login gone claude"* ]]
  [[ "$output" == *"  account: gone -- .agent-sandbox [agent] account; its directory ~/.local/state/agent-sandbox/claude/accounts/gone is NOT USABLE (above), so a launch refuses: log it in with asb --account-login gone claude"* ]]
  [[ "$output" == *"account gone: not usable, a launch refuses"* ]]
  [[ "$output" == *"check: a launch refuses this role: its account 'gone' cannot be its state directory (above)"* ]]
  [ ! -s "$H/argv" ]
}
