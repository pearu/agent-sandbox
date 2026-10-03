#!/usr/bin/env bats
# The briefing (issue #15): the sandbox tells the session what it may and may
# not do, so a deliberate block is not mistaken for a fault and deliberately
# opened access actually gets used. Asserted on the bwrap argv and on the files
# the engine writes into the session directory, which a probing stub copies out
# before the engine removes it.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  IN=/run/agent-sandbox # where the briefing is bound inside the sandbox
  # a stub bwrap that also copies the session dir out, so the generated
  # briefing and settings can be read after the engine cleans up
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
if [ -n "${BWRAP_COPY:-}" ]; then
  mkdir -p "$BWRAP_COPY"
  cp -r "$AGENT_SANDBOX_SESSION_BASE"/session.*/. "$BWRAP_COPY"/.. 2>/dev/null || true
fi
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
  OUT="$H/copied/briefing" # the session directory's briefing/, bound at $IN
}

# approve -- the project's dot-file, approved the way `--trust` records it (with the
# purpose files it names, #222). Its output is in $output.
approve() {
  output="$(cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "$ENGINE" --trust 2>&1)"
}

trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "on by default: the briefing is bound read-only and handed to the agent as session hooks" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  # the artefacts are one directory, bound once, read-only, at a fixed path inside:
  # the launch is a keeper, and a later join's own settings file must appear in it
  local i
  i="$(argv_index "$IN")"
  [ "$(grep -c "^$IN$" "$H/argv")" -eq 1 ]
  [ "${ARGV[i - 2]}" = --ro-bind ]
  [[ "${ARGV[i - 1]}" == "$H/base/session."*/briefing ]]
  local a
  for a in briefing.md hook-SessionStart.json hook-SubagentStart.json settings.json; do
    [ -s "$OUT/$a" ]
  done
  # the agent is pointed at the settings file, first on the line, before its own
  # arguments: a subcommand refuses --settings after it
  [ "${JOINB[*]}" = "--settings $IN/settings.json" ]
  # SessionStart AND SubagentStart, each cat-ing its own payload
  grep -q '"SessionStart"' "$OUT/settings.json"
  grep -q '"SubagentStart"' "$OUT/settings.json"
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
  grep -q "cat $IN/hook-SubagentStart.json" "$OUT/settings.json"
  # the payloads are what the agent's hook contract expects
  grep -q '"hookEventName":"SessionStart"' "$OUT/hook-SessionStart.json"
  grep -q '"hookEventName":"SubagentStart"' "$OUT/hook-SubagentStart.json"
  grep -q '"additionalContext":' "$OUT/hook-SessionStart.json"
}

@test "the briefing states the policy actually in force, and tells the agent how to ask" {
  mkdir -p "$H/ro1" "$H/rw1" "$H/other"
  mkdir -p "$H/home/.claude/projects/$(printf '%s' "$H/other" | sed 's:[^A-Za-z0-9-]:-:g')/memory"
  printf '[share-memory]\n%s\n' "$H/other" >"$PROJ/.agent-sandbox"
  trust
  local SC="$H/seccomp"
  mkdir -p "$SC"
  printf 'x' >"$SC/$(uname -m).bpf"
  run_engine BWRAP_COPY="$OUT" AGENT_SANDBOX_SECCOMP=on AGENT_SANDBOX_SECCOMP_DIR="$SC" \
    -- asb --allow pypi.org --connect "$H/ro1 = read-only" --connect "$H/rw1 = read-write" claude --version
  [ "$status" -eq 0 ]
  local md="$OUT/briefing.md"
  grep -q 'allowlist' "$md"     # egress is described
  grep -q 'pypi.org' "$md"      # the session's own --allow
  grep -q -- "$H/rw1" "$md"     # extra writable path
  grep -q -- "$H/ro1" "$md"     # extra read-only path
  grep -q -- "$PROJ" "$md"      # the project is writable
  grep -q -- "$H/other" "$md"   # the project whose memory is shared
  grep -q 'seccomp is on' "$md" # the syscall filter
  grep -q 'trust-gated' "$md"   # ...and how to ask for more
  grep -q 'asb --trust' "$md"
  # names and paths only: nothing is read out of the shared project
  printf 'SECRET-CANARY\n' >"$H/home/.claude/projects/$(printf '%s' "$H/other" | sed 's:[^A-Za-z0-9-]:-:g')/memory/MEMORY.md"
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  run ! grep -q 'SECRET-CANARY' "$OUT/briefing.md"
}

