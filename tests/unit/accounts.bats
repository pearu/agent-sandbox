#!/usr/bin/env bats
# Accounts (#355, P6): `[agent] account = NAME`, `[agent:<glob>] account = NAME` and
# `--account [ROLE=]NAME` name a directory under the agent's state,
# <state>/<profile>/accounts/NAME/, which is bound at the base's inside path in place of
# the base: {base}, CLAUDE_CONFIG_DIR and every channel's store slot stay what they are,
# the channels layer on top, the base's other top-level entries are bound one by one
# (P7), and the base's login is never in the sandbox, which is the security assertion
# here. `-` names the base. The fixtures are fake files in a fake HOME, never a real
# login.
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
  # the base's other entries (P7): a nested channel, a hidden one, the refresh lock, a
  # symlink and a channel at the top
  mkdir -p "$C/cache" "$C/daemon"
  printf 'notes\n' >"$C/cache/changelog.md"
  printf 'LOCK\n' >"$C/.oauth_refresh.lock"
  printf 'OWNER\n' >"$C/.oauth_refresh.lock.owner"
  ln -s somewhere "$C/link"
  printf '{}\n' >"$C/settings.json"
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

# base_is_only_channels SBOX -- THE SECURITY ASSERTION: of the base, the argv names its
# inside path only as the account's destination (and CLAUDE_CONFIG_DIR's value), and
# below it only the channels' paths (each a path the role's record lists: the record is
# what the channels bound), the hide tmpfs, and the base's own top-level entries bound
# one by one at themselves or made again as symlinks (P7) -- never one of the profile's
# account-paths: the base's login, and its refresh lock, appear nowhere.
base_is_only_channels() {
  local sb="$1" i a name
  local -a known=()
  mapfile -t known < <(
    cut -f3 "$sb/record.tsv"
    cut -f4 "$sb/record.tsv"
  )
  for name in .credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner; do
    run ! grep -qF "$C/$name" "$H/argv"
  done
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
    [[ " ${known[*]} " == *" $a "* ]] && continue
    # a top-level entry of the base bound at itself (its source here, its destination
    # next), or the destination of that bind; never a symlink entry (made again on the
    # host, in the account's directory, not named in the argv)
    if [[ "${a#"$C"/}" != */* && ! -L "$a" ]]; then
      [[ "${ARGV[i - 1]}" == --bind && "${ARGV[i + 1]}" == "$a" ]] && continue
      [[ "${ARGV[i - 2]}" == --bind && "${ARGV[i - 1]}" == "$a" ]] && continue
    fi
    echo "argv names $a (after ${ARGV[i - 1]}), which is neither a channel path of the role nor a top-level entry of the base bound at itself"
    return 1
  done
}

@test "an account: its directory is bound at the base's inside path in place of the base; CLAUDE_CONFIG_DIR, the channels and the hide tmpfs as before; the base's other entries one by one; its login nowhere" {
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
  # the base's other entries, one by one (P7)
  argv_has --bind "$C/response-hook.py" "$C/response-hook.py"
  argv_has --bind "$C/ide" "$C/ide"
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
  # a read-write channel at its own path: bound onto itself over the base, so it is a
  # mount point the role cannot rename away (R1)
  argv_has --bind "$C/skills" "$C/skills"
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
  [[ "$output" == *"the account 'work' (--account): there is no $ACC/work for the agent claude: log it in with asb --agent claude --account work --login"* ]]
  [ ! -s "$H/argv" ]
  dotfile '[agent]' 'account = work'
  run_engine -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'work' (.agent-sandbox [agent] account): there is no $ACC/work"*"asb --agent claude --account work --login"* ]]
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
  [[ "$output" == *"there is no $ST/codex/accounts/work for the agent codex: log it in with asb --agent codex --account work --login"* ]]
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
  [[ "$output" == *".agent-sandbox: [agent] account = work: every role run on the account 'work'"*"log it in with asb --agent AGENT --account work --login"* ]]
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

@test "the review says each [agent] accounts line: the accounts a restart marker may move the roles to (#482); a bad word in it, or none, is said and the line ignored; a launch reads none of it" {
  printf '[agent]\naccounts = work -\n[agent:r]\naccounts = home\n[agent:q]\naccounts = ok a/b\n[agent:p]\naccounts =\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [agent] accounts = work -: every role may be moved to 'work', the base by a restart marker of the Supervisor's (account=NAME), at the user's word, besides back to the account they were launched on; until the next asb --roles, which starts from the line and the file again"* ]]
  [[ "$output" == *".agent-sandbox: [agent:r] accounts = home: the roles r may be moved to 'home' by a restart marker"* ]]
  [[ "$output" == *".agent-sandbox: [agent] accounts = ok a/b: 'a/b' not an account name (a letter or digit, then letters, digits, '.', '_' or '-'), nor '-', the base; ignoring the line"* ]]
  [[ "$output" != *"[agent:q] accounts = ok a/b: the roles q may be moved"* ]]
  [[ "$output" == *".agent-sandbox: [agent] accounts names no account (accounts = NAME..., - for the base); ignoring"* ]]
  # a role section's list followed by a glob's that matches it: the later wins, and is said
  printf '[agent:r]\naccounts = home\n[agent:r*]\naccounts = work\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [agent:r] accounts = home: role r takes the later [agent:r*] accounts = work instead (among suffixed sections the later line wins); put [agent:r] after it to keep its own"* ]]
  # a launch: no account of the list is the role's, nor checked
  dotfile '[agent]' 'accounts = work'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t' ]
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
  [[ "$output" == *"there is no $ACC/gone for the agent claude: log it in with asb --agent claude --account gone --login"* ]]
  [[ "$output" == *"  account: gone -- .agent-sandbox [agent] account; its directory ~/.local/state/agent-sandbox/claude/accounts/gone is NOT USABLE (above), so a launch refuses: log it in with asb --agent claude --account gone --login"* ]]
  [[ "$output" == *"account gone: not usable, a launch refuses"* ]]
  [[ "$output" == *"check: a launch refuses this role: its account 'gone' cannot be its state directory (above)"* ]]
  [ ! -s "$H/argv" ]
}

# argv_count TOKEN... -- how many times the tokens appear consecutively in ARGV.
argv_count() {
  local -a want=("$@")
  local n=${#want[@]} i j c=0
  for ((i = 0; i + n <= ${#ARGV[@]}; i++)); do
    for ((j = 0; j < n; j++)); do
      [[ "${ARGV[i + j]}" == "${want[j]}" ]] || break
    done
    ((j == n)) && c=$((c + 1))
  done
  printf '%s' "$c"
}

@test "P7: the base's other top-level entries are bound one by one, read-write at their paths, before the channels; a hidden one is blanked, a channel's is the channel's, a symlink made again unfollowed; the login and its lock nowhere" {
  mkdir -p "$H/home/.ssh"
  ln -s "$H/home/.ssh" "$C/keys" # a symlink entry naming a secret store: made again, never followed
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  argv_has --bind "$C/response-hook.py" "$C/response-hook.py"
  argv_has --bind "$C/ide" "$C/ide"
  argv_has --bind "$C/cache" "$C/cache"
  # each after the account's directory; the channel nested in cache/ layers on top of it
  [ "$(argv_index "$ACC/work")" -lt "$(argv_index "$C/response-hook.py")" ]
  argv_has "$C/cache/changelog.md"
  [ "$(argv_index "$C/cache")" -lt "$(argv_index "$C/cache/changelog.md")" ]
  # hidden: the tmpfs, no bind
  argv_has --tmpfs "$C/daemon"
  run ! argv_has --bind "$C/daemon" "$C/daemon"
  # a channel at the top: bound by its channel only (read-write at its own source here)
  [ "$(argv_count --bind "$C/settings.json" "$C/settings.json")" -eq 1 ]
  # symlinks: made again in the account's directory with their targets as written,
  # never followed, and not in the argv (no --symlink: bwrap < 0.9 dies on an existing
  # one)
  [ "$(readlink "$ACC/work/link")" = somewhere ]
  [ "$(readlink "$ACC/work/keys")" = "$H/home/.ssh" ]
  run ! grep -qxF "$H/home/.ssh" "$H/argv"
  run ! grep -qxF "$C/link" "$H/argv"
  run ! grep -qxF "$C/keys" "$H/argv"
  # (the one --symlink there is the installed agent's `current`, #6)
  [ "$(grep -cxF -- --symlink "$H/argv")" -eq 1 ]
  argv_has --symlink 2.1.300 "${STUB_AGENT_DIR%/*}/current"
  # a second launch finds them there, and keeps them
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(readlink "$ACC/work/link")" = somewhere ]
  # the account paths nowhere: the mutation-checked assertion
  base_is_only_channels "$SBOX"
  # under isolated the channel's own store is at settings.json; the base's is not bound
  TEST_PRESET=isolated run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(argv_count --bind "$C/settings.json" "$C/settings.json")" -eq 0 ]
  argv_has --bind "$C/response-hook.py" "$C/response-hook.py"
  base_is_only_channels "$SBOX"
}

@test "P7: a project's [claude] hide entry is blanked, not bound" {
  mkdir -p "$C/secret-notes"
  dotfile '[agent]' 'account = work' '[claude]' 'hide = secret-notes'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$C/secret-notes"
  run ! argv_has --bind "$C/secret-notes" "$C/secret-notes"
  argv_has --bind "$C/ide" "$C/ide"
}

@test "P7: no account, no per-entry binds: the base is bound at itself and its entries are not named (cache/ only as the pin on the way to its channel)" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! grep -qxF "$C/response-hook.py" "$H/argv"
  run ! grep -qxF "$C/ide" "$H/argv"
  [ "$(grep -cxF "$C/cache" "$H/argv")" -eq 2 ] # --bind C/cache C/cache: the pin, once
  argv_has --bind "$C/cache/changelog.md" "$C/cache/changelog.md"
  run ! grep -qxF "$C/link" "$H/argv"
  run ! argv_has --symlink somewhere "$C/link"
}

@test "P7: mount points the entry binds make in the account's directory: an empty file is removed after the launch; the base's file is untouched" {
  mountpoint_bwrap
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C/response-hook.py" "$C/response-hook.py"
  [ ! -e "$ACC/work/response-hook.py" ]
  [ "$(cat "$C/response-hook.py")" = "echo hook" ]
}

@test "P7 helper: an account named but its directory not resolved refuses rather than bind the base in its place" {
  source_engine
  HOME="$H/home"
  # shellcheck disable=SC2034 # read by _as_base_bind by dynamic scope
  local profile=claude profile_base="$C" _acct_name=work _acct_dir="" rc=0
  # shellcheck disable=SC2034
  local -a args=() profile_channels=() profile_isolate_spec=() _as_placeholder_files=()
  # shellcheck disable=SC2034
  local -a profile_account_paths=(.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner)
  _as_base_bind 2>"$H/err" || rc=$?
  [ "$rc" -eq 1 ]
  [ "${#args[@]}" -eq 0 ]
  grep -qF "the account 'work': its directory was not resolved; refusing to run the role on the base in its place" "$H/err"
  # resolved: the account's directory, then the entries; never the login
  _acct_dir="$ACC/work"
  _as_base_bind
  [ "${args[0]} ${args[1]} ${args[2]}" = "--bind $ACC/work $C" ]
  [[ " ${args[*]} " == *" --bind $C/response-hook.py $C/response-hook.py "* ]]
  [[ " ${args[*]} " != *"$C/.credentials.json"* ]]
  [[ " ${args[*]} " != *"$C/.oauth_refresh.lock"* ]]
  # the base: bound at itself
  args=() _acct_name="" _acct_dir=""
  _as_base_bind
  [ "${args[*]}" = "--bind $C $C" ]
}

@test "P7 helper: a declaration whose source is repointed at the base, or its login, between the parse and the bind is refused at the bind" {
  source_engine
  HOME="$H/home"
  # shellcheck disable=SC2034 # read by _as_connect_bind_path by dynamic scope
  local profile=claude profile_base="$C" _overlay_mode=off cwd="$PROJ" p="$H/data"
  # shellcheck disable=SC2034
  local -a args=() _as_placeholder_files=()
  # shellcheck disable=SC2034
  local -a profile_account_paths=(.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner)
  # shellcheck disable=SC2034
  local -A _connect_key=() _connect_mode=() _connect_src=() _connect_sandbox=() _connect_isdir=() _connect_scope=() _connect_host=()
  mkdir -p "$H/realdata"
  ln -s "$H/realdata" "$p"
  _connect_key[$p]="$p" _connect_mode[$p]=read-only _connect_isdir[$p]=0
  # as parsed: a plain directory, bound
  _as_connect_bind_path "$p"
  [ "${args[*]}" = "--ro-bind $H/realdata $p" ]
  # repointed at the base
  args=()
  ln -sfn "$C" "$p"
  run _as_connect_bind_path "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to bind '$p': it resolves to a protected path ('$C')"* ]]
  # at its login
  ln -sfn "$C/.credentials.json" "$p"
  run _as_connect_bind_path "$p"
  [ "$status" -eq 1 ]
  [[ "$output" == *"('$C/.credentials.json')"* ]]
  # at another path under the base: a declaration like any other
  ln -sfn "$C/ide" "$p"
  _as_connect_bind_path "$p"
  [ "${args[*]}" = "--ro-bind $C/ide $p" ]
}

@test "P7 helper: a mount point under a base entry bound from the base is the base's host path; one at the top is the account's" {
  source_engine
  HOME="$H/home"
  # shellcheck disable=SC2034 # read by the helpers by dynamic scope
  local profile=claude profile_base="$C" _acct_name=work _acct_dir="$ACC/work"
  # shellcheck disable=SC2034
  local -a args=() profile_channels=() profile_isolate_spec=() _as_placeholder_files=() _as_base_entries=()
  # shellcheck disable=SC2034
  local -a profile_account_paths=(.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner)
  local _as_base_real=""
  rm "$C/cache/changelog.md"
  _as_base_bind
  [ "$(_as_host_path_of "$C/cache/changelog.md")" = "$C/cache/changelog.md" ]
  [ "$(_as_host_path_of "$C/CLAUDE.md")" = "$ACC/work/CLAUDE.md" ]
  [ "$(_as_host_path_of "$C")" = "$ACC/work" ]
  # the response hook's own mount point: recorded at the account, removed while empty
  [[ " ${_as_placeholder_files[*]} " == *" $ACC/work/response-hook.py "* ]]
}

@test "P7: a symlink an earlier launch made in the account's directory is replaced when the base's entry changed; one still right is kept" {
  ln -s old-target "$ACC/work/link" # the base's link now points at somewhere
  mkdir -p "$H/x"
  ln -s "$H/x" "$ACC/work/ide" # the base's ide/ is a directory now
  ln -s somewhere "$ACC/work/keep"
  ln -s somewhere "$C/keep"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C/ide" "$C/ide"
  [ "$(readlink "$ACC/work/link")" = somewhere ] # made again with the base's target
  [ ! -L "$ACC/work/ide" ]
  [ -d "$H/x" ] # its target untouched
  [ "$(readlink "$ACC/work/keep")" = somewhere ]
}

@test "P7: a same-name entry of another kind in the account's directory refuses the launch before bwrap runs, naming both paths; the same kind is covered" {
  : >"$ACC/work/ide" # a file where the base has a directory
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"the account 'work': '$ACC/work/ide' is a file where the base's '$C/ide' is a directory, so the base's cannot be put over it; remove '$ACC/work/ide' (the account's) to see the base's there, or '$C/ide' (the base's) to keep the account's. Nothing was started"* ]]
  [ ! -s "$H/argv" ]
  [ ! -L "$ACC/work/link" ] # every entry checked before anything is changed
  rm "$ACC/work/ide"
  mkdir "$ACC/work/response-hook.py" # a directory where the base has a file
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'$ACC/work/response-hook.py' is a directory where the base's '$C/response-hook.py' is a file"* ]]
  [ ! -s "$H/argv" ]
  rmdir "$ACC/work/response-hook.py"
  : >"$ACC/work/link" # a file where the base has a symlink
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'$ACC/work/link' is a file where the base's '$C/link' is a symlink"* ]]
  [ -e "$ACC/work/link" ] # never removed: it is not one a launch made
  rm "$ACC/work/link"
  # the same kind: the base's is bound over it
  printf 'mine\n' >"$ACC/work/response-hook.py"
  mkdir -p "$ACC/work/ide"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C/response-hook.py" "$C/response-hook.py"
  argv_has --bind "$C/ide" "$C/ide"
  [ "$(cat "$ACC/work/response-hook.py")" = mine ]
}

@test "P7: a missing read-write file channel with no start: file is made in the base under an account -- {} for a .json path, empty otherwise -- and bound from there; one with a start: file is not; nothing without an account" {
  [ ! -e "$C/CLAUDE.md" ]
  [ ! -e "$C/policy-limits.json" ]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$C/CLAUDE.md" ]
  [ ! -e "$C/policy-limits.json.signature.json" ]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  # no start: file (instructions): made in the base, bound from there
  [ -f "$C/CLAUDE.md" ]
  [ ! -s "$C/CLAUDE.md" ]
  argv_has --bind "$C/CLAUDE.md" "$C/CLAUDE.md"
  [ ! -e "$ACC/work/CLAUDE.md" ] # the stub makes no mount point
  # a .json path with no start: file: {} (settings.json is in the fixture; a signature)
  [ "$(cat "$C/policy-limits.json.signature.json")" = "{}" ]
  argv_has --bind "$C/policy-limits.json.signature.json" "$C/policy-limits.json.signature.json"
  [ "$(cat "$C/settings.json")" = "{}" ] # the fixture's own, untouched
  # not .json: empty
  [ -f "$C/remote-settings.json.synced-at" ]
  [ ! -s "$C/remote-settings.json.synced-at" ]
  # a start: file (the policy bodies, start:{profile}/policy.json): not made, not bound
  [ ! -e "$C/policy-limits.json" ]
  [ ! -e "$C/remote-settings.json" ]
  run ! grep -qxF "$C/policy-limits.json" "$H/argv"
}

@test "P7 helper: the entry listing ignores a GLOBIGNORE in force" {
  source_engine
  HOME="$H/home"
  # shellcheck disable=SC2034 # read by _as_base_bind by dynamic scope
  local profile=claude profile_base="$C" _acct_name=work _acct_dir="$ACC/work" _as_base_real=""
  # shellcheck disable=SC2034
  local -a args=() profile_channels=() profile_isolate_spec=() _as_placeholder_files=() _as_base_entries=()
  # shellcheck disable=SC2034
  local -a profile_account_paths=(.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner)
  GLOBIGNORE='*:.*:*/*'
  _as_base_bind
  unset GLOBIGNORE
  [[ " ${args[*]} " == *" --bind $C/response-hook.py $C/response-hook.py "* ]]
  [ "$(readlink "$ACC/work/link")" = somewhere ]
}

@test "the review's base/login note is for the profile --profile names when it names one, else for each profile with a base" {
  mkdir -p "$H/profiles2/codex"
  ln -sfn "$REPO_ROOT/profiles/claude" "$H/profiles2/claude"
  printf 'profile_command=codex\n' >"$H/profiles2/codex/profile.sh"
  printf '[agent]\nbase = ~/.claude\naccount-paths = .credentials.json\n' >"$H/profiles2/codex/agent-sandbox"
  printf '[connect]\n~/.claude/.credentials.json = read-only\n' >"$PROJ/.agent-sandbox"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --check
  [[ "$output" == *"(profile claude); a launch refuses the line."* ]]
  [[ "$output" == *"(profile codex); a launch refuses the line."* ]]
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --profile claude --check
  [[ "$output" == *"(profile claude); a launch refuses the line."* ]]
  [[ "$output" != *"(profile codex)"* ]]
}

@test "P7: a read-write source made in the base under an account is made before the entries are listed: its new directory is bound from the base at the first launch, as at every later one" {
  rm -r "$C/cache" # the changelog channel's file and its directory, both missing
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ -f "$C/cache/changelog.md" ]
  [ ! -s "$C/cache/changelog.md" ]
  argv_has --bind "$C/cache" "$C/cache" # an entry already: the same mount points as the next launch
  [ "$(argv_index "$C/cache")" -lt "$(argv_index "$C/cache/changelog.md")" ]
  run ! grep -qxF "$ACC/work/cache/changelog.md" "$H/home/.local/state/agent-sandbox/placeholders"
}

# ---- asb [--agent AGENT] --account NAME --login (P9) ----
# The login runs as the role account-login of a scratch project with no dot-file,
# ~/.cache/agent-sandbox/account-login/, under --preset isolated; the stub join stands
# for the agent, so no login really runs: JOIN_EXIT is its exit status.

# login_paths -- LSCR: the scratch project; LSB: the login role's store under it.
login_paths() {
  LSCR="$H/home/.cache/agent-sandbox/account-login"
  LSB="$ST/claude/${LSCR//[^A-Za-z0-9-]/-}/account-login"
}

# codex_profile [LINE...] -- a second profile, codex, whose dot-file's [agent] is these
# lines, and a codex stub on PATH.
codex_profile() {
  mkdir -p "$H/profiles2/codex"
  ln -sfn "$REPO_ROOT/profiles/claude" "$H/profiles2/claude"
  printf 'profile_command=codex\n' >"$H/profiles2/codex/profile.sh"
  printf '%s\n' '[agent]' 'base = ~/.codex' "$@" >"$H/profiles2/codex/agent-sandbox"
  printf '#!/bin/sh\n' >"$H/bin/codex"
  chmod +x "$H/bin/codex"
}

@test "--login: refused with anything else on the line, a bad NAME, an AGENT naming no profile, a profile with no account-paths or no login key; nothing is made" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  rm -r "$ACC"
  local -a refused=(
    "--verbose --agent claude --account work --login"
    "--agent claude --account work --login --role r"
    "--account work --login --login"
    "--agent claude --agent claude --account work --login"
    "--account work --account work --login"
    "--account work --login --resume"
    "--preset isolated --account work --login"
    "--account work --login --list"
    "--check --account work --login"
    "--account work --role r --login"
    "--login --account work --shutdown"
  )
  local w
  for w in "${refused[@]}"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine -- asb $w
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login takes --agent AGENT and --account NAME, each at most once, and nothing else on the line: asb [--agent AGENT] --account NAME --login" ]
  done
  for w in a/b .hidden; do
    run_engine -- asb --agent claude --account "$w" --login
    [ "$status" -eq 2 ]
    [[ "$output" == *"--account '$w': '$w' is not an account name"* ]]
  done
  run_engine -- asb --agent claude --account -x --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account needs an account"* ]]
  run_engine -- asb --agent nosuch --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: 'nosuch' names no profile. Profiles available in"* ]]
  codex_profile
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --agent codex --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: profile 'codex' says nothing of which of its agent's files are an account's ([agent] account-paths), so it has no accounts to log in"* ]]
  codex_profile 'account-paths = auth.json'
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --agent codex --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: profile 'codex' does not say what starts its agent's login ([agent] login = ARGS, possibly empty)"* ]]
  [ ! -e "$ACC" ]
  [ ! -e "$ST/codex/accounts" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
  [ ! -s "$H/argv" ]
}

@test "--login takes no command: the agent is named with --agent" {
  local w
  for w in "--account work --login claude" "--login work claude" "--agent claude --account work --login auth login"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine -- asb $w
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login takes no command: the agent is named with --agent, asb [--agent AGENT] --account NAME --login" ]
  done
  [ ! -s "$H/argv" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
}

@test "--login: the base is refused for now, bare or as --account -; NAME is required" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  local w
  for w in "--login" "--account - --login" "--account=- --login"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine -- asb $w
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login: the base is still the agent's own native directory, your own login, and asb does not log it in; log in an account: asb --agent AGENT --account NAME --login" ]
  done
  # the agent typed is the agent named back
  for w in "--agent claude --login" "--agent claude --account - --login" "--login --agent=claude"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine -- asb $w
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login: the base is still the agent's own native directory, your own login, and asb does not log it in; log in an account: asb --agent claude --account NAME --login" ]
  done
  [ "$(cat "$C/.credentials.json")" = BASE-LOGIN ]
  [ ! -s "$H/argv" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
}

@test "--login: a login has no role: the ROLE= and GLOB= forms of --agent and --account are refused" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  local w
  for w in r=claude 'r*=claude' '*=claude'; do
    run_engine -- asb --agent "$w" --account work --login
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login: --agent $w names a role's agent, and a login has no role: --agent AGENT" ]
  done
  for w in r=work 'r*=work' '*=-'; do
    run_engine -- asb --agent claude --account "$w" --login
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --login: --account $w names a role's account, and a login has no role: --account NAME" ]
  done
  [ ! -s "$H/argv" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
}

@test "--login: AGENT defaults to the default agent: the only one asb can run, else the one set; several and none set, or none at all, refused" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  # the only one asb can run (the harness's profiles: claude, and sshd chosen by --profile alone)
  run_engine -- asb --account work --login
  [ "$status" -eq 0 ]
  [[ "$output" == *"role: account-login (--role)"* ]]
  [ "${JOINV[*]:1}" = "auth login" ]
  argv_has --bind "$ACC/work" "$C"
  # two asb can run, none set: refused, naming both ways to name one
  codex_profile
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --account work --login
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --login: no agent named, and there are several agents asb can run (claude codex) and no default is set: set it, asb --set-default-agent AGENT, or name one, asb --agent AGENT --account work --login" ]
  [ ! -s "$H/argv" ]
  # the one set is not one asb can run
  mkdir -p "$H/home/.config/agent-sandbox"
  printf 'gone\n' >"$H/home/.config/agent-sandbox/default-agent"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --account work --login
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --login: no agent named, and the default agent 'gone' (~/.config/agent-sandbox/default-agent) is not one asb can run here (claude codex): set another, asb --set-default-agent AGENT, or name one, asb --agent AGENT --account work --login" ]
  # the one set: codex, whose profile has no accounts, so its refusal is codex's
  printf 'codex\n' >"$H/home/.config/agent-sandbox/default-agent"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: profile 'codex' says nothing of which of its agent's files are an account's"* ]]
  # ... and --agent beats it
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  argv_has --bind "$ACC/work" "$C"
  # none asb can run at all
  rm "$H/home/.config/agent-sandbox/default-agent"
  mkdir -p "$H/profiles3/codex"
  cp "$H/profiles2/codex/profile.sh" "$H/profiles2/codex/agent-sandbox" "$H/profiles3/codex/"
  rm "$H/bin/codex"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles3" -- asb --account work --login
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --login: no agent named, and there is no agent asb can run here (installed: codex): install one, or name one, asb --agent AGENT --account work --login" ]
}

@test "--login: the --agent=AGENT and --account=NAME forms, and --login first on the line, run the login" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  local w
  for w in "--agent=claude --account=work --login" "--login --agent claude --account work" "--login --account=work" "--account work --login --agent=claude"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine -- asb $w
    [ "$status" -eq 0 ]
    [[ "$output" == *"role: account-login (--role)"* ]]
    [[ "$output" == *"--login: the account 'work' of claude has its login"* ]]
    argv_has --bind "$ACC/work" "$C"
    [ "${JOINV[*]:1}" = "auth login" ]
  done
}

