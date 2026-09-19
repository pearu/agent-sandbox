#!/usr/bin/env bats
# Comparing two runs of the cow suite (probes/connections/compare.py).
#
# This is W8's other half. `cow` with an overlay and `cow` fallen back to `copy` are
# claimed to be identical across launches, and `[overlay] mode = off` lets both run on one
# host so the claim can be checked directly rather than against a memory of a run on other
# hardware. The runner diffs the verdicts and fails the batch on any divergence.
#
# Which makes this the third thing in this study that reports a number nobody watches
# being computed. Today it prints zero because every cow assertion is not-implemented in
# both arrangements, so it would print zero just as happily if it compared nothing at all.
# These tests are what separates those two zeros.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  CMP="$REPO_ROOT/probes/connections/compare.py"
  A="$BATS_TEST_TMPDIR/a"
  B="$BATS_TEST_TMPDIR/b"
  mkdir -p "$A" "$B"
}

# count -- the number on stdout, with the detail lines kept off it.
#
# `run` merges stderr into $output, and this script deliberately puts the COUNT on stdout
# and the per-assertion detail on stderr so the runner can capture one with a command
# substitution while the other reaches the log. Asserting on the merged stream would
# compare the count against the count plus every difference, which fails whenever the
# script is working and passes when it finds nothing -- backwards.
count() { run bash -c "python3 '$CMP' '$1' '$2' 2>/dev/null"; }
detail() { run bash -c "python3 '$CMP' '$1' '$2' 2>&1 >/dev/null"; }

# rec DIR FILE CELL ASSERTION STATUS
rec() {
  python3 - "$1/$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, cell, assertion, status = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"cell": cell, "assertion": assertion, "status": status}, fh)
PY
}

@test "two runs that agree report no divergence" {
  rec "$A" 1.json W1 "reads through" pass
  rec "$B" 1.json W1 "reads through" pass
  count "$A" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "a verdict that differs between the arrangements is counted AND named" {
  # The failure this exists to catch: the fallback quietly behaving unlike the overlay.
  rec "$A" 1.json W5 "the next launch does not see it" pass
  rec "$B" 1.json W5 "the next launch does not see it" fail
  count "$A" "$B"
  [ "$output" = 1 ]
  # The name matters: a count alone tells nobody which promise broke.
  detail "$A" "$B"
  [[ "$output" == *W5* ]]
  [[ "$output" == *"overlay=pass"* ]]
  [[ "$output" == *"off=fail"* ]]
  [[ "$output" == *"the next launch does not see it"* ]]
}

@test "an assertion reached in only one arrangement is a divergence too" {
  # A cell that stopped part-way in one arrangement is exactly the case where comparing
  # only the assertions both runs share would report a reassuring zero.
  rec "$A" 1.json W6 "the whiteout went too" pass
  rec "$A" 2.json W6 "and so did the shadow" pass
  rec "$B" 1.json W6 "the whiteout went too" pass
  count "$A" "$B"
  [ "$output" = 1 ]
  detail "$A" "$B"
  [[ "$output" == *"only one arrangement"* ]]
  [[ "$output" == *"and so did the shadow"* ]]
}

@test "controls are not compared: they describe the tree, not the implementation" {
  # Each run builds its own throwaway tree, so control records legitimately differ in
  # ways that say nothing about cow. Comparing them would report noise as divergence.
  rec "$A" 1.json W1 "reads through" pass
  rec "$B" 1.json W1 "reads through" pass
  rec "$A" 2.json W1 "positive control" control-pass
  rec "$B" 2.json W1 "positive control" control-fail
  count "$A" "$B"
  [ "$output" = 0 ]
}

@test "many assertions, one difference: the count is the difference, not the total" {
  for i in 1 2 3 4 5; do
    rec "$A" "$i.json" "W$i" "assertion $i" pass
    rec "$B" "$i.json" "W$i" "assertion $i" pass
  done
  rec "$B" 3.json W3 "assertion 3" fail
  count "$A" "$B"
  [ "$output" = 1 ]
}

@test "usage error when it is not given two directories" {
  run python3 "$CMP" "$A"
  [ "$status" -eq 2 ]
}
