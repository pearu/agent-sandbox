#!/usr/bin/env bats
# The post-run holder check (tests/helpers/holder-leaks.sh), which tests/run.sh runs
# after the suites. It exists because 128 orphaned holders once accumulated in two days
# of running this suite without anything noticing.
#
# A fake holder is a process whose argv[0] is `bwrap` and whose arguments carry
# --overlay-src -- the same STRUCTURE the check matches on. It is a python3 process
# started with `exec -a bwrap`, which ignores its extra arguments and is one process,
# so killing it leaves nothing behind.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  HL="$REPO_ROOT/tests/helpers/holder-leaks.sh"
  export AS_HOLDER_SETTLE=2
  export AS_REAL_STATE="$BATS_TEST_TMPDIR/realstate"
  FAKES=()
}

teardown() {
  local p
  for p in ${FAKES[@]+"${FAKES[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  return 0
}

fake_holder() { # fake_holder SECONDS UPPER
  (exec -a bwrap python3 -c "import time; time.sleep($1)" \
    --overlay-src "$BATS_TEST_TMPDIR/gone-src" --overlay "$2" /w /m) \
    </dev/null >/dev/null 2>&1 3>&- &
  FAKES+=("$!")
  disown "$!"
  sleep 0.3
}

@test "a holder the suite leaves running fails the check, is named, and is killed" {
  local before
  before="$("$HL" snapshot)"
  fake_holder 60 "$BATS_TEST_TMPDIR/upper"
  local pid="${FAKES[0]}"
  # shellcheck disable=SC2086 # a list of pids
  run "$HL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $pid"* ]]
  [[ "$output" == *"gone-src"* ]]
  sleep 0.5
  [ ! -d "/proc/$pid" ]
}

@test "a holder that exits within the settle window passes: that is the fix working" {
  local before
  before="$("$HL" snapshot)"
  fake_holder 1 "$BATS_TEST_TMPDIR/upper"
  # shellcheck disable=SC2086
  run "$HL" check $before
  [ "$status" -eq 0 ]
}

@test "a holder that was already running before the suite is not counted" {
  fake_holder 60 "$BATS_TEST_TMPDIR/upper"
  local before
  before="$("$HL" snapshot)"
  # shellcheck disable=SC2086
  run "$HL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ] # and it was left alone
}

@test "a REAL session's holder started during the run is never counted or killed" {
  # Its upper layer is under the user's own state directory, which no test uses.
  local before
  before="$("$HL" snapshot)"
  fake_holder 60 "$AS_REAL_STATE/claude/-proj/default/instructions/upper/x"
  # shellcheck disable=SC2086
  run "$HL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ]
}

@test "nothing new running means no wait at all" {
  local before t0
  before="$("$HL" snapshot)"
  t0=$SECONDS
  # shellcheck disable=SC2086
  run "$HL" check $before
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -lt 2 ]
}
