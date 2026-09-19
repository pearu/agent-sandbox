#!/usr/bin/env bats
# The connections suite's assertion logic (probes/connections/lib.sh).
#
# Why this is worth a test when the suite itself runs: conn_expect is what turns an
# observation into pass or fail, so a bug in it makes every cell of the acceptance
# suite meaningless while the suite still reports a tidy score. That is this repo's own
# lesson about a check that cannot go red, applied to the check that grades the checks.
#
# The multi-value form ("absent|unreachable") is where the trap is. Matching by
# substring would accept `obtained` for `not-obtained-absent`, which is the exact
# opposite verdict -- the padded-delimiter comparison exists to stop that, and the
# cases below fail if anyone simplifies it away.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  # Sourcing is safe: both libraries only assign variables and define functions.
  # shellcheck source=probes/connections/lib.sh
  source "$REPO_ROOT/probes/connections/lib.sh"
  LEAK_RUN="$BATS_TEST_TMPDIR/run"
  mkdir -p "$LEAK_RUN/records"
  CONN_SUITE=test CONN_ID=X CONN_MODE=copy CONN_DESC=d CONN_LAUNCH=1
  CONN_PASS=0 CONN_FAIL=0 CONN_TODO=0 CONN_SKIP=0
  CONN_BLOCKED=0 CONN_CTRL_OK=0 CONN_CTRL_BAD=0
  CONN_READER_OUT=/dev/null
}

# assert_status EXPECTED ACTUAL WANT -- run one assertion and check what it recorded.
#
# NOT `[ "$(status_of ...)" = pass ]`: a command substitution is a subshell, so the
# counters conn_expect increments would be lost and every counter assertion in this
# file would pass whatever the code did. (The same shape as this repo's $BASHPID
# pitfall.) conn_expect therefore runs in the test's own shell, and the status is read
# back from the record it wrote.
assert_status() {
  CONN_VERDICT="$2"
  conn_expect "$1" "an assertion" >/dev/null
  local n=$((CONN_PASS + CONN_FAIL + CONN_TODO + CONN_BLOCKED + \
    CONN_CTRL_OK + CONN_CTRL_BAD)) got
  got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' \
    "$LEAK_RUN/records/X-$n.json")"
  [ "$got" = "$3" ]
}

@test "a verdict that matches is a pass, one that does not is a fail, and the counters follow" {
  assert_status obtained obtained pass
  [ "$CONN_PASS" -eq 1 ]
  assert_status obtained not-obtained-absent fail
  [ "$CONN_FAIL" -eq 1 ]
  [ "$CONN_PASS" -eq 1 ] # the pass counter did not move on a failure
}

@test "a multi-value expectation accepts each alternative and nothing else" {
  local closed="not-obtained-absent|not-obtained-unreachable"
  assert_status "$closed" not-obtained-absent pass
  assert_status "$closed" not-obtained-unreachable pass
  assert_status "$closed" obtained fail
  assert_status "$closed" invalid-reader-output fail
}

@test "matching is by whole verdict, never by substring: 'obtained' is not 'not-obtained-absent'" {
  # Both directions of the trap. A substring comparison would call the first a pass
  # (obtained is inside not-obtained-absent) and the second one too.
  assert_status not-obtained-absent obtained fail
  assert_status not-obtained-absent absent fail
  assert_status obtained not-obtained-absent fail
}

@test "an empty verdict is a failure, not a pass: a launch that produced nothing is not a result" {
  assert_status obtained "" fail
}

@test "a skipped cell records not-implemented whatever the verdict says, and never counts as a pass" {
  CONN_SKIP=1
  assert_status obtained obtained not-implemented
  [ "$CONN_PASS" -eq 0 ]
  [ "$CONN_TODO" -eq 1 ]
  assert_status obtained not-obtained-absent not-implemented
  [ "$CONN_FAIL" -eq 0 ]
}

@test "a host-side assertion compares exactly, and is also suppressed by a skip" {
  conn_expect_host abc abc "a host assertion" >/dev/null
  [ "$CONN_PASS" -eq 1 ]
  conn_expect_host abc abd "a host assertion" >/dev/null
  [ "$CONN_FAIL" -eq 1 ]
  CONN_SKIP=1
  conn_expect_host abc abc "a host assertion" >/dev/null
  [ "$CONN_TODO" -eq 1 ]
  [ "$CONN_PASS" -eq 1 ] # the skipped one did not add a pass
}

