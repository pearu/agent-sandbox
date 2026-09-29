#!/usr/bin/env bats
# probes/orphans.sh (#127): a keeper payload whose parent is gone is found, and killed
# only with --kill; one that still has its parent is never listed.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  O="$REPO_ROOT/probes/orphans.sh"
}

teardown() {
  [[ -n "${KID:-}" ]] && kill -KILL "$KID" 2>/dev/null
  [[ -n "${LIVE:-}" ]] && kill -KILL "$LIVE" 2>/dev/null
  return 0
}

# an orphaned keeper payload: started through a parent that exits at once, so it is
# reparented, as one is when whatever launched it was killed
orphan_keeper() {
  local f="$BATS_TEST_TMPDIR/kid"
  (
    setsid bash -c 'exec -a agent-sandbox-keeper sleep 300' </dev/null >/dev/null 2>&1 &
    echo $! >"$f"
  )
  KID="$(cat "$f")"
  local i
  for ((i = 0; i < 100; i++)); do
    [[ "$(tr '\0' ' ' <"/proc/$KID/cmdline" 2>/dev/null)" == "agent-sandbox-keeper 300 " ]] && return 0
    sleep 0.02
  done
  return 1
}

@test "an orphaned keeper payload is listed, and left running without --kill" {
  orphan_keeper
  run "$O"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $KID: keeper payload"* ]]
  kill -0 "$KID"
}

@test "--kill ends it" {
  orphan_keeper
  run "$O" --kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $KID: keeper payload"*"killed"* ]]
  local i
  for ((i = 0; i < 100; i++)); do
    kill -0 "$KID" 2>/dev/null || break
    sleep 0.02
  done
  run ! kill -0 "$KID"
}

@test "a keeper payload that still has its parent is not an orphan" {
  bash -c 'exec -a agent-sandbox-keeper sleep 300' &
  LIVE=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ "$(tr '\0' ' ' <"/proc/$LIVE/cmdline" 2>/dev/null)" == "agent-sandbox-keeper 300 " ]] && break
    sleep 0.02
  done
  run "$O"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pid $LIVE:"* ]]
}

@test "an unknown argument is refused" {
  run "$O" --bogus
  [ "$status" -eq 2 ]
}
