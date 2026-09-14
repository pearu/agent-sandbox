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
