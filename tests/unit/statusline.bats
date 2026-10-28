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
# terminal and the hook's JSON on stdin, on this test's state file. CLAUDE_PID is the
# test's own process, so a watcher counts only when this test started it (the host may
# run real ones).
hook() {
  CLAUDE_PID=$$ run bash "$P/state-hook.sh" "$1" "${2:-off}" "$S" <<<"${3:-{\}}"
}

# watcher -- start a process named inbox-wait (a script of that name, as the roles
# model's is) under this test; its pid in W.
watcher() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$BATS_TEST_TMPDIR/bin/inbox-wait"
  chmod +x "$BATS_TEST_TMPDIR/bin/inbox-wait"
  "$BATS_TEST_TMPDIR/bin/inbox-wait" 3>&- &
  W=$!
  local _
  for _ in $(seq 50); do
    [ "$(cat "/proc/$W/comm" 2>/dev/null)" = inbox-wait ] && return 0
    sleep 0.1
  done
  return 1
}

# bar COLOUR NAME STATE COLUMNS -- the status line statusline.sh prints for a state
bar() {
  local rest=22 text=" $2  $3 "
  [[ "$3" == "NEEDS YOU" ]] && rest=1
  printf '\e[%s;1m %s\e[%sm  %s %*s\e[0m' "$1" "$2" "$rest" "$3" "$(($4 - 4 - ${#text}))" ""
}

# plain TEXT -- TEXT without its SGR sequences
# shellcheck disable=SC2001 # a regex, which ${//} is not
plain() { sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }

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
  [ "$(cat "$S")" = idle ] # no watcher, no question
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
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = idle ]
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

@test "state-hook.sh: Stop says asks you when one of the reply's last three lines ends with a question, quotes not counted, from last_assistant_message" {
  local m
  # shellcheck disable=SC2016 # backticks of markdown, in JSON
  for m in 'Send it?' 'Send it?\n\n' '**Send it?**  ' 'Shall I go on?_' 'Which `x`?`' 'First.\n\nWhich one, A or B?' 'a \"quoted\" word?' 'a\\\\b?' \
    'Is it?\nDone.' 'Is it?\nA.\n\nB.' \
    'Send this to P1, on your yes?\nThe message:\n\n> ## 22\n> Report done 22.' \
    'Send it?\n\n▎ ## 22\n▎ Report\n▎ done 22.\n  > quoted too'; do
    printf 'idle\n' >"$S"
    hook Stop off "{\"session_id\":\"x\",\"last_assistant_message\": \"$m\",\"background_tasks\":[]}"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$S")" = "asks you" ] || {
      echo "not asks you: $m"
      false
    }
  done
  # a question four lines up, mid-line, in quotes, in a quote line, in a code block, none
  # shellcheck disable=SC2016 # backticks of markdown, in JSON
  for m in 'Is it?\nA.\nB.\n\nC.' 'Is it?\nA.\nB.\n> q\nC.' 'Is it? I will wait.' 'He said \"why?\"' '> Why?\nDone.' '```\nwhy?\n```' 'Done.\n```\nx\ny\nwhy?\n```' '' 'Done.'; do
    printf 'asks you\n' >"$S"
    hook Stop off "{\"last_assistant_message\":\"$m\"}"
    [ "$status" -eq 0 ]
    [ "$(cat "$S")" = idle ] || {
      echo "not idle: $m"
      false
    }
  done
  # a long reply reads fast (bash's own regex took 13 s on 64 KiB)
  m="$(head -c 1000000 /dev/zero | tr '\0' a)"
  printf '{"last_assistant_message":"%s?","background_tasks":[]}' "$m" >"$BATS_TEST_TMPDIR/long.json"
  local t0=$SECONDS
  CLAUDE_PID=$$ run bash "$P/state-hook.sh" Stop off "$S" <"$BATS_TEST_TMPDIR/long.json"
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = "asks you" ]
  ((SECONDS - t0 < 5))
}

