#!/usr/bin/env bats
# The claude profile's context file (#456): context.sh writes how full a role's context
# is, statusline.sh feeds it from the status line's stdin JSON, state-hook.sh from the
# transcript at Stop, and profile_serve_result from a --serve turn's JSON result, on the
# host. Run directly, on files of the test's own.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  P="${ENGINE%/*}/profiles/claude"
  S="$BATS_TEST_TMPDIR/state"
  C="$BATS_TEST_TMPDIR/coord/r1/context"
  mkdir -p "${C%/*}"
}

# sl TOKENS [WINDOW [SESSION [PLAN RESCUE]]] -- statusline.sh with a stdin JSON whose
# current_usage sums to TOKENS (input 2, cache-creation 1000, cache-read the rest)
sl() {
  local t="$1" w="${2:-1000000}" s="${3:-s1}"
  local j="{\"session_id\":\"$s\",\"context_window\":{\"total_input_tokens\":$t,\"context_window_size\":$w,\"current_usage\":{\"input_tokens\":2,\"output_tokens\":5,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":$((t - 1002))},\"used_percentage\":7,\"remaining_percentage\":93}}"
  run bash "$P/statusline.sh" r1 "$S" "$C" "${4:-60}" "${5:-25000}" <<<"$j"
}

# line -- the context file's line without its `at=`
line() {
  local l
  IFS= read -r l <"$C"
  printf '%s' "${l% at=*}"
}

# level -- the .level file's content
level() { cat "$C.level"; }

# fp FILE -- the file's inode and modification time: what a rewrite changes
fp() { stat -c '%i %Y.%y' -- "$1"; }

