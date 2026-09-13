#!/usr/bin/env bats
# Background helpers the previous suites did not cover: _claude_roster_supervisor
# (parse the daemon roster) and _claude_bg_autotrust (record a project's trust in
# ~/.claude.json). _claude_bg_prepare_daemon kills/restarts a live daemon and
# needs the host, so it is exercised by the probes, not here.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  # shellcheck disable=SC1090
  source "$ENGINE"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/profiles/claude.sh"
}

@test "_claude_roster_supervisor prints an integer supervisorPid, nothing otherwise" {
  local r="$BATS_TEST_TMPDIR/roster.json"
  printf '{"supervisorPid":12345,"workers":{}}' >"$r"
  [ "$(_claude_roster_supervisor "$r")" = "12345" ]
  printf '{"workers":{}}' >"$r" # no supervisorPid
  [ -z "$(_claude_roster_supervisor "$r")" ]
  printf '{"supervisorPid":"nope"}' >"$r" # non-int
  [ -z "$(_claude_roster_supervisor "$r")" ]
  printf 'not json' >"$r" # garbage
  [ -z "$(_claude_roster_supervisor "$r")" ]
  [ -z "$(_claude_roster_supervisor "$BATS_TEST_TMPDIR/absent.json")" ] # missing
}

@test "_claude_bg_autotrust records hasTrustDialogAccepted, preserving existing config" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf '{"projects":{"/other":{"x":1}},"topKey":true}' >"$HOME/.claude.json"
  _claude_bg_autotrust "/work/proj"
  run python3 - "$HOME/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["projects"]["/work/proj"]["hasTrustDialogAccepted"] is True, "flag not set"
assert d["projects"]["/other"]["x"] == 1, "existing project lost"
assert d["topKey"] is True, "top-level key lost"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "_claude_bg_autotrust creates ~/.claude.json when it is absent" {
  HOME="$BATS_TEST_TMPDIR/home2"
  mkdir -p "$HOME"
  _claude_bg_autotrust "/p"
  [ -f "$HOME/.claude.json" ]
  run python3 - "$HOME/.claude.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["projects"]["/p"]["hasTrustDialogAccepted"])
PY
  [ "$output" = "True" ]
}
