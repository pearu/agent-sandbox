#!/usr/bin/env bash
# profiles/claude.sh — agent-sandbox profile for Claude Code (the flagship).
#
# Sourced by the engine (agent-sandbox) after it has parsed its own flags,
# on the HOST, before the sandbox exists. The engine runs with
# `set -euo pipefail`; profile code is subject to it.
#
# ============================================================================
# THE PROFILE CONTRACT
# ============================================================================
#
# Variables a profile declares (all optional unless marked REQUIRED):
#
#   profile_command             on-PATH name of the agent. The installer
#                               symlinks ~/.local/bin/<profile_command> at the
#                               engine, and the engine infers the profile from
#                               argv[0]. Defaults to the profile's file name.
#   profile_config_binds=(...)  host paths bound READ-WRITE into the sandbox:
#                               the agent's state and config. They must exist
#                               when the sandbox is built; create them in
#                               profile_prepare().
#   profile_env_pass=(...)      environment variable NAMES forwarded into the
#                               sandbox IF set in the caller's environment, on
#                               top of the engine's own list (locale, proxy,
#                               TLS, CUDA).
#   profile_env_set=(...)       NAME=VALUE pairs always set in the sandbox.
#   profile_allowlist_seed      path of a file listing the hosts this agent
#                               must reach (allowlist syntax: one host per
#                               line, leading dot = domain + subdomains). The
#                               installer merges it into the global egress
#                               allowlist; the engine does not read it.
#   profile_host_subcommands=() agent subcommands the engine hands to
#                               profile_handle_subcommand() to run on the
#                               host, unsandboxed, instead of launching the
#                               sandbox (e.g. self-update).
#
# Functions a profile defines:
#
#   profile_bin_discover()      REQUIRED. Locate the agent executable: set
#                               profile_bin (path) and profile_version (for
#                               messages). On failure print why (use _as_msg)
#                               and return non-zero.
#   profile_prepare()           optional. Runs right before the sandbox is
#                               assembled; create state files here.
#   profile_handle_subcommand() required iff profile_host_subcommands is
#                               non-empty. Receives the agent's full argv
#                               ($1 is the subcommand); its return code is
#                               the exit code.
#
# What the engine provides to a profile: AGENT_SANDBOX_ENGINE (real path of
# the engine file), AGENT_SANDBOX_PROFILE (this profile's name),
# AGENT_SANDBOX_PROFILE_DIR, and _as_msg (prefixed stderr messages). A
# profile must not touch the engine's bwrap argument list directly -- the
# declarations above are the whole interface, so that the sandbox's isolation
# guarantees stay reviewable in one place (the engine).

# The profile_* variables below are the contract: the engine reads them after
# sourcing this file, so shellcheck sees them as unused here.
# shellcheck disable=SC2034
profile_command=claude

# Claude keeps its state in ~/.claude (sessions, OAuth/API tokens, settings)
# and top-level config in ~/.claude.json. Both must be writable.
profile_config_binds=("$HOME/.claude" "$HOME/.claude.json")

profile_env_pass=(
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
  ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
)

# Never let the sandboxed claude try to self-update. Downloads are blocked by
# the proxy allowlist and the versions directory is not bound, so the attempt
# could only fail; `claude update` (run on the host via
# profile_handle_subcommand below) is the supported path. Note: the legacy
# `autoUpdates: false` in ~/.claude.json is ignored for native installs.
profile_env_set=(DISABLE_AUTOUPDATER=1)

profile_allowlist_seed="$(dirname -- "${BASH_SOURCE[0]}")/claude.allowlist"

profile_host_subcommands=(update upgrade install)

# The native installer's layout: each entry under versions/ is either a
# single executable file named after the version (e.g. 2.1.143) or a
# directory containing a `claude` binary.
_claude_versions_dir="$HOME/.local/share/claude/versions"

_claude_list_versions() {
  find "$_claude_versions_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d -o -type l \) \
    -printf '%f\n' 2>/dev/null | sort -V
}

profile_prepare() {
  mkdir -p "$HOME/.claude"
  # Ensure ~/.claude.json exists so it can be bound (bwrap refuses missing
  # sources).
  [[ -e "$HOME/.claude.json" ]] || : >"$HOME/.claude.json"
  return 0
}

profile_bin_discover() {
  [[ -d "$_claude_versions_dir" ]] || {
    _as_msg "missing $_claude_versions_dir"
    return 1
  }
  # Pick the highest version-sorted entry of either kind.
  local latest cand
  latest="$(_claude_list_versions | tail -n1)"
  [[ -n "$latest" ]] || {
    _as_msg "no versions under $_claude_versions_dir"
    return 1
  }
  profile_bin=""
  if [[ -x "$_claude_versions_dir/$latest" && ! -d "$_claude_versions_dir/$latest" ]]; then
    profile_bin="$_claude_versions_dir/$latest"
  else
    for cand in "$_claude_versions_dir/$latest/claude" "$_claude_versions_dir/$latest/bin/claude"; do
      [[ -x "$cand" ]] && {
        profile_bin="$cand"
        break
      }
    done
  fi
  [[ -n "$profile_bin" ]] || {
    _as_msg "no executable found for version '$latest'"
    return 1
  }
  profile_version="$latest"
  return 0
}

# `claude update` (alias `upgrade`) and `claude install [target]` run the
# newest installed binary directly on the host with the caller's environment;
# the sandbox would block the download and has no writable versions directory.
# The native updater installs under versions/<version>, and
# profile_bin_discover always runs the highest version found there, so the
# update takes effect on the next launch. As of Claude Code 2.1.263 the
# updater refuses to overwrite a launcher at ~/.local/bin/claude that is not
# its own versions/ symlink (it logs "Not replacing ..." and still reports
# success), so the engine stays on PATH. Should an installer re-point the
# launcher anyway, restore it right after the subcommand finishes.
profile_handle_subcommand() {
  local launcher="$HOME/.local/bin/$profile_command" before after rc=0
  before="$(readlink -f -- "$launcher" 2>/dev/null || true)"
  _as_msg "running '$profile_version $*' on the host (unsandboxed)"
  "$profile_bin" "$@" || rc=$?
  after="$(readlink -f -- "$launcher" 2>/dev/null || true)"
  if [[ "$before" == "$AGENT_SANDBOX_ENGINE" && "$after" != "$AGENT_SANDBOX_ENGINE" ]]; then
    ln -sfn -- "$AGENT_SANDBOX_ENGINE" "$launcher"
    _as_msg "installer re-pointed $launcher -> $after; restored -> $AGENT_SANDBOX_ENGINE"
  fi
  _as_msg "installed versions: $(_claude_list_versions | tr '\n' ' ')"
  return "$rc"
}
