#!/usr/bin/env bats
# --serve (#277), under the REAL bwrap: a role with no terminal. The loop holds the
# role's launch, and each change to the file its [serve:ROLE] section names is one turn
# of the role's session, joined into that launch. The agent is the probe, which appends
# its argv -- the turn's arguments and the prompt -- to $PWD/turns, inside the sandbox
# (the project is bound read-write). The probe profile's turn arguments are the claude
# profile's (tests/helpers/probe-profile.sh).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v python3 >/dev/null || skip "python3 not installed"
  command -v flock >/dev/null || skip "flock not installed (util-linux)"
  make_integration <<'PROBE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PWD/turns"
# a turn that fails: the last message asks for it
[ "$(tail -n 1 "$PWD/inbox.md")" != FAIL ] || exit 3
# a turn still running when the launch ends
[ "$(tail -n 1 "$PWD/inbox.md")" != SLOW ] || sleep 30
PROBE
  W="$(cd "$IWORK" && pwd -P)"
  SB="$IHOME/.local/state/agent-sandbox/probe/$(printf '%s' "$W" | sed 's:[^A-Za-z0-9-]:-:g')/worker"
  printf '[serve:worker]\nwatch = inbox.md\nprompt = prompt.md\n' >"$W/.agent-sandbox"
  printf 'Read your inbox and act on it.\n' >"$W/prompt.md"
  : >"$W/inbox.md"
  # approved, the way --trust records it
  engine_cmd
  (cd "$W" && printf 'y\nn\n' | env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  BGS=()
}

teardown() {
  local p f spid
  : >"$W/release" 2>/dev/null
  for p in ${BGS[@]+"${BGS[@]}"}; do kill "$p" 2>/dev/null; done
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# engine NAME ENGINE-ARGS... -- run the engine from the project as the suites do, in the
# background, its output in $I/NAME.out; sets BG_PID.
engine() {
  local name="$1"
  shift
  engine_cmd
  (cd "$W" && exec env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state" \
    "${ENGINE_CMD[@]}" "$@") </dev/null >"$I/$name.out" 2>&1 3>&- &
  BG_PID=$!
  BGS+=("$BG_PID")
}

# serve -- start `--role worker --serve probe`; return once it serves. Sets SERVE_PID.
serve() {
  local i
  engine serve --role worker --serve probe
  SERVE_PID=$BG_PID
  for ((i = 0; i < 600; i++)); do
    grep -q "serving --" "$I/serve.out" 2>/dev/null && return 0
    kill -0 "$SERVE_PID" 2>/dev/null || break
    sleep 0.05
  done
  echo "serve: did not start serving:" >&2
  cat "$I/serve.out" >&2
  return 1
}

# turns N -- wait (up to 30 s) until the probe has run N turns.
turns() {
  local i
  for ((i = 0; i < 600; i++)); do
    [[ "$(cat "$W/turns" 2>/dev/null | wc -l)" -ge "$1" ]] && return 0
    sleep 0.05
  done
  echo "turns: expected $1, got:" >&2
  cat "$W/turns" >&2 2>/dev/null
  cat "$I/serve.out" >&2
  return 1
}

# recorded -- wait (up to 10 s) for the session file the first turn writes after it ends.
recorded() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -s "$W/.asb/coord/worker/session" ]] && return 0
    sleep 0.05
  done
  return 1
}

# stopped PID -- wait (up to 20 s) for PID to exit; its status in $STOPPED.
stopped() {
  local i
  for ((i = 0; i < 400; i++)); do
    kill -0 "$1" 2>/dev/null || break
    sleep 0.05
  done
  STOPPED=0
  wait "$1" || STOPPED=$?
}

status_of() { # --status of the role, in $output
  engine_cmd
  run bash -c 'cd "$1" && shift && exec "$@"' _ "$W" env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" XDG_STATE_HOME="$IHOME/.local/state" \
    "${ENGINE_CMD[@]}" --role worker "$@" probe
}