@test "state-hook.sh: without last_assistant_message, Stop reads the last assistant text in the transcript's tail" {
  local tr="$BATS_TEST_TMPDIR/t.jsonl"
  {
    printf '{"type":"user","message":{"role":"user","content":"Ask me?"}}\n'
    printf '{"type":"assistant","message":{"type":"message","role":"assistant","content":[{"type":"text","text":"Earlier, a question?"}]}}\n'
    printf '{"type":"assistant","message":{"type":"message","role":"assistant","content":[{"type":"text","text":"Noted.\\n\\nWhich one, **A** or B?"}]}}\n'
    printf '{"type":"system","subtype":"turn_duration","text":"done."}\n'
  } >"$tr"
  hook Stop off "{\"transcript_path\":\"$tr\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = "asks you" ]
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}\n' >>"$tr"
  hook Stop off "{\"transcript_path\":\"$tr\"}"
  [ "$(cat "$S")" = idle ]
  # last_assistant_message wins over the transcript
  hook Stop off "{\"transcript_path\":\"$tr\",\"last_assistant_message\":\"Now?\"}"
  [ "$(cat "$S")" = "asks you" ]
  # no transcript, or one it cannot read: idle
  hook Stop off "{\"transcript_path\":\"$BATS_TEST_TMPDIR/none.jsonl\"}"
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = idle ]
}

@test "state-hook.sh: a running watcher (a process named inbox-wait under Claude Code) makes Stop and SessionStart say waiting" {
  watcher
  hook SessionStart
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = waiting ]
  hook Stop off '{"last_assistant_message":"Watcher armed. Waiting."}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = waiting ]
  # a question still comes first
  hook Stop off '{"last_assistant_message":"Send it?"}'
  [ "$(cat "$S")" = "asks you" ]
  # another session's watcher -- one that is not Claude Code's descendant -- does not count
  local other
  sleep 30 3>&- &
  other=$!
  CLAUDE_PID=$other run bash "$P/state-hook.sh" Stop off "$S" <<<'{}'
  kill "$other"
  [ "$status" -eq 0 ]
  [ "$(cat "$S")" = idle ]
  kill "$W"
  wait "$W" 2>/dev/null || true
  hook Stop
  [ "$(cat "$S")" = idle ]
  hook SessionStart
  [ "$(cat "$S")" = idle ]
}

# tasks ENTRY... -- a Stop input whose background_tasks holds each ENTRY (a JSON object)
tasks() {
  local IFS=,
  printf '{"hook_event_name":"Stop","last_assistant_message":"%s","background_tasks":[%s],"session_crons":[]}' "${M:-ok}" "$*"
}

# the entries a live Stop input carried (2.1.300): the roles model's watcher, and a
# command the session ran in the background
WT='{"id":"b01uoyluy","type":"shell","status":"running","description":"Arm inbox watcher for planner-1","command":".asb/bin/inbox-wait -a .asb/coord/planner-1/alive .asb/coord/to/planner-1.md"}'
ST='{"id":"bsy1vrv0j","type":"shell","status":"running","description":"Sleep 90 seconds in background","command":"sleep 90"}'

@test "state-hook.sh: a background command of the session's own other than the watcher makes Stop say running, from background_tasks" {
  watcher
  hook Stop off "$(tasks "$WT" "$ST")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = running ]
  # the watcher alone: waiting
  hook Stop off "$(tasks "$WT")"
  [ "$(cat "$S")" = waiting ]
  # a question still comes first
  local M='Run the suite now?'
  hook Stop off "$(tasks "$WT" "$ST")"
  M=ok
  [ "$(cat "$S")" = "asks you" ]
  # an entry with no command (a subagent), one whose description alone names the
  # watcher, and keys in another order count; an empty array is nothing running
  hook Stop off "$(tasks '{"id":"a1","type":"subagent","status":"running","description":"x","agent_type":"Explore"}')"
  [ "$(cat "$S")" = running ]
  hook Stop off "$(tasks '{"command":"make test","description":"not inbox-wait, \"really\" { [","id":"x"}' "$WT")"
  [ "$(cat "$S")" = running ]
  hook Stop off "$(tasks)"
  [ "$(cat "$S")" = waiting ]
  # a command naming inbox-wait anywhere is the watcher
  hook Stop off "$(tasks '{"type":"shell","command":"cd x && .asb/bin/inbox-wait a.md b.md"}')"
  [ "$(cat "$S")" = waiting ]
  kill "$W"
  wait "$W" 2>/dev/null || true
  hook Stop off "$(tasks "$WT" "$ST")"
  [ "$(cat "$S")" = running ]
  hook Stop off "$(tasks)"
  [ "$(cat "$S")" = idle ]
  # the field's name in the reply is not the field; an array that never ends is no answer
  hook Stop off '{"last_assistant_message":"\"background_tasks\":[{}]"}'
  [ "$(cat "$S")" = idle ]
  hook Stop off '{"background_tasks":[{"command":"sleep 9"}'
  [ "$(cat "$S")" = idle ]
  # SessionStart is unchanged
  hook SessionStart off "$(tasks "$ST")"
  [ "$(cat "$S")" = idle ]
}

