#!/usr/bin/env bats
# probes/orphans.sh (#127): a keeper payload whose parent is gone is found, and killed
# only with --kill; one that still has its parent is never listed. So is a strict keeper
# whose supervisor is gone (#430): an orphaned pasta with a keeper payload below it, and
# an orphaned watcher.

# Not in parallel within this file: `orphans.sh --kill` ends every orphaned keeper
# payload on the machine, a sibling test's included (measured under bats --jobs 18).
#
# Host only, the whole file: `--kill` ends every keeper payload whose parent is pid 1,
# and inside a sandbox the role's own keeper payload is one (its bwrap is pid 1 there):
# a run inside a role killed the role, its agent with it (measured on ey). Skipped in
# setup_file, before any test can start.
setup_file() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  require_host "probes/orphans.sh acts on every process it can see, and inside a sandbox the role's own keeper is an orphan to it"
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  O="$REPO_ROOT/probes/orphans.sh"
}

teardown() {
  [[ -n "${KID:-}" ]] && kill -KILL "$KID" 2>/dev/null
  [[ -n "${LIVE:-}" ]] && kill -KILL "$LIVE" 2>/dev/null
  [[ -n "${PASTA:-}" ]] && kill -KILL "$PASTA" 2>/dev/null
  [[ -n "${TIE:-}" ]] && kill -KILL "$TIE" 2>/dev/null
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

# A stand-in for strict's pasta: a script named pasta (its name is the process's comm)
# that starts a keeper payload and waits, as pasta waits for bwrap.
fake_pasta() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nbash -c "exec -a agent-sandbox-keeper sleep 300; :" &\nwait\n' >"$BATS_TEST_TMPDIR/bin/pasta"
  chmod +x "$BATS_TEST_TMPDIR/bin/pasta"
}

# payload_below PID -- set KID to PID's child that is a keeper payload, once it is there
payload_below() {
  local i c f
  local -a k
  for ((i = 0; i < 100; i++)); do
    for f in /proc/"$1"/task/*/children; do
      k=()
      { read -r -a k <"$f"; } 2>/dev/null || :
      for c in ${k[@]+"${k[@]}"}; do
        [[ "$(tr '\0' ' ' <"/proc/$c/cmdline" 2>/dev/null)" == "agent-sandbox-keeper 300 " ]] && KID="$c" && return 0
      done
    done
    sleep 0.02
  done
  return 1
}

# orphan_strict -- a strict keeper whose supervisor is gone: the pasta reparented, the
# payload below it still its child. Sets PASTA and KID.
orphan_strict() {
  fake_pasta
  local f="$BATS_TEST_TMPDIR/pasta.pid"
  (
    setsid "$BATS_TEST_TMPDIR/bin/pasta" </dev/null >/dev/null 2>&1 &
    echo $! >"$f"
  )
  PASTA="$(cat "$f")"
  payload_below "$PASTA"
}

@test "a strict keeper whose supervisor is gone is listed: an orphaned pasta, a keeper payload below it (#430)" {
  orphan_strict
  run "$O"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $KID: strict keeper payload, its supervisor gone (pasta $PASTA orphaned)"* ]]
  kill -0 "$PASTA"
  kill -0 "$KID"
}

@test "--kill ends its pasta and the payload" {
  orphan_strict
  run "$O" --kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $KID: strict keeper payload"*"killed"* ]]
  local i
  for ((i = 0; i < 100; i++)); do
    kill -0 "$PASTA" 2>/dev/null || kill -0 "$KID" 2>/dev/null || break
    sleep 0.02
  done
  run ! kill -0 "$PASTA"
  run ! kill -0 "$KID"
}

@test "a strict keeper whose pasta still has its parent (a live supervisor) is not listed" {
  fake_pasta
  "$BATS_TEST_TMPDIR/bin/pasta" 3>&- &
  PASTA=$!
  payload_below "$PASTA"
  run "$O"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pid $KID:"* ]]
}

@test "a strict keeper's watcher whose supervisor is gone is listed, and --kill ends it; one with its parent is not" {
  local f="$BATS_TEST_TMPDIR/tie.pid" i
  (
    setsid bash -c 'sleep 300; :' agent-sandbox-tie 1 2 3 </dev/null >/dev/null 2>&1 &
    echo $! >"$f"
  )
  TIE="$(cat "$f")"
  bash -c 'sleep 300; :' agent-sandbox-tie 1 2 3 3>&- &
  LIVE=$!
  for ((i = 0; i < 100; i++)); do
    [[ "$(tr '\0' ' ' <"/proc/$TIE/cmdline" 2>/dev/null)" == *" agent-sandbox-tie 1 2 3 " ]] && break
    sleep 0.02
  done
  run "$O"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $TIE: strict keeper's watcher, its supervisor gone"* ]]
  [[ "$output" != *"pid $LIVE:"* ]]
  run "$O" --kill
  [[ "$output" == *"pid $TIE: strict keeper's watcher"*"killed"* ]]
  for ((i = 0; i < 100; i++)); do
    kill -0 "$TIE" 2>/dev/null || break
    sleep 0.02
  done
  run ! kill -0 "$TIE"
  kill -0 "$LIVE"
}
