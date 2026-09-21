#!/usr/bin/env bats
# The claude profile: binary discovery, state paths, host-routed subcommands.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  V="$H/home/.local/share/claude/versions"
  # the slug tests call the profile's functions directly
  source "$REPO_ROOT/profiles/claude.sh"
}

# Two slugs RECORDED from Claude Code 2.1.270 by probes/config-dir-check.sh
# --matrix: the project path a session ran in, and the directory name it created
# under projects/. These pin the whole scheme -- the 200-character truncation
# point, the "-" separator, and the hash -- against real output rather than
# against our own reimplementation of it.
slug_vector() {
  local tag="$1" n="$2" seg i p
  seg="$(printf 'x%.0s' {1..60})"
  p="/tmp/as-leak-matrix.3WbHJO/$tag"
  for ((i = 1; i <= n; i++)); do p="$p/$seg$i"; done
  printf '%s' "$p"
}

@test "discovers the highest version across the three layouts (file, dir/claude, dir/bin/claude)" {
  rm -rf "${V:?}"/*
  printf '#!/bin/sh\n' >"$V/2.1.100"
  mkdir -p "$V/2.1.300" "$V/2.1.301/bin" "$V/2.1.9"
  printf '#!/bin/sh\n' >"$V/2.1.300/claude"
  printf '#!/bin/sh\n' >"$V/2.1.301/bin/claude"
  printf '#!/bin/sh\n' >"$V/2.1.9/claude"
  chmod +x "$V/2.1.100" "$V/2.1.300/claude" "$V/2.1.301/bin/claude" "$V/2.1.9/claude"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$V/2.1.301/bin/claude" "$V/2.1.301/bin/claude"
  rm -rf "$V/2.1.301"
  run_engine -- claude --version
  argv_has --ro-bind "$V/2.1.300/claude" "$V/2.1.300/claude"
  rm -rf "$V/2.1.300" "$V/2.1.9"
  run_engine -- claude --version
  argv_has --ro-bind "$V/2.1.100" "$V/2.1.100"
}

@test "no install: exit 1 with a message naming the versions directory" {
  rm -rf "$V"
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing $V"* ]]
  mkdir -p "$V"
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"no versions under"* ]]
  mkdir -p "$V/1.0.0"
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"no runnable Claude Code executable under $V"* ]]
}

@test "tolerates a phantom newest version (mid self-update): falls back to the newest runnable one" {
  rm -rf "${V:?}"/*
  # 2.1.269 is runnable; 2.1.270 exists (as during a native self-update) but its
  # binary has not landed yet -- so it must be skipped, not fail the launch.
  mkdir -p "$V/2.1.269"
  printf '#!/bin/sh\n' >"$V/2.1.269/claude"
  chmod +x "$V/2.1.269/claude"
  mkdir -p "$V/2.1.270" # phantom: directory, no executable inside
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$V/2.1.269/claude" "$V/2.1.269/claude"
}

@test "profile_prepare creates ~/.claude and ~/.claude.json for a launch, not for a host subcommand" {
  run_engine -- claude update
  [ ! -e "$H/home/.claude" ]
  run_engine -- claude --version
  [ -d "$H/home/.claude" ]
  [ -f "$H/home/.claude.json" ]
}

# this project's copy of the config file, keyed by Claude Code's project slug
copy_path() {
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  printf '%s' "$H/home/.local/state/agent-sandbox/claude/${proj//[^A-Za-z0-9-]/-}/claude.json"
}

# seed the host file with two projects: this one and another with a secret in it
seed_host_config() {
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  printf '{"a":1,"mcpServers":{"host":{}},"projects":{"%s":{"t":true},"/elsewhere":{"lastSessionFirstPrompt":"SECRET"}}}' "$proj" >"$H/home/.claude.json"
  cp "$H/home/.claude.json" "$H/host-before.json"
}

# json_get FILE EXPR -> python expression over d (the parsed file)
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

@test "the config file bound inside the state directory is this project's copy, and CLAUDE_CONFIG_DIR points Claude Code there: its lock and temp file need a writable parent, and \$HOME is not one" {
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(copy_path)" "$H/home/.claude/.claude.json"
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/.claude" ]
  # the host's own file is bound nowhere, at neither path
  run ! argv_has --bind "$H/home/.claude.json" "$H/home/.claude.json"
  run ! argv_has --bind "$H/home/.claude.json" "$H/home/.claude/.claude.json"
}

@test "the copy is seeded from ~/.claude.json with every top-level key and only this project's entry, mode 0600 in a 0700 directory; the host file is untouched" {
  seed_host_config
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  local c
  c="$(copy_path)"
  [ -f "$c" ]
  [ "$(stat -c %a "$c")" = 600 ]
  [ "$(stat -c %a "$(dirname "$c")")" = 700 ]
  [ "$(json_get "$c" 'd["a"]')" = 1 ]
  [ "$(json_get "$c" 'sorted(d["mcpServers"])')" = "['host']" ]
  [ "$(json_get "$c" 'len(d["projects"])')" = 1 ]
  [ "$(json_get "$c" 'list(d["projects"].values())[0]["t"]')" = True ]
  run ! grep -q SECRET "$c"
  cmp "$H/home/.claude.json" "$H/host-before.json"
}

@test "later launches keep the project's own entry and follow the host file's user-level mcpServers, added and removed; other projects never arrive" {
  seed_host_config
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  local c proj
  c="$(copy_path)"
  proj="$(cd "$H/proj" && pwd -P)"
  # the session changed its copy: its own entry, and a user-level server added inside
  python3 - "$c" "$proj" <<'PY'
import json, sys
p, proj = sys.argv[1:3]
d = json.load(open(p))
d["projects"][proj]["inside"] = 1
d["mcpServers"] = {"inside": {}}
json.dump(d, open(p, "w"))
PY
  # the host file changed too: a new user-level server, and a third project
  printf '{"a":2,"mcpServers":{"native2":{}},"projects":{"%s":{"t":false},"/elsewhere":{"lastSessionFirstPrompt":"SECRET"},"/third":{}}}' "$proj" >"$H/home/.claude.json"
  cp "$H/home/.claude.json" "$H/host-before.json"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ "$(json_get "$c" 'd["projects"][sys.argv[2]]["inside"]' 2>/dev/null || json_get "$c" 'list(d["projects"].values())[0]["inside"]')" = 1 ]
  [ "$(json_get "$c" 'list(d["projects"].values())[0]["t"]')" = True ] # the copy's entry, not the host's
  [ "$(json_get "$c" 'len(d["projects"])')" = 1 ]
  [ "$(json_get "$c" 'sorted(d["mcpServers"])')" = "['native2']" ] # followed the host: added there, and the one added inside is gone
  [ "$(json_get "$c" 'd["a"]')" = 1 ]                              # other top-level keys are the project's own
  cmp "$H/home/.claude.json" "$H/host-before.json"
  # removed natively: removed from the copy too
  printf '{"a":2,"projects":{}}' >"$H/home/.claude.json"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ "$(json_get "$c" '"mcpServers" in d')" = False ]
}

@test "without python3 the copy is the whole host file, made once and never refreshed, and the launch says so" {
  seed_host_config
  # a PATH with every tool but python3
  mkdir -p "$H/nopy"
  local t
  for t in /usr/bin/*; do
    [[ "$(basename "$t")" == python3* ]] || ln -s "$t" "$H/nopy/$(basename "$t")" 2>/dev/null || true
  done
  run_engine PATH="$H/bin:$H/nopy" -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 missing: this project's config file is a whole copy"* ]]
  cmp "$(copy_path)" "$H/host-before.json"
  printf '{"changed":true}' >"$H/home/.claude.json"
  run_engine PATH="$H/bin:$H/nopy" -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"not refreshed"* ]]
  cmp "$(copy_path)" "$H/host-before.json"
}

@test "user-mcp: none leaves the host's user-level mcpServers out of the copy at seeding and at every refresh; env and flag set it, the flag wins, an unknown value keeps inherit and says so" {
  seed_host_config # the host file carries mcpServers {"host": {}}
  local c
  c="$(copy_path)"
  run_engine AGENT_SANDBOX_CLAUDE_USER_MCP=none -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"user-level MCP servers left out"*"via AGENT_SANDBOX_CLAUDE_USER_MCP"* ]]
  [ "$(json_get "$c" '"mcpServers" in d')" = False ]
  [ "$(json_get "$c" 'd["a"]')" = 1 ] # the rest of the seed is as before
  # inherit at the next launch: the refresh brings the block back from the host
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ "$(json_get "$c" 'sorted(d["mcpServers"])')" = "['host']" ]
  # none again, by flag, both spellings: the refresh takes it out
  run_engine -- claude --user-mcp none --version
  [ "$status" -eq 0 ]
  [ "$(json_get "$c" '"mcpServers" in d')" = False ]
  run_engine -- claude --version # back
  [ "$(json_get "$c" '"mcpServers" in d')" = True ]
  run_engine -- claude --user-mcp=none --version
  [ "$(json_get "$c" '"mcpServers" in d')" = False ]
  # the flag wins over the environment
  run_engine AGENT_SANDBOX_CLAUDE_USER_MCP=none -- claude --user-mcp inherit --version
  [ "$status" -eq 0 ]
  [ "$(json_get "$c" '"mcpServers" in d')" = True ]
  # an unknown value is said and treated as inherit
  run_engine AGENT_SANDBOX_CLAUDE_USER_MCP=maybe -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown value 'maybe'"*"keeping inherit"* ]]
  [ "$(json_get "$c" '"mcpServers" in d')" = True ]
  # the flag without a value is an error, not a silent inherit
  run_engine -- claude --user-mcp
  [ "$status" -eq 2 ]
  [[ "$output" == *"--user-mcp needs a value"* ]]
}

@test "user-mcp = none without a working python3 refuses the launch: the block cannot be left out of a whole copy" {
  seed_host_config
  printf '#!/usr/bin/env bash\nexit 3\n' >"$H/bin/python3"
  chmod +x "$H/bin/python3"
  run_engine AGENT_SANDBOX_CLAUDE_USER_MCP=none -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs python3 to leave the user-level mcpServers out"* ]]
  [ ! -s "$H/argv" ]      # bwrap never invoked
  [ ! -e "$(copy_path)" ] # and no whole copy was made either
}

@test "a python3 that fails degrades like a missing one: the whole file, made once, said out loud -- and never the host file itself" {
  seed_host_config
  printf '#!/usr/bin/env bash\nexit 3\n' >"$H/bin/python3"
  chmod +x "$H/bin/python3"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 failed (exit 3): this project's config file is a whole copy"* ]]
  cmp "$(copy_path)" "$H/host-before.json"
  argv_has --bind "$(copy_path)" "$H/home/.claude/.claude.json"
  run ! argv_has --bind "$H/home/.claude.json" "$H/home/.claude/.claude.json"
}

@test "the empty mount-point file bwrap leaves on the host for the config file is removed after the session; a file that was already there is kept" {
  # This stub bwrap creates the mount point the way the real one does when the
  # bind's destination is missing inside a read-write directory: an empty file
  # on the host. Left behind, it is a config file that parses as nothing for
  # anyone who points CLAUDE_CONFIG_DIR at ~/.claude natively.
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
[ -e "$HOME/.claude/.claude.json" ] || : >"$HOME/.claude/.claude.json"
exit 0
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$H/home/.claude/.claude.json" ]
  # a file that already existed there before the launch is not ours, whatever it holds
  printf '{}' >"$H/home/.claude/.claude.json"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$H/home/.claude/.claude.json")" = '{}' ]
  : >"$H/home/.claude/.claude.json"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ -e "$H/home/.claude/.claude.json" ]
}

@test "update/upgrade/install run on the host: no bwrap, argv passed through, exit code propagated, engine flags ignored with a note" {
  cat >"$V/2.1.300/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-agent argv: $*"
[[ "$1" == upgrade ]] && exit 7
exit 0
STUB
  run_engine -- claude update --foo
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ]
  [[ "$output" == *"running '2.1.300 update --foo' on the host"* ]]
  [[ "$output" == *"stub-agent argv: update --foo"* ]]
  [[ "$output" == *"installed versions: 2.1.300"* ]]
  run_engine -- claude upgrade
  [ "$status" -eq 7 ]
  run_engine -- claude --allow pypi.org --ssh-unrestricted update
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ssh*/--allow flags are ignored for 'update'"* ]]
  [ -z "$(ls -A "$H/base")" ]
}

