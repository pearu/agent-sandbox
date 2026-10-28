#!/usr/bin/env bats
# --serve and [serve] (#277): a role with no terminal. The section (parse, review,
# --check, --apply), the flag's refusals, the profile's turn arguments, a -p join's
# briefing, and the loop's host-side helpers. The loop itself runs under the real bwrap
# in tests/integration/serve.bats.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  # shellcheck disable=SC2086 # pids, one word each
  [[ -n "${KILL:-}" ]] && kill $KILL 2>/dev/null
  return 0
}

# trust -- record approval of the project's dot-file the way --trust would.
trust() {
  local t="$CFG/trust"
  mkdir -p "$t"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 >"$t/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

# check_role ROLE -- `--check --role ROLE` from the project, stdin closed.
check_role() {
  engine_cmd
  run bash -c 'r="$1" proj="$2" home="$3" path="$4"; shift 4; cd "$proj" && env -i HOME="$home" PATH="$path" "$@" --check --role "$r" 2>&1 </dev/null' \
    _ "$1" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}

# run_apply ANSWERS ARGS... -- `--apply ARGS...` from the project, ANSWERS typed.
run_apply() {
  local answers="$1"
  shift
  engine_cmd
  run bash -c '
    cd "$2" || exit 99
    h="$1" a="$3" n="$4"
    shift 4
    e=("${@:1:n}")
    shift "$n"
    exec < <(printf "%b" "$a")
    env -i HOME="$h/home" PATH="$h/bin:/usr/bin:/bin" USER=tester \
      AGENT_SANDBOX_SESSION_BASE="$h/base" "${e[@]}" --profile claude --apply "$@"
  ' _ "$H" "$PROJ" "$answers" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

@test "[serve]: the review says what the loop waits on and reads, per section; a missing key or a path out of the project is said" {
  printf '%s\n' '[serve:impl-*]' 'watch = .asb/coord/to/{role}.md' 'prompt = .asb/serve/p.md' \
    '[serve:half]' 'prompt = p.md' '[serve:out]' 'watch = ../x' 'prompt = /etc/passwd' 'colour = red' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[serve:impl-*], for the roles impl-*: \`asb --role ROLE --serve CMD\` holds the role's launch on the host and, at each change to .asb/coord/to/{role}.md, runs one turn of the role's session in its sandbox, told the text of .asb/serve/p.md; the role's session id goes to .asb/coord/ROLE/session. It widens nothing"*"approve this"* ]]
  [[ "$output" == *"[serve:half] has no 'watch = PATH'; --serve refuses for the roles half until it has both watch and prompt"* ]]
  [[ "$output" == *"[serve:out] watch '../x' is not a path in the project (relative to it, no '..'); --serve refuses for the roles out"* ]]
  [[ "$output" == *"[serve:out] prompt '/etc/passwd' is not a path in the project"* ]]
  [[ "$output" == *"ignoring unknown [serve] key 'colour'"* ]]
}

@test "[serve]: --check names the role's loop, the prompt file's absence, and a section --serve refuses; the suffix makes a role" {
  printf '%s\n' '[serve:impl-*]' 'watch = inbox.md' 'prompt = p.md' '[serve:half]' 'prompt = p.md' >"$PROJ/.agent-sandbox"
  check_role impl-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--serve: a turn of its session per change to inbox.md, told the text of p.md -- MISSING: --serve refuses"* ]]
  [[ "$output" == *"roles in this file: half, impl-*"* ]]
  : >"$PROJ/p.md"
  check_role impl-1
  [[ "$output" == *"--serve: a turn of its session per change to inbox.md, told the text of p.md"$'\n'* ]]
  check_role half
  [[ "$output" == *"--serve: refused -- [serve] needs watch and prompt, paths in the project (watch = none, prompt = p.md)"* ]]
}

# settings_of [VAR=value ...] CMD ARGS... -- run_engine, then the launch's briefing
# directory copied out by the stub bwrap to $OUT (the engine removes it with the session).
settings_of() {
  OUT="$H/copied/briefing"
  grep -q BWRAP_COPY "$H/bin/bwrap" || sed -i 's|^\. "\${0%/\*}/keeper-tail"$|if [ -n "${BWRAP_COPY:-}" ]; then mkdir -p "$BWRAP_COPY"; cp -r "$AGENT_SANDBOX_SESSION_BASE"/session.*/. "$BWRAP_COPY"/.. 2>/dev/null \|\| true; fi\n&|' "$H/bin/bwrap"
  grep -q BWRAP_COPY "$H/bin/bwrap"
  rm -rf "$H/copied"
  run_engine BWRAP_COPY="$OUT" -- "$@"
}

@test "[serve:ROLE] with watch alone: the review and --check say watch only, the Stop hook guards the inbox, and --serve refuses the role" {
  printf '%s\n' '[serve:gate]' 'watch = .asb/coord/to/gate.md' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[serve:gate], for the roles gate: watch only -- the watcher on .asb/coord/to/gate.md is enforced, the role is not served (no prompt: --serve refuses). It widens nothing"*"approve this"* ]]
  [[ "$output" != *"[serve:gate] has no"* ]]
  check_role gate
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  --serve: watch only -- the watcher on .asb/coord/to/gate.md is enforced, the role is not served"$'\n'* ]]
  [[ "$output" == *$'\n'"  watcher: a turn does not end while .asb/coord/to/gate.md has no watcher running (the Stop hook refuses once)"$'\n'* ]]
  [[ "$output" != *"--serve: refused"* ]]
  trust
  settings_of asb --role gate claude --continue
  [ "$status" -eq 0 ]
  python3 -I -c 'import json, sys; [print(h["command"]) for g in json.load(open(sys.argv[1]))["hooks"]["Stop"] for h in g["hooks"]]' "$OUT/settings.json" >"$H/stop"
  [ "$(cat "$H/stop")" = "AGENT_SANDBOX_WATCH=.asb/coord/to/gate.md AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line bash /run/agent-sandbox/state-hook.sh Stop off" ]
  run_engine -- asb --role gate --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--serve: role 'gate': its [serve] names no prompt -- watch only: this role is not served"* ]]
  [[ "$output" != *"--apply"* ]]
  [ ! -s "$H/argv" ]
}

@test "[serve]: --apply adds a [serve:ROLE] section, and the review names it" {
  printf '[connect:planner-1]\n' >"$PROJ/.agent-sandbox"
  run_apply 'y\n' '[serve:planner-1]' 'watch = inbox.md' 'prompt = p.md'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[serve:planner-1], for the roles planner-1: \`asb --role ROLE --serve CMD\`"* ]]
  [[ "$output" == *"approved."* ]]
  [ "$(sed -n '/^\[serve:planner-1\]/,$p' "$PROJ/.agent-sandbox")" = "$(printf '%s\n' '[serve:planner-1]' 'watch = inbox.md' 'prompt = p.md')" ]
}

@test "--serve refuses without --role, naming the form, and starts nothing" {
  run_engine -- asb --serve claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--serve needs the role it serves: asb --role NAME --serve CMD"* ]]
  [ ! -s "$H/argv" ]
}

@test "--serve refuses a role with no [serve] section, naming the --apply line; and one missing a key" {
  run_engine -- asb --role planner-1 --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--serve: role 'planner-1' has no [serve] section with both 'watch = PATH'"*"asb --apply '[serve:planner-1]' 'watch = PATH' 'prompt = PATH'"* ]]
  [ ! -s "$H/argv" ]
  printf '[serve:planner-*]\nprompt = p.md\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- asb --role planner-1 --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no [serve] section with both"* ]]
  [ ! -s "$H/argv" ]
  printf '[serve:planner-*]\nwatch = inbox.md\nprompt = ../p.md\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- asb --role planner-1 --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"[serve] watch and prompt are paths in the project, relative to it, with no '..'"* ]]
}

@test "--serve refuses under --preset native, and with --exec, a verb or a review" {
  printf '[serve:planner-*]\nwatch = inbox.md\nprompt = p.md\n' >"$PROJ/.agent-sandbox"
  : >"$PROJ/p.md"
  trust
  run_engine -- asb --role planner-1 --preset native --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--serve is refused under --preset native"* ]]
  [ ! -s "$H/argv" ]
  for f in --status --shutdown --delete --check; do
    run_engine -- asb --role planner-1 --serve "$f" claude
    [ "$status" -eq 2 ]
    [[ "$output" == *"--serve runs a role's session with no terminal; it is not combined with --exec, a verb or a review"* ]]
  done
  run_engine -- asb --role planner-1 --serve --profile claude --exec true
  [ "$status" -eq 2 ]
  run_engine -- asb --role planner-1 --serve claude agents
  [ "$status" -eq 2 ]
  [[ "$output" == *"'agents' is a verb, not a session"* ]]
}

@test "--serve refuses a profile that says nothing of how to run one turn" {
  local pd="$H/profiles"
  mkdir -p "$pd"
  cp -r "$REPO_ROOT/profiles/claude" "$pd/claude"
  sed -i '/^serve-\(new\|resume\) =/d' "$pd/claude/agent-sandbox"
  printf '[serve:planner-*]\nwatch = inbox.md\nprompt = p.md\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine AGENT_SANDBOX_PROFILE_DIR="$pd" -- asb --role planner-1 --serve claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--serve: profile 'claude' says nothing of how to run one turn of a session ([agent] serve-new and serve-resume)"* ]]
}

@test "the claude profile's turn: -p, the session by id -- --session-id first, --resume after -- and bypassPermissions" {
  source_engine
  # shellcheck disable=SC2034 # the profile contract, read by _as_profile_dotfile
  local profile=claude profile_base="" profile_base_env="" profile_base_from="" profile_command=claude
  # shellcheck disable=SC2034
  local profile_home="$REPO_ROOT/profiles/claude"
  # shellcheck disable=SC2034
  local -a profile_verbs=() profile_verbs_observe=() profile_daemon_argv=() profile_status_argv=()
  # shellcheck disable=SC2034
  local -a profile_serve_new=() profile_serve_resume=() profile_channels=() profile_channel_templates=()
  # shellcheck disable=SC2034
  local -a profile_hide=() profile_visible=() profile_env_pass=() profile_env_set=() profile_env_refuse=() _profile_allow_hosts=()
  # shellcheck disable=SC2034
  local -a profile_channel_sources=() profile_channel_filters=() profile_channel_vendor=()
  # shellcheck disable=SC2034
  local -a profile_channel_start=() profile_channel_presets=() profile_channel_reach=() profile_channel_env=()
  # shellcheck disable=SC2034
  local -a profile_channel_create=() profile_channel_login=()
  profile_slug() { printf 'slug'; }
  _as_profile_dotfile "$REPO_ROOT/profiles/claude/agent-sandbox"
  [ "${profile_serve_new[*]}" = "-p --session-id {id} --permission-mode bypassPermissions" ]
  [ "${profile_serve_resume[*]}" = "-p --resume {id} --permission-mode bypassPermissions" ]
}

# a join stub that also copies this join's briefing settings out, before the engine
# removes them with the join
join_copy_stub() {
  cat >"$H/bin/join-copy.py" <<'STUB'
import glob, os, shutil, sys
with open(os.environ["JOIN_DUMP"], "w") as fh:
    for a in sys.argv[1:]:
        fh.write(a + "\n")
for f in glob.glob(os.path.join(os.environ["AGENT_SANDBOX_SESSION_BASE"], "*", "briefing", "join.*", "settings.json")):
    shutil.copy(f, os.environ["JOIN_COPY"])
STUB
}

@test "a -p turn joined into a running role carries the briefing's --settings, with the role's [permissions]" {
  printf '%s\n' '[permissions]' 'Bash(tail:*)' '[permissions:planner-*]' 'Read' '[serve:planner-*]' 'watch = inbox.md' 'prompt = p.md' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- asb --role planner-1 claude
  join_copy_stub
  run_engine AGENT_SANDBOX_JOIN="$H/bin/join-copy.py" JOIN_COPY="$H/settings.json" -- \
    asb --role planner-1 claude -p --resume 01234567-89ab-cdef-0123-456789abcdef --permission-mode bypassPermissions 'Read your inbox.'
  [ "$status" -eq 0 ]
  [[ "$output" == *"joining role 'planner-1'"* ]]
  [[ "${JOINB[0]}" == --settings && "${JOINB[1]}" == /run/agent-sandbox/join.*/settings.json ]]
  [ "${JOINV[*]:1}" = "-p --resume 01234567-89ab-cdef-0123-456789abcdef --permission-mode bypassPermissions Read your inbox." ]
  python3 - "$H/settings.json" <<'CHECK'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["permissions"]["allow"] == ["Bash(tail:*)", "Read"], m
assert "SessionStart" in m["hooks"], m
CHECK
  release_bg
}

@test "the loop reads the prompt through one open file in the project: a link out of it, control characters, an empty file and a missing one are refused" {
  source_engine
  mkdir -p "$PROJ/.asb/serve"
  printf 'secret\n' >"$H/secret"
  ln -s "$H/secret" "$PROJ/.asb/serve/out.md"
  run _as_serve_text "$PROJ" "$PROJ/.asb/serve/out.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is $H/secret, not a file in the project; not reading it"* ]]
  [[ "$output" != *secret$'\n'* ]]
  printf 'a\033[2Kb\n' >"$PROJ/.asb/serve/esc.md"
  run _as_serve_text "$PROJ" "$PROJ/.asb/serve/esc.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has control characters"* ]]
  printf '  \n' >"$PROJ/.asb/serve/empty.md"
  run _as_serve_text "$PROJ" "$PROJ/.asb/serve/empty.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is empty"* ]]
  run _as_serve_text "$PROJ" "$PROJ/.asb/serve/none.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not there"* ]]
  printf 'Read your inbox.\n' >"$PROJ/.asb/serve/ok.md"
  ln -s ok.md "$PROJ/.asb/serve/in.md" # a link inside the project is fine
  run _as_serve_text "$PROJ" "$PROJ/.asb/serve/in.md"
  [ "$status" -eq 0 ]
  [ "$output" = "Read your inbox." ]
}

@test "the loop writes in the role's directory by a rename: a link planted there is replaced, never written through" {
  source_engine
  mkdir -p "$PROJ/.asb/coord/r"
  printf 'keep\n' >"$H/victim"
  ln -s "$H/victim" "$PROJ/.asb/coord/r/session"
  _as_serve_put "$PROJ/.asb/coord/r" session "01234567-89ab-cdef-0123-456789abcdef"$'\n'
  [ "$(cat "$H/victim")" = keep ]
  [ ! -L "$PROJ/.asb/coord/r/session" ]
  [ "$(cat "$PROJ/.asb/coord/r/session")" = 01234567-89ab-cdef-0123-456789abcdef ]
}

@test "a turn waits on a join that is not the loop's own: the keeper's record, by descent from the loop" {
  source_engine
  local sb="$H/sb" mine other
  mkdir -p "$sb/keeper/joined"
  sleep 30 &
  mine=$!
  KILL="$mine"
  _as_proc_start "$mine"
  # shellcheck disable=SC2154 # _ps_start: _as_proc_start's
  printf '%s %s\n' "$mine" "$_ps_start" >"$sb/keeper/joined/$mine"
  run ! _as_serve_foreign "$sb" "$$" # the loop's own: its child
  (
    sleep 30 &
    echo $! >"$H/other"
  )
  other="$(cat "$H/other")"
  KILL="$mine $other"
  _as_proc_start "$other"
  printf '%s %s\n' "$other" "$_ps_start" >"$sb/keeper/joined/$other"
  run _as_serve_foreign "$sb" "$$"
  [ "$status" -eq 0 ]
  [ "$output" = "$other" ]
  kill "$mine" "$other"
  wait "$mine" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$other" 2>/dev/null || break
    sleep 0.1
  done
  run ! _as_serve_foreign "$sb" "$$" # gone: no longer counted
}

@test "a failed turn is appended to the role's messages by a rename: a link planted there is replaced, never read or written through" {
  source_engine
  local d="$PROJ/.asb/coord/r"
  mkdir -p "$d"
  printf 'ack 1\n' >"$d/messages.md"
  _as_serve_failed "$d" "turn failed (exit 1)"
  [ "$(cat "$d/messages.md")" = "$(printf 'ack 1\nturn failed (exit 1)')" ]
  rm "$d/messages.md"
  printf 'secret\n' >"$H/secret"
  ln -s "$H/secret" "$d/messages.md"
  _as_serve_failed "$d" "turn failed (exit 2)"
  [ "$(cat "$H/secret")" = secret ]
  [ ! -L "$d/messages.md" ]
  [ "$(cat "$d/messages.md")" = "turn failed (exit 2)" ]
}

@test "a reset marker beside the role's inbox is found and removed; a link is removed, never followed; a linked inboxes directory is not entered" {
  source_engine
  local to="$PROJ/.asb/coord/to"
  mkdir -p "$to"
  run ! _as_serve_reset "$PROJ" r # none: no reset
  : >"$to/r.reset"
  _as_serve_reset "$PROJ" r
  [ ! -e "$to/r.reset" ]
  run ! _as_serve_reset "$PROJ" r # once
  # a link: removed itself, its target untouched
  printf 'keep\n' >"$H/victim"
  ln -s "$H/victim" "$to/r.reset"
  _as_serve_reset "$PROJ" r
  [ ! -L "$to/r.reset" ]
  [ "$(cat "$H/victim")" = keep ]
  ln -s "$H/nowhere" "$to/r.reset" # a dangling one too
  _as_serve_reset "$PROJ" r
  [ ! -L "$to/r.reset" ]
  # the inboxes directory a link out of the project: nothing there is removed
  rm -rf "$to"
  mkdir -p "$H/elsewhere"
  : >"$H/elsewhere/r.reset"
  ln -s "$H/elsewhere" "$to"
  run _as_serve_reset "$PROJ" r
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a directory of the project; not reading a reset marker there"* ]]
  [ -e "$H/elsewhere/r.reset" ]
}
