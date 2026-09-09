#!/usr/bin/env bats
# The REAL agent through the engine, one cheap turn per net mode, against the
# host's real proxy and your credentials (AGENT_SANDBOX_LIVE=1; never in CI).
#
# These exist because the stub-agent unit/integration suites cannot exercise the
# agent's own HTTP stack, and two real bugs slipped past them: a proxy URL with
# an empty-password token hung Node, and strict mode wiped the proxy env with
# --clearenv so the agent got ENOTFOUND. Each test here fails on those engines.
# Cost: a few short Haiku calls per run.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests (real network + your credentials)"
  command -v bwrap >/dev/null || skip "bwrap not installed"
  (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null || skip "no proxy on 127.0.0.1:8888 (start agent-sandbox-mitmproxy)"
  [ -r "$HOME/.claude/.credentials.json" ] || skip "no Claude credentials in ~/.claude"
  ls "$HOME/.local/share/claude/versions"/* >/dev/null 2>&1 || skip "no Claude binary under ~/.local/share/claude/versions"
}

# strict modes need pasta able to make a namespace here (as the integration suite).
strict_available() {
  command -v pasta >/dev/null || skip "pasta (passt) not installed"
  command -v nft >/dev/null || skip "nft (nftables) not installed"
  ip route show default 2>/dev/null | grep -q . || skip "no default-route gateway"
  timeout -k 1 8 pasta --config-net --quiet -- true >/dev/null 2>&1 3>&- \
    || skip "pasta cannot create a namespace here (needs passt + its AppArmor profile, or the userns sysctl relaxed)"
}

# reach MODE [engine flags...]: run one real Haiku turn through the engine in MODE.
# Prints the agent's reply; a hang or ENOTFOUND makes `timeout` fail the test.
# The prompt uses no tools, so no permission mode is set -- and note the agent
# refuses --dangerously-skip-permissions when it sees itself as root inside the
# userns, so a bypass flag would fail the launch, not exercise the network.
reach() {
  local mode="$1"
  shift
  env AGENT_SANDBOX_NET="$mode" timeout 120 "$ENGINE" --profile claude "$@" \
    --model claude-haiku-4-5-20251001 \
    -p 'Reply with the single word ok and nothing else.' </dev/null
}

@test "proxy: the real agent reaches the API" {
  run reach proxy
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

@test "proxy + --allow (per-session token): the real agent reaches the API (was the empty-password hang)" {
  run reach proxy --allow example.com
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

@test "strict: the real agent reaches the API (was the --clearenv proxy-env wipe -> ENOTFOUND)" {
  strict_available
  run reach strict
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

@test "strict + --allow (per-session token): the real agent reaches the API" {
  strict_available
  run reach strict --allow example.com
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

# --- seccomp (AGENT_SANDBOX_SECCOMP=default): the real agent still completes a turn ---
seccomp_available() {
  [ -r "$HOME/.local/share/agent-sandbox/seccomp/$(uname -m).bpf" ] \
    || skip "no compiled seccomp filter for $(uname -m); re-run install.sh"
}

@test "proxy + seccomp: the real agent reaches the API under the default-deny syscall filter" {
  seccomp_available
  AGENT_SANDBOX_SECCOMP=default run reach proxy
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

@test "strict + seccomp: the real agent reaches the API under the default-deny syscall filter" {
  seccomp_available
  strict_available
  AGENT_SANDBOX_SECCOMP=default run reach strict
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}
