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
# its source, filter, vendor prefixes and starting template (#191), and the presets'
# rungs are its [preset:<name>] sections (#191), with the reasons beside them.

# The environment it pins and refuses is the dot-file's [env] (#177): DISABLE_AUTOUPDATER
# and the refusal of CLAUDE_CODE_PROJECT_DIR_NAME, each with its reason. CLAUDE_CONFIG_DIR
# is the engine's: `base-env`, set to the base it built (not under `native`).

# Keys this profile reads from a `[claude]` section of a project's .agent-sandbox.
# The single source of truth: the review warns on any other [claude] key (a typo
# must not silently do nothing), and the docs drift-check verifies each is
# documented. The engine reads `hide` (_as_hide_spec). The profile's own [agent] keys
# (the verbs, in agent-sandbox beside this file) are not among them: a project's
# file may not set those.
profile_dotfile_keys=(hide)

# Map a project directory to Claude Code's per-project state slug: the absolute
# path with every character outside [A-Za-z0-9-] turned into "-", one for one
# (/home/u/pro.j -> -home-u-pro-j). This must match Claude Code's own scheme, or
# the transcripts and memory channels ({slug}) bind a directory Claude Code never
# uses, while the project's own state sits elsewhere in the `projects` store --
# silently, and --continue/--resume would find nothing.
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
# the session's transcripts and memory land outside their channels' stores;
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

# ~/.claude.json is NOT created when absent. Measured on 2.1.286: with none, Claude Code
# runs and writes its own; with a 0-byte one it reports the file "corrupted", backs it
# up and fails -- which is what creating one here did under `native` and `config =
# read-write`, where it is the file Claude Code reads. The seeding modes need nothing
# there: the filter seeds {"projects": {}} from a missing file, and `own` starts from
# config.json.
profile_prepare() {
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
# _claude_py SUBCOMMAND ARGS... -- run this profile's helper, profile.py beside this file:
# Claude Code's file formats, one subcommand each (see its docstring). python3 is there:
# the engine refuses a launch without it, since every command is joined by python3
# (components/join.py), so nothing here is written twice, once in bash for its absence.
# Through AGENT_SANDBOX_TEST_PYTHON when set, so the coverage stage can trace it.
_claude_py() {
  # shellcheck disable=SC2154 # profile_home: the engine's, by dynamic scope ({profile})
  ${AGENT_SANDBOX_TEST_PYTHON:-python3} "$profile_home/profile.py" "$@"
}

# _claude_config_filter SOURCE VIEW -- the seed the seeding modes read: every top-level
# key and, of the per-project entries, only this project's. A view that cannot be made
# refuses the launch: seeding the whole file instead would hand this project every
# other project's entry, which is what the filter is for (leak study row 10).
_claude_config_filter() {
  _claude_py config-view "$1" "$2" --project "$(_as_project_dir)" && return 0
  _as_msg "config: could not make this project's view of $1; refusing rather than seeding the whole file"
  return 1
}
_claude_config_prepare() {
  # THE CONFIG FILE'S SOURCE DEPENDS ON THE BASE. With the default base, native Claude
  # Code keeps it at ~/.claude.json, which the dot-file's `outside:` relocates into the
  # base. With CLAUDE_CONFIG_DIR set, it keeps it at $CLAUDE_CONFIG_DIR/.claude.json
  # (measured: with the variable set, ~/.claude.json is never opened) -- the path itself,
  # so the relocation goes. A condition on the launching environment, so code (#190).
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    local -a _src=()
    local _s
    for _s in ${profile_channel_sources[@]+"${profile_channel_sources[@]}"}; do
      # shellcheck disable=SC2154 # profile_base: set by the engine from [agent] base
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
  proj="$(_as_project_dir)"
  store="$(_as_channel_store config "$profile_base/.claude.json" "$mode")"
  [[ -f "$store" ]] || return 0
  _claude_py trust-recorded "$store" --project "$proj" 2>/dev/null && return 0
  if _claude_py mark-trust "$store" --project "$proj" 2>/dev/null; then
    _as_msg "recorded workspace trust for $proj in role '${_role:-default}' (a --bg cannot ask)"
  else
    _as_msg "could not record workspace trust for '$proj' in $store"
  fi
  return 0
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
# (profile_agent_argv), or it would win over ours. When the merge is refused (a
# shape profile.py does not recognise), the USER's --settings is kept and the
# briefing's hooks are dropped with a loud note. Losing a hint beats changing how
# someone's tools behave.
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
    local _merge_note=""
    if ! _merge_note=$(_claude_py merge-settings --ours "$ours" --user "$user_val" --out "$host_file"); then
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

# _claude_history_view SOURCE VIEW -- the prompt history a seeding mode reads: this
# project's records only, matched by the field, not the bytes (profile.py). A view that
# cannot be made refuses the launch, as the config file's does.
_claude_history_view() {
  _claude_py history-view "$1" "$2" --project "$(_as_project_dir)" && return 0
  _as_msg "transcripts: could not make this project's view of $1; refusing rather than seeding it"
  return 1
}