# transcript FILE TOKENS... -- a transcript with one assistant record per TOKENS (its
# usage: input 3, cache-creation 1000, cache-read the rest; its text "earlier.", the
# last one's $TXT, default "done.", the reply a Stop below ends on; each after a user
# record of its prompt, "p-earlier", the last one's $PID, default "p1"), a subagent's record
# with more after them, and a tool input whose JSON says "usage" too
transcript() {
  local f="$1" t
  shift
  : >"$f"
  for t in "$@"; do
    printf '{"type":"user","promptId":"%s","message":{"content":"x"}}\n' "$([[ "$t" == "${!#}" ]] && printf '%s' "${PID:-p1}" || printf p-earlier)" >>"$f"
    printf '{"parentUuid":"p","isSidechain":false,"message":{"model":"m","content":[{"type":"tool_use","input":{"usage":{"input_tokens":5}}},{"type":"text","text":"%s"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%s,"output_tokens":9,"output_tokens_details":{"thinking_tokens":1},"iterations":[{"input_tokens":7}]}},"type":"assistant","uuid":"u"}\n' "$([[ "$t" == "${!#}" ]] && printf '%s' "${TXT:-done.}" || printf earlier.)" "$((t - 1003))" >>"$f"
  done
  printf '%s\n' '{"isSidechain":true,"message":{"usage":{"input_tokens":999999}},"type":"assistant"}' >>"$f"
}

# hook EVENT JSON [ENV...] -- state-hook.sh with the context file in its environment
hook() {
  local ev="$1" j="$2"
  shift 2
  run env AGENT_SANDBOX_CONTEXT="$C" AGENT_SANDBOX_CONTEXT_PLAN=60 AGENT_SANDBOX_CONTEXT_RESCUE=25000 "$@" \
    bash "$P/state-hook.sh" "$ev" off "$S" <<<"$j"
}

# stop SESSION TRANSCRIPT [ENV...] -- a Stop of SESSION
stop() {
  local s="$1" t="$2"
  shift 2
  hook Stop "{\"session_id\":\"$s\",\"transcript_path\":\"$t\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"done.\"}" "$@"
}

# prompt SESSION [ENV...] -- a UserPromptSubmit of SESSION
prompt() {
  local s="$1"
  shift
  hook UserPromptSubmit "{\"session_id\":\"$s\",\"prompt\":\"go\"}" "$@"
}

@test "statusline.sh writes the context line from its stdin JSON: tokens of current_usage, the window, the stop (window - 23000), left, used of the stop, the session; .level beside it" {
  sl 612000
  [ "$status" -eq 0 ]
  [ "$(line)" = "level=plan tokens=612000 window=1000000 stop=977000 left=365000 used=62% turn=? maxturn=? session=s1" ]
  [[ "$(cat "$C")" =~ \ at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(level)" = plan ]
  [[ "$output" == *r1* ]] # the row is still printed
}

@test "statusline.sh rewrites neither file while nothing but the time would change, and .level only when the level changes" {
  sl 100000
  local a b
  a="$(fp "$C")" b="$(fp "$C.level")"
  sleep 1.1
  sl 100000
  [ "$(fp "$C")" = "$a" ]
  [ "$(fp "$C.level")" = "$b" ]
  sl 200000 # another number, the same level
  [ "$(fp "$C")" != "$a" ]
  [ "$(line)" = "level=ok tokens=200000 window=1000000 stop=977000 left=777000 used=20% turn=? maxturn=? session=s1" ]
  [ "$(fp "$C.level")" = "$b" ]
  [ "$(level)" = ok ]
}

@test "statusline.sh writes nothing while used_percentage is null (no response yet), nor without a context path" {
  run bash "$P/statusline.sh" r1 "$S" "$C" 60 25000 <<<'{"session_id":"s1","context_window":{"total_input_tokens":0,"context_window_size":1000000,"current_usage":null,"used_percentage":null,"remaining_percentage":null}}'
  [ "$status" -eq 0 ]
  [ ! -e "$C" ]
  [ ! -e "$C.level" ]
  run bash "$P/statusline.sh" r1 "$S" <<<'{"session_id":"s1","context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":5},"used_percentage":1}}'
  [ "$status" -eq 0 ]
  run ls -A "${C%/*}"
  [ -z "$output" ]
  # null used_percentage is the rule, whatever else the JSON has
  run bash "$P/statusline.sh" r1 "$S" "$C" 60 25000 <<<'{"session_id":"s1","context_window":{"total_input_tokens":5000,"context_window_size":1000000,"current_usage":{"input_tokens":5000,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"used_percentage":null}}'
  [ "$status" -eq 0 ]
  run ls -A "${C%/*}"
  [ -z "$output" ]
}

@test "the levels, at each threshold: plan from PLAN% of the stop, rescue at RESCUE tokens left or fewer, stopped at the stop; the .level file follows each" {
  sl 586199 # 60% of 977000 is 586200
  [ "$(level)" = ok ]
  sl 586200
  [ "$(level)" = plan ]
  sl 951999 # 25001 left
  [ "$(level)" = plan ]
  sl 952000 # 25000 left
  [ "$(level)" = rescue ]
  [ "$(line)" = "level=rescue tokens=952000 window=1000000 stop=977000 left=25000 used=97% turn=? maxturn=? session=s1" ]
  sl 976999
  [ "$(level)" = rescue ]
  sl 977000
  [ "$(level)" = stopped ]
  [ "$(line)" = "level=stopped tokens=977000 window=1000000 stop=977000 left=0 used=100% turn=? maxturn=? session=s1" ]
  sl 1000 # a context made smaller
  [ "$(level)" = ok ]
}

@test "the levels on a 200K window: the stop is 177000; a level of - is never reached" {
  sl 106200 200000
  [ "$(line)" = "level=plan tokens=106200 window=200000 stop=177000 left=70800 used=60% turn=? maxturn=? session=s1" ]
  sl 106199 200000
  [ "$(level)" = ok ]
  sl 160000 200000 s1 - 25000
  [ "$(level)" = rescue ]
  sl 160000 200000 s1 - -
  [ "$(level)" = ok ]
  sl 176000 200000 s1 - -
  [ "$(level)" = ok ]
  sl 177000 200000 s1 - -
  [ "$(level)" = stopped ]
}

@test "the Stop hook takes the tokens from the transcript's last assistant record that is not a subagent's; turn and maxturn from the tokens at the prompt, of this session" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  sl 100000 # the status line: the window, and the tokens at the prompt
  prompt s1
  [ "$status" -eq 0 ]
  [ "$(cat "$S.base")" = "s1 100000" ]
  transcript "$t" 110000 130000
  stop s1 "$t"
  [ "$status" -eq 0 ]
  [ -z "$output" ] # a Stop hook prints nothing but a refusal
  [ "$(line)" = "level=ok tokens=130000 window=1000000 stop=977000 left=847000 used=13% turn=+30000 maxturn=30000 session=s1" ]
  prompt s1
  transcript "$t" 140000
  stop s1 "$t"
  [ "$(line)" = "level=ok tokens=140000 window=1000000 stop=977000 left=837000 used=14% turn=+10000 maxturn=30000 session=s1" ]
  prompt s1
  transcript "$t" 190000
  stop s1 "$t"
  [ "$(line)" = "level=ok tokens=190000 window=1000000 stop=977000 left=787000 used=19% turn=+50000 maxturn=50000 session=s1" ]
}

@test "the Stop hook at a new session: turn and maxturn reset (no prompt tokens of this session), the window kept" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  sl 100000
  prompt s1
  transcript "$t" 160000
  stop s1 "$t"
  [ "$(line)" = "level=ok tokens=160000 window=1000000 stop=977000 left=817000 used=16% turn=+60000 maxturn=60000 session=s1" ]
  prompt s2 # the file is s1's: no start for s2's turn
  [ "$(cat "$S.base")" = "s2 ?" ]
  transcript "$t" 30000
  stop s2 "$t"
  [ "$(line)" = "level=ok tokens=30000 window=1000000 stop=977000 left=947000 used=3% turn=? maxturn=? session=s2" ]
  prompt s2
  transcript "$t" 35000
  stop s2 "$t"
  [ "$(line)" = "level=ok tokens=35000 window=1000000 stop=977000 left=942000 used=3% turn=+5000 maxturn=5000 session=s2" ]
}

@test "a served role's rescue level is the larger of RESCUE and twice its largest turn" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  sl 800000
  prompt s1
  transcript "$t" 840000 # a turn of 40000: rescue at 80000 left, served
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(level)" = plan ] # 137000 left
  prompt s1
  transcript "$t" 897000 # 80000 left: rescue, served
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(line)" = "level=rescue tokens=897000 window=1000000 stop=977000 left=80000 used=91% turn=+57000 maxturn=57000 session=s1" ]
  sl 897000 # the same numbers at a terminal: RESCUE alone
  [ "$(level)" = plan ]
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1 # 2 x 57000 = 114000 >= 80000
  [ "$(level)" = rescue ]
  prompt s1
  transcript "$t" 863000 # 114000 left: 2 x 57000 = 114000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(level)" = rescue ]
}

@test "the Stop hook waits for the turn's record, which Claude Code writes after the hook starts (measured, 2.1.311), and takes it" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  sl 100000
  prompt s1
  PID=p0 transcript "$t" 100000 # the previous turn's record only, with the same reply
  (
    sleep 0.5
    transcript "$t.new" 100000 170000
    mv "$t.new" "$t"
  ) 3>&- &
  stop s1 "$t"
  [ "$(line)" = "level=ok tokens=170000 window=1000000 stop=977000 left=807000 used=17% turn=+70000 maxturn=70000 session=s1" ]
  # a record that never comes: after 2 s, the last one there
  prompt s1
  local t0=$SECONDS
  hook Stop "{\"session_id\":\"s1\",\"transcript_path\":\"$t\",\"prompt_id\":\"p2\",\"last_assistant_message\":\"another reply.\"}"
  [ "$status" -eq 0 ]
  ((SECONDS - t0 >= 2))
  [ "$(line)" = "level=ok tokens=170000 window=1000000 stop=977000 left=807000 used=17% turn=+0 maxturn=70000 session=s1" ]
}

