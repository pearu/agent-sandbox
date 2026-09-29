#!/usr/bin/env bats
# The post-run keeper check (tests/helpers/keeper-leaks.sh), which tests/run.sh runs
# after the suites. Its predecessor, the holder check, exists because 128 orphaned
# overlay holders once accumulated in two days of running this suite without anything
# noticing; a keeper that outlives its joins is the same leak in the new shape.
#
# A fake keeper is a process whose argv[0] is `agent-sandbox-keeper` -- the same
# STRUCTURE the check matches on -- started with `exec -a` over sleep, with the HOME
# the check reads from its environment.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  KL="$REPO_ROOT/tests/helpers/keeper-leaks.sh"
  export AS_KEEPER_SETTLE=2
  export AS_REAL_HOME="$BATS_TEST_TMPDIR/realhome"
  # Only this test's fake keepers: other suites may be running keepers beside it.
  export AS_KEEPER_SCOPE="$BATS_TEST_TMPDIR"
  FAKES=()
}

teardown() {
  local p
  for p in ${FAKES[@]+"${FAKES[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  return 0
}

fake_keeper() { # fake_keeper SECONDS HOME
  (HOME="$2" exec -a agent-sandbox-keeper sleep "$1") </dev/null >/dev/null 2>&1 3>&- &
  FAKES+=("$!")
  disown "$!"
  sleep 0.3
}

@test "a keeper the suite leaves running fails the check, is named, and is killed" {
  local before
  before="$("$KL" snapshot)"
  fake_keeper 60 "$BATS_TEST_TMPDIR/testhome"
  local pid="${FAKES[0]}"
  # shellcheck disable=SC2086 # a list of pids
  run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $pid"* ]]
  [[ "$output" == *"testhome"* ]]
  sleep 0.5
  [ ! -d "/proc/$pid" ]
}

@test "a keeper that ends within the settle window passes: that is the grace working" {
  local before
  before="$("$KL" snapshot)"
  fake_keeper 1 "$BATS_TEST_TMPDIR/testhome"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
}

@test "a keeper that was already running before the suite is not counted" {
  fake_keeper 60 "$BATS_TEST_TMPDIR/testhome"
  local before
  before="$("$KL" snapshot)"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ] # and it was left alone
}

@test "a REAL session's keeper started during the run is never counted or killed" {
  # Its HOME is the user's own, which no test uses.
  local before
  before="$("$KL" snapshot)"
  fake_keeper 60 "$AS_REAL_HOME"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ]
}

@test "nothing new running means no wait at all" {
  local before t0
  before="$("$KL" snapshot)"
  t0=$SECONDS
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -lt 2 ]
}
