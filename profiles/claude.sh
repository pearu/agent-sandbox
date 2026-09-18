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
#                               TLS, CUDA).
#   profile_env_set=(...)       NAME=VALUE pairs always set in the sandbox.
#   profile_env_refuse=(...)    NAMES a user may not forward ([forward],
#                               AGENT_SANDBOX_FORWARD): refused with a
#                               message. Names in profile_env_set are refused
#                               the same way, so a forward cannot override
#                               what the profile pins.
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
# and top-level config in ~/.claude.json. Both must be writable -- and the
# config file must be writable THE WAY CLAUDE CODE WRITES IT: a lock directory
# and a temp file created beside it, then a rename over it (measured, 2.1.274).
# Bound at $HOME/.claude.json, "beside it" is the read-only $HOME tmpfs: the
# lock and the temp file fail with EROFS, no fallback runs, and every write --
# folder trust accepted inside, per-project allowed tools and MCP servers, app
# state -- was silently lost while the session reported success. So the file is
# bound INSIDE the state directory, at ~/.claude/.claude.json, and
# CLAUDE_CONFIG_DIR (profile_env_set, below) points Claude Code there. The
# rename onto a bind mount fails (EBUSY) and Claude Code then rewrites the file
# in place, which reaches the host's ~/.claude.json. Order matters: the
# directory first, the file inside it second.
profile_config_binds=("$HOME/.claude" "$HOME/.claude.json"$'\t'"$HOME/.claude/.claude.json")

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
# CLAUDE_CONFIG_DIR at its own default value: nothing else moves, but Claude
# Code then keeps its config file at ~/.claude/.claude.json (measured: with the
# variable set, ~/.claude.json is never opened), which is where the bind above
# puts it. HOME is the same path inside and out, so the value is right on both
# sides.
profile_env_set+=("CLAUDE_CONFIG_DIR=$HOME/.claude")
# With CLAUDE_CONFIG_DIR set, Claude Code honours CLAUDE_CODE_PROJECT_DIR_NAME,
# which stores every session's transcripts and memory under one name -- out from
# under the per-project scoping, silently. Never forwarded, whatever a [forward]
# section says.
profile_env_refuse=(CLAUDE_CODE_PROJECT_DIR_NAME)

profile_allowlist_seed="$(dirname -- "${BASH_SOURCE[0]}")/claude.allowlist"

profile_host_subcommands=(update upgrade install)

# Management verbs that observe or manage the background service. The engine runs
# these natively (unsandboxed), before any project machinery, so a project's
# .agent-sandbox never gates listing or stopping sessions. See profile_route for
# foreground/background routing (which does depend on the dot-file's scope).
profile_native_verbs=(daemon agents attach logs stop rm)