@test "without AGENT_SANDBOX_CONTEXT the hooks write no context file and no base" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  transcript "$t" 50000
  run bash "$P/state-hook.sh" UserPromptSubmit off "$S" <<<'{"session_id":"s1","prompt":"go"}'
  [ "$status" -eq 0 ]
  run bash "$P/state-hook.sh" Stop off "$S" <<<"{\"session_id\":\"s1\",\"transcript_path\":\"$t\",\"last_assistant_message\":\"done.\"}"
  [ "$status" -eq 0 ]
  [ ! -e "$S.base" ]
  run ls -A "${C%/*}"
  [ -z "$output" ]
}

@test "the Stop hook without the window: the line says ? for what follows from it, and level ?" {
  local t="$BATS_TEST_TMPDIR/t.jsonl"
  transcript "$t" 50000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(line)" = "level=? tokens=50000 window=? stop=? left=? used=? turn=? maxturn=? session=s1" ]
  [ "$(level)" = "?" ]
}

@test "context.sh reads back only numbers: a line a sandbox wrote with anything else in it runs nothing and is replaced" {
  # shellcheck disable=SC2016 # literally, as a sandbox could write it
  printf '%s\n' 'level=ok tokens=a[$(touch '"$BATS_TEST_TMPDIR"'/pwned)] window=1000000 stop=x maxturn=$(id) turn=+1;id session=s1' >"$C"
  run bash "$P/context.sh" "$C" 60 25000 1 window=1000000 maxout=128000
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ "$(line)" = "level=? tokens=? window=1000000 stop=977000 left=? used=? turn=? maxturn=? session=s1" ]
}

