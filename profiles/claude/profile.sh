#!/usr/bin/env bash
# profiles/claude/profile.sh — agent-sandbox profile for Claude Code (the flagship).
#
# Sourced by the engine (agent-sandbox) after it has parsed its own flags,
# on the HOST, before the sandbox exists. The engine runs with
# `set -euo pipefail`; profile code is subject to it.
#
# What the profile states as data is in its dot-file beside this script,
# profiles/claude/agent-sandbox (#181): the verbs, the paths blanked every launch,
# the forwarded variables and the hosts it must reach. This script keeps the rest.
#
# ============================================================================
# THE PROFILE CONTRACT
# ============================================================================
#
# Variables a profile declares (all optional unless marked REQUIRED):
#
#   profile_command             on-PATH name of the agent: what the engine
#                               runs when no command is typed (a verb, --exec,
#                               `asb --profile NAME`). Defaults to the profile's
#                               file name, which is also what a typed command's
#                               basename must be to select the profile (#151).
#   profile_config_binds=(...)  host paths bound READ-WRITE into the sandbox:
#                               the agent's state and config. They must exist
#                               when the sandbox is built; create them in
#                               profile_prepare(). An entry is a path bound at
#                               itself, or SRC<TAB>DEST to bind SRC at DEST
#                               inside; a DEST under an earlier entry layers
#                               on it, so order the entries parent first.
#   profile_tmpfs=(...)         paths to overlay with a fresh tmpfs AFTER the
#   profile_rw_binds=(...)      state binds, then rebind read-write /
#   profile_ro_binds=(...)      read-only. Populated by profile_memory_scope()
#                               to hide ~/.claude/projects and rebind the
#                               current project plus approved shares.
#   profile_env_pass=(...)      environment variable NAMES forwarded into the
#                               sandbox IF set in the caller's environment, on
#                               top of the engine's own list (locale, proxy,
#                               TLS, CUDA). Also the dot-file's [env] NAME.
#   profile_env_set=(...)       NAME=VALUE pairs always set in the sandbox.
#   profile_env_refuse=(...)    NAMES a user may not forward ([env],
#                               AGENT_SANDBOX_FORWARD): refused with a
#                               message. Names in profile_env_set are refused
#                               the same way, so a forward cannot override
#                               what the profile pins.
#
# Functions a profile defines:
#
#   profile_prepare()           optional. Runs right before the sandbox is
#                               assembled; create state files here.
#   profile_memory_scope(MODE [PATH...])  optional. Called with the memory
#                               mode (scoped|shared) and the approved share
#                               paths; appends to profile_tmpfs/_rw_binds/
#                               _ro_binds to scope per-project memory. See
#                               docs/config.md.
#
# What the engine provides to a profile: profile_bin (the agent executable,
# resolved), AGENT_SANDBOX_ENGINE (real path of the engine file),
# AGENT_SANDBOX_PROFILE (this profile's name),
# AGENT_SANDBOX_PROFILE_DIR, and _as_msg (prefixed stderr messages). A
# profile must not touch the engine's bwrap argument list directly -- the
# declarations above are the whole interface, so that the sandbox's isolation
# guarantees stay reviewable in one place (the engine).

# The profile_* variables below are the contract: the engine reads them after
# sourcing this file, so shellcheck sees them as unused here.
# shellcheck disable=SC2034
profile_command=claude

# Claude keeps its state in ~/.claude (sessions, OAuth/API tokens, settings), or where
# CLAUDE_CONFIG_DIR says: the profile's base, bound read-write first -- `[agent] base`
# and `base-env` in its dot-file (#175, #190). The engine sets $profile_base to it.
#
# THE CHANNEL TABLE is the dot-file's [channel:<name>] sections (#190), each path with
# its source, filter and vendor prefixes, and the reasons beside them. What a channel
# starts as under `own`, and its rung under each preset, are still here until #191:
# shellcheck disable=SC2034
profile_channel_empty=("config	{}" "policy	{}")
# shellcheck disable=SC2034
profile_channel_presets=("config	inherit=seed-only shared=seed-only"
  "transcripts	inherit=own shared=own" "logs	inherit=own shared=own"
  "artefacts	inherit=own" "policy	inherit=seed-only")

