#!/usr/bin/env bats
# The claude profile: the binary, state paths.

setup() {
  load "$BATS_TEST_DIRNAME/../../helpers/common"
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

@test "a launch runs the claude asb installed (#6): never one on PATH, nor the native installer's versions/" {
  mkdir -p "$H/pkg/bin" "$V/2.1.200" "$H/home/.local/bin"
  printf '#!/bin/sh\n' >"$H/pkg/bin/claude"
  chmod +x "$H/pkg/bin/claude"
  printf '#!/bin/sh\n' >"$V/2.1.200/claude"
  chmod +x "$V/2.1.200/claude"
  ln -s "$V/2.1.200/claude" "$H/home/.local/bin/claude"
  rm "$H/bin/claude"
  local p
  for p in isolated inherit shared native; do
    run_engine PATH="$H/pkg/bin:$H/home/.local/bin:$H/bin:/usr/bin:/bin" -- asb --preset "$p" claude --version
    [ "$status" -eq 0 ]
    [ "${JOINV[0]}" = "$STUB_AGENT_DIR/claude" ]
    argv_has --ro-bind "$STUB_AGENT_DIR" "$STUB_AGENT_DIR"
    run ! grep -qxF -- "$H/pkg/bin/claude" "$H/argv"
  done
  # a path still runs what it names
  run_engine -- asb "$H/pkg/bin/claude" --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/pkg/bin/claude" ]
  argv_has --ro-bind "$H/pkg/bin/claude" "$H/pkg/bin/claude"
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
import json, re, sys
path, role, bg = sys.argv[1:4]
IN = "/run/agent-sandbox"
m = json.load(open(path))
# the status line's command may set the summary line's path before it (T39)
sl = dict(m["statusLine"], command=re.sub(r"^AGENT_SANDBOX_SUMMARY=\S+ ", "", m["statusLine"]["command"]))
assert sl == {"type": "command", "command": f"bash {IN}/statusline.sh {role}", "refreshInterval": 1}, m["statusLine"]
hooks = m["hooks"]
def cmds(ev):
    return [h["command"] for g in hooks.get(ev, []) for h in g["hooks"]]
for ev in ("SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "Notification"):
    # the Stop hook's command may set the rules' variables before it (the watcher, the summary)
    got = [re.sub(r"^(AGENT_SANDBOX_(WATCH|SUMMARY)=\S+ )+", "", c) if ev == "Stop" else c for c in cmds(ev)]
    assert f"bash {IN}/state-hook.sh {ev} {bg}" in got, (ev, cmds(ev))
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
for ev, theirs, env in (("Stop", "echo their-stop", "AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line "), ("Notification", "echo their-note", "")):
    got = [h["command"] for g in m["hooks"][ev] for h in g["hooks"]]
    assert got == [theirs, f"{env}bash /run/agent-sandbox/state-hook.sh {ev} off"], got
CHECK
  # without one of theirs, ours is added to their settings
  settings_of asb --role planner-1 claude --settings '{"model":"opus"}' --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  grep -q '"model": "opus"' "$OUT/settings.json"
}

@test "a role's settings turn /auto-mode-setup off; a plain session's have no skillOverrides" {
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["skillOverrides"])' "$OUT/settings.json")" = "{'auto-mode-setup': 'off'}" ]
  settings_of asb claude --version
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" default off
  run ! grep -q skillOverrides "$OUT/settings.json"
}

@test "a user's --settings that sets skillOverrides auto-mode-setup, or has a skillOverrides that is not an object, keeps it, and the launch says so" {
  settings_of asb --role planner-1 claude --settings '{"skillOverrides":{"auto-mode-setup":"on"}}' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"your --settings sets skillOverrides \"auto-mode-setup\", so it decides whether /auto-mode-setup is offered; the role's \"off\" is not added"* ]]
  grep -q '"auto-mode-setup": "on"' "$OUT/settings.json"
  settings_of asb --role planner-1 claude --settings '{"skillOverrides":"off"}' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"your --settings has a skillOverrides value that is not an object; it is left as it is, and the role's \"auto-mode-setup\": \"off\" is not added"* ]]
  grep -q '"skillOverrides": "off"' "$OUT/settings.json"
  # theirs with another override: both kept, nothing said
  settings_of asb --role planner-1 claude --settings '{"skillOverrides":{"simplify":"off"}}' --version
  [ "$status" -eq 0 ]
  [[ "$output" != *skillOverrides* ]]
  [ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["skillOverrides"])' "$OUT/settings.json")" = "{'simplify': 'off', 'auto-mode-setup': 'off'}" ]
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

