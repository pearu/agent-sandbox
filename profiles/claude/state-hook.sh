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
#   SessionEnd                (nothing)   only the background reset and the asking file
#                                         below
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
# THE CONTEXT FILE (#456). With AGENT_SANDBOX_CONTEXT set -- the profile sets it in the
# UserPromptSubmit and Stop hooks' commands to the role's `[briefing] context` path, with
# AGENT_SANDBOX_CONTEXT_PLAN and _RESCUE (the role's levels) and, on a turn of --serve,
# AGENT_SANDBOX_CONTEXT_SERVED=1 -- UserPromptSubmit records the session and the file's
# tokens of that session, the turn's start, in STATE.base; Stop writes the file
# (context.sh, beside this file) with the tokens of the transcript's last assistant
# record that is not a subagent's (its usage: input, cache-creation and cache-read, the
# context of that request), the session, and that start, which sets turn and maxturn.
# The window is the status line's (a role at a terminal) or the serve loop's (a served
# one, profile_serve_result), kept from the file's line. A print run too: a served
# role's turns are print runs.
#
# THE SAVE PROMPT (#456). With the context file, a Stop whose update puts the level at
# `rescue` is refused once, so that the role saves its working state in this same turn:
# "your context is at its rescue level (LEFT tokens left before the stop): save your
# working state as your purpose file says" -- naming no file: the purpose file says
# where (a role's state.md, the Supervisor's reminders.md). Once per crossing: the
# refusal writes this session's id to STATE.rescue, and a Stop at `rescue` whose
# session is the one there is not refused again; `stopped` and `?` never are. A Stop
# below `rescue` (ok, plan) removes the record, and a new session (a clear, another
# session) does not match it: either rearms the prompt. The crossing is this record's,
# not the file's previous level: the status line rewrites the file each second, and the
# serve loop after each turn, so the file is often at `rescue` before the Stop that
# should prompt. Not when stop_hook_active is true, as above; nor is STATE.rescue
# written then, so the next Stop prompts. A served role's first turn has no window yet
# (level ?): it prompts from its second turn on. It combines with the two refusals
# above in one reason.
#
# THE ASKING FILE (#485). With AGENT_SANDBOX_ASKING set -- the profile sets it in every
# state event's command to the role's `[briefing] asking` path, not in a print run (a
# served turn has no pane to ask in) -- the file is written when the role starts waiting
# for the user (`since=`, when it began), and removed at the first hook event after the
# user's answer, for the Supervisor, whose watch has it. Claude Code (2.1.321, measured)
# runs no hook at the answer itself: after a permission approved, that event is the
# approved tool's end (PostToolUse), so the file outlasts the dialog by the tool's run.
# A denial or a reply ends it at the next event. A new state of `needs you` or `asks
# you` writes it, one line `since=<UTC, ISO 8601, seconds, Z>`, by rename, unless it is
# already there: a PermissionRequest and then its Notification, or `asks you` and then
# `needs you`, are one wait, and its `since` stays the wait's start. Any other new state
# (working, running, waiting, idle) removes it, and so does SessionEnd. An event that
# sets no state (a Notification of another type) leaves it. A Stop that the hook refuses
# (the rules above) is not an end: the turn goes on, so it removes the file, as working
# does, whatever its reply ends on. AskUserQuestion, the question dialog, is a
# PermissionRequest, at once, in every permission mode (measured, 2.1.321). A dialog
# declined with Escape fires no hook (measured): the file stays until the next turn's
# first event, while the role sits at its prompt, the user's. A session killed with the
# file there runs no hook either: the next launch's SessionStart removes it.
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
# Exits 0 always and prints nothing but the refusals above: a hook's stdout can become
# the session's context.
set -u
# This file's directory, where context.sh is.
here="${BASH_SOURCE[0]%/*}"
[[ "$here" != "${BASH_SOURCE[0]}" ]] || here=.
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

