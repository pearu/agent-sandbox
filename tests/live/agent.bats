#!/usr/bin/env bats
# The REAL agent through the engine, one cheap turn per net mode, against the
# host's real proxy and your credentials (AGENT_SANDBOX_LIVE=1; never in CI).
# For every profile with a test adapter (profiles/*/test.bash): its test_live_turn says
# how to ask for one turn, its test_live_ready whether this machine can. An adapter that
# is not ready skips, saying why; AGENT_SANDBOX_LIVE_AGENTS="claude codex" runs only
# those named, and fails one of them that is not ready, since it was asked for.
#
# These exist because the stub-agent unit/integration suites cannot exercise the
# agent's own HTTP stack, and two real bugs slipped past them: a proxy URL with
# an empty-password token hung Node, and strict mode wiped the proxy env with
# --clearenv so the agent got ENOTFOUND. Each test here fails on those engines.
# Cost: a few short calls of the agent's cheapest model per run.

# shellcheck disable=SC2154,SC2016,SC2030,SC2031
# (file-wide: the tests are functions registered with bats_test_function, where `run`
# sets $status and $output out of ShellCheck's sight, and the adapter's test_* names are
# sourced at run time; the single-quoted scripts run in another shell)
load "$BATS_TEST_DIRNAME/../helpers/adapters"

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests (real network + your credentials)"
  command -v bwrap >/dev/null || skip "bwrap not installed"
}

# live_setup NAME -- the adapter in use, ready to run a real turn here, or the test skips
# (fails, when AGENT_SANDBOX_LIVE_AGENTS names it).
live_setup() {
  use_adapter "$1"
  local why
  if ! why="$(test_live_ready)"; then
    if [[ -n "${AGENT_SANDBOX_LIVE_AGENTS:-}" ]]; then
      echo "$1: not ready for a live turn: $why"
      return 1
    fi
    skip "$1: $why"
  fi
}

# strict modes need pasta able to make a namespace here (as the integration suite).
strict_available() {
  command -v pasta >/dev/null || skip "pasta (passt) not installed"
  command -v nft >/dev/null || skip "nft (nftables) not installed"
  ip route show default 2>/dev/null | grep -q . || skip "no default-route gateway"
  timeout -k 1 8 pasta --config-net --quiet -- true >/dev/null 2>&1 3>&- \
    || skip "pasta cannot create a namespace here (needs passt + its AppArmor profile, or the userns sysctl relaxed)"
}

# --- seccomp (AGENT_SANDBOX_SECCOMP=on): the real agent still completes a turn ---
seccomp_available() {
  [ -r "$HOME/.local/share/agent-sandbox/seccomp/$(uname -m).bpf" ] \
    || skip "no compiled seccomp filter for $(uname -m); re-run install.sh"
}

# reach MODE [engine flags...]: run one real turn of the adapter's agent through the
# engine in MODE. Prints the agent's reply; a hang or ENOTFOUND makes `timeout` fail the
# test. How the turn is asked for (model, print mode, no tool) is the adapter's
# (test_live_turn).
reach() {
  local mode="$1"
  shift
  test_live_turn 'Reply with the single word ok and nothing else.'
  env AGENT_SANDBOX_NET="$mode" timeout 120 "$ENGINE" "$@" "${TEST_LIVE_ARGV[@]}" </dev/null
}

live_proxy() {
  live_setup "$1"
  run reach proxy
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

live_proxy_allow() {
  live_setup "$1"
  run reach proxy --allow example.com
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

live_strict() {
  live_setup "$1"
  strict_available
  run reach strict
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

live_strict_allow() {
  live_setup "$1"
  strict_available
  run reach strict --allow example.com
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

live_proxy_seccomp() {
  live_setup "$1"
  seccomp_available
  AGENT_SANDBOX_SECCOMP=on run reach proxy
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

live_strict_seccomp() {
  live_setup "$1"
  seccomp_available
  strict_available
  AGENT_SANDBOX_SECCOMP=on run reach strict
  [ "$status" -eq 0 ]
  [[ "${output,,}" == *ok* ]]
}

# --- the briefing (issue #15): does the real agent actually receive it? ---
# The unit suite proves the engine writes the briefing and passes the hooks; only
# the real agent can prove the hooks FIRE and the text lands in its context. The
# prompt is answerable only from injected context: nothing tells the agent that
# path except the briefing, and the question forbids looking (test_live_briefing_ask).

live_briefing() {
  live_setup "$1"
  test_live_turn "$test_live_briefing_ask Reply with the path and nothing else."
  run env AGENT_SANDBOX_NET=proxy timeout 120 "$ENGINE" "${TEST_LIVE_ARGV[@]}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"$test_live_briefing_marker"* ]]
}

live_briefing_off() {
  live_setup "$1"
  test_live_turn "$test_live_briefing_ask Reply with the path, or the single word none."
  run env AGENT_SANDBOX_NET=proxy AGENT_SANDBOX_BRIEFING=off timeout 120 "$ENGINE" "${TEST_LIVE_ARGV[@]}" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"$test_live_briefing_marker"* ]]
}

if [[ -n "${AGENT_SANDBOX_LIVE_AGENTS:-}" ]]; then
  live_agents="$AGENT_SANDBOX_LIVE_AGENTS"
else
  live_agents="$(test_adapters)"
fi
for a in $live_agents; do
  bats_test_function --description "$a: proxy: the real agent reaches the API" -- live_proxy "$a"
  bats_test_function --description "$a: proxy + --allow (per-session token): the real agent reaches the API (was the empty-password hang)" -- live_proxy_allow "$a"
  bats_test_function --description "$a: strict: the real agent reaches the API (was the --clearenv proxy-env wipe -> ENOTFOUND)" -- live_strict "$a"
  bats_test_function --description "$a: strict + --allow (per-session token): the real agent reaches the API" -- live_strict_allow "$a"
  bats_test_function --description "$a: proxy + seccomp: the real agent reaches the API under the default-deny syscall filter" -- live_proxy_seccomp "$a"
  bats_test_function --description "$a: strict + seccomp: the real agent reaches the API under the default-deny syscall filter" -- live_strict_seccomp "$a"
  bats_test_function --description "$a: briefing: the real agent has the briefing in context at session start, without reading any file" -- live_briefing "$a"
  bats_test_function --description "$a: briefing off: the same question has no answer, so the briefing is what put it there" -- live_briefing_off "$a"
done
