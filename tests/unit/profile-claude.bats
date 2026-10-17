#!/usr/bin/env bats
# The claude profile: the binary, state paths.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  V="$H/home/.local/share/claude/versions"
  # the slug tests call the profile's functions directly
  source "$REPO_ROOT/profiles/claude/profile.sh"
}

# Two slugs RECORDED from Claude Code 2.1.270 by probes/config-dir-check.sh
# --matrix: the project path a session ran in, and the directory name it created
# under projects/. These pin the whole scheme -- the 200-character truncation
# point, the "-" separator, and the hash -- against real output rather than
# against our own reimplementation of it.
slug_vector() {
  local tag="$1" n="$2" seg i p
  seg="$(printf 'x%.0s' {1..60})"
  p="/tmp/as-leak-matrix.3WbHJO/$tag"
  for ((i = 1; i <= n; i++)); do p="$p/$seg$i"; done
  printf '%s' "$p"
}

@test "a launch does not look in versions/: it runs what the command resolves to" {
  rm -rf "${V:?}"/*
  mkdir -p "$H/pkg/bin"
  printf '#!/bin/sh\n' >"$H/pkg/bin/claude"
  chmod +x "$H/pkg/bin/claude"
  rm "$H/bin/claude"
  run_engine PATH="$H/bin:$H/pkg/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/pkg/bin/claude" "$H/pkg/bin/claude"
  [ "${JOINV[0]}" = "$H/pkg/bin/claude" ]
}

@test "a launch creates ~/.claude, and never an empty ~/.claude.json: Claude Code calls a 0-byte one corrupted" {
  # Measured on 2.1.286: with no ~/.claude.json Claude Code runs and writes its own; with
  # a 0-byte one it backs it up as corrupted and fails. Under `native` and `config =
  # read-write` that is the file it reads, so the engine must not plant one.
  local p
  for p in shared native; do
    rm -rf "$H/home/.claude" "$H/home/.claude.json"
    TEST_PRESET="" run_engine -- asb --preset "$p" claude --version
    [ "$status" -eq 0 ]
    [ -d "$H/home/.claude" ]
    [ ! -e "$H/home/.claude.json" ]
  done
}

@test "the empty mount-point file bwrap leaves on the host for the config file is removed after the session; a file that was already there is kept" {
  # This stub bwrap creates the mount point the way the real one does when the
  # bind's destination is missing inside a read-write directory: an empty file
  # on the host. Left behind, it is a config file that parses as nothing for
  # anyone who points CLAUDE_CONFIG_DIR at ~/.claude natively.
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
[ -e "$HOME/.claude/.claude.json" ] || : >"$HOME/.claude/.claude.json"
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$H/home/.claude/.claude.json" ]
  # a file that already existed there before the launch is not ours, whatever it holds
  printf '{}' >"$H/home/.claude/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$H/home/.claude/.claude.json")" = '{}' ]
  : >"$H/home/.claude/.claude.json"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ -e "$H/home/.claude/.claude.json" ]
}

@test "asb claude update runs in the sandbox like any command: claude update typed natively is the update" {
  run_engine -- asb claude update --foo
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # the sandbox was built, and the command joined into it
  [[ " ${JOINV[*]} " == *"/claude update --foo "* ]]
  [[ "$output" != *"on the host"* ]]
}

@test "profile_telemetry_hosts names Claude Code's own telemetry in the allowlist's syntax, and nothing a session needs (#276)" {
  run profile_telemetry_hosts
  [ "$status" -eq 0 ]
  grep -qxF .datadoghq.com <<<"$output"
  local h
  while IFS= read -r h; do
    [[ "$h" =~ ^\.?[a-z0-9-]+(\.[a-z0-9-]+)+$ ]]
    [[ "$h" != *anthropic.com && "$h" != *claude.ai && "$h" != *claude.com ]]
  done <<<"$output"
}

@test "project slug: a converted name of 200 characters or fewer is used unchanged" {
  [ "$(_claude_project_slug /home/u/proj.x)" = "-home-u-proj-x" ]
  local p200 s
  p200="/$(printf 'a%.0s' $(seq 1 199))"
  [ "${#p200}" -eq 200 ]
  s="$(_claude_project_slug "$p200")"
  [ "${#s}" -eq 200 ]
  [ "$s" = "${p200//[^A-Za-z0-9-]/-}" ] # no truncation, no hash appended
}

@test "project slug: past 200 characters it is truncated and hashed, matching Claude Code 2.1.270" {
  local seg p want
  seg="$(printf 'x%.0s' {1..60})"
  # vector 1: a 280-character converted name -> recorded slug ended "...-b8aa65"
  p="$(slug_vector long4 4)"
  want="-tmp-as-leak-matrix-3WbHJO-long4-${seg}1-${seg}2-$(printf 'x%.0s' {1..43})-b8aa65"
  [ "$(_claude_project_slug "$p")" = "$want" ]
  # vector 2: a 466-character converted name -> recorded slug ended "...-mcwljf"
  # (its hash is NEGATIVE; the suffix is the absolute value, which is what
  # caught an implementation that only considered unsigned hashes)
  p="$(slug_vector long7 7)"
  want="-tmp-as-leak-matrix-3WbHJO-long7-${seg}1-${seg}2-$(printf 'x%.0s' {1..43})-mcwljf"
  [ "$(_claude_project_slug "$p")" = "$want" ]
  # both recorded slugs were 207 characters: 200 + "-" + a 6-character hash
  [ "${#want}" -eq 207 ]
}

@test "project slug: the hash suffix is variable width, not padded to six characters" {
  # /a hashes to 176 -- three characters. A suffix padded or truncated to a
  # fixed width would produce the wrong directory name for such a path.
  [ "$(_claude_path_hash /a)" = "176" ]
  [ "$(_claude_path_hash "")" = "0" ]
}

@test "a project path longer than 200 characters binds the truncated project directory" {
  local seg deep real plain slug
  seg="$(printf 'z%.0s' {1..60})"
  deep="$H/home/$seg/$seg/$seg"
  mkdir -p "$deep"
  real="$(cd "$deep" && pwd -P)"
  # the UNtruncated conversion, computed here rather than by the code under
  # test: asserting only on _claude_project_slug's own answer would pass for any
  # scheme, including no truncation at all
  plain="${real//[^A-Za-z0-9-]/-}"
  [ "${#plain}" -gt 200 ] # otherwise this test proves nothing
  slug="$(_claude_project_slug "$real")"
  RUN_CWD="$deep" run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$H/home/.claude/projects/$plain/memory" "$H/home/.claude/projects/$plain/memory"
  argv_has --bind "$H/home/.claude/projects/$slug/memory" "$H/home/.claude/projects/$slug/memory" # memory on top of the transcripts store
  [ "${#slug}" -le 207 ]                                                                          # 200 + "-" + at most six characters, so under NAME_MAX
}

# ----- the status line and the state hooks (#287) ------------------------------

# settings_of [VAR=value ...] CMD ARGS... -- run the engine with a stub bwrap that copies the
# session's briefing directory out before the engine removes it; the settings file the
# agent is given is then $OUT/settings.json. The caller checks $status.
settings_of() {
  OUT="$H/copied/briefing"
  grep -q BWRAP_COPY "$H/bin/bwrap" || sed -i 's|^\. "\${0%/\*}/keeper-tail"$|if [ -n "${BWRAP_COPY:-}" ]; then mkdir -p "$BWRAP_COPY"; cp -r "$AGENT_SANDBOX_SESSION_BASE"/session.*/. "$BWRAP_COPY"/.. 2>/dev/null \|\| true; fi\n&|' "$H/bin/bwrap"
  grep -q BWRAP_COPY "$H/bin/bwrap"
  rm -rf "$H/copied"
  local -a envs=()
  while [[ "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  run_engine BWRAP_COPY="$OUT" ${envs[@]+"${envs[@]}"} -- "$@"
}

# check_state_settings FILE ROLE BACKGROUND -- the statusLine names ROLE and redraws
# every second; SessionStart, UserPromptSubmit, Stop, PermissionRequest, Notification,
# PostToolUse and PostToolUseFailure each run state-hook.sh with BACKGROUND (the last two
# for any tool, beside the refusal hook's Bash entry), and SessionEnd only when it is on.
check_state_settings() {
  python3 -I - "$@" <<'CHECK'
import json, sys
path, role, bg = sys.argv[1:4]
IN = "/run/agent-sandbox"
m = json.load(open(path))
assert m["statusLine"] == {"type": "command", "command": f"bash {IN}/statusline.sh {role}", "refreshInterval": 1}, m["statusLine"]
hooks = m["hooks"]
def cmds(ev):
    return [h["command"] for g in hooks.get(ev, []) for h in g["hooks"]]
for ev in ("SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "Notification"):
    assert f"bash {IN}/state-hook.sh {ev} {bg}" in cmds(ev), (ev, cmds(ev))
assert f"cat {IN}/hook-SessionStart.json" in cmds("SessionStart"), cmds("SessionStart")
for ev in ("PostToolUse", "PostToolUseFailure"):
    refusal, state = hooks[ev]
    assert refusal == {"matcher": "Bash", "hooks": [{"type": "command", "command": f"bash {IN}/refusal-hook.sh {ev}"}]}, refusal
    assert state == {"hooks": [{"type": "command", "command": f"bash {IN}/state-hook.sh {ev} {bg}"}]}, state
end = cmds("SessionEnd")
assert end == ([f"bash {IN}/state-hook.sh SessionEnd on"] if bg == "on" else []), end
CHECK
}

@test "the status line names the role and redraws every second; the state hooks beside the briefing's, the scripts beside it (#287)" {
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  [ -f "$OUT/statusline.sh" ]
  [ -f "$OUT/state-hook.sh" ]
  cmp "$REPO_ROOT/profiles/claude/statusline.sh" "$OUT/statusline.sh"
  cmp "$REPO_ROOT/profiles/claude/state-hook.sh" "$OUT/state-hook.sh"
  # no role: "default", which the script shows as the project's name
  settings_of asb claude --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" default off
  # the briefing off (a role of its own, so a fresh launch): no settings file at all,
  # so no status line and no hooks
  settings_of AGENT_SANDBOX_BRIEFING=off asb --role quiet claude --version
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = --version ]
  [ ! -e "$OUT/statusline.sh" ]
  [ ! -e "$OUT/settings.json" ]
  [ "${#JOINB[@]}" -eq 0 ]
}

@test "a statusLine in the user's --settings wins; their own hooks on the state events run beside ours (#287)" {
  local mine='{"statusLine":{"type":"command","command":"echo MINE"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo their-stop"}]}],"Notification":[{"hooks":[{"type":"command","command":"echo their-note"}]}]}}'
  settings_of asb --role planner-1 claude --settings "$mine" --version
  [ "$status" -eq 0 ]
  python3 -I - "$OUT/settings.json" <<'CHECK'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["statusLine"] == {"type": "command", "command": "echo MINE"}, m["statusLine"]
for ev, theirs in (("Stop", "echo their-stop"), ("Notification", "echo their-note")):
    got = [h["command"] for g in m["hooks"][ev] for h in g["hooks"]]
    assert got == [theirs, f"bash /run/agent-sandbox/state-hook.sh {ev} off"], got
CHECK
  # without one of theirs, ours is added to their settings
  settings_of asb --role planner-1 claude --settings '{"model":"opus"}' --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  grep -q '"model": "opus"' "$OUT/settings.json"
}

@test "[claude] state-background = on: the state hooks set the terminal background, and SessionEnd resets it; off by default (#287)" {
  printf '[claude]\nstate-background = on\n' >"$H/proj/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"state-background"*"not"* ]] # a key the profile reads: no warning
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 on
  # an unknown value is said, and is off
  printf '[claude]\nstate-background = blue\n' >"$H/proj/.agent-sandbox"
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"state-background 'blue' unknown (on|off); keeping off"* ]]
  check_state_settings "$OUT/settings.json" planner-1 off
}

