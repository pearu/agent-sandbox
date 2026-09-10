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
#   profile_tmpfs=(...)         paths to overlay with a fresh tmpfs AFTER the
#   profile_rw_binds=(...)      state binds, then rebind read-write /
#   profile_ro_binds=(...)      read-only. Populated by profile_memory_scope()
#                               to hide ~/.claude/projects and rebind the
#                               current project plus approved shares.
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
#   profile_memory_scope(MODE [PATH...])  optional. Called with the memory
#                               mode (scoped|shared) and the approved share
#                               paths; appends to profile_tmpfs/_rw_binds/
#                               _ro_binds to scope per-project memory. See
#                               docs/config.md.
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

# Map a project directory to Claude Code's per-project state slug: the absolute
# path with every character outside [A-Za-z0-9-] turned into "-", one for one
# (/home/u/pro.j -> -home-u-pro-j). This must match Claude Code's own scheme, or
# scoped memory binds a directory that does not exist: the profile would mkdir
# and bind that, while the project's real memory and transcripts stayed hidden
# behind the tmpfs -- silently, and --continue/--resume would find nothing.
#
# Determined empirically with probes/slug-probe.sh, since the scheme is not
# documented: a project at .../Ab.c_d+e@f~g:h=i,j-k9 became
# ...-Ab-c-d-e-f-g-h-i-j-k9, so ".", "_", "+", "@", "~", ":", "=" and "," all
# convert, dashes/digits/both letter cases survive, and 21 input characters gave
# 21 output characters, so runs are not collapsed. Re-run that probe if a Claude
# Code release seems to have moved the scheme.
#
# Note the consequence, which is Claude Code's and not ours: two project paths
# differing only in a converted character (~/x.y and ~/x-y) share one slug, and
# therefore one memory directory.
_claude_project_slug() { printf '%s' "${1//[^A-Za-z0-9-]/-}"; }

