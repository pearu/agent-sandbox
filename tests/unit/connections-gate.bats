#!/usr/bin/env bats
# The connections study's validity gate (probes/connections/validate.py).
#
# A gate that cannot refuse is worse than no gate: it converts "nobody checked" into
# "checked and fine". So every check below is exercised in both directions — a run that
# should pass and a run that should be refused for that one reason — and the refusal is
# matched by name, so a check silently renamed or dropped shows up here rather than as a
# quietly greener suite.
#
# The distinction the gate exists to hold: a FAILED ASSERTION is a result (the engine
# broke a promise it makes), while a failed control, a version that moved mid-run or a
# write into the real config make every verdict in the run unsafe to read, passes
# included. The first must not invalidate; the rest must.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  GATE="$REPO_ROOT/probes/connections/validate.py"
  RUN="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN/records"
}

# rec FILE KEY=VALUE... -- one record, defaulting to a well-formed passing assertion.
rec() {
  local file="$1"
  shift
  python3 - "$RUN/records/$file" "$@" <<'PY'
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
d = {"suite": "s", "cell": "C1", "channel": "instructions", "mode": "copy",
     "source": "native", "role": "default", "preset": "n/a", "launch": "1",
     "assertion": "a", "expected": "obtained", "actual": "obtained",
     "status": "pass", "verdict": "obtained",
     "claude_version": "2.1.277", "engine_version": "0.2.1"}
for p in pairs:
    k, _, v = p.partition("=")
    d[k] = v
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh)
PY
}

controls_for() { # controls_for CELL -- the two control records a ran cell must carry
  rec "$1-ctl1.json" cell="$1" status=control-pass
  rec "$1-ctl2.json" cell="$1" status=control-pass
}

gate() { run python3 "$GATE" "$RUN" "$@"; }

@test "a well-formed run with controls is valid" {
  rec a.json
  controls_for C1
  gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}

@test "a FAILED ASSERTION is a result, not an invalid run: the engine broke a promise" {
  rec a.json status=fail actual=not-obtained-absent
  controls_for C1
  gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}

@test "a control that did not hold refuses the run" {
  rec a.json
  rec ctl.json status=control-fail
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"every control held"*FAIL* ]]
}

@test "a cell that ran without controls refuses the run" {
  rec a.json cell=C7
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"carries its controls"*FAIL* ]]
  [[ "$output" == *C7* ]]
}

@test "an unreadable reader result from a launch refuses the run" {
  rec a.json verdict=invalid-reader-output
  controls_for C1
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no invalid reader output"*FAIL* ]]
}

@test "the same on a NOT-IMPLEMENTED record does not, because no launch ran" {
  # The harness no longer attaches reader evidence to a recorded expectation; a run made
  # before that fix still carries it, and it must not be read as a broken experiment.
  rec a.json status=not-implemented verdict=invalid-reader-output actual=
  gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}

@test "two Claude Code versions in one run refuse it: a score may not span two subjects" {
  rec a.json
  rec b.json claude_version=2.1.300
  controls_for C1
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"one claude across the run"*FAIL* ]]
}

@test "two engine versions in one run refuse it" {
  rec a.json
  rec b.json engine_version=0.3.0
  controls_for C1
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"one engine across the run"*FAIL* ]]
}

@test "a missing version refuses the run" {
  rec a.json claude_version=
  controls_for C1
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"one claude across the run"*FAIL* ]]
}

@test "a real-config change attributable to this run refuses it" {
  rec a.json
  controls_for C1
  printf 'content\t%s/.claude/CLAUDE.md\n' "$HOME" >"$RUN/real-attributable"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"the real config carries nothing from this run"*FAIL* ]]
}

@test "a known-ambient path in that list does not refuse it" {
  rec a.json
  controls_for C1
  printf 'content\t%s/.claude/responses.log\n' "$HOME" >"$RUN/real-attributable"
  gate --known-ambient 'responses\.log'
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}

@test "a status the gate does not know refuses the run, so harness and gate cannot drift" {
  rec a.json status=probably-fine
  controls_for C1
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"every status is one this gate knows"*FAIL* ]]
  [[ "$output" == *probably-fine* ]]
}

@test "an empty run refuses, and unparseable records are named" {
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"records present"*FAIL* ]]
  printf 'not json' >"$RUN/records/bad.json"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"records readable"*FAIL* ]]
  [[ "$output" == *bad.json* ]]
}

@test "a run where every cell was skipped is valid: nothing launched, so nothing to control" {
  rec a.json status=not-implemented actual= verdict=
  rec b.json status=blocked actual="cannot run here" verdict=
  gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}

@test "the gate writes its verdict beside the records, for a reader who was not there" {
  rec a.json
  rec ctl.json status=control-fail
  gate
  [ -f "$RUN/validity.json" ]
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["valid"] is False
print([c["name"] for c in d["checks"] if not c["pass"]])
' "$RUN/validity.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"every control held"* ]]
}
