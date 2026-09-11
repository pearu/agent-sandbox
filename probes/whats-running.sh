#!/usr/bin/env bash
# Which agent processes are running right now, and which of them are sandboxed?
#
# "Is my IDE session sandboxed?" should be answerable by looking, not by trust.
# For every running Claude Code process this reports the executable behind it
# and whether a bwrap ancestor stands between it and its session leader.
#
# Use it to settle what claudeCode.useTerminal actually does: enable it, start a
# session in VS Code, and run this. If the session's executable is the launcher
# (or its ancestry includes bwrap), the IDE is going through the sandbox; if it
# is the extension's own resources/native-binary/claude with no bwrap above it,
# it is not.
#
# Read-only. Run on the HOST, as yourself:
#     ./probes/whats-running.sh
set -uo pipefail

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# Select by EXECUTABLE, not by command line: `pgrep -f claude` also matches a
# `tail -f claude.log` or any shell whose argv mentions claude, and a
# verification step that reports false "no"s is worse than none.
agentish() { # true if this pid's exe is an agent binary or the engine
  local exe
  exe="$(readlink -f "/proc/$1/exe" 2>/dev/null)" || return 1
  # */claude already covers the extension's native-binary/claude; the versions
  # pattern is for the CLI, whose file is named by version rather than "claude".
  case "$exe" in
    */claude | */claude-code | */agent-sandbox | */share/claude/versions/*) return 0 ;;
    *) return 1 ;;
  esac
}
pids=()
for d in /proc/[0-9]*; do
  pid="${d#/proc/}"
  [[ "$pid" == "$$" ]] && continue
  agentish "$pid" && pids+=("$pid")
done
((${#pids[@]})) || {
  say "No claude processes running"
  note "Start a session (terminal or IDE) and re-run."
  exit 0
}

say "Agent processes (${#pids[@]})"
printf '   %-8s %-9s %-7s %s\n' PID SANDBOXED PPID EXECUTABLE
for pid in "${pids[@]}"; do
  [[ -r "/proc/$pid/stat" ]] || continue
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo '(unreadable)')"
  ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
  # Walk up: a bwrap ancestor means this process is inside a sandbox. Reading
  # the ancestry is what makes this an observation rather than a claim.
  sandboxed=no
  walk="$pid"
  # Examine each ancestor INCLUDING pid 1, then stop when the parent is 0 (pid
  # 1's parent) or repeats. Breaking on "reached pid 1" instead would miss the
  # case that matters when this runs inside a sandbox, where bwrap IS pid 1 --
  # which is exactly what the first self-test reported wrongly.
  while [[ -n "$walk" && "$walk" != 0 && -r "/proc/$walk/stat" ]]; do
    comm="$(tr -d '\0' <"/proc/$walk/comm" 2>/dev/null)"
    if [[ "$comm" == bwrap || "$comm" == pasta* ]]; then
      sandboxed=yes
      break
    fi
    next="$(awk '{print $4}' "/proc/$walk/stat" 2>/dev/null)"
    [[ "$next" == "$walk" ]] && break
    walk="$next"
  done
  printf '   %-8s %-9s %-7s %s\n' "$pid" "$sandboxed" "$ppid" "${exe:0:96}"
done

say "Where each executable comes from"
for pid in "${pids[@]}"; do
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || continue
  case "$exe" in
    *.vscode/extensions/*) note "$pid: the VS CODE EXTENSION's own bundled binary" ;;
    *agent-sandbox*) note "$pid: the agent-sandbox engine" ;;
    *.local/share/claude/versions/*) note "$pid: the CLI's own binary (sandboxed only if bwrap is above it)" ;;
    *) [[ -n "$exe" ]] && note "$pid: $exe" ;;
  esac
done

say "Reading this"
note "sandboxed=yes  -> a bwrap/pasta ancestor: the limits apply."
note "sandboxed=no   -> nothing is enforced for that process, whatever is configured."
note "An IDE session showing the extension's bundled binary with sandboxed=no is"
note "the case that matters: the terminal beside it is sandboxed, that session is not."