@test "--account-login is not a flag of asb any more: an unknown option, as any other" {
  run_engine -- asb --account-login work claude
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: '--account-login' is not an option of agent-sandbox. "* ]]
  [ ! -s "$H/argv" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
}

@test "--login: refused inside a sandbox (AGENT_SANDBOX=1)" {
  run_engine AGENT_SANDBOX=1 -- asb --agent claude --account fresh --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login runs on the host"* ]]
  [ ! -e "$ACC/fresh" ]
  [ ! -s "$H/argv" ]
}

@test "--login: the account's directory is made with mode 700; a symlink or a file there, or a symlinked accounts, is refused; an existing directory is a re-login" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  run_engine -- asb --agent claude --account fresh --login
  [ -d "$ACC/fresh" ]
  [ ! -L "$ACC/fresh" ]
  [ "$(stat -c %a "$ACC/fresh")" = 700 ]
  [[ "$output" == *"--login: made ~/.local/state/agent-sandbox/claude/accounts/fresh, the account 'fresh' of claude"* ]]
  # a symlink, even to a fine account directory
  ln -s "$ACC/personal" "$ACC/link"
  run_engine -- asb --agent claude --account link --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: $ACC/link is a symlink"* ]]
  [ ! -s "$H/argv" ]
  : >"$ACC/file"
  run_engine -- asb --agent claude --account file --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: $ACC/file is not a directory"* ]]
  [ ! -s "$H/argv" ]
  # an `accounts` that is a symlink: nothing is made through it
  mkdir -p "$H/elsewhere"
  mv "$ACC" "$ACC.real"
  ln -s "$H/elsewhere" "$ACC"
  run_engine -- asb --agent claude --account other --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: $ACC is a symlink"* ]]
  [ ! -e "$H/elsewhere/other" ]
  [ ! -s "$H/argv" ]
  rm "$ACC"
  mv "$ACC.real" "$ACC"
  # an existing directory: the login runs in it, its mode left as it is
  chmod 750 "$ACC/work"
  run_engine -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  [[ "$output" != *"made "* ]]
  [ "$(stat -c %a "$ACC/work")" = 750 ]
  argv_has --bind "$ACC/work" "$C"
}