@test "state-hook.sh: without background_tasks, running is a Bash tool wrapper other than the watcher's among Claude Code's children" {
  # Claude Code runs a Bash call as `bash -c '... eval '\''CMD'\'' < /dev/null && pwd -P >| F'`
  # (measured, 2.1.300); CLAUDE_PID is this shell, whose child the wrapper is
  local me=$BASHPID x
  bash -c "true && eval 'sleep 30' < /dev/null && pwd -P >| /dev/null" 3>&- &
  x=$!
  CLAUDE_PID=$me run bash "$P/state-hook.sh" Stop off "$S" <<<'{"last_assistant_message":"ok"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = running ]
  # background_tasks, when there, wins
  CLAUDE_PID=$me run bash "$P/state-hook.sh" Stop off "$S" <<<'{"background_tasks":[]}'
  [ "$(cat "$S")" = idle ]
  # not Claude Code's child, or no CLAUDE_PID: nothing
  local other
  sleep 30 3>&- &
  other=$!
  CLAUDE_PID=$other run bash "$P/state-hook.sh" Stop off "$S" <<<'{}'
  kill "$other"
  [ "$(cat "$S")" = idle ]
  run env -u CLAUDE_PID bash "$P/state-hook.sh" Stop off "$S" <<<'{}'
  [ "$(cat "$S")" != running ] # waiting, when the host runs a watcher of its own
  kill "$x"
  wait "$x" 2>/dev/null || true
  # the watcher's own wrapper is the watcher; a bash that is not a -c wrapper is not one
  bash -c "true && eval 'sleep 30; : inbox-wait' < /dev/null && pwd -P >| /dev/null" 3>&- &
  x=$!
  printf 'sleep 30\n' >"$BATS_TEST_TMPDIR/s.sh"
  bash "$BATS_TEST_TMPDIR/s.sh" 3>&- &
  local y=$!
  sleep 0.2
  CLAUDE_PID=$me run bash "$P/state-hook.sh" Stop off "$S" <<<'{}'
  kill "$x" "$y"
  wait "$x" "$y" 2>/dev/null || true
  [ "$(cat "$S")" = idle ]
}

@test "state-hook.sh: the watcher rule -- with AGENT_SANDBOX_WATCH and no watcher, Stop refuses once; not with a watcher, stop_hook_active, or no watch path" {
  local why='agent-sandbox: your watcher on .asb/coord/to/planner-1.md is not running; arm it as your purpose file says (the Bash tool, run_in_background: true), then end your turn.'
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md hook Stop off '{"stop_hook_active":false,"last_assistant_message":"done; in my file; S has it"}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"decision\":\"block\",\"reason\":\"$why\"}" ]
  python3 -I -c 'import json, sys; m = json.loads(sys.argv[1]); assert m == {"decision": "block", "reason": sys.argv[2]}, m' "$output" "$why"
  [ "$(cat "$S")" = idle ] # the state as without the rule
  # a reply that asks is refused the same, and still says asks you
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md hook Stop off '{"last_assistant_message":"Send it?"}'
  [[ "$output" == *'"decision":"block"'* ]]
  [ "$(cat "$S")" = "asks you" ]
  # already continuing because of a Stop hook: never a second refusal
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md hook Stop off '{"stop_hook_active": true}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = idle ]
  # no watch path (another role, a print run, a turn of --serve): nothing
  hook Stop off '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  AGENT_SANDBOX_WATCH='' hook Stop off '{}'
  [ -z "$output" ]
  # only Stop refuses
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md hook SessionStart
  [ -z "$output" ]
  # a watcher under Claude Code: the turn ends
  watcher
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md hook Stop off '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = waiting ]
  kill "$W"
  wait "$W" 2>/dev/null || true
  # a path with a quote and a backslash is a JSON string still
  AGENT_SANDBOX_WATCH='in "x\y.md' hook Stop off '{}'
  python3 -I -c 'import json, sys; assert json.loads(sys.argv[1])["reason"].startswith("agent-sandbox: your watcher on in \"x\\y.md is not running")' "$output"
}

