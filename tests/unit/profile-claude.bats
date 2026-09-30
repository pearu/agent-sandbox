#!/usr/bin/env bats
# The claude profile: the binary, state paths, host-routed subcommands.

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

@test "a launch does not look in versions/: it runs what the command resolves to" {
  rm -rf "${V:?}"/*
  mkdir -p "$H/pkg/bin"
  printf '#!/bin/sh\n' >"$H/pkg/bin/claude"
  chmod +x "$H/pkg/bin/claude"
  rm "$H/bin/claude"
  run_engine PATH="$H/bin:$H/pkg/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/pkg/bin/claude" "$H/pkg/bin/claude"
  [ "${JOINV[0]}" = "$H/pkg/bin/claude" ]
}

@test "profile_prepare creates ~/.claude and ~/.claude.json for a launch, not for a host subcommand" {
  run_engine -- asb claude update
  [ ! -e "$H/home/.claude" ]
  run_engine -- asb claude --version
  [ -d "$H/home/.claude" ]
  [ -f "$H/home/.claude.json" ]
}

@test "the empty mount-point file bwrap leaves on the host for the config file is removed after the session; a file that was already there is kept" {
  # This stub bwrap creates the mount point the way the real one does when the
  # bind's destination is missing inside a read-write directory: an empty file
  # on the host. Left behind, it is a config file that parses as nothing for
  # anyone who points CLAUDE_CONFIG_DIR at ~/.claude natively.
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
[ -e "$HOME/.claude/.claude.json" ] || : >"$HOME/.claude/.claude.json"
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$H/home/.claude/.claude.json" ]
  # a file that already existed there before the launch is not ours, whatever it holds
  printf '{}' >"$H/home/.claude/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$H/home/.claude/.claude.json")" = '{}' ]
  : >"$H/home/.claude/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ -e "$H/home/.claude/.claude.json" ]
}

@test "update/upgrade/install run on the host: no bwrap, argv passed through, exit code propagated, engine flags ignored with a note" {
  cat >"$V/2.1.300/claude" <<'STUB'
#!/usr/bin/env bash
set +x
echo "stub-agent argv: $*"
[[ "$1" == upgrade ]] && exit 7
exit 0
STUB
  run_engine -- asb claude update --foo
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ]
  [[ "$output" == *"running '$V/2.1.300/claude update --foo' on the host"* ]]
  [[ "$output" == *"stub-agent argv: update --foo"* ]]
  run_engine -- asb claude upgrade
  [ "$status" -eq 7 ]
  run_engine -- asb --allow pypi.org --ssh-unrestricted claude update
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ssh*/--allow flags are ignored for 'update'"* ]]
  [ -z "$(ls -A "$H/base")" ]
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
  RUN_CWD="$deep" run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$H/home/.claude/projects/$plain/memory" "$H/home/.claude/projects/$plain/memory"
  argv_has --bind "$H/home/.claude/projects/$slug/memory" "$H/home/.claude/projects/$slug/memory" # memory on top of the transcripts store
  [ "${#slug}" -le 207 ]                                                                          # 200 + "-" + at most six characters, so under NAME_MAX
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
