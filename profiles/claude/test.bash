# shellcheck shell=bash
# profiles/claude/test.bash -- the claude profile's test adapter.
#
# ============================================================================
# THE TEST ADAPTER CONTRACT
# ============================================================================
#
# What the shared tests need to know about an agent that its profile does not say.
# A profile with this file is tested by every shared test, once per adapter:
# tests/unit/profile-contract.bats, tests/integration/profile-contract.bats,
# tests/live/agent.bats and the agent block of tests/e2e/install.bats. Its agent-only
# tests go under tests/<layer>/profile-<name>/. Adding a profile adds these two and
# changes no shared test.
#
# Sourced by tests/helpers/adapters.bash (use_adapter), one adapter per test process,
# never by the engine or the installer (install.sh leaves it out of the install). It
# defines only `test_` names, writes only under the directories it is handed, and never
# reads the real HOME: a login it writes is a fake one, of the agent's shape, with no
# secrets. The live part is the exception, and only under AGENT_SANDBOX_LIVE=1: it says
# whether this machine can run a real turn, and how.
#
# What the profile already states is NOT here; the shared tests read it the engine's
# way, from _as_profile_facts and the dot-file (tests/helpers/adapters.bash:
# profile_facts, profile_get): the command, the base and its variable, the hide list,
# the resume, clear and login words, the account paths and the login's expiry key, the
# daemon's argv and status verb, the [allow] hosts.
#
#   test_plant HOME FILE        REQUIRED. Install FILE (the shared fake agent,
#                               tests/helpers/fake-agent.sh, with its header) as the
#                               agent's binary under HOME, executable, where a launch
#                               of `asb CMD` runs it from. For a profile with an
#                               install recipe ([agent] install, #6), as `asb
#                               --install` installs it: install_fake_agent HOME FILE
#                               VERSION (tests/helpers/adapters.bash) does that and
#                               prints the installed binary's path. For any other,
#                               the way the agent's own installer lays it out, with
#                               the agent's command (the profile's profile_command)
#                               on a user's PATH linked to it; print the command's
#                               path. The installer's report and the engine's binds
#                               see what a user's machine has.
#   test_root_options=(...)     The agent's options that take one value and may come
#                               before a subcommand, as the profile's briefing
#                               arguments do: the fake skips them in pairs before it
#                               reads its words. Empty when the agent has none.
#   test_base_layout=(...)      The base's top-level layout as the agent leaves it,
#                               names and kinds only: `d NAME` for a directory, `f NAME`
#                               for a file. The unit contract builds it and runs
#                               `asb --check` on it, which must list nothing
#                               unclassified: an entry left native on purpose is the
#                               profile's `[agent] visible` line, with its reason.
#   test_login DIR MARK         Write a fake login into DIR (the base, or an account's
#                               directory) in the agent's shape: the file the profile's
#                               account-paths names first, MARK in its values, no
#                               secret, an expiry (the profile's account-expiry key)
#                               far in the future. Only for a profile with accounts.
#   test_live_ready             Live only. Return 0 when this machine can run a real
#                               turn of the agent (its binary, its login, the proxy);
#                               else print why and return 1. Reading a path's
#                               existence is fine; reading a credential is not.
#   test_live_turn PROMPT       Live only. Set TEST_LIVE_ARGV to the agent's command and
#                               arguments for one cheap real turn answering PROMPT,
#                               non-interactively, using no tool.
#   test_live_briefing_ask      Live only. The question whose answer is in the agent's
#                               context only if the briefing reached it (no tool may be
#                               used); the shared test adds how to reply.
#   test_live_briefing_marker   Live only. What the answer contains when it did.
#
# docs/profiles.md ("Adding a profile") points here.

# The claude profile has an install recipe (#6): `asb claude` runs asb's install of Claude
# Code, never one on PATH, so the fake is installed as `asb --install claude` would.
test_plant() {
  install_fake_agent "$1" "$2" 9.9.9
}