@test "[agent] resume: the profile's resume verb is --continue, read by a launch and emitted by _as_profile_facts (#355)" {
  grep -qxF 'resume = --continue' "$REPO_ROOT/profiles/claude/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$REPO_ROOT/profiles/claude/profile.sh" >"$H/facts"
  )
  grep -qxF "$(printf 'resume\tclaude\t--continue')" "$H/facts"
  # a profile without the key emits no resume line
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  printf '[agent]\nclear = /clear\n' >"$H/profiles2/other/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$H/profiles2/other/profile.sh" >"$H/facts2"
  )
  run ! grep -q '^resume' "$H/facts2"
  # what a launch runs: the agent's own arguments, then the profile's resume words
  run_engine -- asb --resume claude -x
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "-x --continue" ]
}

@test "[agent] account-paths: the login and its refresh lock are an account's, not visible; read by a launch and emitted by _as_profile_facts (#355)" {
  grep -qxF 'account-paths = .credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner' "$REPO_ROOT/profiles/claude/agent-sandbox"
  grep -qxF 'visible = ide' "$REPO_ROOT/profiles/claude/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$REPO_ROOT/profiles/claude/profile.sh" >"$H/facts"
  )
  grep -qxF "$(printf 'account-paths\tclaude\t.credentials.json\t.oauth_refresh.lock\t.oauth_refresh.lock.owner')" "$H/facts"
  # a profile without the key emits no account-paths line
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  printf '[agent]\nclear = /clear\n' >"$H/profiles2/other/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$H/profiles2/other/profile.sh" >"$H/facts2"
  )
  run ! grep -q '^account-paths' "$H/facts2"
}
@test "[agent] account-expiry: the login's expiry key, emitted by _as_profile_facts; a line of another shape is said and ignored (#355)" {
  grep -qxF 'account-expiry = .credentials.json claudeAiOauth.refreshTokenExpiresAt' "$REPO_ROOT/profiles/claude/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$REPO_ROOT/profiles/claude/profile.sh" >"$H/facts"
  )
  grep -qxF "$(printf 'account-expiry\tclaude\t.credentials.json\tclaudeAiOauth.refreshTokenExpiresAt')" "$H/facts"
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  printf '[agent]\naccount-expiry = only-a-file\n' >"$H/profiles2/other/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$H/profiles2/other/profile.sh" >"$H/facts2"
    # shellcheck disable=SC2034 # the profile _as_profile_dotfile names in what it says
    local profile=other
    local -a profile_account_expiry=()
    _as_profile_dotfile "$H/profiles2/other/agent-sandbox" 2>"$H/said" || :
    [ "${#profile_account_expiry[@]}" -eq 0 ]
  )
  run ! grep -q '^account-expiry' "$H/facts2"
  grep -qF "[agent] account-expiry takes FILE KEYPATH, two words; ignoring" "$H/said"
}

@test "[agent] login-renew: what renews the base's login, emitted by _as_profile_facts; a value with a tab is said and ignored (#355)" {
  grep -qxF 'login-renew = /login' "$REPO_ROOT/profiles/claude/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$REPO_ROOT/profiles/claude/profile.sh" >"$H/facts"
  )
  grep -qxF "$(printf 'login-renew\tclaude\t/login')" "$H/facts"
  # the rest of the line, as written
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  printf '[agent]\nlogin-renew = sign in   again\n' >"$H/profiles2/other/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$H/profiles2/other/profile.sh" >"$H/facts2"
  )
  grep -qxF "$(printf 'login-renew\tother\tsign in   again')" "$H/facts2"
  # a tab in it: said, ignored, not emitted
  printf '[agent]\nlogin-renew = run\t/login\n' >"$H/profiles2/other/agent-sandbox"
  (
    # shellcheck disable=SC1090
    source "$ENGINE"
    _as_profile_facts "$H/profiles2/other/profile.sh" >"$H/facts3"
    # shellcheck disable=SC2034 # the profile _as_profile_dotfile names in what it says
    local profile=other
    local profile_login_renew=""
    _as_profile_dotfile "$H/profiles2/other/agent-sandbox" 2>"$H/said" || :
    [ -z "$profile_login_renew" ]
  )
  run ! grep -q '^login-renew' "$H/facts3"
  grep -qF "[agent] login-renew is one line of text, without a tab; ignoring" "$H/said"
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