@test "install: if the native installer re-points the launcher, the engine restores it" {
  mkdir -p "$H/home/.local/bin"
  ln -s "$ENGINE" "$H/home/.local/bin/claude"
  cat >"$V/2.1.300/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-agent argv: $*"
[[ "$1" == install ]] && ln -sfn "$0" "$HOME/.local/bin/claude"
exit 0
STUB
  run_engine -- claude install latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-pointed"*"restored"* ]]
  [ "$(readlink "$H/home/.local/bin/claude")" = "$ENGINE" ]
}

@test "project slug: a converted name of 200 characters or fewer is used unchanged" {
  [ "$(_claude_project_slug /home/u/proj.x)" = "-home-u-proj-x" ]
  local p200 s
  p200="/$(printf 'a%.0s' $(seq 1 199))"
  [ "${#p200}" -eq 200 ]
  s="$(_claude_project_slug "$p200")"
  [ "${#s}" -eq 200 ]
  [ "$s" = "${p200//[^A-Za-z0-9-]/-}" ] # no truncation, no hash appended
}

@test "project slug: past 200 characters it is truncated and hashed, matching Claude Code 2.1.270" {
  local seg p want
  seg="$(printf 'x%.0s' {1..60})"
  # vector 1: a 280-character converted name -> recorded slug ended "...-b8aa65"
  p="$(slug_vector long4 4)"
  want="-tmp-as-leak-matrix-3WbHJO-long4-${seg}1-${seg}2-$(printf 'x%.0s' {1..43})-b8aa65"
  [ "$(_claude_project_slug "$p")" = "$want" ]
  # vector 2: a 466-character converted name -> recorded slug ended "...-mcwljf"
  # (its hash is NEGATIVE; the suffix is the absolute value, which is what
  # caught an implementation that only considered unsigned hashes)
  p="$(slug_vector long7 7)"
  want="-tmp-as-leak-matrix-3WbHJO-long7-${seg}1-${seg}2-$(printf 'x%.0s' {1..43})-mcwljf"
  [ "$(_claude_project_slug "$p")" = "$want" ]
  # both recorded slugs were 207 characters: 200 + "-" + a 6-character hash
  [ "${#want}" -eq 207 ]
}