@test "--login: the login runs as role account-login of the scratch project, under --preset isolated, on the account, with the profile's login args" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  login_paths
  run_engine -- asb --agent claude --account fresh --login
  [ "$status" -eq 1 ] # the stub made no login file
  [[ "$output" == *"role: account-login (--role)"* ]]
  [[ "$output" == *"connect: preset isolated"* ]]
  [[ "$output" == *"account: fresh (--account), $ACC/fresh as the agent's state directory"* ]]
  argv_has --bind "$ACC/fresh" "$C"
  run ! argv_has --bind "$C" "$C"
  run ! grep -qF "$C/.credentials.json" "$H/argv"
  argv_has --chdir "$LSCR"
  [ ! -e "$LSCR/.agent-sandbox" ]
  # role account-login, isolated: every channel the role's own store under it (the
  # harness's default preset is shared, which would bind settings.json natively)
  local slot="${C//\//_}"
  argv_has --bind "$LSB/settings/own/${slot#_}_settings.json" "$C/settings.json"
  run ! argv_has --bind "$C/settings.json" "$C/settings.json"
  # the agent and the profile's login args, `claude auth login`
  [ "${JOINV[0]}" = "$H/home/.local/state/agent-sandbox/claude/install/2.1.300/claude" ]
  [ "${JOINV[*]:1}" = "auth login" ]
  # a profile's empty `login =` runs the agent with no arguments
  codex_profile 'account-paths = auth.json' 'login ='
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb --agent codex --account work --login
  [ "$status" -eq 1 ]
  argv_has --bind "$ST/codex/accounts/work" "$H/home/.codex"
  [ "${JOINV[*]}" = "$H/bin/codex" ]
  [[ "$output" == *"the account 'work' of codex has no login: there is no ~/.local/state/agent-sandbox/codex/accounts/work/auth.json"* ]]
}