@test "a read-only project is said so: the briefing lists it read-only and only what is declared writable (#220)" {
  mkdir -p "$PROJ/impl"
  run_engine BWRAP_COPY="$OUT" -- asb --connect 'project = read-only' --connect './impl/ = read-write' claude --version
  [ "$status" -eq 0 ]
  grep -q -- "- writable: $PROJ/impl\$" "$OUT/briefing.md"
  grep -q -- "- extra read-only paths: $PROJ (the project)\$" "$OUT/briefing.md"
  run_engine BWRAP_COPY="$OUT" -- asb --connect 'project = read-only' claude --version
  grep -q -- "- writable: nothing in the project\$" "$OUT/briefing.md"
}

@test "the compact summary carries the actionable half, not just the prohibitions" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  local h="$OUT/hook-SessionStart.json"
  grep -q 'deliberate' "$h"                 # a block is not a fault
  grep -q 'opened on purpose' "$h"          # ...and what is open should be used
  grep -q "$IN/briefing.md" "$h"            # pointer to the full text
  grep -q 'cannot widen this yourself' "$h" # escalation, not workarounds
  # ...through the command that reviews a dot-file: `claude` is Claude Code itself (#151)
  # shellcheck disable=SC2016 # the backticks are literal text in the summary
  grep -q 're-run `asb --trust`' "$h"
  run ! grep -q 'claude --trust' "$h"
  # one line of JSON: the payload must parse as the hook contract, not as prose
  [ "$(wc -l <"$h")" -eq 1 ]
}

@test "off suppresses every trace of it; a dot-file can ask for that, and the shell knob wins" {
  run_engine AGENT_SANDBOX_BRIEFING=off BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "${#JOINB[@]}" -eq 0 ]
  run ! join_has --settings
  run ! grep -q "$IN" "$H/argv"
  [ ! -e "$OUT/briefing.md" ]
  # a trusted dot-file can turn it off...
  printf '[briefing]\nmode = off\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  # ...and says so, which is what distinguishes "the file was read" from "the
  # default happened to match"
  [[ "$output" == *"using briefing mode 'off' from .agent-sandbox"* ]]
  [ "${#JOINB[@]}" -eq 0 ]
  # an explicit knob in the shell overrides the file, as everywhere else
  run_engine AGENT_SANDBOX_BRIEFING=on -- asb claude --version
  [ "${JOINB[*]}" = "--settings $IN/settings.json" ]
  [[ "$output" == *"overrides the .agent-sandbox briefing mode 'off'"* ]]
}

@test "an unknown briefing value is refused before bwrap runs" {
  run_engine AGENT_SANDBOX_BRIEFING=verbose -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* && "$output" == *"'on' or 'off'"* ]]
  [ ! -s "$H/argv" ]
}

@test "a user --settings is merged, not clobbered: Claude Code honours only the last one" {
  local mine='{"permissions":{"defaultMode":"plan"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged your --settings"* ]]
  # the user's own settings survive, ours are added alongside
  grep -q '"defaultMode": "plan"' "$OUT/settings.json"
  grep -q 'echo mine' "$OUT/settings.json"
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
  grep -q '"SubagentStart"' "$OUT/settings.json"
  # ours is the only one on the line, so it is the one Claude Code keeps: theirs is
  # in it now, and dropped from their arguments, which are otherwise as typed
  [ "${JOINB[*]}" = "--settings $IN/settings.json" ]
  [ "${JOINV[*]:1}" = "--version" ]
}

@test "--settings=VALUE spelling is recognised too, and a file path is read" {
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo from-file"}]}]}}' >"$H/mine.json"
  run_engine BWRAP_COPY="$OUT" -- asb claude "--settings=$H/mine.json" --version
  [ "$status" -eq 0 ]
  grep -q 'echo from-file' "$OUT/settings.json"
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
}

