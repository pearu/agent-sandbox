#!/usr/bin/env bash
# refusal-hook.sh EVENT [DIR [STATE]] -- the claude profile's PostToolUse and
# PostToolUseFailure hook for Bash (installed by profile_briefing_args, copied
# beside the briefing and run from there, inside the sandbox).
#
# The proxy appends each refusal of this session to DIR/refused.log
# (/run/agent-sandbox, bound read-only), one "<ts>\t<host>\t<method>\t<why>" line.
# After a Bash call that failed this reports the lines that are new since the last
# call, once each, as additionalContext next to the tool result: a refused host then
# reaches the conversation when it happens, not only through the briefing read at
# the start. Both events, because a command a refusal broke usually exits nonzero,
# and Claude Code reports that as PostToolUseFailure, not PostToolUse.
#
# Only a failed command's refusals are reported (#304): a refusal during a command
# that exited 0 did not affect the task -- gh's own telemetry inside a gh call that
# succeeded, say. PostToolUse consumes: it advances STATE past the new lines, so they
# are never reported later, and prints nothing. PostToolUseFailure reports. The rule
# is the same for every reason (allowlist, [deny], retrieve-only, git refuse, git
# push, non-public). Every refusal is still in refused.log and the host's blocked.log,
# so the user's view is unchanged; this changes only what the agent is told
# mid-command.
#
# No policy here: the section to ask for is the engine's (DIR/apply-section). Only
# two fields of a line reach the text, and only when they pass a strict check: the
# host as a hostname, the reason as one the addon writes. Anything else is skipped.
# Nor the hosts the agent reaches on its own (DIR/telemetry-hosts, the profile's
# profile_telemetry_hosts, #276): a refusal of one is left out of the note, since it is
# not the command's -- refused all the same, and still in refused.log.
# STATE (the count of lines already reported) lives in /tmp, a fresh tmpfs per
# sandbox. Exits 0 with no output whenever there is nothing to say.
set -u
event="${1:-}"
case "$event" in
  PostToolUse | PostToolUseFailure) ;;
  *) exit 0 ;;
esac
dir="${2:-/run/agent-sandbox}"
state="${3:-/tmp/agent-sandbox-refused.seen}"
log="$dir/refused.log"
[[ -r "$log" ]] || exit 0

section="$(head -n 1 -- "$dir/apply-section" 2>/dev/null)"
[[ "$section" =~ ^\[allow(:[A-Za-z0-9._-]+)?\]$ ]] || section="[allow]"
# The --shutdown that restarts this role, as the engine spells it (DIR/restart): an
# --apply reaches a role only at its next keeper, and a relaunch that joins a session of
# it still running keeps the old policy. Only the engine's shape passes.
restart="$(head -n 1 -- "$dir/restart" 2>/dev/null)"
[[ "$restart" =~ ^[A-Za-z0-9._-]+\ --role\ [A-Za-z0-9._-]+\ --shutdown(\ --profile)?\ [A-Za-z0-9._-]+$ ]] || restart=""

# One entry per line, an exact hostname or a .domain; anything else is ignored.
own=()
while IFS= read -r t; do
  [[ "$t" =~ ^\.?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$ ]] && own+=("$t")
done < <(head -n 64 -- "$dir/telemetry-hosts" 2>/dev/null)
is_own() {
  local t
  for t in ${own[@]+"${own[@]}"}; do
    if [[ "$t" == .* ]]; then
      [[ "$1" == "${t#.}" || "$1" == *"$t" ]] && return 0
    else
      [[ "$1" == "$t" ]] && return 0
    fi
  done
  return 1
}

# Whole lines only: one being appended right now is left for the next call.
n="$(wc -l <"$log" 2>/dev/null)" || exit 0
seen=0
[[ -r "$state" ]] && read -r seen <"$state"
[[ "$seen" =~ ^[0-9]+$ ]] || seen=0
((n == seen)) && exit 0
printf '%s\n' "$n" >"$state" 2>/dev/null
((n > seen)) || exit 0 # the log never shrinks; a stale count is just reset
# A command that succeeded: its refusals did not affect it (#304), consumed above.
[[ "$event" == PostToolUseFailure ]] || exit 0

text="" done_hosts=" "
while IFS=$'\t' read -r _ host _ why _; do
  [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || continue
  [[ "$done_hosts" == *" $host "* ]] && continue
  is_own "$host" && continue
  case "$why" in
    allowlist)
      note="$host was refused by the sandbox ($why) during this command."
      ask=" The user adds the host, on the host, with: asb --apply '$section' $host. It applies once this role is restarted${restart:+: $restart}, then launched again -- a launch that joins a session of this role still running keeps the old policy."
      ;;
    "[deny]" | retrieve-only | "git refuse" | "git push" | non-public)
      owner="the project's policy"
      [[ "$why" == non-public ]] && owner="the sandbox's policy (a local or LAN address)"
      note="$host was refused by $owner ($why) during this command; --apply does not lift it." ask=""
      ;;
    *) continue ;;
  esac
  done_hosts+="$host "
  # Statements, not commands: Claude Code's hooks doc warns that text framed as
  # out-of-band instructions can be taken for a prompt injection.
  text+="${text:+\\n}agent-sandbox: $note Going on with a mirror, another channel or another tool for the same thing is going on without it, and whether to do that is the user's decision.$ask This session continues without it only once the user has said so."
done < <(head -n "$n" -- "$log" | tail -n "+$((seen + 1))")

[[ -n "$text" ]] || exit 0
# Every byte of $text is the literal above, a validated host or a known reason, and
# $section matched its pattern: nothing in it needs JSON escaping but the \n joins.
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$text"