@test "state-hook.sh: the summary rule (#314) -- Stop refuses once while the line is missing or empty; a line that is there passes every Stop, a prompt between or not; never with stop_hook_active or without AGENT_SANDBOX_SUMMARY" {
  local L="$BATS_TEST_TMPDIR/line"
  local why="agent-sandbox: write this session's one-line summary to $L, then end your turn."
  # UserPromptSubmit records working and nothing else: no prompt stamp
  hook UserPromptSubmit off '{"session_id":"sess-1","prompt":"go"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$S")" = working ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'agent-sandbox-prompt.*')" ]
  # missing: refused, as one JSON object, the state written as without the rule
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "{\"decision\":\"block\",\"reason\":\"$why\"}" ]
  python3 -I -c 'import json, sys; m = json.loads(sys.argv[1]); assert m == {"decision": "block", "reason": sys.argv[2]}, m' "$output" "$why"
  [ "$(cat "$S")" = idle ]
  # already continuing because of a Stop hook: never a second refusal
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active": true}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # empty: refused
  : >"$L"
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ "$output" = "{\"decision\":\"block\",\"reason\":\"$why\"}" ]
  # there, and older than any prompt: two Stops in a row pass, untouched
  printf 'Fixing the CI pin\n' >"$L"
  touch -d '-1 minute' "$L"
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # a prompt between them changes nothing
  hook UserPromptSubmit off '{"session_id":"sess-1","prompt":"and now?"}'
  [ -z "$output" ]
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  hook UserPromptSubmit off '{"session_id":"sess-1","prompt":"again"}'
  AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"sess-1","stop_hook_active":false}'
  [ -z "$output" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'agent-sandbox-prompt.*')" ]
  # without the variable (a print run, the briefing off): nothing
  rm -f "$L"
  hook Stop off '{"session_id":"sess-1"}'
  [ -z "$output" ]
  AGENT_SANDBOX_SUMMARY='' hook Stop off '{"session_id":"sess-1"}'
  [ -z "$output" ]
  # only Stop refuses
  AGENT_SANDBOX_SUMMARY="$L" hook SessionStart
  [ -z "$output" ]
  AGENT_SANDBOX_SUMMARY="$L" hook UserPromptSubmit off '{"session_id":"sess-1"}'
  [ -z "$output" ]
}

@test "state-hook.sh: a Stop that fails the watcher rule and the summary rule is refused once, naming both" {
  local L="$BATS_TEST_TMPDIR/line"
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"s"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  local why="agent-sandbox: your watcher on .asb/coord/to/planner-1.md is not running; arm it as your purpose file says (the Bash tool, run_in_background: true); write this session's one-line summary to $L, then end your turn."
  [ "$output" = "{\"decision\":\"block\",\"reason\":\"$why\"}" ]
  python3 -I -c 'import json, sys; m = json.loads(sys.argv[1]); assert m == {"decision": "block", "reason": sys.argv[2]}, m' "$output" "$why"
  # the line written: the watcher's refusal alone, as without the summary rule
  printf 'x\n' >"$L"
  AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md AGENT_SANDBOX_SUMMARY="$L" hook Stop off '{"session_id":"s"}'
  [ "$output" = '{"decision":"block","reason":"agent-sandbox: your watcher on .asb/coord/to/planner-1.md is not running; arm it as your purpose file says (the Bash tool, run_in_background: true), then end your turn."}' ]
  # a path with a quote and a backslash is a JSON string still
  AGENT_SANDBOX_SUMMARY='in "x\y' hook Stop off '{}'
  python3 -I -c 'import json, sys; m = json.loads(sys.argv[1]); assert m["reason"] == "agent-sandbox: write this session'"'"'s one-line summary to in \"x\\y, then end your turn.", m' "$output"
}