@test "several --settings: the LAST one is merged, so overriding an earlier one still works" {
  # Claude Code honours only the last --settings, so a wrapper that appends one
  # to override an earlier one relies on the earlier being dropped. Merging must
  # not resurrect it.
  local first='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo FIRST"}]}]}}'
  local last='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo LAST"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings "$first" --settings "$last" --version
  [ "$status" -eq 0 ]
  grep -q 'echo LAST' "$OUT/settings.json"
  run ! grep -q 'echo FIRST' "$OUT/settings.json" # overridden, as it would have been
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
}

@test "settings that disable all hooks are respected, and the briefing says it will not arrive" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings '{"disableAllHooks":true}' --version
  [ "$status" -eq 0 ]
  grep -q '"disableAllHooks": true' "$OUT/settings.json" # their call stands
  [[ "$output" == *"will NOT be injected"* ]]
  # the readable copy is still there, so the information is not lost entirely
  [ "$(grep -c "^$IN$" "$H/argv")" -eq 1 ]
}

@test "the merge only appends two hook entries: no setting of the user's changes" {
  # The briefing contributes a list of hook entries and nothing else, so every
  # key it does not write must come through byte-identical.
  local mine
  mine='{"permissions":{"defaultMode":"plan","allow":["Bash(git *)"]},"env":{"FOO":"bar"},"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo theirs"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo stop"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  python3 - "$OUT/settings.json" <<'CHECK'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["permissions"] == {"defaultMode": "plan", "allow": ["Bash(git *)"]}, m
assert m["env"] == {"FOO": "bar"}, m
assert m["model"] == "opus", m
assert len(m["hooks"]["Stop"]) == 1, m          # an event we do not use: untouched
ss = m["hooks"]["SessionStart"]                 # one we do: theirs first, ours appended
assert len(ss) == 2, ss
assert ss[0]["hooks"][0]["command"] == "echo theirs", ss
assert "hook-SessionStart.json" in ss[1]["hooks"][0]["command"], ss
CHECK
}

@test "a subcommand gets the briefing before it, and what follows a -- is never read as Claude Code's" {
  # `claude mcp list --settings X` is "unknown option"; `claude --settings X mcp list`
  # works (measured, 2.1.285)
  run_engine -- asb claude mcp list
  [ "$status" -eq 0 ]
  [ "${JOINB[*]}" = "--settings $IN/settings.json" ]
  [ "${JOINV[*]:1}" = "mcp list" ]
  # after `--` the words are an MCP server's command line: a --settings there is its own
  run_engine -- asb claude mcp add srv -- tool --settings keep.json
  [ "$status" -eq 0 ]
  [[ "$output" != *"merged your --settings"* ]]
  [ "${JOINV[*]:1}" = "mcp add srv -- tool --settings keep.json" ]
}

@test "a hooks shape we do not recognise is refused, never coerced" {
  # list() of a dict yields its keys, which would silently replace their data.
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings '{"hooks":{"SessionStart":{"oops":1}}}' --version
  [ "$status" -eq 0 ] # the launch goes on
  [[ "$output" == *"not installed"* ]]
  [ "${#JOINB[@]}" -eq 0 ]
  join_has --settings '{"hooks":{"SessionStart":{"oops":1}}}'
}

@test "when the merge cannot be done the USER's settings are kept and the loss is said out loud" {
  # A merge that fails keeps the user's settings: losing a hint must never cost
  # someone their settings. The stub fails the merge (profile.py merge-settings) only:
  # the join into the keeper is python3 too.
  # shellcheck disable=SC2016 # the stub's own $2 and $@
  printf '#!/bin/sh\n[ "$2" = merge-settings ] && exit 3\nexec /usr/bin/python3 "$@"\n' >"$H/bin/python3"
  chmod +x "$H/bin/python3"
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings '{"a":1}' --version
  [ "$status" -eq 0 ]           # the launch goes on
  join_has --settings '{"a":1}' # theirs, untouched
  [[ "$output" == *"not installed"* ]]
  [[ "$output" == *"briefing.md"* ]] # ...and where to read it anyway
  [ "${#JOINB[@]}" -eq 0 ]
  # the readable briefing is still bound: only the injection was lost
  [ "$(grep -c "^$IN$" "$H/argv")" -eq 1 ]
}

