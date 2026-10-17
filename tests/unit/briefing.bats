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
# a bubblewrap that can mount an overlay, as the harness's own stub says it can
if [ "${1:-}" = --help ]; then
  printf '    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST\n'
  exit 0
fi
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
  engine_cmd
  output="$(cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust 2>&1)"
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
  # the command the user runs on the host: it edits the file and asks, as --trust does
  grep -qxF "      asb --apply '[allow]' example.com" "$md" # no role: the unsuffixed section
  # not only hosts: any section the same way
  grep -qxF "  any section the same way, e.g. asb --apply '[connect]' '~/data/ = read-only'" "$md"
  grep -qF 'for a host and for this launch only: asb --allow example.com ...' "$md"
  # going on with less is the user's call, not the session's
  grep -q 'only when the user says so' "$md"
  # names and paths only: nothing is read out of the shared project
  printf 'SECRET-CANARY\n' >"$H/home/.claude/projects/$(printf '%s' "$H/other" | sed 's:[^A-Za-z0-9-]:-:g')/memory/MEMORY.md"
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  run ! grep -q 'SECRET-CANARY' "$OUT/briefing.md"
}

@test "the briefing's SSH line names each host and where it came from: the dot-file's section, --ssh" {
  make_ssh_stubs
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  grep -qxF -- "- SSH reachable through a constrained agent: none -- to ask the user for a host, the command is asb --apply '[ssh]' HOST, then a relaunch" "$OUT/briefing.md"
  printf '[ssh]\ngithub.com\n[ssh:impl-*]\ngit@gitlab.example\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine BWRAP_COPY="$OUT" -- asb --role impl-1 --ssh flag.example --ssh github.com claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- '- SSH reachable through a constrained agent: flag.example (--ssh), github.com (.agent-sandbox [ssh], --ssh), git@gitlab.example (.agent-sandbox [ssh:impl-*])' "$OUT/briefing.md"
  grep -qF 'SSH: flag.example (--ssh), github.com (.agent-sandbox [ssh], --ssh), git@gitlab.example (.agent-sandbox [ssh:impl-*]).' "$OUT/hook-SessionStart.json"
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
  grep -q 'continue without it only when they say so' "$h"
  # ...through the engine's command that changes the dot-file and reviews it: `claude` is
  # Claude Code itself (#151)
  # shellcheck disable=SC2016 # the backticks are literal text in the summary
  grep -q 'the `asb --apply` command to run on the host' "$h"
  run ! grep -q 'claude --' "$h"
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

@test "the merge only appends hook entries (and a status line where theirs has none): no setting of the user's changes" {
  # The briefing contributes hook entries and, absent theirs, a status line, so every
  # key it does not write must come through byte-identical.
  local mine
  mine='{"permissions":{"defaultMode":"plan","allow":["Bash(git *)"]},"env":{"FOO":"bar"},"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo theirs"}]}],"PreCompact":[{"hooks":[{"type":"command","command":"echo compact"}]}]}}'
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  python3 - "$OUT/settings.json" <<'CHECK'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["permissions"] == {"defaultMode": "plan", "allow": ["Bash(git *)"]}, m
assert m["env"] == {"FOO": "bar"}, m
assert m["model"] == "opus", m
assert len(m["hooks"]["PreCompact"]) == 1, m    # an event we do not use: untouched
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
  # The stub is the interpreter under coverage too, where AGENT_SANDBOX_TEST_PYTHON
  # would otherwise run profile.py past it (unmeasured here, then).
  # shellcheck disable=SC2034 # read by engine_cmd (common.bash)
  AGENT_SANDBOX_TEST_PYTHON="$H/bin/python3"
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
  grep -qxF "      asb --apply '[allow:reviewer-1]' example.com" "$OUT/briefing.md" # a role asks for its own lines
  grep -qF "asb --apply '[connect:reviewer-1]' '~/data/ = read-only'" "$OUT/briefing.md"
  argv_has --ro-bind "$PROJ/.asb/roles/reviewer-1.md" "$PROJ/.asb/roles/reviewer-1.md"
  # a role the section does not match is not briefed
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  run ! grep -q 'Your purpose' "$OUT/hook-SessionStart.json"
}

@test "a session is told when its purpose file changed since the role's previous launch; the hash is kept in the role's store" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'Report, do not fix.\n' >"$PROJ/.asb/roles/reviewer-1.md"
  printf '[briefing:reviewer-*]\n' >"$PROJ/.agent-sandbox"
  approve
  local said="this purpose file has changed since this role's previous launch; the text above is the current one, and it replaces whatever earlier turns of this conversation followed."
  local rec
  # first launch: nothing to compare with, so nothing said; the hash is recorded
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  rec=("$H"/home/.local/state/agent-sandbox/claude/*/reviewer-1/purpose.sha256)
  [ -f "${rec[0]}" ]
  [ "$(cat "${rec[0]}")" = "$(sha256sum "$PROJ/.asb/roles/reviewer-1.md" | cut -d' ' -f1)" ]
  [[ "${rec[0]}" != "$PROJ"/* ]]
  run ! grep -qF "$said" "$OUT/hook-SessionStart.json"
  run ! grep -qF "$said" "$OUT/briefing.md"
  # unchanged: nothing said
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"its purpose file changed"* ]]
  run ! grep -qF "$said" "$OUT/hook-SessionStart.json"
  run ! grep -qF "$said" "$OUT/briefing.md"
  # changed (and approved again): said right after the purpose text, in both, and once on the host
  printf 'Report, and fix too.\n' >"$PROJ/.asb/roles/reviewer-1.md"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'reviewer-1': its purpose file changed since its previous launch; the session is told"* ]]
  grep -qF 'Report, and fix too.\n\nagent-sandbox: '"$said" "$OUT/hook-SessionStart.json"
  run ! grep -qF "$said" "$OUT/hook-SubagentStart.json"
  grep -qxF "agent-sandbox: $said" "$OUT/briefing.md"
  [ "$(sed -n '/^## Your role: /,/^## /p' "$OUT/briefing.md" | grep -cxF "agent-sandbox: $said")" -eq 1 ]
  [ "$(cat "${rec[0]}")" = "$(sha256sum "$PROJ/.asb/roles/reviewer-1.md" | cut -d' ' -f1)" ]
  # and the launch after that is unchanged again
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$said" "$OUT/hook-SessionStart.json"
}

@test "a role without a purpose file keeps no purpose hash and is told nothing about one" {
  printf '[briefing:reviewer-*]\n[connect:supervisor]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  compgen -G "$H/home/.local/state/agent-sandbox/claude/*/supervisor/record.tsv" # its store is there
  run ! compgen -G "$H/home/.local/state/agent-sandbox/claude/*/supervisor/purpose.sha256"
  run ! grep -q 'purpose file has changed' "$OUT/hook-SessionStart.json"
  run ! grep -q 'purpose file has changed' "$OUT/briefing.md"
}

@test "a role with no role section to join asks for [allow]: a first [allow:ROLE] would refuse every other role name" {
  printf '[allow]\nexample.org\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  grep -qxF "      asb --apply '[allow]' example.com" "$OUT/briefing.md"
  run ! grep -q '\[allow:' "$OUT/briefing.md"
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
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"briefed from: .asb/roles/reviewer.md"* ]]
}

