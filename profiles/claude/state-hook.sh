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
#   Stop                      asks you    one of the reply's last three lines ends with
#                                         a question
#                             running     else, a background command of the session's own
#                                         other than the watcher runs: it wakes when that ends
#                             waiting     else, a watcher runs: a message will wake it
#                             idle        else: the prompt is the user's
#   SessionStart              waiting     a watcher runs (a resumed session's)
#                             idle        else
#   SessionEnd                (nothing)   only the background reset below
#
# The reply is the stdin JSON's last_assistant_message, which Stop carries; without
# it, the last assistant text in the tail of transcript_path (the hooks reference says
# the transcript may lag the turn at Stop, so it is the second choice). One of its last
# three lines -- not counting blank ones, quotes (a line starting with `>` or `▎`) and a
# fenced code block -- ends with `?`, trailing whitespace and markdown emphasis
# stripped: a question the turn ended on, a quoted message below it or not. A watcher
# is a process named inbox-wait (the roles model's .asb/bin/inbox-wait, a script, so
# the kernel names it after the file) among Claude Code's descendants, CLAUDE_PID's,
# or anywhere in view without one. A
# background command is an entry of the Stop input's background_tasks (the hooks
# reference: one per in-flight task -- a shell, a subagent, a monitor...; a shell's has
# its command line) whose command does not name inbox-wait; without that field, a
# child of CLAUDE_PID that is the Bash tool's wrapper, `bash -c ... eval '...'`
# (measured, 2.1.300), its command line not naming inbox-wait -- at Stop the turn's
# own Bash calls have ended, so a wrapper still running is a background one; without
# CLAUDE_PID, none. Anything that fails to read falls through to the next test.
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
# THE SUMMARY RULE (#314). With AGENT_SANDBOX_SUMMARY set -- the profile sets it in the
# Stop hook's command to the session's summary line, where the engine bound its
# directory, not in a print run -- a Stop is refused once when that file is missing or
# empty. Not when stop_hook_active is true, as above. A Stop that fails both rules is
# refused once, naming both: one JSON object per hook output.
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