@test "a role's purpose file goes into the SessionStart hook after the engine's lines, not to a subagent, and is bound read-only (#222)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'Report, do not fix.\n' >"$PROJ/.asb/roles/reviewer-1.md"
  printf '[briefing:reviewer-*]\n[connect:supervisor]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  grep -q "You are the role 'reviewer-1' of this project. Your purpose, from .asb/roles/reviewer-1.md (read-only here):\\\\n\\\\nReport, do not fix." "$OUT/hook-SessionStart.json"
  grep -q '"additionalContext":"agent-sandbox: this session is sandboxed' "$OUT/hook-SessionStart.json" # the engine's lines first
  run ! grep -q 'Report, do not fix' "$OUT/hook-SubagentStart.json"
  grep -q '^## Your role: reviewer-1$' "$OUT/briefing.md"
  grep -q '^Report, do not fix.$' "$OUT/briefing.md"
  argv_has --ro-bind "$PROJ/.asb/roles/reviewer-1.md" "$PROJ/.asb/roles/reviewer-1.md"
  # a role the section does not match is not briefed
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  run ! grep -q 'Your purpose' "$OUT/hook-SessionStart.json"
}

@test "file = names the purpose file, with {role}; the unsuffixed [briefing] briefs every role (#222)" {
  mkdir -p "$PROJ/purposes"
  printf 'Implement.\n' >"$PROJ/purposes/impl-1.txt"
  printf 'Anyone.\n' >"$PROJ/purposes/all.txt"
  printf '[briefing]\nfile = purposes/all.txt\n[briefing:impl-*]\nfile = purposes/{role}.txt\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  grep -q 'from purposes/impl-1.txt' "$OUT/hook-SessionStart.json"
  grep -q 'Implement.' "$OUT/hook-SessionStart.json"
  run_engine BWRAP_COPY="$OUT" -- asb --role other claude --version
  [ "$status" -eq 0 ]
  grep -q 'from purposes/all.txt' "$OUT/hook-SessionStart.json"
}

@test "a purpose file that does not exist refuses the role's launch, naming it (#222)" {
  printf '[briefing:reviewer]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine -- asb --role reviewer claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"briefed from '.asb/roles/reviewer.md'"*"does not exist"* ]]
  [ ! -s "$H/argv" ]
}

@test "a purpose file is part of the approval: an edit refuses the launch, and the review shows the difference (#222)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'Report.\n' >"$PROJ/.asb/roles/reviewer.md"
  printf '[briefing:reviewer]\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"purpose file "*"/.asb/roles/reviewer.md, new to this approval"*"Report."* ]]
  approve
  run_engine -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  printf 'Report, and fix too.\n' >"$PROJ/.asb/roles/reviewer.md"
  run_engine -- asb --role reviewer claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"or a purpose file it names, has changed since you approved it"* ]]
  run_review
  [[ "$output" == *"/.asb/roles/reviewer.md has changed since you approved it"*"+Report, and fix too."* ]]
  [[ "$output" != *".agent-sandbox has changed"* ]] # the dot-file itself did not
  # a new file the section's glob matches is new to the approval too
  printf '[briefing:reviewer-*]\n' >"$PROJ/.agent-sandbox"
  printf 'One.\n' >"$PROJ/.asb/roles/reviewer-1.md"
  approve
  printf 'Two.\n' >"$PROJ/.asb/roles/reviewer-2.md"
  run_engine -- asb --role reviewer-1 claude --version
  [ "$status" -ne 0 ]
}

@test "a purpose file may not be declared read-write; [briefing:<role>] mode is the unsuffixed section's (#222)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'x\n' >"$PROJ/.asb/roles/r.md"
  printf '[briefing:r]\nmode = off\n[connect]\n.asb/roles/r.md = read-write\n' >"$PROJ/.agent-sandbox"
  approve
  [[ "$output" == *"[briefing:r] mode"*"unsuffixed [briefing] only"* ]]
  run_engine -- asb --role r claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"a role's purpose file is part of its approved policy"* ]]
}

@test "--check names the file a role is briefed from (#222)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'x\n' >"$PROJ/.asb/roles/reviewer.md"
  printf '[briefing:reviewer]\n' >"$PROJ/.agent-sandbox"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"briefed from: .asb/roles/reviewer.md"* ]]
}