@test "project slug: the hash suffix is variable width, not padded to six characters" {
  # /a hashes to 176 -- three characters. A suffix padded or truncated to a
  # fixed width would produce the wrong directory name for such a path.
  [ "$(_claude_path_hash /a)" = "176" ]
  [ "$(_claude_path_hash "")" = "0" ]
}

@test "a project path longer than 200 characters binds the truncated project directory" {
  local seg deep real plain slug
  seg="$(printf 'z%.0s' {1..60})"
  deep="$H/home/$seg/$seg/$seg"
  mkdir -p "$deep"
  real="$(cd "$deep" && pwd -P)"
  # the UNtruncated conversion, computed here rather than by the code under
  # test: asserting only on _claude_project_slug's own answer would pass for any
  # scheme, including no truncation at all
  plain="${real//[^A-Za-z0-9-]/-}"
  [ "${#plain}" -gt 200 ] # otherwise this test proves nothing
  slug="$(_claude_project_slug "$real")"
  RUN_CWD="$deep" run_engine -- claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$H/home/.claude/projects/$plain" "$H/home/.claude/projects/$plain"
  argv_has --bind "$H/home/.claude/projects/$slug" "$H/home/.claude/projects/$slug"
  [ "${#slug}" -le 207 ] # 200 + "-" + at most six characters, so under NAME_MAX
}