# jsession -- the session_id of the stdin JSON (in $input), or nothing.
jsession() {
  local re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,64})"'
  [[ "$input" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# ctx_record TRANSCRIPT [PROMPT] -- the transcript's last assistant record that is not a
# subagent's; with PROMPT (the turn's prompt_id), the last one after a record of that
# prompt (its user records carry "promptId"), or nothing.
ctx_record() {
  tail -c 4194304 -- "$1" 2>/dev/null | awk -v p="${2:+\"promptId\":\"$2\"}" '
    p != "" && index($0, p) { r = ""; seen = 1; next }
    (p == "" || seen) && index($0, "\"type\":\"assistant\"") && !index($0, "\"isSidechain\":true") { r = $0 }
    END { if (r != "") print r }'
}

# ctx_tokens TRANSCRIPT PROMPT WANT -- the context of the turn's last response: its record's
# usage (input, cache-creation and cache-read tokens, summed; the three come first in a
# usage object, before any nested one). At Stop the record may not be written yet
# (measured, 2.1.311: about 0.1 s after the hook starts, for interactive and -p turns
# alike; the previous turn's is last until then), so it waits, up to 2 s, for a record
# after the turn's prompt (PROMPT, its prompt_id) whose text ends as the turn's reply
# (WANT, its last lines as jlast gives them) -- a reply may repeat the previous turn's --
# and takes the last record there after that. Either empty: not waited on.
ctx_tokens() {
  local r u k re n=0 have=0 i
  for ((i = 0; i < 20; i++)); do
    r=""
    [[ -f "$1" && -r "$1" ]] && r="$(ctx_record "$1" "$2")"
    [[ -z "$2" || -z "$3" || (-n "$r" && "$(jlast text 3 <<<"$r")" == "$3") ]] && break
    sleep 0.1
  done
  [[ -n "$r" ]] || r="$(ctx_record "$1")"
  [[ -n "$r" ]] || return 1
  u="$(grep -o '"usage":{[^{}]*' <<<"$r" | tail -n 1)" || return 1
  for k in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    re="\"$k\"[[:space:]]*:[[:space:]]*([0-9]{1,15})([^0-9]|\$)"
    if [[ "$u" =~ $re ]]; then
      n=$((n + 10#${BASH_REMATCH[1]}))
      [[ "$k" == input_tokens ]] && have=1
    fi
  done
  ((have)) || return 1
  printf '%s' "$n"
}

# context EVENT -- the context file's part of UserPromptSubmit and Stop (above). Silent.
context() {
  local f="${AGENT_SANDBOX_CONTEXT:-}" sess line kv tp tok bs bt base="" want pid
  local -a words=()
  CTX_LEVEL="" CTX_LEFT="" ctx_session=""
  [[ -n "$f" ]] || return 0
  sess="$(jsession)"
  ctx_session="${sess:-?}"
  if [[ "$1" == UserPromptSubmit ]]; then
    line="" tok=""
    if [[ -n "$sess" && -f "$f" && ! -L "$f" ]]; then
      { IFS= read -r -n 4096 line <"$f"; } 2>/dev/null || :
      [[ " $line " == *" session=$sess "* ]] || line=""
      words=()
      read -r -a words <<<"$line" || :
      for kv in ${words[@]+"${words[@]}"}; do
        [[ "$kv" =~ ^tokens=([0-9]{1,15})$ ]] && tok="${BASH_REMATCH[1]}"
      done
    fi
    { printf '%s %s\n' "${sess:-?}" "${tok:-?}" >"$statef.base.$$" && mv -f -- "$statef.base.$$" "$statef.base"; } 2>/dev/null \
      || rm -f -- "$statef.base.$$" 2>/dev/null
    return 0
  fi
  tp="$(jlast transcript_path <<<"$input")" || return 0
  want="$(jlast last_assistant_message 3 <<<"$input")" || want=""
  pid=""
  [[ "$input" =~ \"prompt_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,64})\" ]] && pid="${BASH_REMATCH[1]}"
  tok="$(ctx_tokens "$tp" "$pid" "$want")" || return 0
  bs="" bt=""
  { read -r bs bt <"$statef.base"; } 2>/dev/null || :
  [[ -n "$sess" && "$bs" == "$sess" && "$bt" =~ ^[0-9]{1,15}$ ]] && base="$bt"
  # shellcheck source=SCRIPTDIR/context.sh
  source "$here/context.sh" 2>/dev/null || return 0
  ctx_update "$f" "${AGENT_SANDBOX_CONTEXT_PLAN:--}" "${AGENT_SANDBOX_CONTEXT_RESCUE:--}" \
    "${AGENT_SANDBOX_CONTEXT_SERVED:-0}" "tokens=$tok" ${sess:+"session=$sess"} ${base:+"base=$base"} 2>/dev/null
  return 0
}

# rescue -- status 0 when this Stop is to prompt the save (THE SAVE PROMPT, above): the
# update put the level at rescue and STATE.rescue does not name this session. Below
# rescue, it removes STATE.rescue: the next crossing prompts again.
rescue() {
  local had=""
  case "$CTX_LEVEL" in
    ok | plan)
      rm -f -- "$statef.rescue" 2>/dev/null
      return 1
      ;;
    rescue) ;;
    *) return 1 ;;
  esac
  { IFS= read -r -n 128 had <"$statef.rescue"; } 2>/dev/null || :
  [[ "$had" != "$ctx_session" ]]
}

# jstr S -- S as the inside of a JSON string (backslash, quote and control characters).
jstr() {
  local w="$1"
  w="${w//\\/\\\\}" w="${w//\"/\\\"}" w="${w//[[:cntrl:]]/ }"
  printf '%s' "$w"
}

# refuse WATCH SUMMARY SAVE -- print the one Stop refusal: the save prompt when SAVE is
# 1, for the watch path in AGENT_SANDBOX_WATCH when WATCH is 1, for the summary line in
# AGENT_SANDBOX_SUMMARY when SUMMARY is 1, all of them in one reason.
refuse() {
  local r="agent-sandbox:" sep=""
  if (($3)); then
    r+=" your context is at its rescue level (${CTX_LEFT:-?} tokens left before the stop): save your working state as your purpose file says"
    sep=";"
  fi
  if (($1)); then
    r+="$sep your watcher on $(jstr "$AGENT_SANDBOX_WATCH") is not running; arm it as your purpose file says (the Bash tool, run_in_background: true)"
    sep=";"
  fi
  (($2)) && r+="$sep write this session's one-line summary to $(jstr "$AGENT_SANDBOX_SUMMARY")"
  r+=", then end your turn"
  printf '{"decision":"block","reason":"%s."}\n' "$r"
}

state="" block=0 bsum=0 bsave=0 CTX_LEVEL="" CTX_LEFT="" ctx_session=""
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
    context Stop
    re='"stop_hook_active"[[:space:]]*:[[:space:]]*true'
    if rescue && [[ ! "$input" =~ $re ]]; then
      { printf '%s\n' "$ctx_session" >"$statef.rescue.$$" && mv -f -- "$statef.rescue.$$" "$statef.rescue"; } 2>/dev/null \
        || rm -f -- "$statef.rescue.$$" 2>/dev/null
      bsave=1
    fi
    if [[ ! "$input" =~ $re ]]; then
      [[ -n "${AGENT_SANDBOX_WATCH:-}" ]] && ((! w)) && block=1
      [[ -n "${AGENT_SANDBOX_SUMMARY:-}" && ! -s "$AGENT_SANDBOX_SUMMARY" ]] && bsum=1
    fi
    ;;
  UserPromptSubmit)
    state=working
    if [[ -n "${AGENT_SANDBOX_CONTEXT:-}" ]]; then
      input="$(head -c 1048576 2>/dev/null)" || input=""
      context UserPromptSubmit
    fi
    ;;
  PostToolUse | PostToolUseFailure) state=working ;;
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

# The asking file (#485), above. A refused Stop goes on working.
ask="${AGENT_SANDBOX_ASKING:-}"
if [[ -n "$ask" ]]; then
  ast="$state"
  ((block || bsum || bsave)) && ast=working
  case "$event:$ast" in
    *:"needs you" | *:"asks you")
      if [[ ! -e "$ask" && ! -L "$ask" ]]; then
        tmp="$ask.$$"
        { printf 'since=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp" && mv -f -- "$tmp" "$ask"; } 2>/dev/null \
          || rm -f -- "$tmp" 2>/dev/null
      fi
      ;;
    SessionEnd:* | *:?*) rm -f -- "$ask" 2>/dev/null ;;
  esac
fi

((block || bsum || bsave)) && refuse "$block" "$bsum" "$bsave"

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
