#!/usr/bin/env bash
# statusline.sh ROLE [STATE [CONTEXT PLAN RESCUE]] -- the claude profile's status line (#287), named in the
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
#
# With CONTEXT (#456; the role's `[briefing] context`, from profile_briefing_args), it
# also writes the context file there (context.sh, beside this file) from the stdin
# JSON's context_window: the tokens of current_usage (input, cache-creation, cache-read:
# the last response's context), context_window_size and session_id; PLAN and RESCUE are
# the role's levels (context.sh). Nothing while used_percentage is null: no response
# yet. Before the row is printed; silently.
#
# With AGENT_SANDBOX_SUMMARY (the session's summary line, #314; set in this command by
# profile_briefing_args where the engine bound it), the row also shows that line, two
# spaces after the state, in the state's colour, not bold: where the session stands, at
# a glance. The file is the agent's own, and the row goes to the user's terminal, so
# every non-printable character is dropped first; then it is cut (a ~ marks the cut) so
# the row stays within COLUMNS - 4, cut here so that Claude Code's ellipsis never takes
# the colour's reset. With no state file, the name, two spaces, the line, plain. A
# missing, unreadable or empty file: the row as without it. One read, no fork: this
# runs every second.
set -u
# This file's directory, where context.sh is.
here="${BASH_SOURCE[0]%/*}"
[[ "$here" != "${BASH_SOURCE[0]}" ]] || here=.
role="${1:-default}"
statef="${2:-/tmp/agent-sandbox-state}"
ctxf="${3:-}"

input=""
if [[ "$role" == default || -n "$ctxf" ]]; then
  input="$(head -c 65536 2>/dev/null)" || input=""
fi
re='"used_percentage"[[:space:]]*:[[:space:]]*null'
window=""
if [[ -n "$ctxf" && ! "$input" =~ $re ]]; then
  re='"context_window_size"[[:space:]]*:[[:space:]]*([0-9]+)'
  [[ "$input" =~ $re ]] && window="${BASH_REMATCH[1]}"
  re='"current_usage"[[:space:]]*:[[:space:]]*\{([^}]*)\}'
  if [[ -n "$window" && "$input" =~ $re ]]; then
    usage="${BASH_REMATCH[1]}" tokens=0 have=0
    for k in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
      re="\"$k\"[[:space:]]*:[[:space:]]*([0-9]{1,15})([^0-9]|\$)"
      if [[ "$usage" =~ $re ]]; then
        tokens=$((tokens + 10#${BASH_REMATCH[1]}))
        [[ "$k" == input_tokens ]] && have=1
      fi
    done
    session=""
    re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,64})"'
    [[ "$input" =~ $re ]] && session="${BASH_REMATCH[1]}"
    # shellcheck source=SCRIPTDIR/context.sh
    if ((have)) && source "$here/context.sh" 2>/dev/null; then
      ctx_update "$ctxf" "${4:--}" "${5:--}" 0 "tokens=$tokens" "window=$window" ${session:+"session=$session"} 2>/dev/null
    fi
  fi
fi

name="$role"
if [[ "$role" == default ]]; then
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
sum=""
sumf="${AGENT_SANDBOX_SUMMARY:-}"
[[ -n "$sumf" && -r "$sumf" ]] && { read -r sum <"$sumf"; } 2>/dev/null
sum="${sum//[^[:print:]]/}"
cols="${COLUMNS:-}"
[[ "$cols" =~ ^[1-9][0-9]{0,3}$ ]] || cols=80
# fit ROOM -- the summary cut to ROOM characters, a ~ marking a cut; empty below 2.
fit() {
  if ((${#sum} <= $1)); then
    :
  elif (($1 >= 2)); then
    sum="${sum:0:$1-1}~"
  else
    sum=""
  fi
}
rest=22 # the state after the bold name: plain, or bold for needs you
case "$state" in
  working | running) sgr='7;33' ;;
  waiting) sgr='7;32' ;;
  "asks you") sgr='7;34' ;;
  "needs you") sgr='7;34' rest=1 ;;
  idle) sgr='7;90' ;;
  *)
    [[ -z "$sum" ]] || fit $((cols - 4 - ${#name} - 2))
    printf '\e[1m%s\e[0m%s\n' "$name" "${sum:+  $sum}"
    exit 0
    ;;
esac
text=" $name  ${state^^} "
[[ -z "$sum" ]] || fit $((cols - 4 - ${#text} - 2))
[[ -z "$sum" ]] || text+=" $sum "
pad=$((cols - 4 - ${#text}))
((pad > 0)) || pad=0
if [[ -z "$sum" ]]; then
  printf '\e[%s;1m %s\e[%sm%s%*s\e[0m\n' "$sgr" "$name" "$rest" "  ${state^^} " "$pad" ""
else
  printf '\e[%s;1m %s\e[%sm%s\e[22m%s%*s\e[0m\n' "$sgr" "$name" "$rest" "  ${state^^} " " $sum " "$pad" ""
fi