@test "statusline.sh: a bar as wide as Claude Code lets it be, in reverse video -- working and running yellow, waiting green, asks you blue, needs you blue and bold, idle grey" {
  local B=$'\e[1m' R=$'\e[0m'
  COLUMNS=100 run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "${B}planner-1${R}" ] # no state file: the role alone, no bar
  local st c
  for st in working:33 running:33 waiting:32 "asks you:34" "needs you:34" idle:90; do
    c="${st##*:}" st="${st%:*}"
    printf '%s\n' "$st" >"$S"
    COLUMNS=100 run bash "$P/statusline.sh" planner-1 "$S" </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "$(bar "7;$c" planner-1 "${st^^}" 100)" ]
    # the padding reaches COLUMNS - 4: Claude Code indents the line by 2 and cuts it at that
    [ "$(plain "$output" | wc -L)" -eq 96 ]
  done
  # needs you stays bold after the name, the others do not
  [[ "$output" == *$'\e[22m  IDLE '* ]]
  printf 'needs you\n' >"$S"
  COLUMNS=100 run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [[ "$output" == *$'\e[1m  NEEDS YOU '* ]]
  # without COLUMNS, or with garbage in it: 80
  printf 'working\n' >"$S"
  run env -u COLUMNS bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "$(bar "7;33" planner-1 WORKING 80)" ]
  COLUMNS='12;x' run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "$(bar "7;33" planner-1 WORKING 80)" ]
  # narrower than the text: no padding, nothing cut
  COLUMNS=10 run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$(plain "$output")" = " planner-1  WORKING " ]
  # anything else in the file is never printed
  printf '\e]11;#ff0000\a\n' >"$S"
  COLUMNS=100 run bash "$P/statusline.sh" planner-1 "$S" </dev/null
  [ "$output" = "${B}planner-1${R}" ]
}

@test "statusline.sh: the default role shows the project's name from the stdin JSON, cut at 40 characters" {
  printf 'waiting\n' >"$S"
  COLUMNS=80 run bash "$P/statusline.sh" default "$S" <<<'{"model":{"id":"x"},"workspace":{"current_dir":"/a/b/sub","project_dir": "/home/u/my-proj"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(bar "7;32" my-proj WAITING 80)" ]
  # no JSON, or none of it parses: the role's own name
  COLUMNS=80 run bash "$P/statusline.sh" default "$S" <<<'garbage'
  [ "$output" = "$(bar "7;32" default WAITING 80)" ]
  # a named role ignores the project
  COLUMNS=80 run bash "$P/statusline.sh" reviewer-2 "$S" <<<'{"workspace":{"project_dir":"/home/u/my-proj"}}'
  [ "$output" = "$(bar "7;32" reviewer-2 WAITING 80)" ]
  # a long name is cut at 40, control characters dropped, and the bar keeps its width
  printf 'needs you\n' >"$S"
  COLUMNS=80 run bash "$P/statusline.sh" "$(printf 'r%.0s' {1..200})"$'\e' "$S" </dev/null
  [ "$output" = "$(bar "7;34" "$(printf 'r%.0s' {1..39})~" "NEEDS YOU" 80)" ]
  [ "$(plain "$output" | wc -L)" -eq 76 ]
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
  [ "$output" = "$(hex '\e]11;#202840\a')" ]
  osc Notification on '{"notification_type":"permission_prompt"}'
  [ "$output" = "$(hex '\e]11;#202840\a')" ]
  osc Notification on '{"notification_type":"idle_prompt"}'
  [ "$output" = "" ]
  osc Stop on
  [ "$output" = "$(hex '\e]111\a')" ] # idle
  osc Stop on '{"last_assistant_message":"Send it?"}'
  [ "$output" = "$(hex '\e]11;#202840\a')" ] # asks you, as needs you
  osc Stop on "$(tasks "$WT" "$ST")"
  [ "$output" = "$(hex '\e]11;#203040\a')" ] # running, as working
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
