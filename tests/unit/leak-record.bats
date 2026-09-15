#!/usr/bin/env bats
# probes/leak/record.py decides each cell's verdict and reports which model served.
# The experiment itself cannot run in CI -- it needs a real host and a real Claude
# Code -- but this part is a pure function, and a wrong classifier does not fail
# loudly: it produces a confidently wrong study. Same reason the instruments were
# validated before anything used them.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  R="$REPO_ROOT/probes/leak/record.py"
  T="$BATS_TEST_TMPDIR"
}

reader_json() { printf '%s' "$1" >"$T/r.json"; }

@test "verdict: the token was read" {
  reader_json '{"open":"ok","token_found":true}'
  run python3 "$R" verdict "$T/r.json"
  [ "$output" = obtained ]
}

@test "verdict: opened but the token was not there is NOT the same as unreachable" {
  # a mis-planted canary must not read as isolation -- both look like "B did not
  # get it", and only one of them is a result about the sandbox
  reader_json '{"open":"ok","token_found":false}'
  run python3 "$R" verdict "$T/r.json"
  [ "$output" = not-obtained-absent ]
  reader_json '{"open":"ENOENT","token_found":false}'
  run python3 "$R" verdict "$T/r.json"
  [ "$output" = not-obtained-unreachable ]
  reader_json '{"open":"EACCES","token_found":false}'
  run python3 "$R" verdict "$T/r.json"
  [ "$output" = not-obtained-unreachable ]
}

@test "verdict: a reader that produced nothing usable is invalid, never a negative" {
  # "the experiment failed" and "the sandbox blocked it" are different findings
  for bad in '{"token_found":true}' '{"open":"ok"}' '{"open":"","token_found":true}' \
    '{"open":"ok","token_found":"yes"}' 'not json at all' '[]'; do
    reader_json "$bad"
    run python3 "$R" verdict "$T/r.json"
    [ "$output" = invalid-reader-output ] || {
      echo "expected invalid for: $bad, got: $output"
      return 1
    }
  done
  run python3 "$R" verdict "$T/does-not-exist.json"
  [ "$output" = invalid-reader-output ]
}

@test "models: counted per message and reported in the order they served" {
  cat >"$T/t.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant"}}
{"type":"user","message":{"role":"user"}}
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant"}}
{"type":"assistant","message":{"model":"claude-opus-5","role":"assistant"}}
EOF
  run python3 "$R" models "$T/t.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"claude-opus-4-8": 2'* ]]
  [[ "$output" == *'"claude-opus-5": 1'* ]]
  # order of first appearance, so a mid-run switch is visible as a sequence
  [[ "$output" == *'"claude-opus-4-8"'*'"claude-opus-5"'* ]]
  # and a straddling run is flagged rather than averaged into one label
  [[ "$output" == *"MORE THAN ONE MODEL"* ]]
}

@test "models: a single model is not flagged, and a missing field is not invented" {
  printf '%s\n' '{"message":{"model":"claude-opus-5"}}' >"$T/one.jsonl"
  run python3 "$R" models "$T/one.jsonl"
  [[ "$output" != *"MORE THAN ONE MODEL"* ]]
  # the transcript schema is undocumented: absence is "unknown", never assumed
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' >"$T/none.jsonl"
  run python3 "$R" models "$T/none.jsonl"
  [[ "$output" == *"no model field found"* ]]
  [[ "$output" == *'"models": {}'* ]]
  run python3 "$R" models "$T/missing.jsonl"
  [[ "$output" == *error* ]]
}

@test "write: the record carries the verdict, the raw reader output and the harness commit" {
  reader_json '{"open":"ok","token_found":true}'
  run python3 "$R" write --out "$T/rec.json" --set row=02-transcripts --set net=strict \
    --reader "$T/r.json"
  [ "$status" -eq 0 ]
  [ "$output" = obtained ]
  run python3 -c "
import json,sys
d=json.load(open('$T/rec.json'))
assert d['verdict']=='obtained', d
assert d['row']=='02-transcripts' and d['net']=='strict', d
assert d['reader']['open']=='ok', d          # raw evidence kept beside the verdict
assert len(d['harness_commit'])>=7, d        # so a result is tied to the method
print('ok')
"
  [ "$output" = ok ]
}