@test "--login: the shell's AGENT_SANDBOX_CONNECT does not reach the login: the config is isolated's own store, never the native file" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  login_paths
  printf '{"oauthAccount":{"emailAddress":"native"}}\n' >"$H/home/.claude.json"
  run_engine AGENT_SANDBOX_CONNECT='config=read-write' -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  local slot="${C//\//_}"
  argv_has --bind "$LSB/config/own/${slot#_}_.claude.json" "$C/.claude.json"
  run ! grep -qxF "$H/home/.claude.json" "$H/argv"
  # the variable itself is honoured elsewhere: a plain launch binds the native file
  run_engine AGENT_SANDBOX_CONNECT='config=read-write' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/.claude.json" "$C/.claude.json"
}

@test "--login: the shell's AGENT_SANDBOX_NET does not reach the login: it runs under the default network mode, the proxy" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  run_engine AGENT_SANDBOX_NET=none -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  argv_has --share-net
  [[ "$(setenv_value HTTPS_PROXY)" == http://*@127.0.0.1:* ]]
  # elsewhere it is honoured: no network at all
  run_engine AGENT_SANDBOX_NET=none -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --share-net
}

@test "--login: the login role's stores are removed afterwards, after a failing login too, and what a killed run left is removed first" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  login_paths
  run_engine -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  grep -qF "$LSB/" "$H/argv" # it had stores
  [ ! -e "$LSB" ]
  [ ! -e "${LSB%/*}" ]
  run_engine JOIN_EXIT=3 -- asb --agent claude --account work --login
  [ "$status" -eq 3 ]
  [[ "$output" == *"--login: the login ended with status 3"* ]]
  grep -qF "$LSB/" "$H/argv"
  [ ! -e "$LSB" ]
  # a store a killed run left: the previous account's config copy is not the next one's
  mkdir -p "$LSB/config/own"
  printf '{"oauthAccount":{"emailAddress":"previous"}}\n' >"$LSB/config/own/x_.claude.json"
  : >"$LSB/stale"
  # ...removed before the login starts, not only after it: the join, standing for the
  # login, looks
  printf '%s\n' 'import os, sys' \
    'with open(os.environ["JOIN_DUMP"], "w") as fh:' \
    '    fh.write("\n".join(sys.argv[1:]) + "\n")' \
    'with open(os.environ["STALE_SEEN"], "w") as fh:' \
    '    fh.write("yes" if os.path.exists(os.environ["STALE"]) else "no")' \
    'sys.exit(3)' >"$H/bin/join-look.py"
  run_engine AGENT_SANDBOX_JOIN="$H/bin/join-look.py" STALE="$LSB/stale" STALE_SEEN="$H/seen" -- asb --agent claude --account work --login
  [ "$status" -eq 3 ]
  [ "$(cat "$H/seen")" = no ]
  [ ! -e "$LSB" ]
  run ! grep -rqF previous "$ST/claude"
  # the account's directory and the base are untouched
  [ "$(cat "$ACC/work/.credentials.json")" = WORK-LOGIN ]
  [ "$(cat "$C/.credentials.json")" = BASE-LOGIN ]
}

