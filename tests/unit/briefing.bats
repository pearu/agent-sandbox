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
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
if [ -n "${BWRAP_COPY:-}" ]; then
  mkdir -p "$BWRAP_COPY"
  cp -r "$AGENT_SANDBOX_SESSION_BASE"/session.*/. "$BWRAP_COPY"/ 2>/dev/null || true
fi
exit 0
STUB
  chmod +x "$H/bin/bwrap"
  OUT="$H/copied"
}

trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "on by default: the briefing is bound read-only and handed to the agent as session hooks" {
  run_engine BWRAP_COPY="$OUT" -- claude --version
  [ "$status" -eq 0 ]
  # the artefacts are bound at fixed paths inside, once each
  local a
  for a in briefing.md hook-SessionStart.json hook-SubagentStart.json; do
    [ "$(grep -c "^$IN/$a$" "$H/argv")" -eq 1 ]
  done
  # settings.json twice: the bind target, and the value of --settings
  [ "$(grep -c "^$IN/settings.json$" "$H/argv")" -eq 2 ]
  # ...and every one of them read-only
  [ "$(grep -c '^--ro-bind$' "$H/argv")" -ge 4 ]
  # the agent is pointed at the settings file, last on the line
  argv_has --settings "$IN/settings.json"
  [ "${ARGV[-1]}" = "$IN/settings.json" ]
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
    AGENT_SANDBOX_RO="$H/ro1" AGENT_SANDBOX_RW="$H/rw1" -- claude --allow pypi.org --version
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
  grep -q 'claude --trust' "$md"
  # names and paths only: nothing is read out of the shared project
  printf 'SECRET-CANARY\n' >"$H/home/.claude/projects/$(printf '%s' "$H/other" | sed 's:[^A-Za-z0-9-]:-:g')/memory/MEMORY.md"
  run_engine BWRAP_COPY="$OUT" -- claude --version
  ! grep -q 'SECRET-CANARY' "$OUT/briefing.md"
}

@test "the compact summary carries the actionable half, not just the prohibitions" {
  run_engine BWRAP_COPY="$OUT" -- claude --version
  local h="$OUT/hook-SessionStart.json"
  grep -q 'deliberate' "$h"                 # a block is not a fault
  grep -q 'opened on purpose' "$h"          # ...and what is open should be used
  grep -q "$IN/briefing.md" "$h"            # pointer to the full text
  grep -q 'cannot widen this yourself' "$h" # escalation, not workarounds
  # one line of JSON: the payload must parse as the hook contract, not as prose
  [ "$(wc -l <"$h")" -eq 1 ]
}

@test "off suppresses every trace of it; a dot-file can ask for that, and the shell knob wins" {
  run_engine AGENT_SANDBOX_BRIEFING=off BWRAP_COPY="$OUT" -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --settings
  ! grep -q "$IN" "$H/argv"
  [ ! -e "$OUT/briefing.md" ]
  # a trusted dot-file can turn it off...
  printf '[briefing]\nmode = off\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --settings
  # ...and says so, which is what distinguishes "the file was read" from "the
  # default happened to match"
  [[ "$output" == *"using briefing mode 'off' from .agent-sandbox"* ]]
  # an explicit knob in the shell overrides the file, as everywhere else
  run_engine AGENT_SANDBOX_BRIEFING=on -- claude --version
  argv_has --settings "$IN/settings.json"
  [[ "$output" == *"overrides the .agent-sandbox briefing mode 'off'"* ]]
}

@test "an unknown briefing value is refused before bwrap runs" {
  run_engine AGENT_SANDBOX_BRIEFING=verbose -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* && "$output" == *"'on' or 'off'"* ]]
  [ ! -s "$H/argv" ]
}

@test "a user --settings is merged, not clobbered: Claude Code honours only the last one" {
  local mine='{"permissions":{"defaultMode":"plan"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged your --settings"* ]]
  # the user's own settings survive, ours are added alongside
  grep -q '"defaultMode": "plan"' "$OUT/settings.json"
  grep -q 'echo mine' "$OUT/settings.json"
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
  grep -q '"SubagentStart"' "$OUT/settings.json"
  # ours is last on the line, so it is the one Claude Code keeps. (Comparing
  # against argv_index of the path would prove nothing: it also appears earlier
  # as the bind target, and argv_index reports the first occurrence.)
  [ "${ARGV[-1]}" = "$IN/settings.json" ]
  [ "$(argv_index "$mine")" -lt "$((${#ARGV[@]} - 1))" ]
}

@test "--settings=VALUE spelling is recognised too, and a file path is read" {
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo from-file"}]}]}}' >"$H/mine.json"
  run_engine BWRAP_COPY="$OUT" -- claude "--settings=$H/mine.json" --version
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
  run_engine BWRAP_COPY="$OUT" -- claude --settings "$first" --settings "$last" --version
  [ "$status" -eq 0 ]
  grep -q 'echo LAST' "$OUT/settings.json"
  ! grep -q 'echo FIRST' "$OUT/settings.json" # overridden, as it would have been
  grep -q "cat $IN/hook-SessionStart.json" "$OUT/settings.json"
}

@test "settings that disable all hooks are respected, and the briefing says it will not arrive" {
  run_engine BWRAP_COPY="$OUT" -- claude --settings '{"disableAllHooks":true}' --version
  [ "$status" -eq 0 ]
  grep -q '"disableAllHooks": true' "$OUT/settings.json" # their call stands
  [[ "$output" == *"will NOT be injected"* ]]
  # the readable copy is still there, so the information is not lost entirely
  [ "$(grep -c "^$IN/briefing.md$" "$H/argv")" -eq 1 ]
}

@test "the merge only appends two hook entries: no setting of the user's changes" {
  # The briefing contributes a list of hook entries and nothing else, so every
  # key it does not write must come through byte-identical.
  local mine
  mine='{"permissions":{"defaultMode":"plan","allow":["Bash(git *)"]},"env":{"FOO":"bar"},"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo theirs"}]}],"Stop":[{"hooks":[{"type":"command","command":"echo stop"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- claude --settings "$mine" --version
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

@test "a hooks shape we do not recognise is refused, never coerced" {
  # list() of a dict yields its keys, which would silently replace their data.
  run_engine BWRAP_COPY="$OUT" -- claude --settings '{"hooks":{"SessionStart":{"oops":1}}}' --version
  [ "$status" -eq 0 ] # the launch goes on
  [[ "$output" == *"not installed"* ]]
  ! argv_has --settings "$IN/settings.json"
  argv_has --settings '{"hooks":{"SessionStart":{"oops":1}}}'
}

@test "when the merge cannot be done the USER's settings are kept and the loss is said out loud" {
  # A python3 that fails stands in for the interpreter being absent: both take
  # the same branch, and losing a hint must never cost someone their settings.
  printf '#!/bin/sh\nexit 3\n' >"$H/bin/python3"
  chmod +x "$H/bin/python3"
  run_engine BWRAP_COPY="$OUT" -- claude --settings '{"a":1}' --version
  [ "$status" -eq 0 ] # the launch goes on
  ! argv_has --settings "$IN/settings.json"
  argv_has --settings '{"a":1}' # theirs, untouched
  [[ "$output" == *"not installed"* ]]
  [[ "$output" == *"briefing.md"* ]] # ...and where to read it anyway
  # the readable briefing is still bound: only the injection was lost
  [ "$(grep -c "^$IN/briefing.md$" "$H/argv")" -eq 1 ]
}