@test "write: a commit is marked dirty when the tree does not match it" {
  # a result claims to be reproducible at the recorded commit; an edited-but-
  # uncommitted script makes that false, and a bare HEAD would assert it anyway
  repo="$T/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@e.invalid -c user.name=t commit -q --allow-empty -m x
  reader_json '{"open":"ok","token_found":true}'

  run bash -c "cd '$repo' && python3 '$R' write --out '$T/clean.json' --reader '$T/r.json'"
  [ "$status" -eq 0 ]
  clean="$(python3 -c "import json;print(json.load(open('$T/clean.json'))['harness_commit'])")"
  [[ "$clean" != *-dirty ]] || {
    echo "clean tree marked dirty: $clean"
    return 1
  }

  echo edit >"$repo/new-file"
  run bash -c "cd '$repo' && python3 '$R' write --out '$T/dirty.json' --reader '$T/r.json'"
  [ "$status" -eq 0 ]
  dirty="$(python3 -c "import json;print(json.load(open('$T/dirty.json'))['harness_commit'])")"
  [[ "$dirty" == "$clean-dirty" ]] || {
    echo "expected $clean-dirty, got $dirty"
    return 1
  }
}

# --- the validity gate ------------------------------------------------------
# It decides whether a run is a RESULT at all. If it cannot fail, a run whose
# controls never fired gets recorded as a finding.

mkrun() { # mkrun DIR -- a minimal valid run
  mkdir -p "$1/records"
  printf '{"topology":"T1","net":"n/a","claude_version":"x","verdict":"obtained"}' >"$1/records/t1.json"
  printf '{"topology":"T2","net":"none","claude_version":"x","verdict":"not-obtained-unreachable"}' >"$1/records/t2.json"
  printf '{"topology":"T2-own","net":"none","claude_version":"x","verdict":"obtained"}' >"$1/records/own.json"
  : >"$1/real-attributable"
}

@test "gate: a run with both controls fired and a mixed verdict set is valid" {
  mkrun "$T/run"
  run python3 "$R" validate "$T/run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
  run python3 -c "import json;d=json.load(open('$T/run/validity.json'));print(d['valid'],d['cells'])"
  [ "$output" = "True 3" ]
}

@test "gate: a control that did not fire makes the run invalid, not a finding" {
  mkrun "$T/a"
  # positive control failed: the plant is broken, not the sandbox working
  printf '{"topology":"T1","net":"n/a","claude_version":"x","verdict":"not-obtained-absent"}' >"$T/a/records/t1.json"
  run python3 "$R" validate "$T/a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive control obtained"*FAIL* ]]
  [[ "$output" == *"INVALID RUN"* ]]

  mkrun "$T/b"
  # negative control failed: "unreachable" may just mean nothing is mounted
  printf '{"topology":"T2-own","net":"none","claude_version":"x","verdict":"not-obtained-unreachable"}' >"$T/b/records/own.json"
  run python3 "$R" validate "$T/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"negative control obtained"*FAIL* ]]
}

@test "gate: an unusable reader, a degenerate verdict set, or missing environment all fail" {
  mkrun "$T/c"
  printf '{"topology":"T2","net":"none","claude_version":"x","verdict":"invalid-reader-output"}' >"$T/c/records/t2.json"
  run python3 "$R" validate "$T/c"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no invalid reader output"*FAIL* ]]

  # every cell identical: usually means nothing was planted
  mkdir -p "$T/d/records"
  for n in 1 2 3; do
    printf '{"topology":"T1","net":"n/a","claude_version":"x","verdict":"obtained"}' >"$T/d/records/$n.json"
  done
  : >"$T/d/real-attributable"
  run python3 "$R" validate "$T/d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdicts not degenerate"*FAIL* ]]

  mkrun "$T/e"
  printf '{"topology":"T2","net":"none","verdict":"not-obtained-unreachable"}' >"$T/e/records/t2.json"
  run python3 "$R" validate "$T/e"
  [ "$status" -eq 1 ]
  [[ "$output" == *"environment recorded"*FAIL* ]]
}

@test "gate: an unclassified change to the real config stops the run; a known one does not" {
  mkrun "$T/f"
  printf 'content\t/home/u/.claude/projects/-something/NEW.md\n' >"$T/f/real-attributable"
  run python3 "$R" validate "$T/f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"real config changes accounted for"*FAIL* ]]
  [[ "$output" == *NEW.md* ]] # names what was unexplained, rather than just counting

  # the observing session's own event-driven writes, classified once with a reason
  printf 'content\t/home/u/.claude/responses.log\n' >"$T/f/real-attributable"
  run python3 "$R" validate "$T/f" --known-ambient '/\.claude/(responses\.log|jobs/)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"=> valid"* ]]
}