@test "--login: a login running already refuses a second one, and its stores stay until it ends" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  login_paths
  engine_bg -- asb --agent claude --account work --login
  [ -d "$LSB" ]
  run_engine -- asb --agent claude --account personal --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"--login: a login is running already (the role account-login of $LSCR); finish it, or end it with: cd $LSCR && asb --role account-login --shutdown claude"* ]]
  [ -d "$LSB" ]
  [ ! -s "$H/argv" ]
  release_bg
  [ "$BG_STATUS" -eq 0 ]
  [ ! -e "$LSB" ]
}

@test "--login: Ctrl-C at the login ends it, and the stores are still removed" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  login_paths
  # The join stands for the agent at the terminal: Ctrl-C is a SIGINT to the terminal's
  # foreground process group, which the engine is in; setsid gives the run its own.
  printf '%s\n' 'import os, signal, sys' \
    'with open(os.environ["JOIN_DUMP"], "w") as fh:' \
    '    fh.write("\n".join(sys.argv[1:]) + "\n")' \
    'with open(os.environ["SIG_SEEN"], "w") as fh:' \
    '    fh.write("ignored" if signal.getsignal(signal.SIGINT) == signal.SIG_IGN else "not ignored")' \
    'signal.signal(signal.SIGINT, signal.SIG_IGN)' \
    'os.killpg(os.getpgrp(), signal.SIGINT)' \
    'sys.exit(130)' >"$H/bin/join-int.py"
  # The engine starts with SIGINT at its default, as at a terminal. Under bats --jobs,
  # where bash hands the test an ignored SIGINT (bash 5.3.9 does; 5.2.37 does not), the
  # engine, a non-interactive bash, could not undo an ignore it started with (#424). The
  # system's env, not one on the test's PATH.
  printf '#!/bin/sh\nexec /usr/bin/env --default-signal=INT setsid -w %q "$@"\n' "$H/bin/asb" >"$H/bin/asb-own-group"
  chmod +x "$H/bin/asb-own-group"
  run_engine AGENT_SANDBOX_JOIN="$H/bin/join-int.py" SIG_SEEN="$H/sig" -- "$H/bin/asb-own-group" --agent claude --account work --login
  [ "$status" -eq 130 ]
  # the login gets Ctrl-C: it does not inherit an ignored SIGINT from the wait around it
  [ "$(cat "$H/sig")" = "not ignored" ]
  grep -qF "$LSB/" "$H/argv"
  [[ "$output" == *"--login: the login ended with status 130"* ]]
  [[ "$output" == *"--login: the account 'work' of claude has its login"* ]]
  [ ! -e "$LSB" ]
}

@test "--login: a hint about the unechoed code is said just before the login runs, never on a refusal" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  local hint="--login: if it asks for a code, paste it and press Enter; the code is not shown as you paste it."
  run_engine -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  [[ "$output" == *"$hint"*"role: account-login (--role)"* ]]
  [[ "$output" != *"role: account-login (--role)"*"$hint"* ]]
  # refused: by the arguments, and by the last check before the login (one running)
  run_engine -- asb --agent nosuch --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" != *"paste it"* ]]
  login_paths
  engine_bg -- asb --agent claude --account work --login
  run_engine -- asb --agent claude --account personal --login
  [ "$status" -eq 2 ]
  [[ "$output" == *"a login is running already"* ]]
  [[ "$output" != *"paste it"* ]]
  release_bg
}

@test "--login: says whether the account has its login file, by its path; the exit status follows" {
  require_host "asb --login is the host's; the engine refuses it inside a sandbox"
  run_engine -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  [[ "$output" == *"--login: the account 'work' of claude has its login: ~/.local/state/agent-sandbox/claude/accounts/work/.credentials.json"* ]]
  [[ "$output" != *"WORK-LOGIN"* ]]
  run_engine -- asb --agent claude --account fresh --login
  [ "$status" -eq 1 ]
  [[ "$output" == *"--login: the account 'fresh' of claude has no login: there is no ~/.local/state/agent-sandbox/claude/accounts/fresh/.credentials.json"* ]]
  [[ "$output" != *"the login ended with status"* ]]
}

@test "--login: the scratch project is left out of --list and --list-all" {
  login_paths
  mkdir -p "$LSB" "$SBOX" "$LSCR"
  printf '%s\n' "$LSCR" >"$LSB/project"
  printf '%s\n' "$PROJ" >"$SBOX/project"
  run_engine -- asb --list-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJ"* ]]
  [[ "$output" != *account-login* ]]
  RUN_CWD="$LSCR" run_engine -- asb --list
  [[ "$output" != *"account-login"*"stopped"* ]]
  [[ "$output" == *"no role"* ]]
}

@test "--login helper: the cleanup removes only the login role's own directory under a project's slug" {
  source_engine
  local slug="-tmp-x"
  mkdir -p "$ST/claude/$slug/other" "$ST/claude/$slug/account-login/config"
  run _as_login_clean "$ST" claude "$slug"
  [ "$status" -eq 0 ]
  [ ! -e "$ST/claude/$slug/account-login" ]
  [ -d "$ST/claude/$slug/other" ] # the slug's other entries stay, and so does the slug
  # not a project's slug: nothing removed
  mkdir -p "$ST/claude/accounts/account-login"
  run _as_login_clean "$ST" claude accounts
  [ "$status" -eq 1 ]
  [ -d "$ST/claude/accounts/account-login" ]
  # a symlinked store: neither it nor its target removed
  mkdir -p "$H/target"
  : >"$H/target/keep"
  ln -s "$H/target" "$ST/claude/$slug/account-login"
  run _as_login_clean "$ST" claude "$slug"
  [ "$status" -eq 1 ]
  [ -f "$H/target/keep" ]
  [ -L "$ST/claude/$slug/account-login" ]
  rm "$ST/claude/$slug/account-login"
  # the slug's directory a symlink: the login role's store behind it stays
  mkdir -p "$H/slugt/account-login"
  : >"$H/slugt/account-login/keep"
  ln -s "$H/slugt" "$ST/claude/-tmp-y"
  run _as_login_clean "$ST" claude -tmp-y
  [ "$status" -eq 1 ]
  [ -f "$H/slugt/account-login/keep" ]
  [ -L "$ST/claude/-tmp-y" ]
  # <state>/<profile> a symlink: no level under it is the login role's own
  mkdir -p "$H/proft/$slug/account-login"
  : >"$H/proft/$slug/account-login/keep"
  ln -s "$H/proft" "$ST/codex"
  run _as_login_clean "$ST" codex "$slug"
  [ "$status" -eq 1 ]
  [ -f "$H/proft/$slug/account-login/keep" ]
  [ -L "$ST/codex" ]
}