# jlast KEY [N] -- the last N (default 1) lines of the last JSON string value of KEY on
# stdin, unescaped (\n, \t, \", \\), a line each, trailing whitespace stripped; lines
# that are blank, quotes (starting with `>` or `▎`) or in a fenced code block (``` lines
# and what is between them) are not counted; status 1 when there is no such value.
# awk, since bash's own regex and pattern removal are quadratic on a long reply.
jlast() {
  awk -v k="\"$1\"" -v want="${2:-1}" 'BEGIN { RS = "\001" }
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
      n = split(v, l, "\n"); o = ""; c = 0; f = 0
      for (i = n; i > 0 && c < want; i--) {
        x = l[i]; sub(/[ \t\r]+$/, "", x)
        if (x ~ /^[ \t]*```/) { f = !f; continue }
        if (f || x ~ /^[ \t]*$/ || x ~ /^[ \t]*(>|▎)/) continue
        o = (c++ ? x "\n" : x) o
      }
      printf "%s", o
    }' 2>/dev/null
}

# asks -- whether the turn's reply (the stdin JSON, in $input) ends with a question: one
# of its last three lines, as jlast counts them.
asks() {
  local lines line tp
  lines="$(jlast last_assistant_message 3 <<<"$input")" || {
    tp="$(jlast transcript_path <<<"$input")" || return 1
    [[ -f "$tp" && -r "$tp" ]] || return 1
    lines="$(tail -c 65536 -- "$tp" 2>/dev/null | grep -F '"role":"assistant"' \
      | tail -n 1 | jlast text 3)" || return 1
  }
  while IFS= read -r line; do
    line="${line%"${line##*[!*_\`~[:space:]]}"}"
    [[ "$line" == *"?" ]] && return 0
  done <<<"$lines"
  return 1
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

# jtasks -- the number of entries of the stdin JSON's background_tasks array whose
# "command" does not name inbox-wait (an entry with no command counts); status 1 when
# there is no such array, or it does not end.
jtasks() {
  awk 'BEGIN { RS = "\001" }
    { t = t $0 }
    END {
      k = "\"background_tasks\""; p = 0; f = 0
      while ((j = index(substr(t, p + 1), k)) > 0) {
        p += j; r = substr(t, p + length(k))
        if (match(r, /^[ \t\r\n]*:[ \t\r\n]*\[/)) { f = 1; break }
      }
      if (!f) exit 1
      r = substr(r, RLENGTH + 1); n = length(r)
      d = 1; s = 0; e = 0; want = 0; key = ""; cmd = ""; str = ""; c = 0
      for (i = 1; i <= n; i++) {
        ch = substr(r, i, 1)
        if (s) {
          if (e) e = 0
          else if (ch == "\\") e = 1
          else if (ch == "\"") {
            s = 0
            if (d == 2) { if (want) { key = str; want = 0 } else if (key == "command") cmd = str }
            continue
          }
          str = str ch
          continue
        }
        if (ch == "\"") { s = 1; str = "" }
        else if (ch == "{" || ch == "[") {
          d++
          if (d == 2 && ch == "{") { want = 1; key = ""; cmd = "" }
        } else if (ch == "}" || ch == "]") {
          d--
          if (d == 1 && ch == "}" && !index(cmd, "inbox-wait")) c++
          if (d == 0) { print c; exit 0 }
        } else if (ch == "," && d == 2) want = 1
      }
      exit 1
    }' 2>/dev/null
}

# running -- whether the session has a background command other than the watcher: from
# background_tasks in the stdin JSON (in $input), or, without it, the process view.
running() {
  local n d c p s pid="${CLAUDE_PID:-}" a
  if n="$(jtasks <<<"$input")"; then
    ((n > 0))
    return
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  for d in /proc/[0-9]*; do
    { read -r c <"$d/comm"; } 2>/dev/null || continue
    [[ "$c" == bash ]] || continue
    { read -r s <"$d/stat"; } 2>/dev/null || continue
    s="${s##*) }" s="${s#* }" p="${s%% *}"
    [[ "$p" == "$pid" ]] || continue
    a=()
    { mapfile -d '' a <"$d/cmdline"; } 2>/dev/null || continue
    [[ "${a[1]:-}" == -c && "${a[2]:-}" == *"eval '"* && "${a[2]}" != *inbox-wait* ]] && return 0
  done
  return 1
}

# jstr S -- S as the inside of a JSON string (backslash, quote and control characters).
jstr() {
  local w="$1"
  w="${w//\\/\\\\}" w="${w//\"/\\\"}" w="${w//[[:cntrl:]]/ }"
  printf '%s' "$w"
}

# refuse WATCH SUMMARY -- print the one Stop refusal: for the watch path in
# AGENT_SANDBOX_WATCH when WATCH is 1, for the summary line in AGENT_SANDBOX_SUMMARY when
# SUMMARY is 1, both in one reason when both are.
refuse() {
  local r="agent-sandbox:"
  (($1)) && r+=" your watcher on $(jstr "$AGENT_SANDBOX_WATCH") is not running; arm it as your purpose file says (the Bash tool, run_in_background: true)"
  (($1 && $2)) && r+=";"
  (($2)) && r+=" write this session's one-line summary to $(jstr "$AGENT_SANDBOX_SUMMARY")"
  r+=", then end your turn"
  printf '{"decision":"block","reason":"%s."}\n' "$r"
}

state="" block=0 bsum=0
case "$event" in
  SessionStart) if watching; then state=waiting; else state=idle; fi ;;
  Stop)
    input="$(head -c 1048576 2>/dev/null)" || input=""
    w=0
    watching && w=1
    if asks; then
      state="asks you"
    elif running; then
      state=running
    elif ((w)); then
      state=waiting
    else
      state=idle
    fi
    re='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
    if [[ ! "$input" =~ $re ]]; then
      [[ -n "${AGENT_SANDBOX_WATCH:-}" ]] && ((! w)) && block=1
      [[ -n "${AGENT_SANDBOX_SUMMARY:-}" && ! -s "$AGENT_SANDBOX_SUMMARY" ]] && bsum=1
    fi
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

((block || bsum)) && refuse "$block" "$bsum"

[[ "$background" == on ]] || exit 0
case "$event:$state" in
  *:working | *:running) seq=$'\e]11;#203040\a' ;;
  *:"needs you" | *:"asks you") seq=$'\e]11;#202840\a' ;;
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
