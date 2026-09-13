#!/usr/bin/env bats
# profile_route: sandbox scopes (--sandbox / [claude] sandbox / context default),
# foreground vs background vs management routing. A sandboxed launch runs the stub
# bwrap (so $H/argv is non-empty); a native one execs the stub agent directly
# (bwrap never runs, so $H/argv is empty and the stub echoes its argv).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
}

sandboxed() { [ -s "$H/argv" ]; } # bwrap ran
native() { [ ! -s "$H/argv" ]; }  # bwrap did not run

@test "default: a foreground session is sandboxed (fg scope on outside a sandbox)" {
  run_engine -- claude -p hello
  [ "$status" -eq 0 ]
  sandboxed
  argv_has --chdir "$H/proj"
}

@test "--sandbox none: a foreground session runs natively (no bwrap)" {
  run_engine -- claude --sandbox none -p hello
  [ "$status" -eq 0 ]
  native
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
  [[ "$output" == *"foreground sandboxing off"* ]]
}

@test "--sandbox bg: foreground has no fg scope, so it runs natively" {
  run_engine -- claude --sandbox bg -p hello
  native
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
}

@test "--sandbox 'fg bg': a foreground session is still sandboxed" {
  run_engine -- claude --sandbox "fg bg" -p hello
  sandboxed
}

@test "context default: inside a sandbox (AGENT_SANDBOX=1) a foreground session is native" {
  run_engine AGENT_SANDBOX=1 -- claude -p hello
  native
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
}

@test "management verbs run natively, before any project machinery" {
  local v
  for v in daemon agents attach logs stop rm; do
    run_engine -- claude "$v" --json
    native
    [[ "$output" == *"stub-agent argv: $v --json"* ]]
    [[ "$output" == *"runs natively"* ]]
  done
}

@test "a management verb is native even with an unapproved, changed .agent-sandbox" {
  # A dot-file that would block a normal launch must not block managing sessions.
  printf '[claude]\nsandbox = none\n' >"$H/proj/.agent-sandbox"
  run_engine -- claude agents
  native
  [[ "$output" == *"stub-agent argv: agents"* ]]
}

@test "--bg without bg scope: runs natively (passthrough), not sandboxed" {
  run_engine -- claude --bg 'do a thing'
  native
  [[ "$output" == *"stub-agent argv: --bg do a thing"* ]]
  [[ "$output" == *"background sandboxing off"* ]]
}

@test "--bg with bg scope: wrapper mode is set up and native claude --bg is run" {
  run_engine -- claude --sandbox "fg bg" --bg 'do a thing'
  [ "$status" -eq 0 ]
  native # the --bg client itself is not sandboxed; its workers are, via the wrapper
  [[ "$output" == *"stub-agent argv: --bg do a thing"* ]]
  [ -x "$H/base/wrap-claude.sh" ]
  grep -q -- '--profile claude --wrap' "$H/base/wrap-claude.sh"
  [ "$(cat "$H/base/bg-project")" = "$H/proj" ]
}

@test "[claude] sandbox = none in a trusted dot-file makes foreground native" {
  printf '[claude]\nsandbox = none\n' >"$H/proj/.agent-sandbox"
  run_engine -- claude --trust <<<"yes" # approve it
  run_engine -- claude -p hello
  native
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
}

@test "--sandbox flag overrides the [claude] sandbox dot-file key" {
  printf '[claude]\nsandbox = none\n' >"$H/proj/.agent-sandbox"
  run_engine -- claude --trust <<<"yes"
  run_engine -- claude --sandbox fg -p hello
  sandboxed
}

@test "[claude] sandbox = none is ignored while the dot-file is unapproved (foreground stays sandboxed)" {
  # Disabling sandboxing is a widening: it must not take effect from an untrusted
  # dot-file (the scope key is trust-gated, like [net] mode = open).
  printf '[claude]\nsandbox = none\n' >"$H/proj/.agent-sandbox"
  run_engine -- claude -p hello
  sandboxed
  [[ "$output" == *"not approved"* ]]
}