# config_store -- the host path of the role's config file store, from its record.
config_store() { awk -F'\t' '$1 == "config" { print $4 }' "$SBOX/record.tsv"; }
# fetched FILE -- the file's oauthAccount.profileFetchedAt (None when absent); the
# organisation beside it must be what the fixture wrote, or nothing.
fetched() {
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("oauthAccount") or {}; assert a.get("organizationName", "X") == "X"; print(a.get("profileFetchedAt"))' "$1"
}
# set_fetched FILE N -- set it in place, as Claude Code's last run would have.
set_fetched() {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("oauthAccount", {})["profileFetchedAt"]=int(sys.argv[2]); json.dump(d, open(p, "w"))' "$1" "$2"
}

@test "P8: a relaunch on another account resets oauthAccount.profileFetchedAt in the role's config store; the same account leaves it; the base after an account resets it, the base after the base leaves it" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  # the first launch on the base, no record: the base, no switch; seed-only seeds 123
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(config_store)"
  [[ "$store" == "$SBOX"/config/seed-only/* ]]
  [ "$(fetched "$store")" = 123 ]
  # the base after the base: unchanged
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 123 ]
  # another account: reset
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(config_store)" = "$store" ]
  [ "$(fetched "$store")" = 0 ]
  # the same account again (the agent fetched meanwhile): unchanged
  set_fetched "$store" 456
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 456 ]
  # a third account: reset
  run_engine -- asb --account personal claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 0 ]
  # the base after an account: reset
  set_fetched "$store" 789
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 0 ]
  # the native file was never the one rewritten
  [ "$(fetched "$H/home/.claude.json")" = 123 ]
}

@test "P8: the first launch under an account (no record: the base) resets the seeded copy" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  [ ! -e "$SBOX/account" ]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$(config_store)")" = 0 ]
  [ "$(fetched "$H/home/.claude.json")" = 123 ]
}

@test "P8: own and copy stores are reset too; an engine turn (AGENT_SANDBOX_SERVE_TURN) neither records nor resets" {
  TEST_PRESET=isolated run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(config_store)"
  [[ "$store" == "$SBOX"/config/own/* ]]
  set_fetched "$store" 123
  TEST_PRESET=isolated run_engine AGENT_SANDBOX_SERVE_TURN=1 -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 123 ]
  TEST_PRESET=isolated run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 0 ]
  # copy: the base after work, so a switch; the copy is synced from 123 first
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  dotfile '[connect]' 'config = copy'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  store="$(config_store)"
  [[ "$store" == "$SBOX"/config/copy/* ]]
  [ "$(fetched "$store")" = 0 ]
  [ "$(fetched "$H/home/.claude.json")" = 123 ]
}

@test "P8: under config = read-write the native file is never touched at a switch" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  dotfile '[connect]' 'config = read-write'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local before
  before="$(stat -c '%i %Y %s' "$H/home/.claude.json")"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
  [ "$(fetched "$H/home/.claude.json")" = 123 ]
  [ "$(stat -c '%i %Y %s' "$H/home/.claude.json")" = "$before" ]
}

@test "P8: config = copy-on-write, a copy store on a file, is reset at a switch; the native file is not" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  dotfile '[connect]' 'config = copy-on-write'
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(config_store)"
  [[ "$store" == "$SBOX"/config/copy/* ]]
  [ "$(fetched "$store")" = 123 ]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 0 ]
  [ "$(fetched "$H/home/.claude.json")" = 123 ]
}

@test "P8: a reset that fails (a store that is not JSON) is said, and the launch goes on; the store is left and the record written" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(config_store)"
  printf 'not json' >"$store"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"config: could not reset oauthAccount.profileFetchedAt in $store;"* ]]
  [ "$(cat "$store")" = "not json" ]
  [ -s "$H/argv" ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
}

@test "P8: a cold --exec on another account counts as a switch, as it writes the record" {
  printf '%s\n' '{"oauthAccount":{"organizationName":"X","profileFetchedAt":123},"projects":{}}' >"$H/home/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(config_store)"
  [ "$(fetched "$store")" = 123 ]
  run_engine -- asb --profile claude --account work --exec true
  [ "$status" -eq 0 ]
  [ "$(fetched "$store")" = 0 ]
  [ "$(cat "$SBOX/account")" = "claude"$'\t'"work" ]
}

# ---- #409: a linked ~/.claude/cache, on the base and on an account ----------------------
# The base's cache/ a symbolic link to ~/dot/cache, which holds the changelog channel's
# cache/changelog.md: the channel's path is reached through the link (its own question),
# and the link itself is the scan's (#401).
linked_cache() {
  rm -rf "$C/cache"
  mkdir -p "$H/home/dot/cache"
  printf 'notes\n' >"$H/home/dot/cache/changelog.md"
  ln -s ../dot/cache "$C/cache"
  TRUST="$H/home/.config/agent-sandbox/trust"
  VIEWS="$TRUST/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1).links.view."
}
# trust_answer ANSWERS -- `asb --trust` in the project, ANSWERS (printf %b) typed in
trust_answer() {
  engine_cmd
  run bash -c 'cd "$1" && printf "%b" "$2" | env -i HOME="$3" PATH="$4" "${@:5}" --trust 2>&1' _ \
    "$PROJ" "$1" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}
CACHE_LINE='  ~/.claude/cache = read-write outside:~/dot/cache'
CHANGELOG_LINE='  ~/.claude/cache/changelog.md = read-write outside:~/dot/cache/changelog.md'
# the changelog once the cache, its parent, is approved: covered, not asked (A2)
COVERED_LINE="~/.claude/cache/changelog.md = read-write outside:~/dot/cache/changelog.md: within ~/.claude/cache, approved; not asked."
# asked_once TEXT -- TEXT (a review or launch) asked exactly one question: the cache's
asked_once() { [ "$(grep -c 'approve this link for' <<<"$1")" -eq 1 ]; }

@test "#409: a launch refused for the linked cache's changelog leaves its view on record; the one review after it asks the cache, and the changelog within it no more once the cache is approved; the next launch binds the cache's target" {
  linked_cache
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to launch until it is reviewed"* ]]
  [ ! -s "$H/argv" ]
  # the view on record, written before the gate refused: the base bound plainly
  grep -qxF "$C"$'\t'rw$'\t'"$C"$'\t'read-write "$VIEWS"*
  trust_answer 'y\ny\n'
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"$COVERED_LINE"* ]]
  asked_once "$output"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  argv_has --bind "$H/home/dot/cache/changelog.md" "$H/home/dot/cache/changelog.md"
}

@test "#409 at a terminal: the first launch asks the linked cache in its one round, the cache before the changelog, which its approval covers" {
  linked_cache
  run_engine_tty 'y\ny\n' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"$COVERED_LINE"* ]]
  asked_once "$output"
  # (a link the scan found is bound from the launch after its approval, as before #409)
  run_engine_tty '' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"approve this link"* ]]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
}

@test "#409: under an account, the base's linked cache is the base's link: the review after a refused launch asks it (the changelog within it covered); approved, the account's launch binds its target and puts the changelog there, the account's copy stays a link; a second account asks nothing" {
  linked_cache
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to launch until it is reviewed"* ]]
  # the account's directory written as the base, its own login a path the scan skips
  grep -qxF "$C"$'\t'rw$'\t'"$C"$'\t'read-write "$VIEWS"*
  grep -qxF "$C/.credentials.json"$'\t'other$'\t\t-' "$VIEWS"*
  run ! grep -qF "$ACC/work"$'\t' "$VIEWS"*
  trust_answer 'y\ny\n'
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"$COVERED_LINE"* ]]
  asked_once "$output"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  argv_has --bind "$H/home/dot/cache/changelog.md" "$H/home/dot/cache/changelog.md"
  [ "$(readlink "$ACC/work/cache")" = ../dot/cache ] # never covered
  run ! grep -qF "$ACC/work/cache" "$H/argv"
  run_engine -- asb --account personal claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"is reached through a symbolic link"* ]]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  [ "$(readlink "$ACC/personal/cache")" = ../dot/cache ]
}

@test "#409: under an account, the base's linked cache not approved: its target is not bound, the changelog goes where the base's link leads, the account's copy stays a link" {
  linked_cache
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  trust_answer 'n\ny\n' # the cache declined, the changelog approved
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"$CHANGELOG_LINE"* ]]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  argv_has --bind "$H/home/dot/cache/changelog.md" "$H/home/dot/cache/changelog.md"
  [ "$(readlink "$ACC/work/cache")" = ../dot/cache ] # never covered
  run ! grep -qF "$ACC/work/cache" "$H/argv"
}

@test "#409: an account's directory with content where the base has a symlink refuses, saying what an earlier launch may have left there; the remove-either advice stays; a file there gets no such sentence" {
  mkdir "$ACC/work/link"
  printf 'agent\n' >"$ACC/work/link/other"
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"the account 'work': '$ACC/work/link' is a directory where the base's '$C/link' is a symlink, so the base's cannot be put over it; remove '$ACC/work/link' (the account's) to see the base's there, or '$C/link' (the base's) to keep the account's. If an earlier launch made it (a cover for the base's link, before #409's fix), what is in it is the agent's writes through that link, which a launch now never puts there. Nothing was started"* ]]
  [ ! -s "$H/argv" ]
  [ -e "$ACC/work/link/other" ] # never removed
  rm -r "$ACC/work/link"
  : >"$ACC/work/link"
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'$ACC/work/link' is a file where the base's '$C/link' is a symlink"* ]]
  [[ "$output" != *"earlier launch"* ]]
}

@test "#409: the view on record before the gate is the launch's final one: a link to where the changelog's mount moves (shown there) is not asked by the review after a refused launch" {
  linked_cache
  ln -s ../dot/cache/changelog.md "$C/cl2" # into the changelog's target, which the view shows
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  trust_answer 'y\ny\n'
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" != *"cl2"* ]]
}

@test "#409: under an account, a link inside an entry of the base's bound from it is the base's too: the review asks it; approved, the account's launch binds its target" {
  mkdir -p "$H/home/dot/ide-x"
  ln -s ../../dot/ide-x "$C/ide/l"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ] # a link the scan finds blocks no launch
  trust_answer 'y\n'
  [[ "$output" == *"  ~/.claude/ide/l = read-write outside:~/dot/ide-x"* ]]
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/ide-x" "$H/home/dot/ide-x"
}

@test "#409 helper: under an account, a path under the account's copy of a base link is the same under the base's link; a name that only starts like it, or no account, is unchanged" {
  source_engine
  # shellcheck disable=SC2034 # read by the helpers by dynamic scope
  local profile_base="$C" _acct_dir="$ACC/work" _as_base_real="$C"
  # shellcheck disable=SC2034
  local -a _as_base_links=(cache)
  local p="$ACC/work/cache/changelog.md"
  _as_ln_acct_base p
  [ "$p" = "$C/cache/changelog.md" ]
  p="$ACC/work/cache"
  _as_ln_acct_base p
  [ "$p" = "$C/cache" ]
  p="$ACC/work/cachex/f"
  _as_ln_acct_base p
  [ "$p" = "$ACC/work/cachex/f" ]
  p="$ACC/work/ide/f"
  _as_ln_acct_base p
  [ "$p" = "$ACC/work/ide/f" ]
  _acct_dir=""
  p="$ACC/work/cache/f"
  _as_ln_acct_base p
  [ "$p" = "$ACC/work/cache/f" ]
}

@test "#409 helper: the account's mount stands for the base only where it is the account's directory at the base's path" {
  source_engine
  # shellcheck disable=SC2034 # read by the helper by dynamic scope
  local profile_base="$C" _acct_dir="$ACC/work" _as_base_real="$C"
  # shellcheck disable=SC2034
  local -a _od=("$C" "$C" "$C/ide")
  # shellcheck disable=SC2034
  local -A _ms=([0]="$ACC/work" [1]="$H/store" [2]="$ACC/work")
  _as_ln_acct_mount 0
  run ! _as_ln_acct_mount 1
  run ! _as_ln_acct_mount 2
  _acct_dir=""
  run ! _as_ln_acct_mount 0
}

@test "#409: under an account, a chain through two of the base's links (cache -> c2 -> ../dot/cache) makes neither again, approved or not: the account's copies are the base's, as on the base (bubblewrap before 0.9.0 dies on a symlink already there)" {
  rm -rf "$C/cache"
  mkdir -p "$H/home/dot/cache"
  printf 'notes\n' >"$H/home/dot/cache/changelog.md"
  ln -s c2 "$C/cache"
  ln -s ../dot/cache "$C/c2"
  local rec
  rec="$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1).links"
  run_engine -- asb --account work claude --version
  [ "$status" -ne 0 ]
  # (the changelog approved on its own first, the two links declined; then the links: an
  # approved parent covers its child, which a review then does not ask, A2)
  trust_answer 'n\nn\ny\n'
  trust_answer 'y\ny\n'
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  run ! grep -qF -- "$C/c2" "$H/argv"
  # the links withdrawn, the changelog's still approved: its mount through the chain too
  sed -i -e "\\|^$C/cache\t|d" -e "\\|^$C/c2\t|d" "$rec"
  grep -q "^$C/cache/changelog.md"$'\t' "$rec"
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  argv_has --bind "$H/home/dot/cache/changelog.md" "$H/home/dot/cache/changelog.md"
  run ! grep -qF -- "$C/c2" "$H/argv"
  [ "$(readlink "$ACC/work/c2")" = ../dot/cache ]
}

@test "#409: a link of the base's at an account path (a linked .credentials.json), approved for a role on the base, binds nothing into a role on an account: only the base's own links are the account's" {
  rm "$C/.credentials.json"
  mkdir -p "$H/home/dot"
  printf 'BASE-LOGIN\n' >"$H/home/dot/creds.json"
  ln -s ../dot/creds.json "$C/.credentials.json"
  run_engine -- asb claude --version
  engine_cmd
  (cd "$PROJ" && yes | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/creds.json" "$H/home/dot/creds.json" # approved on the base
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$H/home/dot/creds.json" "$H/argv"
}

# ---- #409 under every preset: a store's read through the link refused at the check gate ----
# Under `inherit` and the default preset the changelog channel is a `copy` store: its read
# through the link is refused by the check-mode gate (_as_connect_bind_all), before the
# full one. Its view is on record all the same (_as_ln_prepass).

@test "#409 under inherit and the default preset, base and account: a launch refused at the check gate leaves its view on record; the one review after it asks the cache, the changelog within it covered; the next launch starts" {
  local pre acct
  for pre in inherit ''; do
    for acct in '' work; do
      rm -rf "$H/home/.config/agent-sandbox/trust" "$C/cache" "$H/home/dot" "$ACC/work/cache"
      linked_cache
      local -a a=()
      [[ -z "$acct" ]] || a=(--account "$acct")
      TEST_PRESET="$pre" run_engine -- asb "${a[@]}" claude --version
      [ "$status" -ne 0 ]
      [[ "$output" == *"~/.claude/cache/changelog.md = copy outside:~/dot/cache/changelog.md"* ]]
      grep -qxF "$C"$'\t'rw$'\t'"$C"$'\t'read-write "$VIEWS"*
      # the briefing the launch binds after its binds, in the view as the final one has it
      grep -qxF /run/agent-sandbox$'\t'other$'\t\t-' "$VIEWS"*
      trust_answer 'y\ny\n'
      [[ "$output" == *"$CACHE_LINE"* ]]
      [[ "$output" == *"~/.claude/cache/changelog.md = copy outside:~/dot/cache/changelog.md: within ~/.claude/cache, approved; not asked."* ]]
      asked_once "$output"
      TEST_PRESET="$pre" run_engine -- asb "${a[@]}" claude --version
      [ "$status" -eq 0 ] || {
        printf 'preset %s account %s: %s\n' "${pre:-default}" "${acct:--}" "$output" >&3
        false
      }
      argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
    done
  done
}

@test "#409 at a terminal, under inherit and the default preset, base and account: the first launch asks the cache in its one round, the changelog within it covered, and starts" {
  local pre acct
  for pre in inherit ''; do
    for acct in '' work; do
      rm -rf "$H/home/.config/agent-sandbox/trust" "$C/cache" "$H/home/dot" "$ACC/work/cache"
      linked_cache
      local -a a=()
      [[ -z "$acct" ]] || a=(--account "$acct")
      TEST_PRESET="$pre" run_engine_tty 'y\ny\n' -- asb "${a[@]}" claude --version
      [ "$status" -eq 0 ] || {
        printf 'preset %s account %s: %s\n' "${pre:-default}" "${acct:--}" "$output" >&3
        false
      }
      [[ "$output" == *"$CACHE_LINE"* ]]
      [[ "$output" == *"~/.claude/cache/changelog.md = copy outside:~/dot/cache/changelog.md: within ~/.claude/cache, approved; not asked."* ]]
      asked_once "$output"
    done
  done
}

@test "#409: a hide over a directory with a link in it, under each preset: the review after a refused launch does not ask about that link" {
  local pre
  mkdir -p "$H/home/dot/hidden"
  ln -s ../../dot/hidden "$C/daemon/l"
  for pre in shared inherit ''; do
    rm -rf "$H/home/.config/agent-sandbox/trust" "$C/cache" "$H/home/dot/cache"
    linked_cache
    TEST_PRESET="$pre" run_engine -- asb claude --version
    [ "$status" -ne 0 ]
    trust_answer 'y\ny\n'
    [[ "$output" == *"$CACHE_LINE"* ]]
    [[ "$output" != *"daemon/l"* ]]
  done
}

@test "#409 (A2): the cache approved after its changelog was declined: the launch starts, the changelog reached through the approved cache, under shared and inherit" {
  local pre
  for pre in shared inherit; do
    rm -rf "$H/home/.config/agent-sandbox/trust" "$C/cache" "$H/home/dot/cache"
    linked_cache
    TEST_PRESET="$pre" run_engine -- asb claude --version
    [ "$status" -ne 0 ]
    trust_answer 'n\nn\n' # both declined
    [[ "$output" == *"$CACHE_LINE"* ]]
    [ "$(grep -c 'approve this link for' <<<"$output")" -eq 2 ]
    TEST_PRESET="$pre" run_engine -- asb claude --version
    [ "$status" -ne 0 ]
    trust_answer 'y\n' # the cache, then: the changelog within it, not asked
    asked_once "$output"
    trust_answer '' # (before any launch prunes the changelog's pending line)
    [[ "$output" != *"approve this link"* ]]
    [[ "$output" != *"not asked"* ]]
    TEST_PRESET="$pre" run_engine -- asb claude --version
    [ "$status" -eq 0 ]
    [[ "$output" != *"is reached through a symbolic link"* ]]
    argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  done
}

@test "#409 (A2): a parent approved read-only does not cover a child that is read-write: the child is asked" {
  linked_cache
  local rec
  rec="$TRUST/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1).links"
  mkdir -p "$TRUST"
  printf '%s\t%s\t%s\t%s\t%s\n' "$C/cache" "$C/cache -> ../dot/cache" "$H/home/dot/cache" dir read-only >"$rec"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.claude/cache/changelog.md = read-write outside:~/dot/cache/changelog.md"* ]]
  # (the scan asks the cache again with the mode it has now, read-write: declined)
  trust_answer 'n\ny\n'
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"$CHANGELOG_LINE"* ]]
  [[ "$output" != *"not asked."* ]]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
}

@test "#409: under an account, a declaration of your own at the base link's own path keeps its mount where the link leads; the account's copy stays a link" {
  linked_cache
  dotfile '[connect]' '~/.claude/cache = read-write outside:~/dot/cache'
  run_engine -- asb --account work claude --version
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&3
    false
  }
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  [ "$(readlink "$ACC/work/cache")" = ../dot/cache ]
  run ! grep -qF "$ACC/work/cache" "$H/argv"
}

@test "#409 at a terminal: a no to the cache and to the changelog refuses the launch; nothing is bound through the link" {
  linked_cache
  run_engine_tty 'n\nn\n' -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"not approved; refusing to launch."* ]]
  [ "$(grep -c 'approve this link for' <<<"$output")" -eq 2 ]
  [ ! -s "$H/argv" ]
}

@test "#409 (A2): a path through an approved link that leaves its target through another link is not covered: it is asked, and a no refuses" {
  linked_cache
  mkdir -p "$H/home/dot/elsewhere"
  mv "$H/home/dot/cache/changelog.md" "$H/home/dot/elsewhere/changelog.md"
  ln -s ../elsewhere/changelog.md "$H/home/dot/cache/changelog.md"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  trust_answer 'y\nn\n'
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"  ~/.claude/cache/changelog.md = read-write outside:~/dot/elsewhere/changelog.md"* ]]
  [[ "$output" != *"not asked"* ]]
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.claude/cache/changelog.md = read-write outside:~/dot/elsewhere/changelog.md"* ]]
}

@test "#409 (A2): an approved link retargeted since covers nothing: the path through it is asked again" {
  linked_cache
  run_engine -- asb claude --version
  trust_answer 'y\n'
  mkdir -p "$H/home/dot/other"
  printf 'other\n' >"$H/home/dot/other/changelog.md"
  rm "$C/cache"
  ln -s ../dot/other "$C/cache"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.claude/cache/changelog.md = read-write outside:~/dot/other/changelog.md"* ]]
}

@test "#409 (A2): the parent is asked before its child in a UTF-8 locale too (whose collation would put cache/changelog.md first): one question, the child not asked" {
  locale -a 2>/dev/null | grep -qix 'en_US.utf-\?8' || skip "no en_US.UTF-8 locale here"
  linked_cache
  TEST_PRESET=inherit run_engine LANG=en_US.UTF-8 -- asb claude --version
  [ "$status" -ne 0 ]
  engine_cmd
  run bash -c 'cd "$1" && yes | env -i HOME="$2" PATH="$3" LANG=en_US.UTF-8 "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" == *"$CACHE_LINE"* ]]
  [[ "$output" == *"~/.claude/cache/changelog.md = copy outside:~/dot/cache/changelog.md: within ~/.claude/cache, approved; not asked."* ]]
  [ "$(grep -c 'approve this link' <<<"$output")" = 1 ]
}

@test "#409: the view the gate before a store's read leaves is the list as the links rewrite it: with the cache approved (its target bound), a link into that target is not asked by the review after a refused launch" {
  linked_cache
  TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  trust_answer 'y\n' # the cache, which covers its changelog
  [[ "$output" == *"$CACHE_LINE"* ]]
  TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/dot/cache" "$H/home/dot/cache"
  # a new link the gate before a store's read refuses (skills, a store under inherit), and
  # one into the cache's bound target, which the launch's view shows
  rm -r "$C/skills"
  mkdir -p "$H/home/dot/skills"
  ln -s ../dot/skills "$C/skills"
  printf 'x\n' >"$H/home/dot/cache/x"
  ln -s ../dot/cache/x "$C/cl3"
  TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.claude/skills is reached through a symbolic link"* ]]
  trust_answer 'n\n'
  [[ "$output" == *"  ~/.claude/skills = copy-on-write outside:~/dot/skills"* ]]
  [[ "$output" != *"cl3"* ]]
}
