#!/usr/bin/env bats
# The context file under --serve (#456): after each turn the loop hands the turn's output
# to the profile's profile_serve_result, which prints the result's text, writes the
# window from it into the role's context file, and names a turn the context limit
# stopped -- in the role's messages, instead of "turn failed (exit N)". The loop runs on
# the stub bwrap, as in serve-signals.bats: the keeper's payload on the host, the holder
# a join that stays while it lives, and a turn a -p join that prints $H/result and exits
# with the status in $H/rc.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  printf '%s\n' '[serve:worker]' 'watch = inbox.md' 'prompt = p.md' \
    '[briefing]' 'context = .asb/coord/{role}/context' >"$PROJ/.agent-sandbox"
  echo "Read your inbox." >"$PROJ/p.md"
  mkdir -p "$H/home/.config/agent-sandbox/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  cat >"$H/bin/join-turn.py" <<'PY'
import os, sys, time
a = sys.argv[1:]
t = int(a[a.index("--") - 1])
h = os.environ["TURN_DIR"]
if "-p" not in a:
    while True:
        try:
            os.kill(t, 0)
        except OSError:
            break
        time.sleep(0.05)
    sys.exit(0)
with open(os.path.join(h, "turns"), "a") as f:
    f.write(" ".join(a) + "\n")
with open(os.path.join(h, "result")) as f:
    sys.stdout.write(f.read())
with open(os.path.join(h, "rc")) as f:
    sys.exit(int(f.read()))
PY
  C="$PROJ/.asb/coord/worker/context"
  SERVE_PID="" ME=""
}

teardown() {
  if [[ -n "${ME:-}" ]]; then
    kill -TERM "$ME" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null
  fi
  local a t
  if [[ -s "${SB:-}/keeper/id" ]]; then
    read -r a _ t _ <"$SB/keeper/id"
    kill -KILL "$a" "$t" 2>/dev/null
  fi
  return 0
}

# serve_start -- `asb --role worker --serve claude` in the background, returning once it
# serves; SERVE_PID, SB, ME (the loop's process).
serve_start() {
  local i
  engine_cmd "$H/bin/asb"
  (
    cd "$PROJ" || exit 1
    exec /usr/bin/env -i --default-signal=INT,TERM,HUP HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" \
      USER=tester TERM=xterm LANG=C.UTF-8 BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" TURN_DIR="$H" \
      AGENT_SANDBOX_JOIN="$H/bin/join-turn.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared "${ENGINE_CMD[@]}" --role worker --serve claude
  ) </dev/null >"$H/out" 2>&1 3>&- &
  SERVE_PID=$!
  for ((i = 0; i < 600; i++)); do
    grep -q "serving" "$H/out" && break
    sleep 0.05
  done
  grep -q "serving" "$H/out"
  SB="$(echo "$H/home/.local/state/agent-sandbox/claude/"*/worker)"
  read -r ME _ <"$SB/serve"
}

# turn N TEXT -- write the inbox, and wait until the loop has run N turns and its output
# holds TEXT: its waiting line, which comes once the turn is over, or the result's text,
# which comes before the context file's update (settled waits for that)
turn() {
  local i
  echo "message $1" >>"$PROJ/inbox.md"
  for ((i = 0; i < 400; i++)); do
    [[ "$({ wc -l <"$H/turns"; } 2>/dev/null)" -ge "$1" ]] && grep -qF -- "$2" "$H/out" && return 0
    sleep 0.05
  done
  cat "$H/out"
  return 1
}

# settled -- wait (up to 20 s) until the role's session file holds the first turn's
# session, the id of its --session-id. The loop prints the turn's text from inside
# profile_serve_result, before that hook updates the context file, so the text alone is
# no sign that the update is over; the loop writes the session file after the hook has
# returned (a new session whose turn ended with 0). From here the context file is as the
# turn left it: updated, or left alone for good.
settled() {
  local i id s=""
  id="$(sed -n '1s/.* --session-id \([^ ]*\) .*/\1/p' "$H/turns")"
  if [[ -z "$id" ]]; then
    cat "$H/turns"
    return 1
  fi
  for ((i = 0; i < 400; i++)); do
    { IFS= read -r s <"$PROJ/.asb/coord/worker/session"; } 2>/dev/null || :
    [[ "$s" == "$id" ]] && return 0
    sleep 0.05
  done
  cat "$H/out"
  return 1
}

# ended -- TERM the loop, as teardown does, and wait for the launch to end: the loop
# notes a TERM and ends between turns, so the turn's iteration has run to its end, the
# role's messages included
ended() {
  kill -TERM "$ME"
  wait "$SERVE_PID"
  ME=""
}

# messages ERE -- wait (up to 20 s) for a line of the role's messages that matches ERE:
# the loop says the turn's end on its output before it appends that line
messages() {
  local i
  for ((i = 0; i < 400; i++)); do
    grep -qE -- "$1" "$PROJ/.asb/coord/worker/messages.md" 2>/dev/null && return 0
    sleep 0.05
  done
  cat "$PROJ/.asb/coord/worker/messages.md"
  return 1
}

