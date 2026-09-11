#!/usr/bin/env bats
# The claude profile: binary discovery, state paths, host-routed subcommands.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  V="$H/home/.local/share/claude/versions"
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
  [[ "$output" == *"no executable found for version '1.0.0'"* ]]
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
