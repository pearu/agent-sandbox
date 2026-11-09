#!/usr/bin/env bats
# Which binary a launch runs (#6, _as_resolve_bin): for a profile with an install recipe
# (claude), the version `asb --install` made current, under every preset, never one on
# PATH, its directory bound read-only and alone; for a profile without one (`plain`,
# tests/helpers/common.bash), the name looked up on PATH, its file bound; a path always
# what it names. The harness installs the stub agent as claude 2.1.300.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  I="${STUB_AGENT_DIR%/*}" # <state>/claude/install
  # a claude first on PATH that is not the installed one: never what runs
  mkdir -p "$H/pathbin"
  printf '#!/bin/sh\necho path-agent\n' >"$H/pathbin/claude"
  chmod +x "$H/pathbin/claude"
  LPATH="$H/pathbin:$H/bin:/usr/bin:/bin"
}

@test "a profile with an install recipe runs its installed current version under every preset, never the one on PATH" {
  local p
  for p in isolated inherit shared native; do
    run_engine PATH="$LPATH" -- asb --preset "$p" claude --version
    [ "$status" -eq 0 ]
    [ "${JOINV[0]}" = "$STUB_AGENT_DIR/claude" ]
    run ! grep -qxF -- "$H/pathbin/claude" "$H/argv"
  done
  # --agent and [agent] command name it the same way
  run_engine PATH="$LPATH" -- asb --agent claude
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$STUB_AGENT_DIR/claude" ]
  # no sandbox at all: still the installed one, run directly
  run_engine PATH="$LPATH" -- asb --preset none claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-agent argv: --version"* ]]
  [[ "$output" != *path-agent* ]]
}

@test "the installed version's directory is bound read-only and alone, under every preset; outside native, current names it" {
  local p
  for p in isolated inherit shared native; do
    run_engine -- asb --preset "$p" claude --version
    [ "$status" -eq 0 ]
    argv_has --ro-bind "$STUB_AGENT_DIR" "$STUB_AGENT_DIR"
    run ! argv_has --bind "$STUB_AGENT_DIR" "$STUB_AGENT_DIR"                  # never writable
    run ! argv_has --ro-bind "$STUB_AGENT_DIR/claude" "$STUB_AGENT_DIR/claude" # not the file alone
    run ! grep -qxF -- "$I" "$H/argv"                                          # nor the install/ of every version
    if [ "$p" = native ]; then
      run ! grep -qxF -- "$I/current" "$H/argv" # the host's own current is there
    else
      argv_has --symlink 2.1.300 "$I/current"
    fi
  done
}

@test "a path is what it names, its file bound alone, for a profile with an install recipe too" {
  run_engine PATH="$LPATH" -- asb --profile claude "$H/pathbin/claude" --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/pathbin/claude" ]
  argv_has --ro-bind "$H/pathbin/claude" "$H/pathbin/claude"
  run ! grep -qxF -- "$STUB_AGENT_DIR" "$H/argv"
  run ! grep -qxF -- --symlink "$H/argv"
  # with nothing installed, a path still runs
  rm -rf "$I"
  run_engine -- asb --profile claude "$H/pathbin/claude" --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/pathbin/claude" ]
}

@test "a profile with no install recipe is looked up on PATH, under every preset, its file bound" {
  plain_profiles
  local p
  for p in isolated inherit shared native; do
    run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles" -- asb --preset "$p" plain --version
    [ "$status" -eq 0 ]
    [ "${JOINV[0]}" = "$PLAIN_BIN" ]
    argv_has --ro-bind "$PLAIN_BIN" "$PLAIN_BIN" # outside $HOME: bound under native too
  done
}

@test "not installed: refused (1) with the line that installs it; nothing launched" {
  rm -rf "$I"
  run_engine PATH="$LPATH" -- asb claude --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox: install it, asb --install claude" ]
  [ ! -s "$H/argv" ]
  [ ! -s "$H/join" ]
  # the same wherever the agent is named, and under native
  run_engine PATH="$LPATH" -- asb --agent claude
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox: install it, asb --install claude" ]
  run_engine PATH="$LPATH" -- asb --preset native --profile claude
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox: install it, asb --install claude" ]
  # the invoked name is the one it names
  run_engine PATH="$LPATH" -- agent-sandbox claude
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox: install it, agent-sandbox --install claude" ]
}

@test "a broken install is refused as not installed, saying what is wrong" {
  rm "$I/current"
  ln -s 9.9.9 "$I/current"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/current points at 9.9.9, which is not there as a directory): install it, asb --install claude" ]
  [ ! -s "$H/argv" ]
  # current naming anything but a version beside it -- the parent (whose directory has an
  # executable claude too), install/ itself, an absolute or a longer path -- is never
  # bound: nothing of what it leads to reaches the argv
  local t
  mkdir -p "$H/elsewhere/2.1.300"
  cp "$STUB_AGENT_DIR/claude" "${I%/*}/claude"
  cp "$STUB_AGENT_DIR/claude" "$I/claude"
  cp "$STUB_AGENT_DIR/claude" "$H/elsewhere/2.1.300/claude"
  for t in .. . "$H/elsewhere/2.1.300" ../install/2.1.300 2.1.300/; do
    ln -sfn "$t" "$I/current"
    run_engine -- asb claude --version
    [ "$status" -eq 1 ]
    [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/current points at '$t', which is not a version beside it): install it, asb --install claude" ]
    [ ! -s "$H/argv" ]
  done
  # a version beside it that is a symlink (to the parent here): refused, not followed
  ln -s .. "$I/9.9.9"
  ln -sfn 9.9.9 "$I/current"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/current points at 9.9.9, which is not there as a directory): install it, asb --install claude" ]
  [ ! -s "$H/argv" ]
  rm "$I/9.9.9" "$I/claude" "${I%/*}/claude"
  rm "$I/current"
  mkdir "$I/current"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/current is not a symlink): install it, asb --install claude" ]
  rmdir "$I/current"
  ln -s 2.1.300 "$I/current"
  chmod -x "$STUB_AGENT_DIR/claude"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/2.1.300 has no executable claude): install it, asb --install claude" ]
  [ ! -s "$H/argv" ]
}

@test "a name that is not the recipe profile's command is refused: PATH is not read for it" {
  run_engine PATH="$LPATH" -- asb --profile claude other --version
  [ "$status" -eq 1 ]
  [ "$output" = "agent-sandbox: 'other' is not profile claude's command, and claude runs the agent asb installs (asb --install claude), never one from PATH; run another binary by its path: asb --profile claude /path/to/other" ]
  [ ! -s "$H/argv" ]
}
