#!/usr/bin/env bash
# statusline.sh ROLE [STATE] -- the claude profile's status line (#287), named in the
# --settings profile_briefing_args builds (unless the user's own --settings sets a
# statusLine, which wins), copied beside the briefing and run from there, inside the
# sandbox, every second.
#
# Prints one row as wide as Claude Code lets it be -- COLUMNS (set for the command;
# 80 without it) less 4: Claude Code indents the line by 2 and cuts it with an
# ellipsis past COLUMNS - 4 (measured, 2.1.300) -- in reverse video of the state's
# colour: the role in bold -- or, for the role "default", the project's name, from
# the stdin JSON's workspace.project_dir -- then what the session is doing, as
# state-hook.sh last wrote it to STATE (default /tmp/agent-sandbox-state), in
# capitals, then padding to the edge. Colours: working and running yellow, waiting
# green, asks you blue, needs you blue and bold, idle grey. No state file, or one that
# says anything else: the name alone, no bar. The name is cut at 40 characters.
set -u
role="${1:-default}"
statef="${2:-/tmp/agent-sandbox-state}"

name="$role"
if [[ "$role" == default ]]; then
  input="$(head -c 65536 2>/dev/null)" || input=""
  re='"project_dir"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ "$input" =~ $re ]]; then
    dir="${BASH_REMATCH[1]%/}"
    [[ -n "${dir##*/}" ]] && name="${dir##*/}"
  fi
fi
name="${name//[^[:print:]]/}"
((${#name} <= 40)) || name="${name:0:39}~"

state=""
[[ -r "$statef" ]] && { read -r state <"$statef"; } 2>/dev/null
rest=22 # the state after the bold name: plain, or bold for needs you
case "$state" in
  working | running) sgr='7;33' ;;
  waiting) sgr='7;32' ;;
  "asks you") sgr='7;34' ;;
  "needs you") sgr='7;34' rest=1 ;;
  idle) sgr='7;90' ;;
  *)
    printf '\e[1m%s\e[0m\n' "$name"
    exit 0
    ;;
esac
cols="${COLUMNS:-}"
[[ "$cols" =~ ^[1-9][0-9]{0,3}$ ]] || cols=80
text=" $name  ${state^^} "
pad=$((cols - 4 - ${#text}))
((pad > 0)) || pad=0
printf '\e[%s;1m %s\e[%sm%s%*s\e[0m\n' "$sgr" "$name" "$rest" "  ${state^^} " "$pad" ""