@test "--serve: a turn per write -- the first makes the session by id, the next resumes it, under bypassPermissions, told the prompt; --status shows it; --shutdown ends it" {
  serve
  printf '## 1\nwrite a.txt\n' >>"$W/inbox.md"
  turns 1
  local id
  id="$(sed -n 's/^-p --session-id \([0-9a-f-]*\) .*/\1/p' "$W/turns")"
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
  [ "$(sed -n 1p "$W/turns")" = "-p --session-id $id --permission-mode bypassPermissions Read your inbox and act on it." ]
  # the id, where the role, the Supervisor and the user find it
  recorded
  [ "$(cat "$W/.asb/coord/worker/session")" = "$id" ]
  [ -f "$W/.asb/coord/worker/alive" ]
  printf '## 2\nwhat did message 1 ask?\n' >>"$W/inbox.md"
  turns 2
  [ "$(sed -n 2p "$W/turns")" = "-p --resume $id --permission-mode bypassPermissions Read your inbox and act on it." ]
  status_of --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"serving: pid "*", a turn of session $id per change to inbox.md"* ]]
  status_of --shutdown
  [ "$status" -eq 0 ]
  stopped "$SERVE_PID"
  [ "$STOPPED" -eq 0 ]
  [[ "$(cat "$I/serve.out")" == *"its launch has ended; --serve ends with it"* ]]
  [ ! -e "$SB/keeper/id" ]
  [ ! -e "$SB/serve" ]
  [ "$(wc -l <"$W/turns")" -eq 2 ] # nothing else ran
}

@test "--serve: a later loop resumes the session it recorded, and a change made while none ran is a turn at once" {
  serve
  printf '## 1\nfirst\n' >>"$W/inbox.md"
  turns 1
  recorded
  local id
  id="$(cat "$W/.asb/coord/worker/session")"
  status_of --shutdown
  stopped "$SERVE_PID"
  printf '## 2\nwhile nobody served\n' >>"$W/inbox.md"
  serve
  turns 2
  [ "$(sed -n 2p "$W/turns")" = "-p --resume $id --permission-mode bypassPermissions Read your inbox and act on it." ]
}

@test "--serve: a turn waits while something else is joined into the role's launch, then runs" {
  serve
  # a terminal, played by an --exec joined into the same launch until released
  engine term --role worker --profile probe --exec bash -c 'touch term.in; until [ -e release ]; do sleep 0.05; done'
  local i
  for ((i = 0; i < 300; i++)); do
    [[ -e "$W/term.in" ]] && break
    sleep 0.05
  done
  [ -e "$W/term.in" ]
  printf '## 1\nwhile a terminal is on\n' >>"$W/inbox.md"
  sleep 3
  [ ! -s "$W/turns" ] # held back
  [[ "$(cat "$I/serve.out")" == *"something else is joined (pid "*"the turn waits until it has gone"* ]]
  : >"$W/release"
  turns 1
}

@test "--serve: a TERM to the loop ends the role's launch with it" {
  serve
  [ -e "$SB/keeper/id" ]
  kill -TERM "$SERVE_PID"
  local i
  for ((i = 0; i < 400; i++)); do
    [[ -e "$SB/keeper/id" || -e "$SB/serve" ]] || break
    sleep 0.05
  done
  [ ! -e "$SB/keeper/id" ]
  [ ! -e "$SB/serve" ]
}

@test "--serve: a turn that fails is one line in the role's messages, and the loop waits for the next message" {
  mkdir -p "$W/.asb/coord/worker"
  printf 'ack 0\n' >"$W/.asb/coord/worker/messages.md"
  serve
  printf '## 1\nFAIL\n' >>"$W/inbox.md"
  turns 1
  local i
  for ((i = 0; i < 200; i++)); do
    grep -q '^turn failed' "$W/.asb/coord/worker/messages.md" && break
    sleep 0.05
  done
  [ "$(sed -n 1p "$W/.asb/coord/worker/messages.md")" = "ack 0" ] # what was there stays
  [[ "$(sed -n 2p "$W/.asb/coord/worker/messages.md")" =~ ^turn\ failed\ \(exit\ 3\)\ for\ a\ change\ to\ inbox\.md\ at\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[-+][0-9:]+\;\ the\ loop\ waits\ for\ the\ next\ message$ ]]
  [ ! -s "$W/.asb/coord/worker/session" ] # no session made: the next turn starts one
  printf '## 2\nagain\n' >>"$W/inbox.md"
  turns 2
  [[ "$(sed -n 2p "$W/turns")" == "-p --session-id "* ]]
  [ "$(grep -c '^turn failed' "$W/.asb/coord/worker/messages.md")" -eq 1 ]
}

@test "--serve: a turn ended by --shutdown is not a failed turn" {
  serve
  printf '## 1\nSLOW\n' >>"$W/inbox.md"
  turns 1
  status_of --shutdown
  [ "$status" -eq 0 ]
  stopped "$SERVE_PID"
  [ "$STOPPED" -eq 0 ]
  run ! grep -q 'turn failed' "$W/.asb/coord/worker/messages.md"
}