# result TERMINAL_REASON TEXT -- the next turn's JSON result, as Claude Code 2.1.311 prints it
result() {
  printf '{"type":"result","is_error":%s,"result":"%s","session_id":"x","modelUsage":{"claude-main":{"inputTokens":150000,"contextWindow":1000000,"maxOutputTokens":12000}},"terminal_reason":"%s"}\n' \
    "$([[ "$1" == completed ]] && echo false || echo true)" "$2" "$1" >"$H/result"
}

@test "--serve: each turn runs with the JSON result's words; the loop prints the result's text and writes the window and the stop into the role's context file" {
  mkdir -p "${C%/*}"
  printf 'level=? tokens=50000 window=? stop=? left=? used=? turn=? maxturn=? session=s1 at=2026-11-23T00:00:00Z\n' >"$C"
  result completed "Done: the Handoff is written."
  echo 0 >"$H/rc"
  serve_start
  turn 1 "Done: the Handoff is written."
  settled
  [[ "$(sed -n 1p "$H/turns")" == *" -p --session-id "*" --permission-mode bypassPermissions --output-format json Read your inbox." ]]
  run ! grep -qF '"result"' "$H/out" # the text, not the JSON
  local l
  IFS= read -r l <"$C"
  [ "${l% at=*}" = "level=ok tokens=50000 window=1000000 stop=985000 left=935000 used=5% turn=? maxturn=? session=s1" ]
  [ "$(cat "$C.level")" = ok ]
  ended
  [ ! -e "$PROJ/.asb/coord/worker/messages.md" ]
}

@test "--serve: the loop's update of the context file uses the role's levels" {
  printf '%s\n' '[agent]' 'context-plan = 50%' >>"$PROJ/.agent-sandbox"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  mkdir -p "${C%/*}"
  printf 'level=? tokens=500000 window=? stop=? left=? used=? turn=? maxturn=? session=s1 at=x\n' >"$C"
  result completed "Done."
  echo 0 >"$H/rc"
  serve_start
  turn 1 "Done."
  settled
  [ "$(cat "$C.level")" = plan ] # 500000 of the stop 985000, 50.7 %: plan at 50 %, ok at the default 85 %
}

@test "--serve: a turn the context limit stopped is said so in the role's messages, and its context file says stopped" {
  mkdir -p "${C%/*}"
  printf 'level=rescue tokens=960000 window=1000000 stop=977000 left=17000 used=98%% turn=+9000 maxturn=9000 session=s1 at=2026-11-23T00:00:00Z\n' >"$C"
  result blocking_limit "Prompt is too long"
  echo 1 >"$H/rc"
  serve_start
  turn 1 "waiting for the next change"
  grep -qF "role 'worker': the turn ended with status 1, stopped at the context limit (blocking_limit); waiting for the next change" "$H/out"
  grep -qxF "Prompt is too long" "$H/out"
  messages "^turn stopped at the context limit \(blocking_limit\) for a change to inbox.md at [0-9T:+-]+; the loop waits for the next message$"
  run ! grep -qF "turn failed" "$PROJ/.asb/coord/worker/messages.md"
  [ "$(cat "$C.level")" = stopped ]
  # another failure is still "turn failed (exit N)"
  result completed "Something else broke."
  echo 3 >"$H/rc"
  turn 2 "the turn ended with status 3; waiting"
  messages "^turn failed \(exit 3\) for a change to inbox.md at "
}

@test "--serve: with no context file there (its writers made none), the loop makes none" {
  result completed "Done."
  echo 0 >"$H/rc"
  serve_start
  turn 1 "Done."
  settled
  [ ! -e "$C" ]
  [ ! -e "$C.level" ]
}

@test "--serve: a context directory that is a link out of the project is not written through, from the host" {
  # (not the role's own directory, whose link --serve refuses outright)
  printf '%s\n' '[serve:worker]' 'watch = inbox.md' 'prompt = p.md' \
    '[briefing]' 'context = .asb/ctx/{role}/context' >"$PROJ/.agent-sandbox"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  mkdir -p "$PROJ/.asb/ctx" "$H/elsewhere"
  printf 'level=? tokens=50000 window=? stop=? left=? used=? turn=? maxturn=? session=s1 at=x\n' >"$H/elsewhere/context"
  ln -s "$H/elsewhere" "$PROJ/.asb/ctx/worker"
  result completed "Done."
  echo 0 >"$H/rc"
  serve_start
  turn 1 "Done."
  settled
  [ "$(cat "$H/elsewhere/context")" = "level=? tokens=50000 window=? stop=? left=? used=? turn=? maxturn=? session=s1 at=x" ]
  [ ! -e "$H/elsewhere/context.level" ]
}
