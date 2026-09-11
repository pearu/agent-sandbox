#!/usr/bin/env bash
# probes/run.sh — run one probe prompt in a fresh sandbox and collect its report.
#
#   probes/run.sh [-n proxy|strict|open] [-m MODEL] [-i] [-d] PROBE.md
#
#   -n MODE   network mode (default proxy). 'none' is refused: a Claude instance
#             cannot reach the API there, so it cannot report.
#   -m MODEL  model id passed explicitly (default: "model" in ~/.claude/settings.json)
#   -s        turn the seccomp filter on (AGENT_SANDBOX_SECCOMP=on). Off by
#             default because a probe runs OUTSIDE this repo, where no
#             .agent-sandbox applies -- so without this, even a `strict` probe
#             characterizes a looser sandbox than the one we ship. The first
#             real run said so itself: "Seccomp is OFF ... enforcement gap".
#   -i        interactive session instead of headless (claude -p); for watching
#             and demonstrating. Same flags otherwise.
#   -d        dry run: print the plan, launch nothing.
#
# The probe runs from a throwaway directory OUTSIDE this repo, so the instance
# sees neither the repo nor its docs: $PROBE_RUNS/<id> (default
# ~/.local/state/probe-runs/<UTC timestamp>), kept afterwards for inspection and linked
# as probes/work. Inside it the task is TASK.md and the report is report.md,
# with no hint of model, mode or probe name. The engine is launched with a
# sanitized host environment and a neutral session base, so the tool's name is
# absent from the sandbox's paths and variables; README.md lists what still
# identifies it.
#
# Claude Code's permission gate is opened with --allowedTools rather than
# --permission-mode bypassPermissions, for two reasons. The bypass is REFUSED
# when the agent sees itself as root -- "--dangerously-skip-permissions cannot
# be used with root/sudo privileges" -- which is exactly the case in strict
# mode, where the agent runs as uid 0 inside pasta's user namespace, so probing
# the tightest mode was impossible. And the same list is passed in every mode,
# so a difference between runs is attributable to the sandbox rather than to
# the gate. A tool outside the list is refused by Claude Code, not by the
# sandbox; the list is spelled out here so that stays visible.
#
# Must run on the host, not inside a sandbox.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
die() {
  echo "run.sh: $*" >&2
  exit 2
}
usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

mode=proxy model="" interactive=0 dry=0 seccomp=off
while getopts ':n:m:sidh' opt; do
  case "$opt" in
    n) mode="$OPTARG" ;;
    m) model="$OPTARG" ;;
    s) seccomp=on ;;
    i) interactive=1 ;;
    d) dry=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done
shift $((OPTIND - 1))
(($# == 1)) || usage 2
probe="$1"
[[ -r "$probe" ]] || die "probe file not readable: $probe"
case "$mode" in
  proxy | strict | open) ;;
  none) die "net mode 'none' has no route to the API, so a Claude instance cannot run there; use proxy or strict" ;;
  *) die "unknown net mode '$mode' (proxy|strict|open)" ;;
esac
pname="$(basename -- "${probe%.md}")"

# Host only: inside a sandbox PID 1 is bwrap.
if [[ -r /proc/1/cmdline ]] && [[ "$(tr '\0' ' ' </proc/1/cmdline)" == bwrap* ]] && ((! dry)); then
  die "this is inside a sandbox; run it on the host"
fi

# The installed launcher (the 'claude' on PATH is the engine, per install.sh).
launcher="${PROBE_LAUNCHER:-$(command -v claude || true)}"
engine_ver=""
if [[ -n "$launcher" ]]; then
  engine_ver="$("$launcher" --engine-version 2>/dev/null || true)"
fi
if [[ "$engine_ver" != agent-sandbox* ]]; then
  ((dry)) || die "no agent-sandbox launcher found ('claude' on PATH must answer --engine-version); set PROBE_LAUNCHER"
  engine_ver="(launcher not found)"
fi

# Model: explicit, else the one Claude Code's settings pin.
if [[ -z "$model" ]]; then
  model="$(python3 -c 'import json,sys,os
try: print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("model",""))
except Exception: print("")' 2>/dev/null || true)"
fi
[[ -n "$model" ]] || die "no model: pass -m MODEL (none in ~/.claude/settings.json)"

# Claude Code version, the way the profile picks it (newest under versions/).
claude_ver="$(find "$HOME/.local/share/claude/versions" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)"
claude_ver="${claude_ver:-unknown}"

