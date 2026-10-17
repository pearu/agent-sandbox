#!/usr/bin/env bash
# state-hook.sh EVENT [BACKGROUND [STATE]] -- the claude profile's state hooks (#287),
# installed by profile_briefing_args, copied beside the briefing and run from there,
# inside the sandbox. It records what the session is doing, for statusline.sh:
#
#   UserPromptSubmit          working     a turn is running
#   PostToolUse(Failure)      working     a tool ran: working again after a permission
#   PermissionRequest         needs you   a permission dialog is up (fires at once)
#   Notification              needs you   for a permission_prompt, an elicitation or
#                                         agent_needs_input (from the hook's stdin
#                                         JSON); nothing for idle_prompt and the rest
#   Stop                      asks you    the reply's last line ends with a question
#                             waiting     else, a watcher runs: a message will wake it
#                             idle        else: the prompt is the user's
#   SessionStart              waiting     a watcher runs (a resumed session's)
#                             idle        else
#   SessionEnd                (nothing)   only the background reset below
#
# The reply is the stdin JSON's last_assistant_message, which Stop carries; without
# it, the last assistant text in the tail of transcript_path (the hooks reference says
# the transcript may lag the turn at Stop, so it is the second choice). Its last line,
# trailing whitespace and markdown emphasis stripped, ends with `?`: a question the
# turn ended on. A watcher is a process named inbox-wait (the roles model's
# .asb/bin/inbox-wait, a script, so the kernel names it after the file) among
# Claude Code's descendants, CLAUDE_PID's, or anywhere in view without one. Anything
# that fails to read falls through to the next test.
#
# THE WATCHER RULE. With AGENT_SANDBOX_WATCH set -- the profile sets it in the Stop hook's
# command for a role whose [serve:ROLE] watch names its inbox, at a terminal launch, not
# on a --serve turn nor a print run -- a Stop with no watcher running is refused once:
# the hook prints {"decision":"block","reason":...} (the hooks reference's Stop decision
# control), and Claude Code goes on with the reason as what to do. Not when the input's
# stop_hook_active is true: Claude Code is already continuing because of a Stop hook,
# and a second refusal would loop on a condition the model did not fix. The state file
# is written as without the rule.
#
# STATE (default /tmp/agent-sandbox-state; /tmp is the sandbox's own tmpfs) is
# written by rename, so the status line never reads half a file.
#
# BACKGROUND `on` ([claude] state-background = on) also sets the terminal's
# background per state with OSC 11, and resets it with OSC 111 on waiting, idle and
# at SessionEnd. A hook is detached from the terminal (/dev/tty fails, measured), but
# Claude Code's own stdout is the terminal: /proc/$CLAUDE_PID/fd/1, written only when
# it is a character device, and never waited on for more than a second.
#
# Exits 0 always and prints nothing but the refusal above: a hook's stdout can become
# the session's context.
set -u
event="${1:-}"
background="${2:-off}"
statef="${3:-/tmp/agent-sandbox-state}"

# jlast KEY -- the last line of the last JSON string value of KEY on stdin, unescaped
# (\n, \t, \", \\) and with trailing whitespace stripped; status 1 when there is none.
# awk, since bash's own regex and pattern removal are quadratic on a long reply.
jlast() {
  awk -v k="\"$1\"" 'BEGIN { RS = "\001" }
    { t = t $0 }
    END {
      p = 0; i = 0
      while ((j = index(substr(t, p + 1), k)) > 0) { p += j; i = p }
      if (!i) exit 1
      r = substr(t, i + length(k))
      if (!match(r, /^[ \t\r\n]*:[ \t\r\n]*"/)) exit 1
      r = substr(r, RLENGTH + 1)
      if (!match(r, /^([^"\\]|\\.)*"/)) exit 1
      v = substr(r, 1, RLENGTH - 1)
      gsub(/\\\\/, "\002", v); gsub(/\\n/, "\n", v); gsub(/\\[rt]/, " ", v)
      gsub(/\\"/, "\"", v); gsub(/\002/, "\\", v)
      sub(/[ \t\r\n]+$/, "", v)
      n = split(v, l, "\n")
      printf "%s", l[n]
    }' 2>/dev/null
}

# asks -- whether the turn's reply (the stdin JSON, in $input) ends with a question.
asks() {
  local line tp
  line="$(jlast last_assistant_message <<<"$input")" || {
    tp="$(jlast transcript_path <<<"$input")" || return 1
    [[ -f "$tp" && -r "$tp" ]] || return 1
    line="$(tail -c 65536 -- "$tp" 2>/dev/null | grep -F '"role":"assistant"' \
      | tail -n 1 | jlast text)" || return 1
  }
  line="${line%"${line##*[!*_\`~[:space:]]}"}"
  [[ "$line" == *"?" ]]
}

# watching -- whether a watcher (a process named inbox-wait) runs in this session.
watching() {
  local d c p s n pid="${CLAUDE_PID:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=""
  for d in /proc/[0-9]*; do
    { read -r c <"$d/comm"; } 2>/dev/null || continue
    [[ "$c" == inbox-wait ]] || continue
    [[ -n "$pid" ]] || return 0
    p="${d#/proc/}" n=0
    while [[ "$p" =~ ^[0-9]+$ ]] && ((p > 1 && n++ < 64)); do
      [[ "$p" == "$pid" ]] && return 0
      { read -r s <"/proc/$p/stat"; } 2>/dev/null || break
      s="${s##*) }" s="${s#* }" p="${s%% *}"
    done
  done
  return 1
}

# refuse -- print the Stop refusal for the watch path in AGENT_SANDBOX_WATCH, a JSON
# string (backslash, quote and control characters escaped).
refuse() {
  local w="$AGENT_SANDBOX_WATCH"
  w="${w//\\/\\\\}" w="${w//\"/\\\"}" w="${w//[[:cntrl:]]/ }"
  printf '{"decision":"block","reason":"agent-sandbox: your watcher on %s is not running; arm it as your purpose file says (the Bash tool, run_in_background: true), then end your turn."}\n' "$w"
}

state="" block=0
case "$event" in
  SessionStart) if watching; then state=waiting; else state=idle; fi ;;
  Stop)
    input="$(head -c 1048576 2>/dev/null)" || input=""
    w=0
    watching && w=1
    if asks; then
      state="asks you"
    elif ((w)); then
      state=waiting
    else
      state=idle
    fi
    re='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
    [[ -n "${AGENT_SANDBOX_WATCH:-}" ]] && ((! w)) && [[ ! "$input" =~ $re ]] && block=1
    ;;
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

((block)) && refuse

[[ "$background" == on ]] || exit 0
case "$event:$state" in
  *:working) seq=$'\e]11;#203040\a' ;;
  *:"needs you" | *:"asks you") seq=$'\e]11;#402020\a' ;;
  *:waiting | *:idle | SessionEnd:) seq=$'\e]111\a' ;;
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
