#!/usr/bin/env bats
# Accounts (#355) with the REAL bwrap and the claude profile: a stub Claude binary
# reports, from INSIDE the sandbox, which login it sees at $CLAUDE_CONFIG_DIR and what
# else of the base is there. The unit suite (tests/unit/accounts.bats) pins the argv;
# only this shows the account's directory really is the state directory, the base's
# login really is out of reach, a channel still comes from the base, and so do the
# base's other entries (P7: a hook script, a symlink). Fixture files in a throwaway
# HOME, never a real login.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  I="$(mkdir -p "$BATS_TEST_TMPDIR/i" && cd "$BATS_TEST_TMPDIR/i" && pwd -P)"
  IHOME="$I/home"
  IWORK="$I/work"
  ACC="$IHOME/.local/state/agent-sandbox/claude/accounts/work"
  mkdir -p "$IHOME/.local/share/claude/versions/9.9.9" "$IWORK" "$IHOME/.claude/skills" "$ACC"
  cat >"$IHOME/.local/share/claude/versions/9.9.9/claude" <<'PROBE'
#!/usr/bin/env bash
c="${CLAUDE_CONFIG_DIR:-unset}"
# `... hold NAME` (last on the line; the profile adds its own arguments first): report,
# wait for go-NAME, report again
if [ "$#" -ge 2 ] && [ "${@: -2:1}" = hold ]; then
  n="${@: -1}"
  R="$PWD/report-$n"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
  say cfg0 "$([ -e "$c/.claude.json" ] && echo yes || echo no)"
  for i in $(seq 1 600); do [ -e "$PWD/go-$n" ] && break; sleep 0.05; done
  say cfg1 "$([ -e "$c/.claude.json" ] && echo yes || echo no)"
  say hist1 "$([ -e "$c/history.jsonl" ] && echo yes || echo no)"
  exit 0
fi
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say config_dir "$c"
say login "$(cat "$c/.credentials.json" 2>/dev/null || echo none)"
say base_login "$(grep -rqs "BASE-LO""GIN" "$HOME" && echo yes || echo no)"
say hook "$([ -e "$c/response-hook.py" ] && echo yes || echo no)"
say hook_text "$(cat "$c/response-hook.py" 2>/dev/null || echo none)"
say link "$(readlink "$c/link" 2>/dev/null || echo none)"
say lock "$(cat "$c/.oauth_refresh.lock" 2>/dev/null || echo none)"
say skill "$(cat "$c/skills/s.md" 2>/dev/null || echo none)"
say wrote "$(printf 'inside\n' >"$c/written-inside" 2>/dev/null && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  printf 'BASE-LOGIN\n' >"$IHOME/.claude/.credentials.json"
  printf 'echo hook\n' >"$IHOME/.claude/response-hook.py"
  printf 'BASE-LOCK\n' >"$IHOME/.claude/.oauth_refresh.lock"
  ln -s somewhere "$IHOME/.claude/link"
  printf 'MY-SKILL\n' >"$IHOME/.claude/skills/s.md"
  printf 'WORK-LOGIN\n' >"$ACC/.credentials.json"
  BGS=()
}