# Keys this profile reads from a `[claude]` section of a project's .agent-sandbox.
# The single source of truth: the engine warns on any other [claude] key (a typo
# must not silently do nothing), and the docs drift-check verifies each is
# documented. `hide` is read in profile_isolate(); `sandbox` in profile_route().
profile_dotfile_keys=(hide sandbox)

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
  local -a _vers
  mapfile -t _vers < <(_claude_list_versions)
  ((${#_vers[@]})) || {
    _as_msg "no versions under $_claude_versions_dir"
    return 1
  }
  # Highest version first, but skip an entry whose executable is missing and
  # fall back to the newest version that actually has a runnable binary. A native
  # self-update creates versions/<new> before its binary lands, so for a window
  # the highest-sorted entry is a phantom; failing the launch on it would break
  # every sandboxed run (and every background worker) mid-update. Tolerate the
  # skew instead -- the older, runnable version is the right thing to launch.
  profile_bin=""
  profile_version=""
  local i v cand
  for ((i = ${#_vers[@]} - 1; i >= 0; i--)); do
    v="${_vers[i]}"
    if [[ -x "$_claude_versions_dir/$v" && ! -d "$_claude_versions_dir/$v" ]]; then
      profile_bin="$_claude_versions_dir/$v"
      profile_version="$v"
      break
    fi
    for cand in "$_claude_versions_dir/$v/claude" "$_claude_versions_dir/$v/bin/claude"; do
      [[ -x "$cand" ]] && {
        profile_bin="$cand"
        profile_version="$v"
        break
      }
    done
    [[ -n "$profile_bin" ]] && break
  done
  [[ -n "$profile_bin" ]] || {
    _as_msg "no runnable Claude Code executable under $_claude_versions_dir"
    return 1
  }
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

# profile_route [AGENT ARGS...] -- engine hook (see the engine's profile_route
# call). Called for a launch that is neither a wrapper spawn, a --trust review,
# nor a management verb (those are handled earlier). Decides from the effective
# sandbox scopes whether to sandbox this invocation (return 0 -> the engine
# continues its foreground flow) or to run it here and NOT return (exec). Reads
# the engine's locals by dynamic scope, as the other hooks do.
#   scope precedence: --sandbox flag > AGENT_SANDBOX_CLAUDE_SANDBOX env >
#   [claude] sandbox dot-file key > context default (none inside a sandbox, else
#   fg). Tokens: fg, bg, none.
# _sandbox_flag,_sandbox_flag_set,_df_profile_kv,profile_bin are engine locals,
# seen here by dynamic scope (as cwd is elsewhere); shellcheck can't know that.
# shellcheck disable=SC2154
profile_route() {
  local raw="" src="" tok
  if ((_sandbox_flag_set)); then
    raw="$_sandbox_flag" src="--sandbox"
  elif [[ -n "${AGENT_SANDBOX_CLAUDE_SANDBOX:-}" ]]; then
    raw="$AGENT_SANDBOX_CLAUDE_SANDBOX" src="AGENT_SANDBOX_CLAUDE_SANDBOX"
  else
    local _pkv _dfp="" _dfp_set=0
    for _pkv in ${_df_profile_kv[@]+"${_df_profile_kv[@]}"}; do
      [[ "$_pkv" == sandbox=* ]] && {
        _dfp="${_pkv#sandbox=}"
        _dfp_set=1
      }
    done
    if ((_dfp_set)); then
      raw="$_dfp" src="[claude] sandbox"
    elif [[ -n "${AGENT_SANDBOX:-}" ]]; then
      raw="none" src="default (inside a sandbox)"
    else
      raw="fg" src="default"
    fi
  fi

  local want_fg=0 want_bg=0
  for tok in $raw; do
    case "$tok" in
      fg) want_fg=1 ;;
      bg) want_bg=1 ;;
      none)
        want_fg=0
        want_bg=0
        ;;
      *) _as_msg "sandbox scope ($src): ignoring unknown token '$tok' (want: fg, bg, none)" ;;
    esac
  done

  # A background launch iff --bg appears anywhere in the agent's own argv.
  local a is_bg=0
  for a in "$@"; do
    [[ "$a" == "--bg" ]] && {
      is_bg=1
      break
    }
  done

  if ((is_bg)); then
    if ((want_bg)); then
      _claude_bg_launch "$@" || return $? # execs on success; only returns on a setup error
    fi
    _as_msg "background sandboxing off (scope has no 'bg', via $src): running --bg natively"
    exec "$profile_bin" "$@"
  fi
  ((want_fg)) && return 0 # a foreground session: let the engine sandbox it
  _as_msg "foreground sandboxing off (scope has no 'fg', via $src): running natively"
  exec "$profile_bin" "$@"
}

# Sandbox a background launch: bind the project into each worker via the wrapper
# role, keeping the pool project-current without a fragile daemon restart. Execs
# native `claude --bg ...` with CLAUDE_CODE_PROCESS_WRAPPER set; only returns on a
# setup error the caller should propagate.
# cwd,engine,profile,profile_bin are engine locals, seen here by dynamic scope.
# shellcheck disable=SC2154
_claude_bg_launch() {
  local proj="$cwd" _prot_what _prot_path _prot_how base shim
  if [[ "$proj" == "$HOME" ]]; then
    _as_msg "background launch from \$HOME: the worker gets only ~/.claude, not \$HOME (secrets stay hidden)"
    proj="" # no project bind, like a foreground session started from $HOME
  elif _as_path_protected "$proj"; then
    _as_msg "refusing background launch: the cwd $_prot_how $_prot_what '$_prot_path'"
    return 1
  fi

  # Auto-trust the project: a non-interactive bg worker cannot answer the
  # workspace-trust prompt, and the sandbox is strictly more restrictive than
  # native (which itself auto-proceeds for --bg). Documented; disable by not
  # opting bg into the sandbox scope.
  [[ -n "$proj" ]] && _claude_bg_autotrust "$proj"

  base="$(_as_session_base)"
  mkdir -p "$base" 2>/dev/null || true
  printf '%s' "$proj" >"$base/bg-project" # the wrapper (3c) reads this per worker

  # The wrapper Claude Code invokes for every worker: our engine, this profile,
  # --wrap. A shim file, so a multi-word CLAUDE_CODE_PROCESS_WRAPPER is never
  # assumed, and so the daemon's recorded wrapper is a stable path we can match.
  shim="$base/wrap-$profile.sh"
  printf '#!/bin/sh\nexec "%s" --profile %s --wrap "$@"\n' "$engine" "$profile" >"$shim"
  chmod +x "$shim"

  _claude_bg_prepare_daemon "$shim"

  _as_msg "background session sandboxed (wrapper mode)${proj:+, project: $proj}"
  # If the caller already set CLAUDE_CODE_PROCESS_WRAPPER (their own wrapper),
  # wrapper mode replaces it -- the workers run in OUR sandbox, not the caller's
  # wrapper, and it is not chained. Say so rather than dropping it silently, and
  # point at the escape hatch: --sandbox none runs --bg natively, so the caller's
  # wrapper takes effect. Composing a caller wrapper (running it INSIDE the
  # sandbox) is a separate feature, deliberately not built here.
  if [[ -n "${CLAUDE_CODE_PROCESS_WRAPPER:-}" && "$CLAUDE_CODE_PROCESS_WRAPPER" != "$shim" ]]; then
    _as_msg "note: wrapper mode replaces your CLAUDE_CODE_PROCESS_WRAPPER ('$CLAUDE_CODE_PROCESS_WRAPPER') for background workers and does not chain it; use --sandbox none to keep your own wrapper"
  fi
  export CLAUDE_CODE_PROCESS_WRAPPER="$shim"
  exec "$profile_bin" "$@"
}

# Record the project as trusted in ~/.claude.json so the bg worker does not stall
# on the interactive trust prompt. python3-only; degrades to a note if missing.
_claude_bg_autotrust() {
  local proj="$1" cj="$HOME/.claude.json"
  command -v python3 >/dev/null 2>&1 || {
    _as_msg "python3 missing: cannot pre-trust '$proj' for the bg worker; if it stalls, run 'claude' there once"
    return 0
  }
  [[ -e "$cj" ]] || printf '{}' >"$cj"
  AS_CJ="$cj" AS_PROJ="$proj" python3 - <<'PY' 2>/dev/null || _as_msg "could not pre-trust bg project '$proj'"
import json, os
cj, proj = os.environ["AS_CJ"], os.environ["AS_PROJ"]
try:
    d = json.load(open(cj))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(cj, "w"))
PY
}