@test "the proxy's refusals reach the session: an empty refused.log bound read-only, the section to ask for, a Bash hook on both outcomes" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  # the session dir's own file (the addon appends to it), empty at launch, bound over
  # its placeholder after the briefing directory -- never the session dir itself
  [ -f "$H/copied/refused.log" ] && [ ! -s "$H/copied/refused.log" ]
  local i
  i="$(argv_index "$IN/refused.log")"
  [ "${ARGV[i - 2]}" = --ro-bind ]
  [[ "${ARGV[i - 1]}" == "$H/base/session."*/refused.log ]]
  ((i > $(argv_index "$IN")))
  run ! grep -q 'blocked.log' "$H/argv"
  [ "$(cat "$OUT/apply-section")" = '[allow]' ]
  [ -f "$OUT/refusal-hook.sh" ]
  python3 -I - "$OUT/settings.json" "$IN" <<'CHECK'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
for ev in ("PostToolUse", "PostToolUseFailure"):
    entry, state = hooks[ev] # and the state hook's own entry, for any tool (#287)
    assert "matcher" not in state, state
    assert entry["matcher"] == "Bash", entry
    assert entry["hooks"] == [{"type": "command", "command": f"bash {sys.argv[2]}/refusal-hook.sh {ev}"}], entry
CHECK
  # the briefing says what going on without it means, and that refusals are reported
  grep -q 'a mirror, another channel' "$OUT/briefing.md"
  grep -q 'or another tool for the same thing is going on without it' "$OUT/briefing.md"
  grep -q 'command is reported to this session right after it' "$OUT/briefing.md"
  grep -q 'a mirror or another tool for the same thing counts as going on without it' "$OUT/hook-SessionStart.json"
}