runs="${PROBE_RUNS:-${XDG_STATE_HOME:-$HOME/.local/state}/probe-runs}"
rt="$runs/.rt"    # session base: CA bundle and per-session files live here, under a neutral name
logs="$runs/.log" # engine/CLI output per run; not bound into the sandbox
ts="$(date -u +%Y%m%dT%H%M%SZ)"
model_slug="$(printf '%s' "$model" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/_+$//')"
result="$here/results/${pname}-${model_slug}-${mode}-${ts}.md"

# Arguments for the CLI; engine flags none (the mode goes in by env).
# Every tool a probe might reach for, so what stops it is the sandbox.
probe_tools='Bash Read Write Edit Glob Grep WebFetch WebSearch'
cli=(--allowedTools "$probe_tools" --model "$model")
((interactive)) || cli+=(-p)

if ((dry)); then
  cat <<PLAN
plan:
  probe:     $probe ($pname)
  net mode:  $mode
  seccomp:   $seccomp
  model:     $model
  session:   $([[ $interactive == 1 ]] && echo interactive || echo headless)
  launcher:  ${launcher:-"(none)"}  $engine_ver
  claude:    $claude_ver
  work dir:  $runs/$ts   (linked as $here/work)
  result:    $result
  tools:     $probe_tools
  command:   env -i HOME USER LOGNAME PATH=<system dirs> TERM LANG AGENT_SANDBOX_NET=$mode AGENT_SANDBOX_SECCOMP=$seccomp AGENT_SANDBOX_SESSION_BASE=$rt \\
               claude ${cli[*]} "<TASK.md contents>"
PLAN
  exit 0
fi

mkdir -p "$runs" "$logs" "$here/results"
[[ -e "$here/work" ]] || ln -s "$runs" "$here/work"
# Work dir id = the run's timestamp (same as in the result name); a same-second
# rerun gets a numeric suffix.
work="$runs/$ts" n=1
until mkdir "$work" 2>/dev/null; do work="$runs/$ts-$((n++))"; done
id="$(basename -- "$work")"
{
  cat "$probe"
  printf '\n---\nOutput: write the complete report to a NEW file named report.md in the current\n'
  printf 'working directory (it does not exist yet; creating it is expected), then print\n'
  printf 'the same report as your final answer.\n'
} >"$work/TASK.md"
prompt="$(cat "$work/TASK.md")"

echo "run.sh: $pname / $mode / $model -> $work"
rc=0
(
  cd "$work"
  # env -i: nothing from this shell leaks in (conda env names, PATH entries, the
  # repo as PWD). The engine rebuilds the inside environment from what it gets.
  if ((interactive)); then
    exec env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TERM="${TERM:-xterm-256color}" LANG="${LANG:-C.UTF-8}" \
      AGENT_SANDBOX_NET="$mode" AGENT_SANDBOX_SECCOMP="$seccomp" AGENT_SANDBOX_SESSION_BASE="$rt" \
      "$launcher" "${cli[@]}" "$prompt"
  else
    exec env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      TERM="${TERM:-xterm-256color}" LANG="${LANG:-C.UTF-8}" \
      AGENT_SANDBOX_NET="$mode" AGENT_SANDBOX_SECCOMP="$seccomp" AGENT_SANDBOX_SESSION_BASE="$rt" \
      "$launcher" "${cli[@]}" "$prompt" >"$logs/$id.stdout" 2>"$logs/$id.stderr"
  fi
) || rc=$?

# Collect: report.md is authoritative; a headless run's stdout is the fallback.
src="$work/report.md"
if [[ ! -s "$src" && -s "$logs/$id.stdout" ]]; then
  src="$logs/$id.stdout"
fi
{
  printf -- '---\nprobe: %s\nmodel: %s\nnet: %s\nsession: %s\nengine: %s\nclaude: %s\ndate: %s\nwork: %s\nexit: %s\n---\n\n' \
    "$pname" "$model" "$mode" "$([[ $interactive == 1 ]] && echo interactive || echo headless)" \
    "$engine_ver" "$claude_ver" "$ts" "$work" "$rc"
  if [[ -s "$src" ]]; then
    cat "$src"
  else
    echo "(no report produced; see $logs/$id.stderr)"
  fi
} >"$result"
echo "run.sh: exit $rc; report -> $result"
((rc == 0)) || echo "run.sh: engine/CLI output: $logs/$id.stderr" >&2
exit "$rc"