# stop_cmds FILE -- the Stop hook's commands in the settings file FILE, one per line
stop_cmds() {
  python3 -I -c 'import json, sys; [print(h["command"]) for g in json.load(open(sys.argv[1]))["hooks"]["Stop"] for h in g["hooks"]]' "$1"
}

@test "the watcher rule: a role whose [serve] watch names its inbox gets AGENT_SANDBOX_WATCH in its Stop hook's command; not another role, a print run, or a turn of --serve" {
  printf '[serve:planner-1]\nwatch = .asb/coord/to/planner-1.md\nprompt = .asb/serve/planner-1.md\n[connect:*]\n' >"$H/proj/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  settings_of asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  [ "$(stop_cmds "$OUT/settings.json")" = "AGENT_SANDBOX_WATCH=.asb/coord/to/planner-1.md AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line bash /run/agent-sandbox/state-hook.sh Stop off" ]
  # only the Stop hook carries it
  [ "$(grep -o AGENT_SANDBOX_WATCH "$OUT/settings.json" | wc -l)" -eq 1 ]
  # a role with no [serve] section: the hook as before
  settings_of asb --role other claude --continue
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" other off
  run ! grep -q AGENT_SANDBOX_WATCH "$OUT/settings.json"
  # a print run of the role: its turn is the run
  settings_of asb --role planner-1 claude -p 'Reply ok.'
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  run ! grep -q AGENT_SANDBOX_WATCH "$OUT/settings.json"
  # a turn of --serve: the loop is what watches
  settings_of AGENT_SANDBOX_SERVE_TURN=1 asb --role planner-1 claude --resume 01234567-89ab-cdef-0123-456789abcdef 'Read your inbox.'
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  run ! grep -q AGENT_SANDBOX_WATCH "$OUT/settings.json"
  # a path with a space and a quote reaches the hook as one shell word, in a JSON string
  printf '[serve:planner-1]\nwatch = .asb/in "box.md\n[connect:*]\n' >"$H/proj/.agent-sandbox"
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  settings_of asb --role planner-1 claude --continue
  [ "$status" -eq 0 ]
  local c
  c="$(stop_cmds "$OUT/settings.json")"
  [ "$(bash -c "${c%% bash *} bash -c 'printf %s \"\$AGENT_SANDBOX_WATCH\"'")" = '.asb/in "box.md' ]
}

@test "the summary rule (#314): every session's Stop hook carries AGENT_SANDBOX_SUMMARY, the line's path inside, and its status line too (T39); not a print run, nor with the briefing off" {
  local want="AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line bash /run/agent-sandbox/state-hook.sh Stop off"
  settings_of asb claude --continue
  [ "$status" -eq 0 ]
  [ "$(stop_cmds "$OUT/settings.json")" = "$want" ]
  # the Stop hook and the status line carry it, and nothing else
  [ "$(grep -o AGENT_SANDBOX_SUMMARY "$OUT/settings.json" | wc -l)" -eq 2 ]
  [ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$OUT/settings.json")" = "AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line bash /run/agent-sandbox/statusline.sh default" ]
  settings_of asb --role planner-1 claude
  [ "$(stop_cmds "$OUT/settings.json")" = "$want" ]
  # a print run: its turn is the run, its output the user's
  settings_of asb --role planner-1 claude -p 'Reply ok.'
  [ "$status" -eq 0 ]
  check_state_settings "$OUT/settings.json" planner-1 off
  run ! grep -q AGENT_SANDBOX_SUMMARY "$OUT/settings.json"
  settings_of asb claude --print --continue 'Reply ok.'
  run ! grep -q AGENT_SANDBOX_SUMMARY "$OUT/settings.json"
  # the briefing off: no summary directory is bound, and no rule
  settings_of AGENT_SANDBOX_BRIEFING=off asb claude --continue
  [ "$status" -eq 0 ]
  run ! grep -q /run/agent-sandbox/summary "$H/argv"
}

@test "the summary rule: --check says it with the briefing on, and not with it off" {
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check 2>&1 </dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  summary: a turn does not end while the session's summary line is missing or empty (the Stop hook refuses once)"$'\n'* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_BRIEFING=off "${@:4}" --check 2>&1 </dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"summary:"* ]]
}

@test "the watcher rule: --check says it for a role with a [serve] watch, and not for one without" {
  printf '[serve:planner-1]\nwatch = .asb/coord/to/planner-1.md\nprompt = .asb/serve/planner-1.md\n[connect:*]\n' >"$H/proj/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role planner-1 2>&1 </dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  watcher: a turn does not end while .asb/coord/to/planner-1.md has no watcher running (the Stop hook refuses once)"$'\n'* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role other 2>&1 </dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"watcher:"* ]]
}