# The environment it pins and refuses is the dot-file's [env] (#177): DISABLE_AUTOUPDATER,
# CLAUDE_CONFIG_DIR, and the refusal of CLAUDE_CODE_PROJECT_DIR_NAME, each with its
# reason. Under `native`, _claude_config_prepare drops the second and the third.

# Keys this profile reads from a `[claude]` section of a project's .agent-sandbox.
# The single source of truth: the review warns on any other [claude] key (a typo
# must not silently do nothing), and the docs drift-check verifies each is
# documented. `hide` is read in profile_isolate(). The profile's own [agent] keys
# (the verbs, in agent-sandbox beside this file) are not among them: a project's
# file may not set those.
profile_dotfile_keys=(hide)

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
#
# Long paths are truncated, which the docs do state: "For a working directory
# whose converted name exceeds 200 characters, Claude Code truncates the name to
# 200 characters and appends a hash of the full path"
# (https://code.claude.com/docs/en/sessions). Which hash is not stated; see
# _claude_path_hash. Without this the engine binds projects/<untruncated>, and
# between 201 and 255 characters that is a directory Claude Code never uses, so
# the session's transcripts and memory land on the tmpfs and are lost on exit;
# past 255 the name exceeds NAME_MAX, cannot be created, and the launch fails.
_claude_project_slug() {
  local conv="${1//[^A-Za-z0-9-]/-}"
  if ((${#conv} <= 200)); then
    printf '%s' "$conv"
    return 0
  fi
  printf '%s-%s' "${conv:0:200}" "$(_claude_path_hash "$1")"
}

# profile_slug DIR -- engine hook (#176): what `{slug}` expands to in the channel table
# and in a declaration, this project's name under ~/.claude/projects/.
profile_slug() { _claude_project_slug "$1"; }

# The hash Claude Code appends to a truncated project name: the 32-bit
# h = h*31 + c string hash of the ORIGINAL path, printed base36 from its
# ABSOLUTE value -- so the suffix is 1 to 6 characters, not a fixed width (the
# largest magnitude, 2147483648, is "zik0zk"). Derived from real slugs recorded
# by probes/config-dir-check.sh --matrix; both vectors are pinned as tests.
#
# Hashes bytes, under LC_ALL=C. That reproduces every measured vector, all of
# which are ASCII. A path with non-ASCII characters could differ if Claude Code
# hashes UTF-16 code units instead of bytes -- unmeasured, and it only matters
# for a path whose converted name already exceeds 200 characters. The truncation
# POINT is unaffected: conversion maps any non-ASCII character to "-", so both
# sides count the same characters.
_claude_path_hash() {
  local LC_ALL=C s="$1" n i c v h=0 out=""
  local digits=0123456789abcdefghijklmnopqrstuvwxyz
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    printf -v v '%d' "'$c"
    h=$(((h * 31 + (v & 0xff)) & 0xffffffff))
  done
  if ((h >= 0x80000000)); then h=$((h - 0x100000000)); fi
  if ((h < 0)); then h=$((-h)); fi
  if ((h == 0)); then
    printf '0'
    return 0
  fi
  while ((h > 0)); do
    out="${digits:$((h % 36)):1}$out"
    h=$((h / 36))
  done
  printf '%s' "$out"
}

# profile_memory_scope MODE [SHARE_PATH...] -- engine hook (see the engine's
# profile_memory_scope call). In "scoped" mode, hide ~/.claude/projects and
# rebind only the current project (read-write: its memory and transcripts) plus
# each approved project's memory/ (read-only). In "shared" mode do nothing, so
# every project's memory is visible -- the pre-0.2 default, now an opt-out. $cwd is the
# engine's current working directory.
# _claude_memory_on_top -- when `transcripts` has a store at projects/<slug>/, the
# project's memory, inside it, is still the project's native memory: bound read-write
# after the connections, on top of the store. Memory keeps its own machinery until it
# is a managed channel; the store must not quietly take it over.
_claude_memory_on_top() {
  # shellcheck disable=SC2154 # engine locals, by dynamic scope
  [[ "${_connect_mode[transcripts]:-read-write}" == read-write ]] && return 1
  local mem
  # shellcheck disable=SC2154 # profile_base: set by the engine from [agent] base
  mem="$profile_base/projects/$(_claude_project_slug "$(_as_project_dir)")/memory"
  mkdir -p "$mem" 2>/dev/null || true
  profile_late_rw_binds+=("$mem")
  return 0
}
profile_memory_scope() {
  local mode="$1"
  shift
  if [[ "$mode" != scoped ]]; then
    _claude_memory_on_top || true
    return 0
  fi
  local projects="$profile_base/projects" cur p slug
  # cwd is a local of the engine's agent_sandbox(), visible here by dynamic scope.
  # shellcheck disable=SC2154
  cur="$projects/$(_claude_project_slug "$cwd")"
  mkdir -p "$cur" 2>/dev/null || true
  profile_tmpfs+=("$projects")
  # This project's directory is the native one only when `transcripts` is read-write;
  # otherwise the role's store takes its place and memory goes on top of it.
  _claude_memory_on_top || profile_rw_binds+=("$cur")
  # A share naming this project would rebind the memory the session is about to
  # write READ-ONLY over the read-write bind above, silently breaking its own
  # memory. Drop it instead: it is already there, writable.
  local m own_mem="$cur/memory"
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
        _n=1
        [[ "$projects/$slug/memory" == "$own_mem" ]] && continue
        profile_ro_binds+=("$projects/$slug/memory")
      done < <(compgen -G "$p" || true)
      ((_n)) || _as_msg "share-memory: pattern '$p' matched no project with memory"
    else
      slug="$(_claude_project_slug "$(readlink -f -- "$p" 2>/dev/null || echo "$p")")"
      [[ "$projects/$slug/memory" == "$own_mem" ]] \
        || profile_ro_binds+=("$projects/$slug/memory")
    fi
  done
  return 0
}

profile_prepare() {
  # Ensure ~/.claude.json exists: it seeds this project's copy of it. With
  # CLAUDE_CONFIG_DIR set, Claude Code keeps it in the base instead (see
  # _claude_config_prepare), which the engine creates.
  [[ -n "${CLAUDE_CONFIG_DIR:-}" || -e "$HOME/.claude.json" ]] || : >"$HOME/.claude.json"
  _claude_config_prepare || return 1
  return 0
}

# ----- the config file: the `config` channel ----------------------------------
# ~/.claude.json is app state -- onboarding, tips, caches -- plus three things that
# are per project or user-authored: the per-project entries (folder trust, allowed
# tools, MCP servers added for that project, the last opening prompt), the user-level
# mcpServers, and the account. Bound whole it was two channels at once (leak study
# rows 10 and 11): a sandboxed session read every other project's entry, and what it
# wrote reached every other session. It is now the `config` channel (see
# profile_channels above), and this is the profile's half of it.
_claude_config_project() {
  # The project the file is keyed by: the background project for a wrapped worker
  # (the daemon's cwd is not it), the session's cwd otherwise. The engine asks the
  # same question for a sandbox's connection state, so it answers here too.
  _as_project_dir
}
# The role's store for the config file at MODE, for a project.
_claude_config_store() { # $1 = project dir, $2 = mode
  local inside="$profile_base/.claude.json"
  inside="${inside//\//_}"
  printf '%s/claude/%s/%s/config/%s/%s' "$(_as_state_dir)" "$(_claude_project_slug "$1")" \
    "${_role:-default}" "$2" "${inside#_}"
}
# _claude_config_filter SOURCE VIEW -- the seed the seeding modes read: every
# top-level key and, of the per-project entries, only this project's. Without a
# working python3 the view is the whole file, and the launch says so: a seed that is
# the whole file is the 0.2.0 exposure, but refusing the launch for it would be worse
# than saying it, and the file is still never written back.
_claude_config_filter() {
  local src="$1" view="$2" why="" rc=0
  if command -v python3 >/dev/null 2>&1; then
    AS_SRC="$src" AS_VIEW="$view" AS_PROJECT="$(_claude_config_project)" python3 - <<'PY' 2>/dev/null || rc=$?
import json, os
src, view, project = (os.environ[k] for k in ("AS_SRC", "AS_VIEW", "AS_PROJECT"))
try:
    with open(src, encoding="utf-8") as fh:
        n = json.load(fh)
except (OSError, ValueError):
    n = {}
if not isinstance(n, dict):
    n = {}
v = {k: val for k, val in n.items() if k != "projects"}
projects = n.get("projects")
v["projects"] = {project: projects[project]} if isinstance(projects, dict) and project in projects else {}
fd = os.open(view, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(v, fh)
PY
    ((rc)) && why="python3 failed (exit $rc)"
  else
    why="python3 missing"
  fi
  if [[ -n "$why" ]]; then
    rm -f -- "$view" 2>/dev/null
    (umask 077 && cp -- "$src" "$view") || return 1
    _as_msg "$why: this project's config file is seeded from the whole ~/.claude.json, other projects' entries included"
  fi
  return 0
}
_claude_config_prepare() {
  # `native` means parity with no sandbox, and a native Claude Code reads
  # ~/.claude.json itself. The engine binds nothing for a relocated channel path
  # under `native` (see _as_channel_source), and the profile drops the relocation:
  #
  # CLAUDE_CONFIG_DIR goes with it. The engine sets it because a read-only $HOME
  # loses the lock and the rename Claude Code writes beside its config file
  # (#91) -- and that remount is exactly what `native` skips. Keeping the
  # workaround without the problem would leave the config at a path no native
  # session uses, which was the first divergence this preset turned up.
  #
  # CLAUDE_CODE_PROJECT_DIR_NAME stops being refused for the same reason: it is
  # only honoured when CLAUDE_CONFIG_DIR is set, and there is no per-project
  # scoping left here for it to escape.
  # shellcheck disable=SC2154 # engine local, by dynamic scope
  if [[ "${_preset:-}" == native ]]; then
    local -a _keep=()
    local _kv
    for _kv in "${profile_env_set[@]}"; do
      [[ "$_kv" == CLAUDE_CONFIG_DIR=* ]] || _keep+=("$_kv")
    done
    profile_env_set=("${_keep[@]}")
    profile_env_refuse=()
    return 0
  fi
  # THE CONFIG FILE'S SOURCE DEPENDS ON THE BASE. With the default base, native Claude
  # Code keeps it at ~/.claude.json, which the dot-file's `outside:` relocates into the
  # base. With CLAUDE_CONFIG_DIR set, it keeps it at $CLAUDE_CONFIG_DIR/.claude.json
  # (measured: with the variable set, ~/.claude.json is never opened) -- the path itself,
  # so the relocation goes. A condition on the launching environment, so code (#190).
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    local -a _src=()
    local _s
    for _s in ${profile_channel_sources[@]+"${profile_channel_sources[@]}"}; do
      [[ "${_s%%$'\t'*}" == "$profile_base/.claude.json" ]] || _src+=("$_s")
    done
    profile_channel_sources=(${_src[@]+"${_src[@]}"})
  fi
  return 0
}

# profile_before_join [AGENT ARGS...] -- engine hook, called just before an agent
# command is joined into the role's launch. A `--bg` cannot answer Claude Code's
# workspace-trust prompt, and its worker waits on it (measured, 2.1.283); the user
# running `claude --bg` in this folder is the consent the prompt would ask for. So
# the trust is recorded in the role's own config file when it is not there -- an
# `isolated` role, or a project never trusted natively (under `inherit` the seed
# carries the native entry's trust). Only in a store the role owns: never the native
# file, which `read-write` and `native` bind.
# shellcheck disable=SC2154
profile_before_join() {
  local a is_bg=0 mode store proj
  for a in "$@"; do [[ "$a" == --bg ]] && is_bg=1; done
  ((is_bg)) || return 0
  mode="${_connect_mode[config]:-}"
  case "$mode" in own | seed-only | copy) ;; *) return 0 ;; esac
  proj="$(_claude_config_project)"
  store="$(_claude_config_store "$proj" "$mode")"
  [[ -f "$store" ]] || return 0
  AS_CJ="$store" AS_PROJ="$proj" python3 - <<'PY' 2>/dev/null && return 0
import json, os, sys
d = json.load(open(os.environ["AS_CJ"]))
sys.exit(0 if (d.get("projects") or {}).get(os.environ["AS_PROJ"], {}).get("hasTrustDialogAccepted") else 1)
PY
  _claude_mark_trust "$store" "$proj" \
    && _as_msg "recorded workspace trust for $proj in role '${_role:-default}' (a --bg cannot ask)"
  return 0
}

# _claude_mark_trust FILE PROJECT -- record PROJECT as trusted in the config FILE, in
# place: the file is bind-mounted into the running launch, and a rename would leave
# the launch on the old one.
_claude_mark_trust() {
  AS_CJ="$1" AS_PROJ="$2" python3 - <<'PY' 2>/dev/null || _as_msg "could not record workspace trust for '$2' in $1"
import json, os
cj, proj = os.environ["AS_CJ"], os.environ["AS_PROJ"]
try:
    d = json.load(open(cj))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
with open(cj, "r+") as fh:
    fh.seek(0)
    json.dump(d, fh)
    fh.truncate()
PY
}

# profile_briefing_args INSIDE_DIR [AGENT ARGS...] -- engine hook. Hands the
# briefing to Claude Code as SessionStart and SubagentStart hooks, which fire on
# every launch, on --continue/--resume, and again after compaction, so what the
# session is told can never be older than this launch. Sets
# profile_briefing_argv, which the engine puts BEFORE the user's own arguments:
# a subcommand refuses --settings after it (`claude mcp list --settings X` is
# "unknown option"; `claude --settings X mcp list` works, measured on 2.1.285).
#
# Deliberately not --append-system-prompt: passing that turns system-prompt
# snapshotting off, and with snapshotting on the recorded prompt is reused until
# compaction -- so a session resumed after the user opened a host would keep
# describing the old policy. A hook is re-run rather than recorded.
#
# Claude Code honours only ONE --settings: passing it twice keeps the last and
# silently drops the first (measured). So when the user passes their own, the two
# are merged into one file, and theirs is dropped from the arguments
# (profile_agent_argv), or it would win over ours. That merge needs a JSON
# parser: python3 is used ONLY on this path, and if it is missing the USER's
# --settings is kept and the briefing's hooks are dropped with a loud note.
# Losing a hint beats changing how someone's tools behave.
profile_briefing_args() {
  local inside="$1"
  shift
  # Where this invocation's own file goes: _brief_out_host is a directory the engine
  # has in view at _brief_out_inside -- the briefing directory itself for the launch
  # that starts the keeper, a directory of its own inside it for a later join, whose
  # --settings may differ. Engine locals, reached here by dynamic scope.
  # shellcheck disable=SC2154
  local host_file="$_brief_out_host/settings.json" inside_file="$_brief_out_inside/settings.json"
  local ours user_val="" i
  ours="{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"cat $inside/hook-SessionStart.json\"}]}],\"SubagentStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"cat $inside/hook-SubagentStart.json\"}]}]}}"

  # The LAST --settings, deliberately: Claude Code honours only the last one, so
  # that is the value the user's command line resolves to, and merging any
  # earlier one would resurrect settings they had overridden. A wrapper that
  # appends --settings to override an earlier one keeps working unchanged; the
  # only difference this feature makes is the two hook entries added on top,
  # which is what [briefing] mode = off is for. Only before a `--`: what follows it
  # is another command's (`claude mcp add NAME -- CMD ARGS`), never Claude Code's.
  local -a rest=("$@") kept=()
  for ((i = 0; i < ${#rest[@]}; i++)); do
    case "${rest[i]}" in
      --) break ;;
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
    # Theirs is in ours now; left on the command line it would be the last, and win.
    for ((i = 0; i < ${#rest[@]}; i++)); do
      case "${rest[i]}" in
        --)
          kept+=("${rest[@]:i}")
          break
          ;;
        --settings) ((i++)) || true ;;
        --settings=*) ;;
        *) kept+=("${rest[i]}") ;;
      esac
    done
    profile_agent_argv=(${kept[@]+"${kept[@]}"})
    [[ "$_merge_note" == *hooks-disabled* ]] \
      && _as_msg "briefing: your settings set disableAllHooks, so the briefing will NOT be injected into the session; $inside/briefing.md is bound read-only and can be read on request"
  else
    printf '%s\n' "$ours" >"$host_file" || {
      _as_msg "briefing: cannot write $host_file; continuing without the session hooks"
      return 0
    }
  fi

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
# instructions), credentials, plugins and statsig. The config file .claude.json
# is neither shared nor hidden: each project gets its own copy of it, seeded
# with that project's entry alone (see _claude_config_prepare above).
# _claude_history_view SOURCE VIEW -- the prompt history a seeding mode reads: this
# project's records only, by the rule _claude_history_filter below states. Fails closed:
# without python3 the view is empty.
_claude_history_view() {
  (umask 077 && _claude_history_filter "$1" "$(_as_project_dir)" >"$2")
}
_claude_history_filter() { # $1 = history.jsonl, $2 = project dir
  # Records are compact JSON, one per line, each carrying "project":"<dir>".
  #
  # MATCH THE FIELD, NOT THE BYTES. This was a fixed-string grep whose comment
  # argued that including the closing quote made it safe in one direction: "can
  # only ever return too few lines, never another project's". The closing quote
  # does rule out prefix collisions, and nothing else -- `grep -F` matches that
  # byte sequence ANYWHERE on the line, in any field, at any nesting depth. So a
  # record belonging to another project reached this one as soon as it happened
  # to quote or nest the target path. Measured as row 4 of the leak study (#73).
  #
  # FAILS CLOSED. No python3, a file that will not open, or a line that does not
  # parse: the record is dropped, not passed. Too few lines really is the safe
  # direction here; the old comment's mistake was believing grep gave it.
  command -v python3 >/dev/null 2>&1 || return 0
  AS_HIST="$1" AS_PROJECT="$2" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
want = os.environ["AS_PROJECT"]
try:
    fh = open(os.environ["AS_HIST"], encoding="utf-8")
except OSError:
    sys.exit(0)
with fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("project") == want:
            sys.stdout.write(line if line.endswith("\n") else line + "\n")
PY
}

profile_isolate() {
  local c="$profile_base" name
  # The paths blanked every launch are the dot-file's [agent] hide (profile_hide, set by
  # the engine); why each is there is said beside it, in agent-sandbox. file-history/,
  # plans/, history.jsonl and the hook logs used to be staged here and merged back at
  # exit; they are channels now (`transcripts`, `logs`; #120), each the role's own.
  profile_isolate_spec=()
  # shellcheck disable=SC2154 # set by the engine from the profile's dot-file
  for name in ${profile_hide[@]+"${profile_hide[@]}"}; do
    profile_isolate_spec+=("tmpfs	$c/$name")
  done

  # [claude] hide = a b c -- extra paths under the state directory to blank.
  # ~/.claude is bound read-write and is a catch-all: Claude Code keeps its own
  # state there, and so does anything a user puts there (a GH_CONFIG_DIR, say).
  # The engine cannot know which of those hold secrets, so the user says.
  # Additive to the list above, and only from an approved dot-file.
  #
  # profile_dotfile is set by the engine from the [claude] section, reached here
  # by dynamic scope like $cwd in profile_memory_scope.
  # shellcheck disable=SC2154
  local -a _opts=(${profile_dotfile[@]+"${profile_dotfile[@]}"})
  local kv key val
  for kv in ${_opts[@]+"${_opts[@]}"}; do
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
      hide)
        # Word-splitting $val is the point: the value is a space-separated list.
        # shellcheck disable=SC2086
        for name in $val; do
          case "$name" in
            /* | *..*)
              _as_msg ".agent-sandbox: [claude] hide: ignoring \"$name\" (must be a relative path under the state dir)"
              continue
              ;;
          esac
          profile_isolate_spec+=("tmpfs	$c/$name")
        done
        ;;
      *) ;; # another key: the review warned of it (profile_dotfile_keys)
    esac
  done
}