# Root options come before a subcommand, as Claude Code's do (`claude --settings X mcp
# list`): the briefing's --settings is first on the line.
# shellcheck disable=SC2034 # the adapter contract: read by the shared tests
test_root_options=(--settings)

# ~/.claude's top level as Claude Code 2.1 leaves it, from the layout written down in
# docs/connections.md (the channel table and "Two things in the state directory belong
# to no channel") and docs/cross-project-channels.md (groups C-F), plus the account
# files (#355). Not re-measured for this file: update it from a measurement when Claude
# Code adds an entry, and the contract shows whether the profile classifies it.
# shellcheck disable=SC2034
test_base_layout=(
  "f CLAUDE.md" "d rules" "f settings.json" "d output-styles"
  "d skills" "d commands" "d agents" "d workflows" "d plugins"
  "d projects" "d usage-data" "d file-history" "d plans" "f history.jsonl"
  "d agent-memory" "f responses.log" "f alerts.log"
  "d downloads" "d uploads" "d tasks"
  "f remote-settings.json" "f policy-limits.json" "f policy-limits.json.stamp.json"
  "f policy-limits.json.signature.json" "f policy-limits.json.signature-iat.json"
  "f remote-settings.json.signature.json" "f remote-settings.json.signature-iat.json"
  "f remote-settings.json.synced-at" "d cache"
  "d daemon" "d session-env" "d sessions" "d jobs" "d shell-snapshots" "d debug"
  "d paste-cache" "d backups" "d feedback-bundles" "d image-cache" "d gh" "d ide"
  "f .credentials.json" "f .oauth_refresh.lock" "f .oauth_refresh.lock.owner"
  "d telemetry" "f stats-cache.json"
)

# Claude Code's OAuth login (.credentials.json, measured on 2.1.319: claudeAiOauth with
# the refresh token's expiry in epoch milliseconds). Dummy values only.
test_login() {
  mkdir -p "$1"
  printf '{"claudeAiOauth": {"accessToken": "%s-access-not-a-token", "refreshToken": "%s-refresh-not-a-token", "expiresAt": 4102444800000, "refreshTokenExpiresAt": 4102444800000, "scopes": ["user:inference"], "subscriptionType": "fake"}}\n' \
    "$2" "$2" >"$1/.credentials.json"
}

# The host's proxy at the port install.sh recorded (test_proxy_port,
# tests/helpers/proxy-port.bash), a login in ~/.claude, and Claude Code installed for asb
# (asb --install claude, #6), which is what `asb claude` runs.
test_live_ready() {
  local pp
  pp="$(test_proxy_port "$HOME")"
  (echo >"/dev/tcp/127.0.0.1/$pp") 2>/dev/null || {
    echo "no proxy on 127.0.0.1:$pp (start agent-sandbox-mitmproxy)"
    return 1
  }
  [ -r "$HOME/.claude/.credentials.json" ] || {
    echo "no Claude credentials in ~/.claude"
    return 1
  }
  [ -x "${XDG_STATE_HOME:-$HOME/.local/state}/agent-sandbox/claude/install/current/claude" ] || {
    echo "Claude Code is not installed for asb (asb --install claude)"
    return 1
  }
}

# One short Haiku call. The prompt uses no tools, so no permission mode is set -- and the
# agent refuses --dangerously-skip-permissions when it sees itself as root inside the
# userns, so a bypass flag would fail the launch, not exercise the network.
test_live_turn() {
  # shellcheck disable=SC2034
  TEST_LIVE_ARGV=(claude --model claude-haiku-4-5-20251001 -p "$1")
}

# The briefing's SessionStart hook is the only thing that tells the agent this path.
# shellcheck disable=SC2034
test_live_briefing_ask='Without using any tool, answer from what is already in your context: what absolute path were you told holds the details of this sandbox?'
# shellcheck disable=SC2034
test_live_briefing_marker=/run/agent-sandbox/briefing.md