@test "context.sh replaces a link at the file, never writes through it" {
  printf 'mine\n' >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$C"
  run bash "$P/context.sh" "$C" 60 25000 0 tokens=1000 window=1000000 session=s1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = mine ]
  [ ! -L "$C" ]
  [ "$(line)" = "level=ok tokens=1000 window=1000000 stop=977000 left=976000 used=0% turn=? maxturn=? session=s1" ]
}

@test "context.sh never writes through a link put at its temp file's name once that name exists: on the host the directory is the sandbox's to write" {
  printf 'mine\n' >"$BATS_TEST_TMPDIR/target"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # a mktemp that puts a link to target at the name it gives, as a process watching the
  # directory (inotify) can the moment a file of that name appears
  cat >"$BATS_TEST_TMPDIR/bin/mktemp" <<STUB
#!/bin/bash
t="\$($(command -v mktemp) "\$@")" || exit
ln -sfn "$BATS_TEST_TMPDIR/target" "\$t.l" && mv -fT "\$t.l" "\$t"
printf '%s\n' "\$t"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$P/context.sh" "$C" 60 25000 1 tokens=1000 window=1000000 session=s1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = mine ]
}

# result FILE TERMINAL_REASON [IS_ERROR] -- a -p turn's JSON result, as Claude Code
# 2.1.311 prints it (abridged): the main model and a side one in modelUsage
result() {
  printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","session_id":"s1","usage":{"input_tokens":150000},"modelUsage":{"claude-small":{"inputTokens":10,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"contextWindow":200000,"maxOutputTokens":8192},"claude-main":{"inputTokens":150000,"cacheReadInputTokens":5000,"cacheCreationInputTokens":0,"contextWindow":1000000,"maxOutputTokens":12000}},"terminal_reason":"%s"}\n' \
    "${3:-false}" "$([[ "$2" == completed ]] && printf 'Done: the Handoff is written.' || printf 'Prompt is too long')" "$2" >"$1"
}

# serve_result FILE [CONTEXT] -- the profile's hook, as the engine calls it: profile.sh
# sourced, profile_home its directory; prints its output, then END=profile_serve_end
serve_result() {
  run bash -c 'profile_home="$1"; _context_plan=60 _context_rescue=25000
    source "$1/profile.sh"; profile_serve_result "$2" "$3"; printf "END=%s\n" "$profile_serve_end"' _ "$P" "$1" "${2:-}"
}