# Ensure the background daemon that will serve this launch is one WE started with
# THIS wrapper (else contract #3 makes its workers run unwrapped -- unsandboxed),
# and flush the idle pool so the re-warmed spares bind THIS project. A foreign or
# unwrapped daemon is restarted (active sessions survive: the fresh daemon adopts
# them); then the idle/orphaned sandbox trees are reaped. python3-only.
_claude_bg_prepare_daemon() {
  local shim="$1" roster="$HOME/.claude/daemon/roster.json" sup envw
  command -v python3 >/dev/null 2>&1 || {
    _as_msg "python3 missing: skipping bg pool maintenance (idle sandboxes may accumulate; clear with probes/bg-cleanup.sh)"
    return 0
  }
  [[ -r "$roster" ]] || return 0 # no daemon yet: the one this launch starts is wrapped
  sup="$(_claude_roster_supervisor "$roster")"
  { [[ -n "$sup" ]] && kill -0 "$sup" 2>/dev/null; } || return 0 # no live daemon
  envw=""
  [[ -r "/proc/$sup/environ" ]] \
    && envw="$(tr '\0' '\n' <"/proc/$sup/environ" 2>/dev/null | sed -n 's/^CLAUDE_CODE_PROCESS_WRAPPER=//p' | head -1)"
  if [[ "$envw" != "$shim" ]]; then
    _as_msg "restarting the background daemon so its workers are sandboxed (it was not started by wrapper mode)"
    kill "$sup" 2>/dev/null || true
    sleep 1
  fi
  _claude_bg_reap "$roster"
}

_claude_roster_supervisor() {
  AS_ROSTER="$1" python3 - <<'PY' 2>/dev/null
import json, os
try:
    v = json.load(open(os.environ["AS_ROSTER"])).get("supervisorPid")
    if isinstance(v, int):
        print(v)
except Exception:
    pass
PY
}