@test "blocked is counted apart from not-implemented: one is unmeasurable, the other unbuilt" {
  conn_blocked "needs a host this one is not" >/dev/null
  [ "$CONN_BLOCKED" -eq 1 ]
  [ "$CONN_TODO" -eq 0 ]
  [ "$CONN_PASS" -eq 0 ]
  [ "$CONN_FAIL" -eq 0 ]
  run python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["status"],"|",d["assertion"])' \
    "$LEAK_RUN/records/X-1.json"
  [[ "$output" == "blocked | needs a host this one is not" ]]
}

@test "a control is recorded but kept out of the acceptance score" {
  CONN_READER=/dev/null
  printf '{"open":"ok","token_found":true}' >"$BATS_TEST_TMPDIR/r.json"
  conn_control "$BATS_TEST_TMPDIR/r.json" obtained "positive control" >/dev/null
  [ "$CONN_CTRL_OK" -eq 1 ]
  [ "$CONN_PASS" -eq 0 ]
  conn_control "$BATS_TEST_TMPDIR/r.json" not-obtained-absent "isolation check" >/dev/null
  [ "$CONN_CTRL_BAD" -eq 1 ]
  [ "$CONN_FAIL" -eq 0 ] # a bad control is not a broken promise; the gate handles it
}

@test "a skipped assertion carries no reader evidence, so it cannot look like a broken launch" {
  CONN_SKIP=1
  CONN_READER_OUT="" # what conn_cell leaves after a skipped cell
  CONN_VERDICT=""
  conn_expect obtained "an assertion" >/dev/null
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["status"], "reader" in d, d.get("verdict", "<none>"))
' "$LEAK_RUN/records/X-1.json"
  [[ "$output" == "not-implemented False <none>" ]]
}

@test "the said assertions read the launch stderr, and their absence is not silently a pass" {
  CONN_LAUNCH_SAID="$BATS_TEST_TMPDIR/said.err"
  printf 'agent-sandbox: kept your CLAUDE.md; the source changed\n' >"$CONN_LAUNCH_SAID"
  conn_expect_said 'CLAUDE\.md' "names the file" >/dev/null
  [ "$CONN_PASS" -eq 1 ]
  conn_expect_said 'rules/topic\.md' "names a file it did not" >/dev/null
  [ "$CONN_FAIL" -eq 1 ]
  conn_expect_said_not 'rules/topic\.md' "does not name an unrelated file" >/dev/null
  [ "$CONN_PASS" -eq 2 ]
  conn_expect_said_not 'CLAUDE\.md' "wrongly claims the warning is gone" >/dev/null
  [ "$CONN_FAIL" -eq 2 ]
}

@test "with no launch stderr at all, NEITHER direction passes: nothing to read is not evidence" {
  # The trap this closes: `said_not` used to hold whenever no launch had spoken, so it
  # looked strongest in exactly the case where it established least. A missing stderr is
  # now its own answer and satisfies neither assertion.
  CONN_LAUNCH_SAID=""
  conn_expect_said 'CLAUDE\.md' "no launch said anything" >/dev/null
  conn_expect_said_not 'CLAUDE\.md' "and nothing is there to name it" >/dev/null
  [ "$CONN_FAIL" -eq 2 ]
  [ "$CONN_PASS" -eq 0 ]
  run python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["actual"])' \
    "$LEAK_RUN/records/X-2.json"
  [ "$output" = "no launch" ]
}

@test "a host-side control is recorded as a control, whichever way it goes" {
  conn_control_host "$HOME" "$HOME" "the sandbox sees the right HOME" >/dev/null
  [ "$CONN_CTRL_OK" -eq 1 ]
  conn_control_host "$HOME" /somewhere/else "the sandbox sees the right HOME" >/dev/null
  [ "$CONN_CTRL_BAD" -eq 1 ]
  [ "$CONN_PASS" -eq 0 ]
  [ "$CONN_FAIL" -eq 0 ]
}

@test "every record carries the fields that identify the cell, so a result can be read back" {
  CONN_VERDICT=obtained
  conn_expect obtained "an assertion" >/dev/null
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("suite", "cell", "channel", "mode", "source", "role", "preset",
          "launch", "assertion", "expected", "actual", "status", "cell_desc",
          "claude_version", "engine_version"):
    assert k in d, k
print(d["mode"], d["expected"], d["actual"], d["status"])
' "$LEAK_RUN/records/X-1.json"
  [ "$status" -eq 0 ]
  [ "$output" = "copy obtained obtained pass" ]
}