teardown() {
  local p f spid
  for p in ${BGS[@]+"${BGS[@]}"}; do : >"$IWORK/go-$p"; done
  # Only keepers this test started, by the supervisor pid their record names.
  for f in "$IHOME"/.local/state/agent-sandbox/claude/*/*/keeper/id "$IHOME"/.local/state/agent-sandbox/claude/*/*/keeper/id.hidden "$I"/xs/agent-sandbox/claude/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# bg_claude NAME ROLE [ENGINE ARGS...] -- launch role ROLE in the background, its probe
# holding until go-NAME; return once it is inside (report-NAME exists). Sets BG_PID_NAME.
# BG_ENV: extra VAR=value words for the launch.
bg_claude() {
  local name="$1" role="$2" i
  shift 2
  engine_cmd
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_PRESET=shared ${BG_ENV[@]+"${BG_ENV[@]}"} \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" --role "$role" "$@" \
    "$IHOME/.local/share/claude/versions/9.9.9/claude" hold "$name" </dev/null >"$I/out-$name" 2>&1 3>&- &
  printf -v "BG_PID_$name" '%s' "$!"
  BGS+=("$name")
  for ((i = 0; i < 600; i++)); do
    [[ -e "$IWORK/report-$name" ]] && return 0
    sleep 0.05
  done
  echo "bg_claude $name: not inside:" >&2
  cat "$I/out-$name" >&2
  return 1
}

# finish NAME -- release NAME's probe and wait for its launch to end.
finish() {
  local pid="BG_PID_$1"
  : >"$IWORK/go-$1"
  wait "${!pid}"
}

# empty_files DIR -- the empty files directly in DIR (mount points left behind).
empty_files() { find "$1" -maxdepth 1 -type f -empty; }
# base_empty_left -- the empty files in the base that are mount points left behind: not the
# read-write file channels' sources an account launch makes there on purpose (a channel
# with no start: file, made empty when its path is no .json)
base_empty_left() {
  local f
  while IFS= read -r f; do
    awk -v k="{base}/${f##*/}" '$1 == k && !/start:/ { found = 1 } END { exit !found }' \
      "$REPO_ROOT/profiles/claude/agent-sandbox" || echo "$f"
  done < <(empty_files "$IHOME/.claude")
}

run_claude() {
  rm -f "$IWORK/report"
  engine_cmd
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" "$@" "$IHOME/.local/share/claude/versions/9.9.9/claude" probe
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

@test "with an account, CLAUDE_CONFIG_DIR is the account's directory: its login, not the base's, which is nowhere inside; a channel and the base's other entries still from the base; a write lands in the account" {
  run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[config_dir]}" = "$IHOME/.claude" ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[base_login]}" = no ]
  [ "${M[hook]}" = yes ] # the base's hook script, bound at its path
  [ "${M[hook_text]}" = "echo hook" ]
  [ "${M[link]}" = somewhere ] # made again, as written
  [ "${M[lock]}" = none ]      # the base's refresh lock is the base's
  [ "${M[skill]}" = MY-SKILL ]
  [ "${M[wrote]}" = yes ]
  [ "$(cat "$ACC/written-inside")" = inside ]
  [ ! -e "$IHOME/.claude/written-inside" ]
  [ "$(cat "$IHOME/.claude/.credentials.json")" = BASE-LOGIN ]
  # no mount point left behind in the account's directory; in the base, the read-write
  # file channels' sources it lacked that have no start: file are made there on purpose
  # (P7): {} for a .json path, empty otherwise; one with a start: file is not made
  local left f
  left="$(find "$ACC" -maxdepth 1 -type f -empty)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
  [ -f "$IHOME/.claude/CLAUDE.md" ]
  [ ! -s "$IHOME/.claude/CLAUDE.md" ]
  [ "$(cat "$IHOME/.claude/settings.json")" = "{}" ]
  [ "$(cat "$IHOME/.claude/remote-settings.json.signature.json")" = "{}" ]
  [ ! -s "$IHOME/.claude/remote-settings.json.synced-at" ]
  [ ! -e "$IHOME/.claude/policy-limits.json" ]
  [ ! -e "$IHOME/.claude/remote-settings.json" ]
  [ ! -e "$IHOME/.claude/policy-limits.json.stamp.json" ]
  while IFS= read -r f; do
    [[ "$f" != *.json ]] || {
      echo "an empty .json file in the base: $f"
      false
    }
    awk -v k="{base}/${f##*/}" '$1 == k && !/start:/ { found = 1 } END { exit !found }' "$REPO_ROOT/profiles/claude/agent-sandbox" || {
      echo "empty file in the base that is no file channel without a start: file: $f"
      false
    }
  done < <(find "$IHOME/.claude" -maxdepth 1 -type f -empty)
}

@test "without one, the base's login, as before" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[login]}" = BASE-LOGIN ]
  [ "${M[hook]}" = yes ]
}

@test "a channel nested in a base entry bound into an account role: its mount point is made in the base's entry, and removed after the launch" {
  mkdir -p "$IHOME/.claude/cache" # no changelog.md: the own store's mount point is made
  TEST_PRESET=isolated run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[hook]}" = yes ]
  [ ! -e "$IHOME/.claude/cache/changelog.md" ]
  [ ! -e "$ACC/cache/changelog.md" ]
}

@test "a channel nested under a base entry that is a symlink: the mount point is made through the link, and removed from there after the launch" {
  mkdir -p "$IHOME/.claude/cache.real"
  ln -s cache.real "$IHOME/.claude/cache" # the changelog channel's directory, a link
  TEST_PRESET=isolated run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "$(readlink "$ACC/cache")" = cache.real ] # made again in the account's directory
  [ ! -e "$IHOME/.claude/cache.real/changelog.md" ]
  [ ! -e "$ACC/cache.real/changelog.md" ]
}

# Two roles at once on one state directory share its mount-point files: the first
# launch creates them on the host, the second binds over the same ones. Removing one
# does not fail while the other still has it mounted -- the unlink succeeds and
# detaches that mount in every namespace -- so the first to exit used to strip the
# second of its .claude.json and history.jsonl.
two_roles_first_out() {
  bg_claude a ra "$@"
  bg_claude b rb "$@"
  finish a
  finish b
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report-b"
}

