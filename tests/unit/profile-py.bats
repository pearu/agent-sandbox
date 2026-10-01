#!/usr/bin/env bats
# profiles/claude/profile.py, the claude profile's file formats, driven directly: each
# subcommand, its refusals, and the exit codes profile.sh's fallbacks depend on. The
# hooks around it (what a launch does when it fails) are tested through the engine in
# config-channel.bats, transcripts.bats, briefing.bats and routing.bats.
#
# AGENT_SANDBOX_TEST_PYTHON may wrap the interpreter, e.g. "coverage run -a ..." for the
# coverage stage.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  PY="$REPO_ROOT/profiles/claude/profile.py"
  T="$BATS_TEST_TMPDIR"
}
py() { ${AGENT_SANDBOX_TEST_PYTHON:-python3} "$PY" "$@"; }
pyget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@"; }

@test "config-view: every top-level key, and of the projects only this one's" {
  printf '%s' '{"oauthAccount":{"e":"x"},"mcpServers":{"m":{}},"projects":{"/p/mine":{"t":1},"/p/other":{"secret":1}}}' >"$T/c.json"
  run py config-view "$T/c.json" "$T/view" --project /p/mine
  [ "$status" -eq 0 ]
  [ "$(pyget "$T/view" 'sorted(d)')" = "['mcpServers', 'oauthAccount', 'projects']" ]
  [ "$(pyget "$T/view" 'list(d["projects"])')" = "['/p/mine']" ]
  [ "$(stat -c %a "$T/view")" = 600 ]
}

@test "config-view: a missing or unparsable source is an empty config, which still parses" {
  run py config-view "$T/none.json" "$T/v1" --project /p
  [ "$status" -eq 0 ]
  [ "$(cat "$T/v1")" = '{"projects": {}}' ]
  printf 'not json' >"$T/bad.json"
  run py config-view "$T/bad.json" "$T/v2" --project /p
  [ "$status" -eq 0 ]
  [ "$(cat "$T/v2")" = '{"projects": {}}' ]
}

@test "config-view: an existing view is never overwritten (the hook removes it first)" {
  printf 'KEEP' >"$T/view"
  run py config-view "$T/none.json" "$T/view" --project /p
  [ "$status" -eq 1 ]
  [ "$(cat "$T/view")" = KEEP ]
}

@test "history-view: matches the project FIELD, not the bytes anywhere on the line" {
  # MEASURED, leak study row 4 (#73). The old filter was a fixed-string grep for
  # "project":"<dir>": the closing quote rules out prefix collisions and nothing else,
  # so a record whose own project is someone else's reached this sandbox as soon as it
  # quoted or nested the target path.
  {
    printf '%s\n' '{"display":"MINE","project":"/home/u/mine"}'
    printf '%s\n' '{"display":"THEIRS","project":"/home/u/other"}'
    printf '%s\n' '{"display":"NESTED","meta":{"project":"/home/u/mine"},"project":"/home/u/other"}'
    printf '%s\n' '{"display":"\"project\":\"/home/u/mine\"","project":"/home/u/other"}'
  } >"$T/h.jsonl"
  run py history-view "$T/h.jsonl" "$T/view" --project /home/u/mine
  [ "$status" -eq 0 ]
  [[ "$(cat "$T/view")" == *'"display":"MINE"'* ]]
  [ "$(grep -c . "$T/view")" -eq 1 ]
  [ "$(stat -c %a "$T/view")" = 600 ]
}

@test "history-view: drops a line it cannot parse; a missing source is an empty view" {
  {
    printf '%s\n' 'not json at all "project":"/home/u/mine"'
    printf '%s' '{"display":"MINE","project":"/home/u/mine"}' # no trailing newline
  } >"$T/h.jsonl"
  run py history-view "$T/h.jsonl" "$T/view" --project /home/u/mine
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$T/view")" -eq 1 ]
  [[ "$(tail -c 1 "$T/view" | od -An -c)" == *'\n'* ]] # a record ends its line
  run py history-view "$T/none.jsonl" "$T/v2" --project /home/u/mine
  [ "$status" -eq 0 ]
  [ -e "$T/v2" ]
  [ ! -s "$T/v2" ]
}