# ----- a role's auto-compact (#438) ---------------------------------------------------

# compact_keys FILE -- the settings file's compaction keys as KEY=VALUE, space-separated
# (autoCompactEnabled first), or `none`.
compact_keys() {
  python3 -I -c 'import json, sys
m = json.load(open(sys.argv[1]))
print(" ".join(f"{k}={json.dumps(m[k])}" for k in ("autoCompactEnabled", "idleCompaction") if k in m) or "none")' "$1"
}

# approve_lines LINE... -- the project's .agent-sandbox is LINEs, approved with --trust.
approve_lines() {
  printf '%s\n' "$@" >"$H/proj/.agent-sandbox"
  engine_cmd
  (cd "$H/proj" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
}

@test "[agent] auto-compact (#438): a role's settings file has autoCompactEnabled false with no line, said at the start; a plain session none, nothing said" {
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = "autoCompactEnabled=false" ]
  [[ "$output" == *"auto-compact: off (the default for a role)"* ]]
  check_state_settings "$OUT/settings.json" planner-1 off # the rest as before
  # a role named by AGENT_SANDBOX_ROLE, and by [sandbox] role: a role all the same
  settings_of AGENT_SANDBOX_ROLE=r2 asb claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = "autoCompactEnabled=false" ]
  # no role: the default role, a plain session -- no key, Claude Code's own default
  settings_of asb claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = none ]
  [[ "$output" != *"auto-compact"* ]]
  # --role default is the plain session too
  settings_of asb --role default claude --version
  [ "$(compact_keys "$OUT/settings.json")" = none ]
  approve_lines '[sandbox]' 'role = r3' '[connect:*]'
  settings_of asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"role: r3 (.agent-sandbox [sandbox] role)"* ]]
  [ "$(compact_keys "$OUT/settings.json")" = "autoCompactEnabled=false" ]
}

@test "[agent] auto-compact: idle-off writes only idleCompaction false, on neither key, - neither for a role, whatever a weaker line says; a plain session takes a line naming it" {
  approve_lines '[connect:*]' '[agent]' 'auto-compact = idle-off' '[agent:gate]' 'auto-compact = on' '[agent:free]' 'auto-compact = -'
  settings_of asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = "idleCompaction=false" ]
  [[ "$output" == *"auto-compact: idle-off (.agent-sandbox [agent])"* ]]
  settings_of asb --role gate claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = none ]
  [[ "$output" == *"auto-compact: on (.agent-sandbox [agent:gate])"* ]]
  settings_of asb --role free claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = none ]
  [[ "$output" != *"auto-compact"* ]]
  # [agent] names every launch, the plain session's too
  settings_of asb claude --version
  [ "$status" -eq 0 ]
  [ "$(compact_keys "$OUT/settings.json")" = "idleCompaction=false" ]
}

@test "[agent] auto-compact: a user's own --settings that sets either key keeps its own, either value, and gets neither of ours" {
  local u want
  for u in autoCompactEnabled=true autoCompactEnabled=false idleCompaction=true idleCompaction=false; do
    settings_of asb --role planner-1 claude --settings "{\"${u%=*}\": ${u#*=}, \"model\": \"opus\"}" --version
    [ "$status" -eq 0 ]
    [ "$(compact_keys "$OUT/settings.json")" = "$u" ]
    grep -q '"model": "opus"' "$OUT/settings.json"
    [[ "$output" == *"briefing: your --settings sets autoCompactEnabled or idleCompaction, so it decides how the session compacts; the role's auto-compact off is not added"* ]]
  done
  # theirs without either: ours added to theirs, nothing said
  settings_of asb --role planner-1 claude --settings '{"model":"opus"}' --version
  [ "$(compact_keys "$OUT/settings.json")" = "autoCompactEnabled=false" ]
  [[ "$output" != *"decides how the session compacts"* ]]
  # a plain session (ours has no key) with theirs setting one: nothing to say
  settings_of asb claude --settings '{"idleCompaction": true}' --version
  [ "$(compact_keys "$OUT/settings.json")" = "idleCompaction=true" ]
  [[ "$output" != *"decides how the session compacts"* ]]
  # an idle-off role, theirs saying autoCompactEnabled: theirs alone
  approve_lines '[connect:*]' '[agent:planner-*]' 'auto-compact = idle-off'
  settings_of asb --role planner-1 claude --settings '{"autoCompactEnabled": true}' --version
  [ "$(compact_keys "$OUT/settings.json")" = "autoCompactEnabled=true" ]
  settings_of asb --role planner-1 claude --settings '{"model":"opus"}' --version
  [ "$(compact_keys "$OUT/settings.json")" = "idleCompaction=false" ]
}