# Reap leaked background sandbox trees. KEEP = the rostered worker launchers (the
# active sessions); kill every process in a bg tree (rooted at a --bg-pty-host /
# --bg-spare worker) whose ancestry contains no rostered launcher -- i.e. idle
# pool spares and orphans. A worker is matched STRUCTURALLY: its executable is a
# claude version binary AND --bg-spare/--bg-pty-host is an EXACT argv element --
# never a substring of some process's joined command line. That is what keeps a
# shell or test that merely MENTIONS the token (this repo's own suites and probes
# do), and its children, from being selected and killed. python3-only.
#
# _claude_bg_reap_select prints the pids to reap and is pure: it reads $AS_PROC
# (default /proc) so it is unit-testable against a synthetic process table.
# $AS_VERSIONS_DIR/$AS_BIN identify a claude executable. cwd/profile_bin are
# engine locals seen here by dynamic scope.
# shellcheck disable=SC2154
_claude_bg_reap_select() {
  AS_ROSTER="$1" AS_VERSIONS_DIR="$_claude_versions_dir" AS_BIN="${profile_bin:-}" python3 - <<'PY' 2>/dev/null
import json, os
proc = os.environ.get("AS_PROC", "/proc")
vroot = os.environ.get("AS_VERSIONS_DIR", "").rstrip("/")
binpath = os.environ.get("AS_BIN", "")
keep = set()
try:
    d = json.load(open(os.environ["AS_ROSTER"]))
    for w in (d.get("workers", {}) or {}).values():
        if isinstance(w, dict) and isinstance(w.get("pid"), int):
            keep.add(w["pid"])
except Exception:
    pass
info = {}
for e in os.listdir(proc):
    if not e.isdigit():
        continue
    pid = int(e)
    try:
        with open("%s/%d/stat" % (proc, pid), "rb") as f:
            ppid = int(f.read().rsplit(b") ", 1)[1].split()[1])
        argv = [a.decode("utf-8", "replace") for a in open("%s/%d/cmdline" % (proc, pid), "rb").read().split(b"\0") if a]
        try:
            exe = os.readlink("%s/%d/exe" % (proc, pid))
        except OSError:
            exe = ""
        if exe.endswith(" (deleted)"):
            exe = exe[: -len(" (deleted)")]
    except Exception:
        continue
    info[pid] = (ppid, argv, exe)
def kept_ancestor(pid):
    seen = 0
    while pid and pid != 1 and seen < 50:
        if pid in keep:
            return True
        pr = info.get(pid)
        if not pr:
            return False
        pid = pr[0]
        seen += 1
    return False
children = {}
for pid, (pp, argv, exe) in info.items():
    children.setdefault(pp, []).append(pid)
def subtree(root):
    out, stack = [], [root]
    while stack:
        x = stack.pop()
        out.append(x)
        stack.extend(children.get(x, []))
    return out
def is_worker(argv, exe):
    if not exe:
        return False
    if not (exe == binpath or (vroot and exe.startswith(vroot + "/"))):
        return False
    return "--bg-spare" in argv or "--bg-pty-host" in argv
leaked = set()
for pid, (pp, argv, exe) in info.items():
    if is_worker(argv, exe) and not kept_ancestor(pid):
        leaked.update(subtree(pid))
leaked.discard(1)
leaked.discard(os.getpid())
print(" ".join(str(x) for x in sorted(leaked)))
PY
}

_claude_bg_reap() {
  local roster="$1" pids p n
  pids="$(_claude_bg_reap_select "$roster")"
  [[ -n "$pids" ]] || return 0
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
  n="$(printf '%s\n' "$pids" | wc -w | tr -d ' ')"
  _as_msg "background pool: reaped $n leaked sandbox process(es)"
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
    # Not the agent's own state, despite living in its directory: daemon/ holds
    # the background supervisor's control key and a roster of other sessions'
    # ids, pids and sockets. A sandboxed session has no use for it -- those
    # sockets live under /tmp, which is a fresh tmpfs inside, so the key has
    # nothing to talk to -- and it is a cross-session control channel, which is
    # the one thing isolation exists to prevent.
    #
    # gh/ and ide/ are deliberately NOT here. Both exist to make Claude Code
    # work from inside a sandbox: gh/ is a GH_CONFIG_DIR that lives in a bound
    # directory because ~/.config/gh is not one, and ide/ carries the lockfiles
    # an editor connects through. Hiding either would break the feature it was
    # created for. Use [claude] hide if you want them gone.
    "tmpfs	$c/daemon"
    # Nothing below needs to outlive the session: a probe established that a
    # session starts, and a resume completes, with the whole set blanked.
    "tmpfs	$c/session-env"
    "tmpfs	$c/sessions"
    "tmpfs	$c/jobs"
    "tmpfs	$c/shell-snapshots"
    "tmpfs	$c/debug"
    "tmpfs	$c/paste-cache"
  )

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
  local kv key val name
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
      *) _as_msg ".agent-sandbox: ignoring unknown [claude] key \"$key\"" ;;
    esac
  done
}

# profile_fallback_hint -- engine hook, printed when the sandbox cannot start.
# Claude Code's native installer keeps its binaries under versions/ and
# agent-sandbox never touches them, so the newest one is a working, unsandboxed
# agent. This is the emergency exit; see docs/troubleshooting.md.
profile_fallback_hint() {
  local newest=""
  [[ -d "$_claude_versions_dir" ]] && newest="$(_claude_list_versions | tail -n1)"
  if [[ -n "$newest" && -x "$_claude_versions_dir/$newest" ]]; then
    _as_msg "  $_claude_versions_dir/$newest"
  else
    _as_msg "  the newest entry under $_claude_versions_dir (none found there now)"
  fi
}
