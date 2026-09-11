#!/usr/bin/env bats
# The test harness itself. A broken assertion is worse than a missing one: it
# reports a guarantee nobody is checking, and the suite stays green while the
# thing it claims to protect rots.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
}

@test "run ! fails the test when the command succeeds, and passes when it fails" {
  # The suite's every negative assertion is `run ! cmd`. On bats < 1.5.0 the
  # `!` is not a flag but a command, which does not exist, so `run` records
  # status 127 and returns 0 -- and the test passes without checking anything.
  # bats_require_minimum_version in the helper refuses such a bats; this proves
  # the idiom is live on the bats actually running, by running it and reading
  # the report rather than trusting the version string.
  local t="$BATS_TEST_TMPDIR/probe.bats"
  cat >"$t" <<BATS
setup() { load "$BATS_TEST_DIRNAME/../helpers/common"; }
@test "negative assertion that should fail" { run ! true; }
@test "negative assertion that should pass" { run ! false; }
BATS
  run bats "$t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ok 1 negative assertion that should fail"* ]]
  [[ "$output" == *"ok 2 negative assertion that should pass"* ]]
  [[ "$output" != *"BW02"* ]] # the version floor is declared, so no warning either
}