@test "the history filter matches the project FIELD, not the bytes anywhere on the line" {
  # MEASURED, leak study row 4 (#73). The old filter was a fixed-string grep for
  # "project":"<dir>", whose comment argued it "can only ever return too few
  # lines, never another project's". The closing quote does rule out prefix
  # collisions -- and nothing else: grep -F matches that byte sequence ANYWHERE
  # on the line, so a record whose own project is someone else's reaches this
  # sandbox as soon as it happens to quote or nest the target path.
  local hist="$BATS_TEST_TMPDIR/history.jsonl"
  {
    printf '%s\n' '{"display":"MINE","project":"/home/u/mine"}'
    printf '%s\n' '{"display":"THEIRS","project":"/home/u/other"}'
    # another project's record that NESTS the target path
    printf '%s\n' '{"display":"NESTED","meta":{"project":"/home/u/mine"},"project":"/home/u/other"}'
    # and one that merely quotes it inside a string
    printf '%s\n' '{"display":"\"project\":\"/home/u/mine\"","project":"/home/u/other"}'
  } >"$hist"

  run _claude_history_filter "$hist" /home/u/mine
  [ "$status" -eq 0 ]
  [[ "$output" == *'"display":"MINE"'* ]]
  [[ "$output" != *THEIRS* ]]
  [[ "$output" != *NESTED* ]]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "the history filter drops a line it cannot parse rather than passing it" {
  # Fail closed: too few lines is the safe direction for a filter whose input
  # format we do not control.
  local hist="$BATS_TEST_TMPDIR/history.jsonl"
  {
    printf '%s\n' 'not json at all "project":"/home/u/mine"'
    printf '%s\n' '{"display":"MINE","project":"/home/u/mine"}'
  } >"$hist"
  run _claude_history_filter "$hist" /home/u/mine
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *MINE* ]]
}