@test "trust-recorded and mark-trust: recorded in place, everything else kept" {
  printf '%s' '{"keep":1,"projects":{"/p/other":{"x":2}}}' >"$T/c.json"
  run py trust-recorded "$T/c.json" --project /p/mine
  [ "$status" -eq 1 ]
  local inode
  inode="$(stat -c %i "$T/c.json")"
  run py mark-trust "$T/c.json" --project /p/mine
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$T/c.json")" = "$inode" ] # in place: a bind-mounted file stays the one bound
  run py trust-recorded "$T/c.json" --project /p/mine
  [ "$status" -eq 0 ]
  [ "$(pyget "$T/c.json" 'd["keep"], d["projects"]["/p/other"]')" = "(1, {'x': 2})" ]
}

@test "mark-trust: a config that is not an object, or has no usable projects, becomes one" {
  for body in '[]' '{"projects":[]}' '{"projects":{"/p":"str"}}' 'garbage'; do
    printf '%s' "$body" >"$T/c.json"
    run py mark-trust "$T/c.json" --project /p
    [ "$status" -eq 0 ]
    run py trust-recorded "$T/c.json" --project /p
    [ "$status" -eq 0 ]
  done
  run py trust-recorded "$T/missing.json" --project /p
  [ "$status" -eq 1 ]
  run py mark-trust "$T/missing.json" --project /p # nothing to write in place
  [ "$status" -eq 1 ]
}

OURS='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cat b"}]}]}}'

@test "merge-settings: our hook entries after theirs, the rest of theirs untouched; a path or inline JSON" {
  printf '%s' '{"model":"m","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"theirs"}]}],"Stop":[]}}' >"$T/user.json"
  run py merge-settings --ours "$OURS" --user "$T/user.json" --out "$T/out.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(pyget "$T/out.json" 'd["model"], sorted(d["hooks"])')" = "('m', ['SessionStart', 'Stop'])" ]
  [ "$(pyget "$T/out.json" '[e["hooks"][0]["command"] for e in d["hooks"]["SessionStart"]]')" = "['theirs', 'cat b']" ]
  run py merge-settings --ours "$OURS" --user ' {"x":1}' --out "$T/out2.json"
  [ "$status" -eq 0 ]
  [ "$(pyget "$T/out2.json" 'd["x"], len(d["hooks"]["SessionStart"])')" = "(1, 1)" ]
}

@test "merge-settings: says hooks-disabled when theirs switch every hook off" {
  run py merge-settings --ours "$OURS" --user '{"disableAllHooks":true}' --out "$T/out.json"
  [ "$status" -eq 0 ]
  [ "$output" = hooks-disabled ]
}

@test "merge-settings: a shape it does not recognise is refused, and nothing is written" {
  local u
  printf '[1]' >"$T/array.json" # inline JSON starts with `{`; anything else is a path
  for u in "$T/array.json" '{"hooks":[]}' '{"hooks":{"SessionStart":{}}}'; do
    run py merge-settings --ours "$OURS" --user "$u" --out "$T/out.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to merge --settings, leaving yours untouched"* ]]
    [ ! -e "$T/out.json" ]
  done
  run py merge-settings --ours "$OURS" --user "$T/none.json" --out "$T/out.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read --settings"* ]]
}

@test "a call it does not understand is a usage error, exit 2" {
  run py
  [ "$status" -eq 2 ]
  run py config-view only-one --project /p
  [ "$status" -eq 2 ]
  [[ "$output" == *"profile.py config-view SOURCE VIEW --project DIR"* ]]
  run py bogus
  [ "$status" -eq 2 ]
}
