#!/usr/bin/env bats
# The claude profile's status line (#287): state-hook.sh records what the session is
# doing from Claude Code's hooks, statusline.sh prints the role and that state, and with
# [claude] state-background = on the hook also sets the terminal's background over
# Claude Code's own stdout. Run directly, with a state file of the test's own and a pty
# standing in for the terminal.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  P="${ENGINE%/*}/profiles/claude"
  S="$BATS_TEST_TMPDIR/state"
}

# hook EVENT [BACKGROUND [STDIN]] -- run state-hook.sh as Claude Code would, with no
# terminal and the hook's JSON on stdin, on this test's state file.
hook() {
  run bash "$P/state-hook.sh" "$1" "${2:-off}" "$S" <<<"${3:-{\}}"
}

# osc EVENT BACKGROUND [STDIN] -- the bytes state-hook.sh writes to the terminal, in hex:
# CLAUDE_PID is a process whose stdout is a pty this reads the other end of. Also
# checks the hook's own stdout is empty and its status 0.
osc() {
  run python3 -I - "$P/state-hook.sh" "$S" "$@" <<'PTY'
import os, pty, select, subprocess, sys
hook, statef, event, bg = sys.argv[1:5]
stdin = sys.argv[5].encode() if len(sys.argv) > 5 else b"{}"
try:
    m, s = pty.openpty()
except OSError as exc:
    print(f"NO-PTY {exc}")
    sys.exit(0)
holder = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL, stdout=s, stderr=subprocess.DEVNULL)
os.close(s)
try:
    env = dict(os.environ, CLAUDE_PID=str(holder.pid))
    r = subprocess.run(["bash", hook, event, bg, statef], input=stdin, env=env, capture_output=True, timeout=10)
    assert r.returncode == 0 and r.stdout == b"" and r.stderr == b"", r
    got = b""
    while select.select([m], [], [], 0.3)[0]:
        chunk = os.read(m, 1024)
        if not chunk:
            break
        got += chunk
    print(got.hex())
finally:
    holder.kill()
    holder.wait()
PTY
  [ "$status" -eq 0 ]
  [[ "$output" != NO-PTY* ]] || skip "no pty in this harness: $output"
}

# hex FORMAT -- the bytes printf makes of FORMAT, as osc prints them
hex() { printf '%b' "$1" | od -An -tx1 | tr -d ' \n'; }

@test "state-hook.sh: each event writes its state, prints nothing, exits 0; idle and other notifications leave it" {
  hook SessionStart
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = waiting ]
  hook UserPromptSubmit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = working ]
  hook PermissionRequest
  [ "$(cat "$S")" = "needs you" ]
  # a tool ran, so the turn is working again after a permission the user answered
  hook PostToolUse
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = working ]
  printf 'needs you\n' >"$S"
  hook PostToolUseFailure
  [ "$(cat "$S")" = working ]
  hook Stop
  [ "$(cat "$S")" = waiting ]
  local t
  for t in permission_prompt elicitation agent_needs_input; do
    printf 'waiting\n' >"$S"
    hook Notification off "{\"hook_event_name\":\"Notification\",\"notification_type\": \"$t\",\"message\":\"x\"}"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$S")" = "needs you" ]
  done
  for t in idle_prompt auth_success; do
    printf 'working\n' >"$S"
    hook Notification off "{\"notification_type\":\"$t\"}"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$S")" = working ]
  done
  hook Notification off 'not json'
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = working ]
  # SessionEnd and an event it does not know write nothing
  hook SessionEnd
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = working ]
  hook PreCompact
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = working ]
  # by rename: no temporary file is left beside it
  [ "$(find "$BATS_TEST_TMPDIR" -name 'state*' | wc -l)" -eq 1 ]
  # a state file it cannot write is not an error
  run bash "$P/state-hook.sh" Stop off "$BATS_TEST_TMPDIR/no/such/dir/state" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "statusline.sh: the role in bold, the state in reverse video -- working yellow, waiting green, needs you red and bold" {
  local B=$'\e[1m' R=$'\e[0m'
  run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "${B}planner-1${R}" ] # no state file: the role alone
  printf 'working\n' >"$S"
  run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "${B}planner-1${R} "$'\e[7;33m working \e[0m' ]
  printf 'waiting\n' >"$S"
  run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "${B}planner-1${R} "$'\e[7;32m waiting \e[0m' ]
  printf 'needs you\n' >"$S"
  run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "${B}planner-1${R} "$'\e[1;7;31m needs you \e[0m' ]
  # anything else in the file is never printed
  printf '\e]11;#ff0000\a\n' >"$S"
  run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "${B}planner-1${R}" ]
}

