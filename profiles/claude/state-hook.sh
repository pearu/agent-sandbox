#!/usr/bin/env bash
# state-hook.sh EVENT [BACKGROUND [STATE]] -- the claude profile's state hooks (#287),
# installed by profile_briefing_args, copied beside the briefing and run from there,
# inside the sandbox. It records what the session is doing, for statusline.sh:
#
#   SessionStart, Stop        waiting     the prompt is the user's
#   UserPromptSubmit          working     a turn is running
#   PostToolUse(Failure)      working     a tool ran: working again after a permission
#   PermissionRequest         needs you   a permission dialog is up (fires at once)
#   Notification              needs you   for a permission_prompt, an elicitation or
#                                         agent_needs_input (from the hook's stdin
#                                         JSON); nothing for idle_prompt and the rest
#   SessionEnd                (nothing)   only the background reset below
#
# STATE (default /tmp/agent-sandbox-state; /tmp is the sandbox's own tmpfs) is
# written by rename, so the status line never reads half a file.
#
# BACKGROUND `on` ([claude] state-background = on) also sets the terminal's
# background per state with OSC 11, and resets it with OSC 111 on waiting and at
# SessionEnd. A hook is detached from the terminal (/dev/tty fails, measured), but
# Claude Code's own stdout is the terminal: /proc/$CLAUDE_PID/fd/1, written only when
# it is a character device, and never waited on for more than a second.
#
# Exits 0 always and prints nothing: a hook's stdout can become the session's context.
set -u
event="${1:-}"
background="${2:-off}"
statef="${3:-/tmp/agent-sandbox-state}"

state=""
case "$event" in
  SessionStart | Stop) state=waiting ;;
  UserPromptSubmit | PostToolUse | PostToolUseFailure) state=working ;;
  PermissionRequest) state="needs you" ;;
  Notification)
    input="$(head -c 65536 2>/dev/null)" || input=""
    re='"notification_type"[[:space:]]*:[[:space:]]*"([a-z_]+)"'
    if [[ "$input" =~ $re ]]; then
      case "${BASH_REMATCH[1]}" in
        permission_prompt | elicitation | agent_needs_input) state="needs you" ;;
      esac
    fi
    ;;
  SessionEnd) ;;
  *) exit 0 ;;
esac

if [[ -n "$state" ]]; then
  tmp="$statef.$$"
  { printf '%s\n' "$state" >"$tmp" && mv -f -- "$tmp" "$statef"; } 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
fi

[[ "$background" == on ]] || exit 0
case "$event:$state" in
  *:working) seq=$'\e]11;#203040\a' ;;
  *:"needs you") seq=$'\e]11;#402020\a' ;;
  *:waiting | SessionEnd:) seq=$'\e]111\a' ;;
  *) exit 0 ;;
esac
pid="${CLAUDE_PID:-}"
[[ "$pid" =~ ^[0-9]+$ ]] || exit 0
tty="/proc/$pid/fd/1"
[[ -c "$tty" && -w "$tty" ]] || exit 0
command -v timeout >/dev/null 2>&1 || exit 0
# shellcheck disable=SC2016 # the inner shell's own $1 and $2
timeout 1 bash -c 'printf "%s" "$1" >"$2"' _ "$seq" "$tty" >/dev/null 2>&1
exit 0