@test "profile_start_args: the first turn is the prompt after the agent's own arguments, behind a --; declined where the session is not an interactive start" {
  local -a profile_start_argv=()
  profile_start_args 'Arm your watcher.'
  [ "${profile_start_argv[*]}" = "-- Arm your watcher." ]
  profile_start_argv=()
  profile_start_args 'Arm it.' --continue
  [ "${#profile_start_argv[@]}" -eq 2 ] && [ "${profile_start_argv[0]}" = -- ] && [ "${profile_start_argv[1]}" = 'Arm it.' ]
  profile_start_argv=()
  profile_start_args 'Arm it.' --resume 01234567-89ab-cdef-0123-456789abcdef --add-dir /x
  [ "${profile_start_argv[*]}" = "-- Arm it." ]
  local a
  for a in "-p hi" "--continue --print" "--bg" "--help" "-v" "--version" "--continue -- mine" "mcp list" "my own prompt"; do
    profile_start_argv=()
    # shellcheck disable=SC2086 # the words of the case
    profile_start_args 'Arm it.' $a
    [ "${#profile_start_argv[@]}" -eq 0 ] || {
      echo "not declined for: $a"
      false
    }
  done
}

@test "/start: a role with a [briefing] start gets the text as a command in its briefing directory, added with --add-dir; none without one, nor for a print run" {
  mkdir -p "$H/proj/.asb/start" "$H/proj/.asb/roles"
  printf 'Plan.\n' >"$H/proj/.asb/roles/planner-1.md"
  printf 'Arm your watcher; read your inbox.\n' >"$H/proj/.asb/start/planner-1.md"
  printf '[briefing:planner-*]\nstart = .asb/start/{role}.md\n[connect:*]\n' >"$H/proj/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  settings_of asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  [ "${JOINB[*]}" = "--settings /run/agent-sandbox/settings.json --add-dir /run/agent-sandbox" ]
  [ "${JOINV[*]:1}" = "--continue -- Arm your watcher; read your inbox." ]
  [ "$(cat "$OUT/.claude/commands/start.md")" = "$(printf -- '---\ndescription: The start text of role planner-1, as a turn (after /clear)\ndisable-model-invocation: true\n---\n\nArm your watcher; read your inbox.')" ]
  # a role with no start text: no command, no --add-dir
  settings_of asb --role other claude --continue
  [ "$status" -eq 0 ]
  [ "${JOINB[*]}" = "--settings /run/agent-sandbox/settings.json" ]
  [ ! -e "$OUT/.claude" ]
  # a print run of the role: neither (a fresh launch, the last one's keeper gone)
  settings_of asb --role planner-1 claude -p 'Reply ok.'
  [ "$status" -eq 0 ]
  [ "${JOINB[*]}" = "--settings /run/agent-sandbox/settings.json" ]
  [ "${JOINV[*]:1}" = "-p Reply ok." ]
  [ ! -e "$OUT/.claude" ]
}