@test "statusline.sh: the default role shows the project's name from the stdin JSON, and the line stays under 60 columns" {
  local B=$'\e[1m' R=$'\e[0m'
  printf 'waiting\n' >"$S"
  run bash "$P/statusline.sh" default "$S" <<<'{"model":{"id":"x"},"workspace":{"current_dir":"/a/b/sub","project_dir": "/home/u/my-proj"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "${B}my-proj${R} "$'\e[7;32m waiting \e[0m' ]
  # no JSON, or none of it parses: the role's own name
  run bash "$P/statusline.sh" default "$S" <<<'garbage'
  [ "$output" = "${B}default${R} "$'\e[7;32m waiting \e[0m' ]
  # a named role ignores the project
  run bash "$P/statusline.sh" reviewer-2 "$S" <<<'{"workspace":{"project_dir":"/home/u/my-proj"}}'
  [ "$output" = "${B}reviewer-2${R} "$'\e[7;32m waiting \e[0m' ]
  # the longest name and state, without the escapes, fit in 60 columns
  printf 'needs you\n' >"$S"
  run bash "$P/statusline.sh" "$(printf 'r%.0s' {1..200})" "$S" </dev/null
  local plain
  # shellcheck disable=SC2001 # a regex, which ${//} is not
  plain="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$output")"
  ((${#plain} < 60))
}

@test "state-hook.sh: no terminal background by default; with BACKGROUND on, OSC 11 per state on Claude Code's stdout and OSC 111 to reset" {
  # off (the default): nothing reaches the terminal, for every event
  local e
  for e in SessionStart UserPromptSubmit PermissionRequest Stop SessionEnd; do
    osc "$e" off
    [ "$output" = "" ]
  done
  osc UserPromptSubmit on
  [ "$output" = "$(hex '\e]11;#203040\a')" ]
  osc PostToolUse on
  [ "$output" = "$(hex '\e]11;#203040\a')" ]
  osc PermissionRequest on
  [ "$output" = "$(hex '\e]11;#402020\a')" ]
  osc Notification on '{"notification_type":"permission_prompt"}'
  [ "$output" = "$(hex '\e]11;#402020\a')" ]
  osc Notification on '{"notification_type":"idle_prompt"}'
  [ "$output" = "" ]
  osc Stop on
  [ "$output" = "$(hex '\e]111\a')" ]
  osc SessionStart on
  [ "$output" = "$(hex '\e]111\a')" ]
  osc SessionEnd on
  [ "$output" = "$(hex '\e]111\a')" ]
}

@test "state-hook.sh: the background is written only to a character device, and never fails the hook" {
  # CLAUDE_PID unset, not a number, or a process whose stdout is a file: nothing written
  run env -u CLAUDE_PID bash "$P/state-hook.sh" UserPromptSubmit on "$S" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env CLAUDE_PID='1;x' bash "$P/state-hook.sh" UserPromptSubmit on "$S" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local f="$BATS_TEST_TMPDIR/out" pid
  sleep 30 >"$f" 3>&- &
  pid=$!
  run env CLAUDE_PID="$pid" bash "$P/state-hook.sh" UserPromptSubmit on "$S" </dev/null
  kill "$pid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$f" ]
  [ "$(cat "$S")" = working ] # the state is written either way
}