@test "the section the refusal hook asks for is the engine's: [allow:ROLE] only where the dot-file has role sections" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'Report, do not fix.\n' >"$PROJ/.asb/roles/reviewer-1.md"
  printf '[briefing:reviewer-*]\n[connect:supervisor]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/apply-section")" = '[allow:reviewer-1]' ]
  printf '[allow]\nexample.org\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/apply-section")" = '[allow]' ]
}

@test "refusal-hook.sh reports each new refused host once: --apply for an allowlist gap, the policy for a [deny], nothing for a bad line" {
  local hook="${ENGINE%/*}/profiles/claude/refusal-hook.sh" D="$BATS_TEST_TMPDIR/run" S="$BATS_TEST_TMPDIR/seen"
  mkdir -p "$D"
  printf '[allow:reviewer-1]\n' >"$D/apply-section"
  printf '%s\n' $'2026-10-15T10:00:00\tprefix.dev\tCONNECT\tallowlist' \
    $'2026-10-15T10:00:01\tevil"host\\n\tCONNECT\tallowlist' \
    $'2026-10-15T10:00:02\tshop.example\tGET\t[deny]' \
    $'2026-10-15T10:00:03\tprefix.dev\tGET\tallowlist' >"$D/refused.log"
  run bash "$hook" PostToolUseFailure "$D" "$S"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/out.json"
  python3 -I - "$BATS_TEST_TMPDIR/out.json" <<'CHECK'
import json, sys
o = json.load(open(sys.argv[1]))["hookSpecificOutput"]
assert o["hookEventName"] == "PostToolUseFailure", o
lines = o["additionalContext"].split("\n")
assert len(lines) == 2, lines  # one per distinct host; the invalid line skipped
assert lines[0] == ("agent-sandbox: prefix.dev was refused by the sandbox (allowlist) during this command. "
    "Going on with a mirror, another channel or another tool for the same thing is going on without it, "
    "and whether to do that is the user's decision. The user adds the host, on the host, with: "
    "asb --apply '[allow:reviewer-1]' prefix.dev. This session continues without it only once the user has said so."), lines[0]
assert lines[1] == ("agent-sandbox: shop.example was refused by the project's policy ([deny]) during this command; "
    "--apply does not lift it. Going on with a mirror, another channel or another tool for the same thing is going "
    "on without it, and whether to do that is the user's decision. This session continues without it only once the "
    "user has said so."), lines[1]
assert "asb --apply" not in lines[1], lines[1]
assert "evil" not in o["additionalContext"]
CHECK
  # nothing new: no output at all
  run bash "$hook" PostToolUse "$D" "$S"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  # one new line: only that host, under the event it was called for
  printf '%s\n' $'2026-10-15T10:01:00\tconda.anaconda.org\tCONNECT\tallowlist' >>"$D/refused.log"
  run bash "$hook" PostToolUse "$D" "$S"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/out.json"
  python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$BATS_TEST_TMPDIR/out.json"
  [[ "$output" == *'"hookEventName":"PostToolUse"'* && "$output" == *"asb --apply '[allow:reviewer-1]' conda.anaconda.org."* ]]
  [[ "$output" != *prefix.dev* && "$output" != *shop.example* ]]
  # a line still being written (no newline yet) waits for the next call
  printf '2026-10-15T10:02:00\tlate.example\tCONNECT\tallow' >>"$D/refused.log"
  run bash "$hook" PostToolUse "$D" "$S"
  [ -z "$output" ]
  # no section from the engine, or a malformed one: the unsuffixed [allow]
  printf "x'; rm -rf ~\n" >"$D/apply-section"
  printf 'list\n' >>"$D/refused.log"
  run bash "$hook" PostToolUse "$D" "$S"
  [[ "$output" == *"asb --apply '[allow]' late.example."* ]]
  # an event it was not written for, or no log: silent
  run bash "$hook" PreToolUse "$D" "$BATS_TEST_TMPDIR/seen2"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run bash "$hook" PostToolUse "$BATS_TEST_TMPDIR/nowhere" "$BATS_TEST_TMPDIR/seen3"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "the agent's own telemetry (#276): the profile's hosts beside the briefing, one sentence in it, one line in --check -- none under hosts = public" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  grep -qxF .datadoghq.com "$OUT/telemetry-hosts"
  [ "$(grep -cF 'own telemetry is not reported and is not a blocked action' "$OUT/briefing.md")" -eq 1 ]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  local n
  n="$(bash -c '. "$1"; profile_telemetry_hosts | grep -c .' _ "${ENGINE%/*}/profiles/claude/profile.sh")"
  [[ "$output" == *"  network: the agent's own telemetry is refused and not reported to it ($n hosts)"* ]]
  printf '[net]\nhosts = public\n' >"$PROJ/.agent-sandbox"
  approve
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"network: every public host"* ]]
  [[ "$output" != *"own telemetry"* ]]
}

@test "refusal-hook.sh leaves the agent's own telemetry out of its note (#276): an exact host, a subdomain, and only the other host of a mix" {
  local hook="${ENGINE%/*}/profiles/claude/refusal-hook.sh" D="$BATS_TEST_TMPDIR/run" S="$BATS_TEST_TMPDIR/seen"
  mkdir -p "$D"
  printf '[allow]\n' >"$D/apply-section"
  printf '%s\n' .datadoghq.com browser-intake-us5-datadoghq.com 'bad host' >"$D/telemetry-hosts"
  # a subdomain of a .domain entry, the domain itself, an exact entry: no note at all
  printf '%s\n' $'2026-10-16T10:00:00\thttp-intake.logs.us5.datadoghq.com\tCONNECT\tallowlist' \
    $'2026-10-16T10:00:01\tdatadoghq.com\tCONNECT\tallowlist' \
    $'2026-10-16T10:00:02\tbrowser-intake-us5-datadoghq.com\tCONNECT\tallowlist' >"$D/refused.log"
  run bash "$hook" PostToolUse "$D" "$S"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  # a mix: only the unlisted host, and not one that merely ends in the same letters
  printf '%s\n' $'2026-10-16T10:01:00\thttp-intake.logs.us5.datadoghq.com\tCONNECT\tallowlist' \
    $'2026-10-16T10:01:01\tprefix.dev\tCONNECT\tallowlist' \
    $'2026-10-16T10:01:02\tnotdatadoghq.com\tCONNECT\tallowlist' >>"$D/refused.log"
  run bash "$hook" PostToolUseFailure "$D" "$S"
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/out.json"
  python3 -I - "$BATS_TEST_TMPDIR/out.json" <<'CHECK'
import json, sys
c = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
lines = c.split("\n")
assert len(lines) == 2, lines
assert lines[0].startswith("agent-sandbox: prefix.dev was refused by the sandbox (allowlist)"), lines
assert lines[1].startswith("agent-sandbox: notdatadoghq.com was refused"), lines
assert "datadoghq.com was" not in c.replace("notdatadoghq.com", ""), c
CHECK
  # no list from the engine: every host is reported, as before
  rm "$D/telemetry-hosts"
  printf '%s\n' $'2026-10-16T10:02:00\thttp-intake.logs.us5.datadoghq.com\tCONNECT\tallowlist' >>"$D/refused.log"
  run bash "$hook" PostToolUse "$D" "$S"
  [[ "$output" == *"http-intake.logs.us5.datadoghq.com was refused by the sandbox (allowlist)"* ]]
}

@test "what the session hands the user is one line or a file, and the briefing names where its files are on the host" {
  local sbox="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}"
  local md="$OUT/briefing.md"
  # a read-write project, and an own store declared in it
  run_engine BWRAP_COPY="$OUT" -- asb --connect '.asb/scratch/ = own' claude --version
  [ "$status" -eq 0 ]
  grep -qxF '## Handing the user something to run or read' "$md"
  grep -qF 'heredoc, a patch or a' "$md"
  # shellcheck disable=SC2016 # the backticks are literal text in the briefing
  grep -qF '`git apply PATH`, `git commit -F PATH`, `bash PATH`. The whole command, path' "$md"
  grep -qF "never typed -- a single copied line's prefix is harmless to a shell." "$md"
  grep -qxF -- "- the project (read-write) is the project directory itself, $PROJ" "$md"
  # the store the launch bound there, as the bwrap argv has it
  local slot
  slot="$sbox/default/@paths/own/$(printf '%s' "${PROJ#/}/.asb/scratch" | tr / _)"
  argv_has --bind "$slot" "$PROJ/.asb/scratch"
  grep -qxF -- "- .asb/scratch/ (own) is, on the host, $slot" "$md"
  # the short form: one clause, pointing at the paths
  grep -qF 'What you hand the user to run is one line or a file (where your files are on the host: briefing.md).' "$OUT/hook-SessionStart.json"
  # a copy-on-write project: a file written into it is in the role's layer
  run_engine BWRAP_COPY="$OUT" -- asb --role rev-1 --connect 'project = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$PROJ" --overlay "$sbox/rev-1/@project/upper" "$sbox/rev-1/@project/work" "$PROJ"
  grep -qxF -- "  layer, not in the user's tree -- $PROJ/X is, on the host, $sbox/rev-1/@project/upper/X" "$md"
  run ! grep -qF 'is the project directory itself' "$md"
  # a read-only project, nothing declared: nothing to reach
  run_engine BWRAP_COPY="$OUT" -- asb --connect 'project = read-only' claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- '- none: nothing this session can write is a file the user can reach' "$md"
}

@test "the briefing names the conda command and where its environments are: the host's conda, or agent-sandbox's micromamba" {
  local base="$H/conda" md="$OUT/briefing.md" h="$OUT/hook-SessionStart.json"
  local mm="$H/home/.local/share/agent-sandbox/micromamba/bin" root="$H/home/.local/share/agent-sandbox/conda"
  mkdir -p "$base/envs/e" "$mm"
  printf '#!/bin/sh\n' >"$mm/micromamba"
  chmod +x "$mm/micromamba"
  # shellcheck disable=SC2016 # the backticks are literal text in the briefing
  {
    run_engine BWRAP_COPY="$OUT" MAMBA_ROOT_PREFIX="$base" CONDA_PREFIX="$base/envs/e" -- asb claude --version
    [ "$status" -eq 0 ]
    grep -qxF -- "- conda: the host's \`conda\` at $base" "$md"
    grep -qF " Conda: the host's \`conda\`. " "$h"
    run ! grep -qF micromamba "$md"
    run_engine BWRAP_COPY="$OUT" MAMBA_ROOT_PREFIX="$base" CONDA_PREFIX="$base/envs/e" AGENT_SANDBOX_CONDA_BASE=sandbox -- asb claude --version
    [ "$status" -eq 0 ]
    grep -qxF -- "- conda: \`micromamba\`, root $root (the sandbox's own)" "$md"
    grep -qF " Conda: \`micromamba\`, root $root. " "$h"
    # no conda in play: no line
    run_engine BWRAP_COPY="$OUT" -- asb claude --version
    [ "$status" -eq 0 ]
    run ! grep -qF -- '- conda:' "$md"
    run ! grep -qF 'Conda:' "$h"
  }
}

@test "the briefing's SSH line names the --apply command for this role, with origin's host when it is an SSH remote; under [net] git = refuse as well (#293)" {
  git -C "$PROJ" init -q
  git -C "$PROJ" remote add origin git@github.com:pearu/torch-op-bench.git
  printf '[connect:supervisor]\n[net:reviewer-*]\ngit = refuse\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- "- SSH reachable through a constrained agent: none -- to ask the user for a host, the command is asb --apply '[ssh:supervisor]' github.com (the host of origin), then a relaunch" "$OUT/briefing.md"
  grep -qxF "  -- or SSH for a push to origin: asb --apply '[ssh:supervisor]' github.com" "$OUT/briefing.md"
  grep -qF "SSH: none -- to ask the user for a host, the command is asb --apply '[ssh:supervisor]' github.com" "$OUT/hook-SessionStart.json"
  run_engine BWRAP_COPY="$OUT" -- asb --role reviewer-1 claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- "- SSH reachable through a constrained agent: none -- to ask the user for a host, the command is asb --apply '[ssh:reviewer-1]' github.com (the host of origin), then a relaunch" "$OUT/briefing.md"
  run ! grep -qF 'closes SSH' "$OUT/briefing.md"
  grep -qF "GIT TRANSPORT REFUSED: git cannot fetch or push over HTTPS from here, to any host, and there is no SSH host; the repository on disk is your only remote." "$OUT/briefing.md"
  git -C "$PROJ" remote set-url origin https://github.com/pearu/torch-op-bench.git
  run_engine BWRAP_COPY="$OUT" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  grep -qF "the command is asb --apply '[ssh:supervisor]' HOST, then a relaunch" "$OUT/briefing.md" # no SSH remote: no host to name
}

@test "the briefing says \$HOME is read-only and where a tool can write instead: ~/.cache and /tmp, by its variable" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- "- \$HOME is read-only: an empty tmpfs, the host's home directory is not here," "$OUT/briefing.md"
  grep -qF "plus ~/.cache, writable" "$OUT/briefing.md"
  grep -qF "(TRITON_HOME, XDG_CACHE_HOME, ...) in your own shell" "$OUT/briefing.md"
  grep -qF "under ~ only ~/.cache (and /tmp)" "$OUT/hook-SessionStart.json"
  argv_has --tmpfs "$H/home/.cache" # what the line promises
  argv_has --remount-ro "$H/home"
}

# perm_allow FILE -- the settings file's permissions.allow, one rule per line (none: empty).
perm_allow() {
  python3 -c 'import json,sys; [print(r) for r in json.load(open(sys.argv[1])).get("permissions", {}).get("allow", [])]' "$1"
}

@test "[permissions]: the role's rules, the file's and its own section's, reach the agent in the briefing's --settings; none without an approved file" {
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  run ! grep -q '"permissions"' "$OUT/settings.json"
  printf '[permissions]\nBash(git push:*)\n' >"$PROJ/.agent-sandbox"
  rm -rf "$OUT"
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -ne 0 ] # not approved: refused, nothing granted
  [ ! -e "$OUT/settings.json" ]
  printf '%s\n' '[permissions]' 'Bash(.asb/bin/inbox-wait:*)' 'Bash(tail:*)' \
    '[permissions:gate]' 'Bash(git push:*)' 'Bash(tail:*)' 'Bash(echo "a\b"	x)' 'not a rule' \
    '[permissions:planner-*]' 'Read' >"$PROJ/.agent-sandbox"
  trust
  rm -rf "$OUT"
  run_engine BWRAP_COPY="$OUT" -- asb --role gate claude --version
  [ "$status" -eq 0 ]
  # the union, in file order, each rule once; a line that is no rule is left out
  [ "$(perm_allow "$OUT/settings.json")" = "$(printf '%s\n' 'Bash(.asb/bin/inbox-wait:*)' 'Bash(tail:*)' 'Bash(git push:*)' 'Bash(echo "a\b"	x)')" ]
  grep -q '"SessionStart"' "$OUT/settings.json" # the hooks are still there
  [ "${JOINB[*]}" = "--settings $IN/settings.json" ]
  rm -rf "$OUT"
  run_engine BWRAP_COPY="$OUT" -- asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(perm_allow "$OUT/settings.json")" = "$(printf '%s\n' 'Bash(.asb/bin/inbox-wait:*)' 'Bash(tail:*)' 'Read')" ]
}

@test "[permissions] with a user --settings: their rules first, ours added once, their deny kept" {
  printf '[permissions]\nBash(git push:*)\nRead\n' >"$PROJ/.agent-sandbox"
  trust
  local mine='{"permissions":{"allow":["Read"],"deny":["Bash(rm:*)"],"defaultMode":"plan"}}'
  run_engine BWRAP_COPY="$OUT" -- asb claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged your --settings"* ]]
  python3 - "$OUT/settings.json" <<'CHECK'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["permissions"] == {"allow": ["Read", "Bash(git push:*)"], "deny": ["Bash(rm:*)"], "defaultMode": "plan"}, m
assert "SessionStart" in m["hooks"], m
CHECK
}

@test "[permissions] with the briefing off: not passed, and said" {
  printf '[permissions]\nBash(git push:*)\n[briefing]\nmode = off\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine BWRAP_COPY="$OUT" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[permissions]: not passed to the agent -- they travel with the briefing, which is off"* ]]
  run ! join_has --settings
}

# start_project -- a planner briefed from its purpose file, whose first turn is
# .asb/start/{role}.md; every other role from the unsuffixed [briefing]'s start file.
start_project() {
  mkdir -p "$PROJ/.asb/roles" "$PROJ/.asb/start"
  printf 'Plan.\n' >"$PROJ/.asb/roles/planner-1.md"
  printf 'Arm your watcher; read your inbox.\n' >"$PROJ/.asb/start/planner-1.md"
  printf 'Anyone.\n' >"$PROJ/.asb/start/all.md"
  printf '[briefing]\nstart = .asb/start/all.md\n[briefing:planner-*]\nstart = .asb/start/{role}.md\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  approve
}

@test "[briefing] start: the file's text is the session's first turn, after the agent's own arguments; {role}, the latest matching line wins" {
  start_project
  run_engine -- asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  [ "${#JOINV[@]}" -eq 4 ]
  [ "${JOINV[*]:1}" = "--continue -- Arm your watcher; read your inbox." ]
  [ "${JOINB[0]}" = --settings ] # the briefing's own arguments still come first
  run_engine -- asb --role planner-1 claude --resume 01234567-89ab-cdef-0123-456789abcdef
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "--resume 01234567-89ab-cdef-0123-456789abcdef -- Arm your watcher; read your inbox." ]
  run_engine -- asb --role other claude
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "-- Anyone." ]
  # the profile declines a run that is not an interactive start
  run_engine -- asb --role planner-1 claude -p 'Reply ok.'
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "-p Reply ok." ]
  # a second terminal joining the role's running launch starts a session too
  engine_bg -- asb --role planner-1 claude
  run_engine -- asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *"joining role 'planner-1'"* ]]
  [ "${JOINV[*]:1}" = "--continue -- Arm your watcher; read your inbox." ]
  release_bg
}

@test "[briefing] start: a missing file, or a path out of the project, refuses the launch, naming it" {
  start_project
  rm "$PROJ/.asb/start/planner-1.md"
  run_engine -- asb --role planner-1 claude --continue
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'planner-1' starts with the text of '.asb/start/planner-1.md' ([briefing] start), which does not exist. Refusing"* ]]
  [ ! -s "$H/argv" ]
  printf '[briefing:planner-*]\nstart = ../start.md\n' >"$PROJ/.agent-sandbox"
  printf 'x\n' >"$H/start.md"
  approve
  [[ "$output" == *"[briefing:planner-*] start '../start.md' is not a path in the project (relative to it, no '..'); a launch of the roles planner-* refuses"* ]]
  run_engine -- asb --role planner-1 claude --continue
  [ "$status" -ne 0 ]
  [[ "$output" == *"[briefing] start '../start.md' is not a path in the project"* ]]
  [ ! -s "$H/argv" ]
}

@test "[briefing] start: not read for --exec, a verb, a turn of --serve, or with the briefing off -- a missing file refuses none of them" {
  start_project
  rm "$PROJ/.asb/start/planner-1.md"
  run_engine -- asb --role planner-1 --profile claude --exec true
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "true" ]
  run_engine -- asb --role planner-1 claude agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not running"* ]]
  run_engine AGENT_SANDBOX_SERVE_TURN=1 -- asb --role planner-1 claude -p --resume 01234567-89ab-cdef-0123-456789abcdef 'Read your inbox.'
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "-p --resume 01234567-89ab-cdef-0123-456789abcdef Read your inbox." ]
  run_engine AGENT_SANDBOX_BRIEFING=off -- asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "--continue" ]
}

@test "[briefing] start: the review and --check name the file; --apply adds the key and the review takes it" {
  start_project
  [[ "$output" == *"[briefing:planner-*] start, for the roles planner-*: its first turn at every start is the text of .asb/start/{role}.md"* ]]
  [[ "$output" == *"[briefing] start, for every role: its first turn at every start is the text of .asb/start/all.md"* ]]
  [[ "$output" != *"unknown [briefing] key"* ]]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role planner-1 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  first turn at every start: the text of .asb/start/planner-1.md"$'\n'* ]]
  rm "$PROJ/.asb/start/planner-1.md"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role planner-1 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" == *"  first turn at every start: the text of .asb/start/planner-1.md -- MISSING: a launch refuses"* ]]
  # --apply: the line lands in its section, and the review that follows reads it as a key
  printf '[briefing:reviewer-*]\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$PROJ/.asb/roles"
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[briefing:reviewer-*]" "start = .asb/start/reviewer.md" 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^\[briefing:reviewer-\*\]$/{n;p}' "$PROJ/.agent-sandbox")" = "start = .asb/start/reviewer.md" ]
  [[ "$output" == *"[briefing:reviewer-*] start, for the roles reviewer-*: its first turn at every start is the text of .asb/start/reviewer.md"* ]]
  [[ "$output" != *"unknown [briefing] key"* ]]
}

@test "an [ssh] host under [net] git = refuse, fetch or retrieve-only: the briefing says a push over SSH to it is not refused, and git governs HTTPS only (#293)" {
  make_ssh_stubs
  local g md
  md="$OUT/briefing.md"
  for g in refuse fetch allow; do
    printf '[ssh:impl-*]\ntob-ex\n[net:impl-*]\ngit = %s\nretrieve-only = on\n[connect:supervisor]\n' "$g" >"$PROJ/.agent-sandbox"
    approve
    run_engine BWRAP_COPY="$OUT" -- asb --role impl-1 claude --version
    [ "$status" -eq 0 ]
    grep -qxF -- "- SSH reachable through a constrained agent: tob-ex (.agent-sandbox [ssh:impl-*]); a push over SSH to a listed host is not refused by retrieve-only or [net] git" "$md"
    grep -qF "SSH: tob-ex (.agent-sandbox [ssh:impl-*]); a push over SSH to a listed host is not refused by retrieve-only or [net] git." "$OUT/hook-SessionStart.json"
    grep -qF "publishes nothing over HTTP -- no POST, no push, no comment. SSH to tob-ex is open in full. Leave publishing to the user." "$md"
    run ! grep -qF 'closes SSH' "$md"
    run ! grep -qF 'there is no SSH' "$md"
    case "$g" in
      refuse) grep -qF "GIT TRANSPORT REFUSED: git cannot fetch or push over HTTPS from here, to any host; [net] git does not govern SSH (the SSH line)." "$md" ;;
      fetch) grep -qF "GIT FETCHES ONLY: git can fetch over HTTPS (use an https:// URL); a push over HTTPS is refused; [net] git does not govern SSH (the SSH line)." "$md" ;;
      allow) run ! grep -qF "GIT " "$md" ;;
    esac
  done
  # without retrieve-only and git = allow, the SSH line is the plain list
  printf '[ssh:impl-*]\ntob-ex\n[connect:supervisor]\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine BWRAP_COPY="$OUT" -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  grep -qxF -- "- SSH reachable through a constrained agent: tob-ex (.agent-sandbox [ssh:impl-*])" "$md"
}
