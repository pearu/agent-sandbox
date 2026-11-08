#!/usr/bin/env bats
# Accounts (#355) with the REAL bwrap and the claude profile: a stub Claude binary
# reports, from INSIDE the sandbox, which login it sees at $CLAUDE_CONFIG_DIR and what
# else of the base is there. The unit suite (tests/unit/accounts.bats) pins the argv;
# only this shows the account's directory really is the state directory, the base's
# login really is out of reach, and a channel still comes from the base. Fixture files
# in a throwaway HOME, never a real login.

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
say skill "$(cat "$c/skills/s.md" 2>/dev/null || echo none)"
say wrote "$(printf 'inside\n' >"$c/written-inside" 2>/dev/null && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  printf 'BASE-LOGIN\n' >"$IHOME/.claude/.credentials.json"
  printf 'echo hook\n' >"$IHOME/.claude/response-hook.py"
  printf 'MY-SKILL\n' >"$IHOME/.claude/skills/s.md"
  printf 'WORK-LOGIN\n' >"$ACC/.credentials.json"
  BGS=()
}

teardown() {
  local p f spid
  for p in ${BGS[@]+"${BGS[@]}"}; do : >"$IWORK/go-$p"; done
  # Only keepers this test started, by the supervisor pid their record names.
  for f in "$IHOME"/.local/state/agent-sandbox/claude/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# bg_claude NAME ROLE [ENGINE ARGS...] -- launch role ROLE in the background, its probe
# holding until go-NAME; return once it is inside (report-NAME exists). Sets BG_PID_NAME.
bg_claude() {
  local name="$1" role="$2" i
  shift 2
  engine_cmd
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_PRESET=shared \
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

@test "with an account, CLAUDE_CONFIG_DIR is the account's directory: its login, not the base's, which is nowhere inside; a channel still from the base; a write lands in the account" {
  run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[config_dir]}" = "$IHOME/.claude" ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[base_login]}" = no ]
  [ "${M[hook]}" = no ] # not before #355's per-entry binds
  [ "${M[skill]}" = MY-SKILL ]
  [ "${M[wrote]}" = yes ]
  [ "$(cat "$ACC/written-inside")" = inside ]
  [ ! -e "$IHOME/.claude/written-inside" ]
  [ "$(cat "$IHOME/.claude/.credentials.json")" = BASE-LOGIN ]
  # no mount point left behind in the account's directory, nor in the base
  local left
  left="$(find "$ACC" "$IHOME/.claude" -maxdepth 1 -type f -empty)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
}

@test "without one, the base's login, as before" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[login]}" = BASE-LOGIN ]
  [ "${M[hook]}" = yes ]
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
  left="$(empty_files "$ACC" && empty_files "$IHOME/.claude")"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
  [ ! -s "$IHOME/.local/state/agent-sandbox/placeholders" ] # and the list is empty again
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
  left="$(empty_files "$ACC" && empty_files "$IHOME/.claude")"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
}