# profile_memory_scope MODE [SHARE_PATH...] -- engine hook (see the engine's
# profile_memory_scope call). In "scoped" mode, hide ~/.claude/projects and
# rebind only the current project (read-write: its memory and transcripts) plus
# each approved project's memory/ (read-only). In "shared" mode do nothing, so
# every project's memory is visible -- the pre-0.2 default, now an opt-out. $cwd is the
# engine's current working directory.
profile_memory_scope() {
  local mode="$1"
  shift
  [[ "$mode" == scoped ]] || return 0
  local projects="$HOME/.claude/projects" cur p slug
  # cwd is a local of the engine's agent_sandbox(), visible here by dynamic scope.
  # shellcheck disable=SC2154
  cur="$projects/$(_claude_project_slug "$cwd")"
  mkdir -p "$cur" 2>/dev/null || true
  profile_tmpfs+=("$projects")
  profile_rw_binds+=("$cur")
  local m
  for p in "$@"; do
    [[ -z "$p" ]] && continue
    if [[ "$p" == *[*?[]* ]]; then
      # A pathname pattern (e.g. ~/git/acme/*): share the memory of matching
      # project directories that actually have memory. Globbing at the path
      # level, not the slug level, keeps "~/git/x/*" from also matching a
      # sibling "~/git/x-notes" (whose slug shares the prefix) or descending
      # past a single level.
      local _n=0
      while IFS= read -r m; do
        [[ -d "$m" ]] || continue
        slug="$(_claude_project_slug "$(readlink -f -- "$m")")"
        [[ -d "$projects/$slug/memory" ]] || continue
        profile_ro_binds+=("$projects/$slug/memory")
        _n=1
      done < <(compgen -G "$p" || true)
      ((_n)) || _as_msg "share-memory: pattern '$p' matched no project with memory"
    else
      slug="$(_claude_project_slug "$(readlink -f -- "$p" 2>/dev/null || echo "$p")")"
      profile_ro_binds+=("$projects/$slug/memory")
    fi
  done
  return 0
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

# profile_briefing_args INSIDE_DIR [AGENT ARGS...] -- engine hook. Hands the
# briefing to Claude Code as SessionStart and SubagentStart hooks, which fire on
# every launch, on --continue/--resume, and again after compaction, so what the
# session is told can never be older than this launch. Sets
# profile_briefing_argv; the engine appends it AFTER the user's own arguments.
#
# Deliberately not --append-system-prompt: passing that turns system-prompt
# snapshotting off, and with snapshotting on the recorded prompt is reused until
# compaction -- so a session resumed after the user opened a host would keep
# describing the old policy. A hook is re-run rather than recorded.
#
# Claude Code honours only ONE --settings: passing it twice keeps the last and
# silently drops the first (measured, as is the fact that flags still parse
# after a positional prompt -- which is why ours goes last). So when the user
# passes their own, the two are merged into one file. That merge needs a JSON
# parser: python3 is used ONLY on this path, and if it is missing the USER's
# --settings is kept and the briefing's hooks are dropped with a loud note.
# Losing a hint beats changing how someone's tools behave.
profile_briefing_args() {
  local inside="$1"
  shift
  # _session_dir is a local of the engine's agent_sandbox(), reached here by
  # dynamic scope -- the same arrangement profile_memory_scope uses for $cwd.
  # shellcheck disable=SC2154
  local host_file="$_session_dir/settings.json" inside_file="$inside/settings.json"
  local ours user_val="" i
  ours="{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"cat $inside/hook-SessionStart.json\"}]}],\"SubagentStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"cat $inside/hook-SubagentStart.json\"}]}]}}"

  # The LAST --settings, deliberately: Claude Code honours only the last one, so
  # that is the value the user's command line resolves to, and merging any
  # earlier one would resurrect settings they had overridden. A wrapper that
  # appends --settings to override an earlier one keeps working unchanged; the
  # only difference this feature makes is the two hook entries added on top,
  # which is what [briefing] mode = off is for.
  local -a rest=("$@")
  for ((i = 0; i < ${#rest[@]}; i++)); do
    case "${rest[i]}" in
      --settings) user_val="${rest[i + 1]:-}" ;;
      --settings=*) user_val="${rest[i]#--settings=}" ;;
    esac
  done

  if [[ -n "$user_val" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
      _as_msg "briefing: keeping your --settings, NOT installing the briefing's hooks. Claude Code honours only the last --settings, so merging is the only way to keep both, and that needs python3, which is not on PATH. Install python3 (or read $inside/briefing.md, bound read-only either way)."
      return 0
    fi
    local _merge_note=""
    if ! _merge_note=$(AS_OURS="$ours" AS_USER="$user_val" AS_OUT="$host_file" python3 -c '
import json, os, sys
def load(v):
    v = v.strip()
    if v.startswith("{"):
        return json.loads(v)
    with open(os.path.expanduser(v)) as fh:
        return json.load(fh)
try:
    user = load(os.environ["AS_USER"])
    ours = json.loads(os.environ["AS_OURS"])
except Exception as exc:
    sys.exit(f"cannot read --settings: {exc}")
# There is nothing to resolve here: this whole contribution is a list of two
# hook entries, appended. Only "hooks" is touched, and only by
# APPENDING to the two events the briefing uses -- hook entries merge across
# settings levels, so a per-event union is what Claude Code itself would do with
# two sources. Their entries stay first. Nothing else is read, rewritten or
# merged, so no other setting of theirs can be changed by this.
try:
    if not isinstance(user, dict):
        raise TypeError("top level is not an object")
    hooks = user.get("hooks", {})
    if not isinstance(hooks, dict):
        raise TypeError("hooks is not an object")
    hooks = dict(hooks)
    for event, entries in ours["hooks"].items():
        mine = hooks.get(event, [])
        # A shape we do not recognise is left alone rather than coerced:
        # list() of a dict would silently replace their data with its keys.
        if not isinstance(mine, list):
            raise TypeError(f"hooks.{event} is not an array")
        # Order is cosmetic here, not precedence: matching hooks run in
        # parallel, and these two events are context-only with no decision
        # control, so their additionalContext and ours are both added and
        # neither suppresses the other. Theirs reads first because it is
        # theirs, not because position confers anything.
        hooks[event] = mine + entries
    merged = dict(user)
    merged["hooks"] = hooks
except Exception as exc:
    sys.exit(f"refusing to merge --settings, leaving yours untouched: {exc}")
with open(os.environ["AS_OUT"], "w") as fh:
    json.dump(merged, fh, indent=2)
# Their setting stands, but say so: with hooks off the briefing never arrives.
if merged.get("disableAllHooks"):
    print("hooks-disabled")
'); then
      _as_msg "briefing: keeping your --settings unchanged; the briefing's hooks were not installed. $inside/briefing.md is bound read-only either way."
      return 0
    fi
    _as_msg "briefing: merged your --settings with the briefing's session hooks"
    [[ "$_merge_note" == *hooks-disabled* ]] \
      && _as_msg "briefing: your settings set disableAllHooks, so the briefing will NOT be injected into the session; $inside/briefing.md is bound read-only and can be read on request"
  else
    printf '%s\n' "$ours" >"$host_file" || {
      _as_msg "briefing: cannot write $host_file; continuing without the session hooks"
      return 0
    }
  fi

  # The session dir is host-side, so the file has to be bound in under its own
  # name for the flag to resolve inside.
  args+=(--ro-bind "$host_file" "$inside_file")
  profile_briefing_argv=(--settings "$inside_file")
  return 0
}

# Claude Code's own state directory holds far more than per-project memory, and
# most of it is keyed by session rather than by project, so scoping
# ~/.claude/projects leaves it all readable. Measured on one developer machine:
# file-history alone was 40M of VERBATIM file contents from twelve sessions
# across thirty projects, and history.jsonl held every prompt typed in any of
# them. None of it was asked for by the user, and a session that reads another
# project's source has broken the isolation the README promises.
#
# What stays visible, deliberately: CLAUDE.md and settings.json (the user's own
# instructions), credentials, plugins, statsig, and .claude.json. That last one
# is a known gap -- it lists every project path, but it is written live by the
# agent and filtering it risks breaking Claude Code for a leak that is paths and
# an email address, not project content. docs/design.md records it as a cap.
_claude_history_filter() { # $1 = history.jsonl, $2 = project dir
  # Records are compact JSON, one per line, each carrying "project":"<dir>".
  # A fixed-string match including the closing quote cannot match a different
  # project (no prefix collision), so this can only ever return too few lines,
  # never another project's -- the safe direction for a filter whose input
  # format we do not control.
  grep -F "\"project\":\"$2\"" -- "$1" 2>/dev/null || true
}

profile_isolate() {
  local c="$HOME/.claude"
  profile_isolate_spec=(
    # Verbatim file contents from other sessions. Copied out so this session's
    # own snapshots survive a resume, which is what makes undo work.
    "copyout	$c/file-history"
    # Plans are documents; leaving them shared is a leak, so copy out.
    "copyout	$c/plans"
    # Every prompt typed in any project. The session gets its own project's
    # records back, and its new ones are appended on exit.
    "append	$c/history.jsonl	_claude_history_filter"
    # Not Claude Code's, but in the same directory and just as cross-session:
    # logs written by the user's own Notification/Stop hooks. Not attributable
    # to a project, so the session starts with an empty one and its lines are
    # appended back -- the log stays complete on the host.
    "append	$c/responses.log"
    "append	$c/alerts.log"
    # Nothing below needs to outlive the session: a probe established that a
    # session starts, and a resume completes, with the whole set blanked.
    "tmpfs	$c/session-env"
    "tmpfs	$c/sessions"
    "tmpfs	$c/jobs"
    "tmpfs	$c/shell-snapshots"
    "tmpfs	$c/debug"
    "tmpfs	$c/paste-cache"
  )
}
