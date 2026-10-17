#!/usr/bin/env bash
# statusline.sh ROLE [STATE] -- the claude profile's status line (#287), named in the
# --settings profile_briefing_args builds (unless the user's own --settings sets a
# statusLine, which wins), copied beside the briefing and run from there, inside the
# sandbox, every second.
#
# Prints one line: the role in bold -- or, for the role "default", the project's
# name, from the stdin JSON's workspace.project_dir -- then what the session is
# doing, as state-hook.sh last wrote it to STATE (default /tmp/agent-sandbox-state),
# in reverse video: working yellow, waiting green, needs you red and bold. No state
# file, or one that says anything else: the name alone. Under 60 columns.
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
case "$state" in
  working) tag=$'\e[7;33m working \e[0m' ;;
  waiting) tag=$'\e[7;32m waiting \e[0m' ;;
  "needs you") tag=$'\e[1;7;31m needs you \e[0m' ;;
  *) tag="" ;;
esac
printf '\e[1m%s\e[0m%s\n' "$name" "${tag:+ $tag}"
