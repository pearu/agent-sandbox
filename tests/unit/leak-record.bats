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
