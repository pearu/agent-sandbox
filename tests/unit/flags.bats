#!/usr/bin/env bats
# Engine flag parsing, profile selection and refusals, via the stub bwrap.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
}

@test "no profile: exit 2 with a hint listing the profiles" {
  run_engine -- agent-sandbox --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile selected"* ]]
  [[ "$output" == *"claude"* ]]
  [ ! -s "$H/argv" ]
}

@test "--help without a profile prints engine usage; with a profile it goes to the agent" {
  run_engine -- agent-sandbox --help
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  run_engine -- claude --help
  [ "$status" -eq 0 ]
  [ "${ARGV[-1]}" = "--help" ]
  # the agent's help ends with a footer pointing at --engine-help
  [[ "$output" == *"--engine-help"* ]]
  [[ "$output" == *"runs inside a sandbox"* ]]
}

@test "--engine-help prints the engine usage even with a profile, and does not launch the agent" {
  run_engine -- claude --engine-help
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  [[ "$output" == *"--allow"* && "$output" == *"--trust"* && "$output" == *"--engine-help"* ]]
  [ ! -s "$H/argv" ]
  # also reachable without a profile via the engine name
  run_engine -- agent-sandbox --engine-help
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  [ ! -s "$H/argv" ]
}

@test "profile from argv[0], --profile NAME and --profile=NAME produce identical argv" {
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  cp "$H/argv" "$H/argv.a"
  run_engine -- agent-sandbox --profile claude --version
  [ "$status" -eq 0 ]
  cmp -s "$H/argv" "$H/argv.a"
  run_engine -- agent-sandbox --profile=claude --version
  cmp -s "$H/argv" "$H/argv.a"
  # explicit --profile wins over argv[0]
  run_engine -- claude --profile claude --version
  cmp -s "$H/argv" "$H/argv.a"
}

@test "unknown, path-like or missing profile names are refused with exit 2" {
  run_engine -- agent-sandbox --profile codex --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile 'codex'"* ]]
  run_engine -- agent-sandbox --profile ../profiles/claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad profile name"* ]]
  run_engine -- agent-sandbox --profile
  [ "$status" -eq 2 ]
  ln -s "$ENGINE" "$H/bin/nosuch"
  run_engine -- nosuch --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile 'nosuch'"* ]]
}

@test "AGENT_SANDBOX_PROFILE_DIR overrides where profiles live" {
  mkdir -p "$H/profiles2"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"Available: (none)"* ]]
  printf 'profile_command=x\n' >"$H/profiles2/broken.sh"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- agent-sandbox --profile broken --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not define profile_bin_discover"* ]]
}

@test "sourced mode: agent_sandbox() works with --profile and never infers a profile from \$0" {
  pushd "$H/proj" >/dev/null
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm BWRAP_DUMP="$H/argv" \
    bash -c "source '$ENGINE'; agent_sandbox --profile claude --version"
  popd >/dev/null
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ]
  pushd "$H/proj" >/dev/null
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm BWRAP_DUMP="$H/argv" \
    bash -c "source '$ENGINE'; agent_sandbox --version"
  popd >/dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile selected"* ]]
}

@test "--ssh flags: values required, mutual exclusion, lifetime syntax, key readability" {
  run_engine -- claude --ssh
  [ "$status" -eq 2 ] && [[ "$output" == *"--ssh needs a host"* ]]
  run_engine -- claude --ssh-unrestricted --ssh example.test --version
  [ "$status" -eq 2 ] && [[ "$output" == *"mutually exclusive"* ]]
  run_engine -- claude --ssh-timeout 5m --version
  [ "$status" -eq 2 ] && [[ "$output" == *"need --ssh HOST"* ]]
  run_engine -- claude --ssh example.test --ssh-timeout 5x --version
  [ "$status" -eq 2 ] && [[ "$output" == *"bad lifetime"* ]]
  run_engine -- claude --ssh example.test --ssh-key /nope --version
  [ "$status" -eq 2 ] && [[ "$output" == *"cannot read"* ]]
  [ ! -s "$H/argv" ]
}

@test "--allow: hostnames and .domains accepted, junk refused, ignored without a proxy" {
  run_engine -- claude --allow 'bad host' --version
  [ "$status" -eq 2 ] && [[ "$output" == *"--allow: bad host"* ]]
  run_engine -- claude --allow 'host/path' --version
  [ "$status" -eq 2 ]
  run_engine -- claude --allow
  [ "$status" -eq 2 ]
  run_engine AGENT_SANDBOX_NET=none -- claude --allow pypi.org --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"--allow is ignored"* ]]
  [ -z "$(ls -A "$H/base" 2>/dev/null)" ]
}

@test "unknown network mode is refused" {
  run_engine AGENT_SANDBOX_NET=bogus -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown AGENT_SANDBOX_NET"* ]]
}