@test "profile.py serve-result: the main model's window and max output, the terminal reason, then the result's text" {
  local r="$BATS_TEST_TMPDIR/r.json"
  result "$r" completed
  run python3 "$P/profile.py" serve-result "$r"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "window=1000000 maxout=12000 reason=completed" ]
  [ "${lines[1]}" = "Done: the Handoff is written." ]
  printf 'plain text\n' >"$r"
  run python3 "$P/profile.py" serve-result "$r"
  [ "$status" -eq 1 ]
}

@test "profile_serve_result prints the result's text and, given the context file, writes the window and the stop from the model's max output into it" {
  local r="$BATS_TEST_TMPDIR/r.json" t="$BATS_TEST_TMPDIR/t.jsonl"
  transcript "$t" 50000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1 # the turn's Stop hook: no window
  result "$r" completed
  serve_result "$r" "$C"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Done: the Handoff is written." ]
  [ "${lines[1]}" = "END=" ]
  [ "$(line)" = "level=ok tokens=50000 window=1000000 stop=985000 left=935000 used=5% turn=? maxturn=? session=s1" ]
  [ "$(level)" = ok ]
  # the next turn's Stop hook keeps that stop: the same window, no max output of its own
  prompt s1
  transcript "$t" 60000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(line)" = "level=ok tokens=60000 window=1000000 stop=985000 left=925000 used=6% turn=+10000 maxturn=10000 session=s1" ]
  # and the status line's, with the same window and no max output of its own
  sl 70000
  [ "$(line)" = "level=ok tokens=70000 window=1000000 stop=985000 left=915000 used=7% turn=+10000 maxturn=10000 session=s1" ]
}

@test "profile_serve_result recomputes the level as the role's hooks do: with the role's levels, and as a served role (twice its largest turn)" {
  local r="$BATS_TEST_TMPDIR/r.json" t="$BATS_TEST_TMPDIR/t.jsonl"
  result "$r" completed
  sl 500000 # the window, and the tokens at the prompt
  prompt s1
  transcript "$t" 600000 # a turn of 100000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(level)" = plan ]
  serve_result "$r" "$C"
  [ "$(level)" = plan ] # 600000 of the stop 985000: 60.9 %
  prompt s1
  transcript "$t" 800000 # a turn of 200000: rescue at 400000 left, served
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  [ "$(level)" = rescue ]
  serve_result "$r" "$C"
  [ "$(line)" = "level=rescue tokens=800000 window=1000000 stop=985000 left=185000 used=81% turn=+200000 maxturn=200000 session=s1" ]
}

@test "profile_serve_result at the context limit (blocking_limit): profile_serve_end says so, and the context file says stopped" {
  local r="$BATS_TEST_TMPDIR/r.json" t="$BATS_TEST_TMPDIR/t.jsonl"
  transcript "$t" 950000
  stop s1 "$t" AGENT_SANDBOX_CONTEXT_SERVED=1
  result "$r" blocking_limit true
  serve_result "$r" "$C"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Prompt is too long" ]
  [ "${lines[1]}" = "END=stopped at the context limit (blocking_limit)" ]
  [ "$(line)" = "level=stopped tokens=950000 window=1000000 stop=985000 left=35000 used=96% turn=? maxturn=? session=s1" ]
  [ "$(level)" = stopped ]
}

@test "profile_serve_result: output that is not a JSON result is printed as it is; no context file is made where its writers made none; none given, none written" {
  local r="$BATS_TEST_TMPDIR/r.json"
  printf 'some text\nmore\n' >"$r"
  serve_result "$r" "$C"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "some text" ]
  [ "${lines[1]}" = more ]
  [ "${lines[2]}" = "END=" ]
  result "$r" blocking_limit true
  serve_result "$r" "$C"
  [ "${lines[1]}" = "END=stopped at the context limit (blocking_limit)" ]
  [ ! -e "$C" ]
  [ ! -e "$C.level" ]
}