@test "two roles on one account at once: the first to exit leaves the second's mount points in place" {
  two_roles_first_out --account work
  [ "${M[cfg0]}" = yes ]
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
}

@test "two roles on the base at once: the first to exit leaves the second's mount points in place" {
  two_roles_first_out
  [ "${M[cfg0]}" = yes ]
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
}

@test "two roles on one account, the creator out first: the second keeps its mount points, and removes them when it exits" {
  two_roles_first_out --account work
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
  local left
  left="$(empty_files "$ACC" && base_empty_left)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
  # and the list is empty again
  [ ! -s "$IHOME/.local/state/agent-sandbox/placeholders" ] || {
    echo "still listed:"
    cat "$IHOME/.local/state/agent-sandbox/placeholders"
    false
  }
}

@test "a user's own empty file at a mount-point path is never removed, by the launch nor by the last one out" {
  : >"$ACC/history.jsonl"
  bg_claude a ra --account work
  bg_claude b rb --account work
  finish a
  finish b
  [ -f "$ACC/history.jsonl" ]
  [ ! -s "$ACC/history.jsonl" ]
  run ! grep -qxF "$ACC/history.jsonl" "$IHOME/.local/state/agent-sandbox/placeholders"
  [ ! -e "$ACC/.claude.json" ] # the engine's own still go
}

@test "two roles on one account at once: the last to exit removes the mount points" {
  bg_claude a ra --account work
  bg_claude b rb --account work
  [ -n "$(empty_files "$ACC")" ] # the mount points are there while they run
  finish b
  [ -n "$(empty_files "$ACC")" ] # kept: a still has them mounted
  finish a
  local left
  left="$(empty_files "$ACC" && base_empty_left)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
}

# A launch has its mount points from before bwrap mounts them, but is a live keeper
# only once its supervisor has written keeper/id. Played here by hiding b's record while
# a exits: b's session directory still says what it holds.
@test "a session not yet on its keeper record keeps its mount points when another exits" {
  bg_claude a ra --account work
  bg_claude b rb --account work
  local idf
  idf="$(echo "$IHOME"/.local/state/agent-sandbox/claude/*/rb/keeper/id)"
  mv "$idf" "$idf.hidden"
  finish a
  mv "$idf.hidden" "$idf"
  finish b
  declare -A M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report-b"
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
  [ -z "$(empty_files "$ACC")" ]
}

# Only what is on the engine's list is ever removed: a launch that could not list the
# files it created (the list's lock held past its 10 s wait) leaves them behind.
@test "mount points the launch could not put on the list are left, never removed" {
  local state="$IHOME/.local/state/agent-sandbox"
  mkdir -p "$state"
  : >"$state/placeholders"
  flock "$state/placeholders.lock" sleep 12 &
  local holder=$!
  sleep 0.3
  bg_claude a ra --account work
  wait "$holder"
  [ -n "$(empty_files "$ACC")" ]
  [ ! -s "$state/placeholders" ] # nothing listed
  finish a
  [ -n "$(empty_files "$ACC")" ] # unlisted: left behind
}

# A launch under another XDG_STATE_HOME has a list and a keeper record of its own, out
# of the other's sight; the session base they share still names its keeper.
# ...and before its supervisor records its keeper there (played by hiding that record
# while a exits): its session record names every existing file it binds over.
@test "a role under another XDG_STATE_HOME keeps its mount points from its start, before its keeper is on record" {
  bg_claude a ra
  BG_ENV=(XDG_STATE_HOME="$I/xs")
  bg_claude b rb
  BG_ENV=()
  local spid s rec=""
  read -r spid _ <"$(echo "$I"/xs/agent-sandbox/claude/*/rb/keeper/id)"
  for s in "$I"/base/session.*; do
    [[ "$(cut -d' ' -f1 "$s/owner.id")" == "$spid" ]] && rec="$s/keeper"
  done
  [ -e "$rec" ]
  mv "$rec" "$rec.hidden"
  finish a
  mv "$rec.hidden" "$rec"
  finish b
  declare -A M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report-b"
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
}

@test "a role under another XDG_STATE_HOME on the same base keeps its mount points when the creator exits" {
  bg_claude a ra
  BG_ENV=(XDG_STATE_HOME="$I/xs")
  bg_claude b rb
  BG_ENV=()
  finish a
  finish b
  declare -A M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report-b"
  [ "${M[cfg1]}" = yes ]
  [ "${M[hist1]}" = yes ]
}
