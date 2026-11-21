#!/usr/bin/env bats
# --serve under a flood of signals (#423). The loop runs here as in tests/integration/
# serve.bats, but on the stub bwrap: the keeper's payload runs on the host, the loop's
# holder is a join that stays while that payload lives, and a turn (a -p join) ends at
# once. The flood is spread out, one signal every 10 ms until the loop is gone: signals
# sent back to back arrive as one, and what is tested is the second. Before #423 the end
# of the loop reset INT, TERM and HUP to their default before it shut the launch down,
# and the next signal killed it there: 113 of 120 floods left the loop's record, some its
# holder and the keeper too, on bash 5.2 and 5.3 alike.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  printf '[serve:worker]\nwatch = inbox.md\nprompt = p.md\n' >"$PROJ/.agent-sandbox"
  echo "Read your inbox." >"$PROJ/p.md"
  mkdir -p "$H/home/.config/agent-sandbox/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  # The join: a -p turn ends at once; the loop's holder stays joined while the keeper's
  # payload (the pid before its --) lives, as a real join ends with the sandbox.
  cat >"$H/bin/join-hold.py" <<'PY'
import os, sys, time
a = sys.argv[1:]
t = int(a[a.index("--") - 1])
if "-p" not in a:
    while True:
        try:
            os.kill(t, 0)
        except OSError:
            break
        time.sleep(0.05)
PY
  SERVE_PID="" HOLDER="" ME=""
}

teardown() {
  # shellcheck disable=SC2086 # pids, one word each
  [[ -z "$SERVE_PID$HOLDER$ME" ]] || kill -KILL $SERVE_PID $HOLDER $ME 2>/dev/null
  local a t
  if [[ -s "${SB:-}/keeper/id" ]]; then
    read -r a _ t _ <"$SB/keeper/id"
    kill -KILL "$a" "$t" 2>/dev/null
  fi
  return 0
}

# serve_start -- `asb --role worker --serve claude` in the background, with INT, TERM and
# HUP at their defaults, returning once it serves. Sets SERVE_PID, SB, ME (the loop's
# process, the first word of its record) and HOLDER (its holder, the engine again with
# --serve, a child of the loop).
serve_start() {
  local i f k
  engine_cmd "$H/bin/asb"
  (
    cd "$PROJ" || exit 1
    exec /usr/bin/env -i --default-signal=INT,TERM,HUP HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" \
      USER=tester TERM=xterm LANG=C.UTF-8 BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" \
      AGENT_SANDBOX_JOIN="$H/bin/join-hold.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_VERBOSE=on "${ENGINE_CMD[@]}" --role worker --serve claude
  ) </dev/null >"$H/out" 2>&1 3>&- &
  SERVE_PID=$!
  for ((i = 0; i < 600; i++)); do
    grep -q "serving" "$H/out" && break
    sleep 0.05
  done
  grep -q "serving" "$H/out"
  SB="$(echo "$H/home/.local/state/agent-sandbox/claude/"*/worker)"
  read -r ME _ <"$SB/serve"
  local -a kids=()
  for f in /proc/"$ME"/task/*/children; do
    read -ra kids 2>/dev/null <"$f" || :
    for k in ${kids[@]+"${kids[@]}"}; do
      [[ "$({ tr '\0' ' ' <"/proc/$k/cmdline"; } 2>/dev/null)" == *" --serve "* ]] && HOLDER="$k"
    done
  done
  [ -n "$HOLDER" ]
}

# flood SIG -- SIG to the loop every 10 ms until it is gone (at most 4 s), then wait for
# the engine; sets STATUS.
flood() {
  local i
  for ((i = 0; i < 400; i++)); do
    kill -s "$1" "$ME" 2>/dev/null || break
    sleep 0.01
  done
  STATUS=0
  wait "$SERVE_PID" || STATUS=$?
  SERVE_PID=""
  # shown when a test fails
  echo "the loop's status: $STATUS; its output:"
  cat "$H/out"
}

# ended_clean -- the loop ended as a signal ends it: status 0, the launch shut down (no
# keeper record, the holder gone), its record removed, and no parse error.
ended_clean() {
  local i
  [ "$STATUS" -eq 0 ]
  [[ "$(cat "$H/out")" == *"role 'worker': ended, with everything that ran in it"* ]]
  [ ! -e "$SB/serve" ]
  [ ! -e "$SB/keeper/id" ]
  for ((i = 0; i < 100; i++)); do
    kill -0 "$HOLDER" 2>/dev/null || break
    sleep 0.05
  done
  run ! kill -0 "$HOLDER"
  HOLDER="" ME=""
  run ! grep -q "unexpected EOF" "$H/out"
}

@test "--serve: a flood of TERM ends the loop as one TERM does: the launch shut down, its record removed (#423)" {
  serve_start
  flood TERM
  ended_clean
}

@test "--serve: a flood of INT ends the loop as one INT does: the launch shut down, its record removed (#423)" {
  serve_start
  flood INT
  ended_clean
}

@test "bash 5.2: a flood of TERM on --serve ends the loop cleanly (#423)" {
  bash52
  ln -sf "$BASH52" "$H/bin/bash"
  serve_start
  flood TERM
  ended_clean
}

@test "bash 5.2: a flood of INT on --serve ends the loop cleanly (#423)" {
  bash52
  ln -sf "$BASH52" "$H/bin/bash"
  serve_start
  flood INT
  ended_clean
}