# ac_join_copy_stub -- a join stub that also copies this join's settings file out (to
# $JOIN_COPY), before the engine removes it with the join.
ac_join_copy_stub() {
  cat >"$H/bin/join-copy.py" <<'STUB'
import glob, os, shutil, sys
with open(os.environ["JOIN_DUMP"], "w") as fh:
    for a in sys.argv[1:]:
        fh.write(a + "\n")
for f in glob.glob(os.path.join(os.environ["AGENT_SANDBOX_SESSION_BASE"], "*", "briefing", "join.*", "settings.json")):
    shutil.copy(f, os.environ["JOIN_COPY"])
STUB
}

@test "[agent] auto-compact: a later join writes the key into its own settings file, from its own resolution; a plain session's join none" {
  approve_lines '[connect:*]' '[agent:idle]' 'auto-compact = idle-off'
  ac_join_copy_stub
  local r want
  for r in planner-1:autoCompactEnabled=false idle:idleCompaction=false default:none; do
    want="${r#*:}" r="${r%%:*}"
    engine_bg -- asb --role "$r" claude
    rm -f "$H/settings.json"
    run_engine AGENT_SANDBOX_JOIN="$H/bin/join-copy.py" JOIN_COPY="$H/settings.json" -- asb --role "$r" claude -p hi
    [ "$status" -eq 0 ]
    [[ "$output" == *"joining role '$r'"* ]]
    [[ "${JOINB[0]}" == --settings && "${JOINB[1]}" == /run/agent-sandbox/join.*/settings.json ]]
    [ "$(compact_keys "$H/settings.json")" = "$want" ]
    release_bg
  done
}

@test "[agent] auto-compact with no briefing settings: not applied, said once, and why -- the briefing off, a merge refused; never DISABLE_AUTO_COMPACT" {
  settings_of AGENT_SANDBOX_BRIEFING=off asb --role quiet claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/settings.json" ]
  [[ "$output" == *"role 'quiet': its auto-compact value off (the default for a role) is not applied: profile 'claude' gives it in the briefing's settings (profile_briefing_args), and the briefing is off"* ]]
  [ "$(grep -c 'is not applied' <<<"$output")" -eq 1 ]
  run ! grep -q DISABLE_AUTO_COMPACT "$H/argv"
  # a plain session with the briefing off: nothing to say
  settings_of AGENT_SANDBOX_BRIEFING=off asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"auto-compact"* ]]
  # a --settings of theirs the merge refuses: theirs kept, the key with the hooks lost, said
  settings_of asb --role planner-1 claude --settings '{"hooks": []}' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"the briefing's hooks were not installed (and the role's auto-compact off is not applied) (and /auto-mode-setup is not turned off)"* ]]
  # a plain session's refused merge: neither is said
  settings_of asb claude --settings '{"hooks": []}' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"the briefing's hooks were not installed."* ]]
}

@test "[agent] auto-compact, no briefing to give it: a join of a role whose keeper has none, and a profile with the hook but no profile_briefing_args, say it is not applied, once" {
  engine_bg AGENT_SANDBOX_BRIEFING=off -- asb --role planner-1 claude
  run_engine -- asb --role planner-1 claude -p hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"joining role 'planner-1'"* ]]
  [[ "$output" == *"role 'planner-1': its auto-compact value off (the default for a role) is not applied: profile 'claude' gives it in the briefing's settings (profile_briefing_args), and the running role has no briefing to join"* ]]
  [ "$(grep -c 'is not applied' <<<"$output")" -eq 1 ]
  release_bg
  # a profile that takes the value but has no briefing hook
  mkdir -p "$H/profiles-nb"
  cp -r "$REPO_ROOT/profiles/claude" "$H/profiles-nb/claude"
  printf 'unset -f profile_briefing_args\n' >>"$H/profiles-nb/claude/profile.sh"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles-nb" -- asb --role planner-1 claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'planner-1': its auto-compact value off (the default for a role) is not applied: profile 'claude' gives it in the briefing's settings (profile_briefing_args), and it has no briefing hook"* ]]
  [ "$(grep -c 'is not applied' <<<"$output")" -eq 1 ]
}
