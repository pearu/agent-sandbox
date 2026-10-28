#!/usr/bin/env bats
# The role verbs (#126): --reset takes one channel or declared path back to the source,
# --delete removes every store of the role, --status shows what --shutdown would end.
# (--shutdown itself is in routing.bats, with the rest of #123.) Each does its work and
# exits; none launches the agent -- but --summarize (#314), whose one turn is the stub
# join below.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  C="$H/home/.claude"
  SBOX="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
  mkdir -p "$C/rules" "$C/skills" "$C/commands"
  printf 'NATIVE\n' >"$C/rules/topic.md"
  printf 'NATIVE\n' >"$C/skills/s.md"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}

@test "--reset CHANNEL re-seeds that channel and leaves the others" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native;skills=copy native' -- asb claude --version
  local ins sk
  ins="$SBOX/instructions/copy/$(slugify "$C/rules")"
  sk="$SBOX/skills/copy/$(slugify "$C/skills")"
  printf 'MINE\n' >"$ins/topic.md"
  printf 'MINE\n' >"$sk/s.md"
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset 'instructions' at $C/rules: its copy taken from yours again"* ]]
  [ ! -s "$H/argv" ] # nothing launched
  [ "$(cat "$ins/topic.md")" = NATIVE ]
  [ "$(cat "$sk/s.md")" = MINE ]
}

@test "--reset discards an own store too: its source's version is the empty start" {
  run_engine AGENT_SANDBOX_CONNECT='skills=own native' -- asb claude --version
  local own
  own="$SBOX/skills/own/$(slugify "$C/skills")"
  printf 'MINE\n' >"$own/x.md"
  run_engine -- asb --reset skills claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"its own store discarded, the next launch starts it empty"* ]]
  [ ! -e "$own/x.md" ]
}

@test "a role verb needs no command when one profile is installed; with several it names the verb" {
  TEST_PRESET=isolated run_engine -- asb claude --version
  run_engine -- asb --reset config # no CMD: the only profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset 'config' at "*": its own store discarded, the next launch starts it from the profile's template"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- asb --status
  [ "$status" -eq 0 ]
  [[ "$output" != *"no command"* ]]
  mkdir -p "$H/profiles"
  cp -r "$REPO_ROOT/profiles/claude" "$H/profiles/claude"
  cp -r "$REPO_ROOT/profiles/claude" "$H/profiles/other"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles" -- asb --reset config
  [ "$status" -eq 2 ]
  [[ "$output" == *"--reset config acts on one profile's stores, and there are several"*"asb --reset config claude"* ]]
}

@test "--reset transcripts reaches this project's conversations directory too ({slug}, #176)" {
  # It used to be added to the channel by profile_prepare, which --reset never ran.
  local conv="$C/projects/${PROJ//[^A-Za-z0-9-]/-}" own
  mkdir -p "$conv"
  run_engine AGENT_SANDBOX_CONNECT='transcripts=own native' -- asb claude --version
  own="$SBOX/transcripts/own/$(slugify "$conv")"
  [ -d "$own" ]
  printf 'MINE\n' >"$own/x.jsonl"
  run_engine -- asb --reset transcripts claude
  [ "$status" -eq 0 ]
  [ ! -e "$own/x.jsonl" ]
}

@test "--reset PATH resets one declared path and leaves the others" {
  mkdir -p "$PROJ/scratch" "$PROJ/other"
  run_engine -- asb --connect './scratch/=own' --connect './other/=own' claude --version
  [ "$status" -eq 0 ]
  local s o
  s="$SBOX/@paths/own/$(slugify "$PROJ/scratch")"
  o="$SBOX/@paths/own/$(slugify "$PROJ/other")"
  printf 'MINE\n' >"$s/x"
  printf 'MINE\n' >"$o/x"
  run_engine -- asb --reset ./scratch/ claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset './scratch/'"* ]]
  [ ! -e "$s" ]
  [ "$(cat "$o/x")" = MINE ]
}

@test "--reset of a path that holds nothing says so; of a protected path it refuses" {
  run_engine -- asb --reset ./nothing-here/ claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"holds nothing at './nothing-here/'"* ]]
  # shellcheck disable=SC2088 # the engine expands `~`, as a declaration's does
  run_engine -- asb --reset '~/.ssh/' claude
  [ "$status" -ne 0 ]
}

@test "--reset of a name that is neither a channel nor a path is refused, listing the channels" {
  run_engine -- asb --reset nosuch claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'nosuch'"*"It carries:"* ]]
}

@test "--delete removes every store of the role, and the next launch starts from the source" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  printf 'MINE\n' >"$SBOX/instructions/copy/$(slugify "$C/rules")/topic.md"
  run_engine -- asb --delete claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted its stores"* ]]
  [ ! -s "$H/argv" ]
  [ ! -e "$SBOX" ]
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  [ "$(cat "$SBOX/instructions/copy/$(slugify "$C/rules")/topic.md")" = NATIVE ]
}

@test "--delete removes a role whose overlays left an unreadable work directory" {
  # overlayfs leaves <work>/work at mode 000; du cannot read it and exits 1, which under
  # set -e ended --delete silently before the chmod that makes it removable
  run_engine -- asb claude --version
  mkdir -p "$SBOX/skills/work/x/work"
  chmod 000 "$SBOX/skills/work/x/work"
  run_engine -- asb --delete claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted its stores"* ]]
  [ ! -e "$SBOX" ]
}

@test "--delete of a role with nothing stored says so" {
  run_engine -- asb --role fresh --delete claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'fresh' has nothing stored"* ]]
}

@test "--delete is refused while anything is joined, naming --shutdown, and removes nothing" {
  engine_bg -- asb claude --version
  run_engine -- asb --delete claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"is running; end it first with:"*"--shutdown"* ]]
  [ -d "$SBOX" ]
  release_bg
}

@test "--delete ends an idle keeper first, as a reset does" {
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 -- asb claude --version
  release_bg
  [ -e "$SBOX/keeper/id" ] # waiting out its grace
  run_engine -- asb --delete claude
  [ "$status" -eq 0 ]
  [ ! -e "$SBOX" ]
}

@test "--delete names only its own role" {
  run_engine -- asb --role keep claude --version
  run_engine -- asb --role gone claude --version
  run_engine -- asb --role gone --delete claude
  [ "$status" -eq 0 ]
  [ -d "${SBOX%/default}/keep" ]
  [ ! -e "${SBOX%/default}/gone" ]
}

@test "--status of a role that is not running says so, and where its stores are" {
  run_engine -- asb --status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' of $PROJ: not running, and nothing stored"* ]]
  run_engine -- asb claude --version
  run_engine -- asb --status claude
  [[ "$output" == *"not running; its stores"*"$SBOX"* ]]
  [ ! -s "$H/argv" ]
}

@test "--status of a running role shows the keeper, its dot-file, and no daemon" {
  engine_bg -- asb claude --version
  run_engine -- asb --status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' of $PROJ: running since"*"supervisor pid"* ]]
  [[ "$output" == *"dot-file: none approved when it started"* ]]
  [[ "$output" == *"no background daemon"* ]]
  [ ! -s "$H/argv" ] # it launched nothing
  release_bg
}

@test "--status of a running role whose CA bind is gone says so, with the --shutdown that fixes it" {
  make_fake_ca "$H/ca.pem"
  engine_bg AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- asb claude --version
  run_engine -- asb --status claude
  [ "$status" -eq 0 ]
  # the stub keeper runs on the host, where nothing is mounted at the bundle's path
  [[ "$output" == *"dot-file: none approved"*$'\n'"  warning — role 'default': the host replaced /etc/"*"and the sandbox lost the proxy's CA -- HTTPS fails until the role is restarted: asb --role default --shutdown claude"$'\n'* ]]
  release_bg
  engine_bg -- asb claude --version # no proxy CA, so no bind to lose
  run_engine -- asb --status claude
  [[ "$output" != *"proxy's CA"* ]]
  release_bg
}

# ----- --list, --list-all (#314) -----------------------------------------------------

# store_dir PROJECT ROLE -- where the engine keeps that role's stores; made.
store_dir() {
  local d="$H/home/.local/state/agent-sandbox/claude/${1//[^A-Za-z0-9-]/-}/$2"
  mkdir -p "$d/transcripts/own"
  printf '%s' "$d"
}

# conv STORE NAME MTIME RECORD... -- a conversation file of the store, last written at MTIME.
conv() {
  local d="$1/transcripts/own/home_tester_.claude_projects_x" f
  mkdir -p "$d/memory"
  f="$d/$2.jsonl"
  printf '%s\n' "${@:4}" >"$f"
  touch -d "$3" "$f"
}

user_rec() { printf '{"type":"user","message":{"role":"user","content":"%s"},"timestamp":"%s"}' "$1" "$2"; }

# The fixture: four roles of $PROJ, one of another project, all with known times.
list_fixture() {
  local sb
  sb="$(store_dir "$PROJ" rev)"
  printf '%s\n' "$PROJ" >"$sb/project"
  conv "$sb" old "2026-10-21 09:00 UTC" '{"type":"mode"}' "$(user_rec 'earlier' 2026-10-20T08:00:00.000Z)" \
    '{"type":"ai-title","aiTitle":"The old session"}'
  conv "$sb" new "2026-10-26 15:13 UTC" '{"type":"permission-mode"}' "$(user_rec 'look at CI' 2026-10-23T18:15:00.000Z)" \
    '{"type":"ai-title","aiTitle":"An AI title"}' '{"type":"custom-title","customTitle":"CUDA version pinned in CI"}' \
    '{"type":"ai-title","aiTitle":"A later AI title"}'
  sb="$(store_dir "$PROJ" tri)"
  conv "$sb" s "2026-10-26 12:01 UTC" "$(user_rec 'triage it' 2026-10-26T11:50:00.000Z)" \
    '{"type":"ai-title","aiTitle":"Issue triage: skip build"}'
  sb="$(store_dir "$PROJ" fresh)"
  conv "$sb" s "2026-10-25 10:00 UTC" \
    '{"type":"user","isMeta":true,"message":{"role":"user","content":"<meta caveat>"},"timestamp":"2026-10-25T09:00:00Z"}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the\nbuild   please"},{"type":"image"}]}}'
  sb="$(store_dir "$PROJ" setup)"
  conv "$sb" s "2026-10-24 10:00 UTC" '{"type":"mode","timestamp":"2026-10-14T16:20:00Z"}'
  sb="$(store_dir "$PROJ" own)"
  mkdir -p "$sb/summary"
  printf 'My own line\nnot this\n' >"$sb/summary/line"
  conv "$sb" s "2026-10-22 10:00 UTC" "$(user_rec 'hello' 2026-10-22T09:00:00Z)" '{"type":"ai-title","aiTitle":"Not shown"}'
  sb="$(store_dir /elsewhere/other gh-x)"
  printf '/elsewhere/other\n' >"$sb/project"
  conv "$sb" s "2026-10-27 08:00 UTC" "$(user_rec 'other project' 2026-10-27T07:00:00Z)"
}

@test "--list shows this project's roles, newest first: state, created, active, and the summary chain" {
  list_fixture
  run_engine TZ=UTC -- asb --role ignored --list
  [ "$status" -eq 0 ]
  local want
  want="$PROJ
  rev     stopped   created 2026-10-20 08:00   active 2026-10-26 15:13
    CUDA version pinned in CI
  tri     stopped   created 2026-10-26 11:50   active 2026-10-26 12:01
    Issue triage: skip build
  fresh   stopped   created 2026-10-25 09:00   active 2026-10-25 10:00
    Fix the build please
  setup   stopped   created 2026-10-14 16:20   active 2026-10-24 10:00
    no conversation
  own     stopped   created 2026-10-22 09:00   active 2026-10-22 10:00
    My own line
To resume: asb --role ROLE claude --continue"
  [ "$output" = "$want" ]
  [ ! -s "$H/argv" ] # nothing launched
}

@test "--list-all works outside any project: projects ordered by their newest role" {
  list_fixture
  mkdir -p "$H/nowhere"
  RUN_CWD="$H/nowhere" run_engine TZ=UTC -- asb --list-all
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = /elsewhere/other ]
  [ "${lines[1]}" = "  gh-x   stopped   created 2026-10-27 07:00   active 2026-10-27 08:00" ]
  [ "${lines[2]}" = "    other project" ]
  [ "${lines[3]}" = "$PROJ" ]
  [[ "$output" == *"CUDA version pinned in CI"* ]]
  # one resume line, at the very end, for every project
  [ "${lines[-1]}" = "To resume: cd PROJECT_DIR && asb --role ROLE claude --continue" ]
  [ "$(grep -c 'resume' <<<"$output")" -eq 1 ]
  RUN_CWD="$H/nowhere" run_engine -- asb --list
  [ "$output" = "asb --list: no role of this project has stores" ]
}

@test "--list-all names a project by its project file, else its history, else its slug" {
  local sb
  sb="$(store_dir /p/one r1)"
  printf '/p/one\n' >"$sb/project"
  printf '{"display":"x","project":"/p/WRONG"}\n' >"$sb/transcripts/own/home_tester_.claude_history.jsonl"
  sb="$(store_dir /p/two r2)"
  printf '{"display":"x"}\n{"display":"y","project":"/p/two"}\n' >"$sb/transcripts/own/home_tester_.claude_history.jsonl"
  store_dir /p/three r3 >/dev/null
  run_engine -- asb --list-all
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"/p/one"$'\n'* || "$output" == "/p/one"$'\n'* ]]
  [[ "$output" != *WRONG* ]]
  [[ "$output" == *$'\n'"/p/two"$'\n'* || "$output" == "/p/two"$'\n'* ]]
  [[ "$output" == *"-p-three  (the path is not recorded; this is the store's slug)"$'\n'"  r3 "* ]]
  [ "${lines[-1]}" = "To resume: cd PROJECT_DIR && asb --role ROLE claude --continue" ]
}

@test "--list WORD keeps the roles whose name, summary or conversations mention it" {
  list_fixture
  run_engine TZ=UTC -- asb --list cuda # the summary, any case
  [ "$status" -eq 0 ]
  [[ "$output" == *"  rev "* ]]
  [[ "$output" != *"  tri "* && "$output" != *"  own "* ]]
  run_engine -- asb --list SETU # the role name
  [[ "$output" == *"  setup "* && "$output" != *"  rev "* ]]
  run_engine -- asb --list 'The old session' # a conversation that is not the newest
  [[ "$output" == *"  rev "* && "$output" != *"  fresh "* ]]
  run_engine -- asb --list 'not shown' # the store's line wins, the transcript still matches
  [[ "$output" == *"  own "*"My own line"* ]]
  run_engine -- asb --list zzqx
  [ "$status" -eq 0 ]
  [ "$output" = "asb --list: no role of this project mentions 'zzqx'" ]
  run_engine -- asb --list-all 'other project'
  [[ "$output" == "/elsewhere/other"$'\n'* && "$output" != *"$PROJ"* ]]
  run_engine -- asb --list-all zzqx
  [ "$output" = "asb --list-all: no role of any project mentions 'zzqx'" ]
}

@test "--list takes a command word and ignores it, as the other verbs do; a second other word is refused" {
  list_fixture
  run_engine TZ=UTC -- asb --list
  local all="$output"
  [[ "$all" == *"  rev "*"  tri "* ]]
  run_engine TZ=UTC -- asb --list claude # the profile, not a search word
  [ "$status" -eq 0 ]
  [ "$output" = "$all" ]
  run_engine TZ=UTC -- asb --list-all /usr/local/bin/claude # a path whose basename names it
  [ "$status" -eq 0 ]
  [[ "$output" == *"  rev "*"  tri "* ]]
  run_engine -- asb --list cuda claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"  rev "* && "$output" != *"  tri "* ]]
  run_engine -- asb --list cuda foo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--list takes one search word at most, then the command, which it ignores: asb --list [WORD] [CMD]"* ]]
  run_engine -- asb --list-all claude cuda
  [ "$status" -eq 2 ]
  [[ "$output" == *"--list-all takes one search word at most"* ]]
}

@test "--list through a symlink to the project finds the stores a launch through it made" {
  ln -s "$PROJ" "$H/link"
  RUN_CWD="$H/link" run_engine PWD="$H/link" -- asb --role via-link claude --version
  [ -d "${SBOX%/default}/via-link" ]                       # the launch keys the store by the resolved path
  RUN_CWD="$H/link" run_engine PWD="$H/link" -- asb --list # a shell exports the logical path
  [ "$status" -eq 0 ]
  [[ "$output" == "$PROJ"$'\n'"  via-link "* ]]
}

@test "--list colours role names cyan and the project's line bold at a terminal, nothing else; plain through a pipe and with NO_COLOR (#314)" {
  list_fixture
  # through a pipe (run captures it): plain
  run_engine TZ=UTC -- asb --list
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e'* ]]
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the colour on"
  engine_cmd
  local C=$'\e[36m' R=$'\e[0m' B=$'\e[1m'
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" TZ=UTC script -qec "$(printf "%q " "${@:4}") --list" /dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  output="${output//$'\r'/}"
  [ "${lines[0]//$'\r'/}" = "${B}$PROJ${R}" ]
  [[ "$output" == *$'\n'"  ${C}rev${R}     stopped   created 2026-10-20 08:00   active 2026-10-26 15:13"$'\n'* ]]
  [[ "$output" == *$'\n'"  ${C}setup${R}   stopped   "* ]]
  # nothing but the role names and the project's line
  local plain="${output//$C/}"
  plain="${plain//$B/}"
  plain="${plain//$R/}"
  [[ "$plain" != *$'\e'* ]]
  [ "$(grep -o $'\e\\[36m' <<<"$output" | wc -l)" -eq 5 ]
  [[ "$output" == *$'\n'"To resume: "*" --role ROLE claude --continue" ]] # as the engine was invoked
  # NO_COLOR at the terminal: plain
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" NO_COLOR=1 script -qec "$(printf "%q " "${@:4}") --list" /dev/null' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  rev "* && "$output" != *$'\e'* ]]
}

@test "--list prints the session's own line as text: no control characters, and never through a link or a FIFO (#314)" {
  local sb
  sb="$(store_dir "$PROJ" esc)"
  conv "$sb" s "2026-10-22 10:00 UTC" "$(user_rec 'hello' 2026-10-22T09:00:00Z)" '{"type":"ai-title","aiTitle":"The title"}'
  mkdir -p "$sb/summary"
  printf 'Fixing \e]0;owned\a the \e[31mpin\xc2\x9b\n' >"$sb/summary/line" # ESC, BEL, a C1 CSI
  run_engine -- asb --list
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "  esc   stopped   "* ]]
  [ "${lines[2]}" = "    Fixing ]0;owned the [31mpin" ]
  printf 'secret first line\n' >"$H/secret"
  ln -sf "$H/secret" "$sb/summary/line.tmp" && mv -f "$sb/summary/line.tmp" "$sb/summary/line"
  run_engine -- asb --list
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "    The title" ]
  rm -f "$sb/summary/line"
  mkfifo "$sb/summary/line"
  # shellcheck disable=SC2016 # the inner shell's own arguments
  run timeout 20 bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --list' _ "$H/proj" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "    The title" ]
}

@test "--list-all with no stores at all says so in one line" {
  run_engine -- asb --list-all
  [ "$status" -eq 0 ]
  [[ "$output" == "asb --list-all: no role has stores (nothing under "*")" ]]
}

@test "a launch writes the project's path into its store, and --list shows a running role" {
  run_engine -- asb claude --version
  [ "$(cat "$SBOX/project")" = "$PROJ" ]
  [ -d "$SBOX/summary" ] # the session's own line's directory (#314)
  engine_bg -- asb claude --version
  run_engine -- asb --list
  [ "$status" -eq 0 ]
  [[ "$output" == "$PROJ"$'\n'"  default   running (1 joined)   created "* ]]
  release_bg
}

# ----- --summarize (#314) --------------------------------------------------------------

# summ_setup -- a stopped default role with one conversation, and a stub join that plays
# the summarizing turn: it records its argv, then writes what a turn of the session its
# --session-id names would -- the transcript, a directory of the same name, a prompt
# history record -- into the role's transcripts stores, and the summary files
# ($SUMM_LINE, empty for none; no description when $SUMM_NODESC is set). Exits $JOIN_EXIT.
summ_setup() {
  local slug="${PROJ//[^A-Za-z0-9-]/-}"
  run_engine -- asb claude --version
  CONV="$SBOX/transcripts/own/$(slugify "$H/home/.claude/projects/$slug")"
  HIST="$SBOX/transcripts/own/$(slugify "$H/home/.claude/history.jsonl")"
  [ -d "$CONV" ]
  printf '%s\n' "$(user_rec 'the role at work' 2026-10-27T10:00:00Z)" >"$CONV/mine.jsonl"
  printf '%s\n' '{"display":"the role at work","sessionId":"mine"}' >"$HIST"
  # a python script: the engine runs its join through python3 (_as_python)
  cat >"$H/bin/summ-join" <<STUB
import os, sys
with open(os.environ["JOIN_DUMP"], "w") as fh:
    fh.writelines(a + "\\n" for a in sys.argv[1:])
a = sys.argv[1:]
if "--session-id" in a:
    i = a[a.index("--session-id") + 1]
    with open("$CONV/" + i + ".jsonl", "w") as fh:
        fh.write('{"type":"user","sessionId":"%s"}\\n' % i)
    os.makedirs("$CONV/" + i + "/subagents")
    with open("$HIST", "a") as fh:
        fh.write('{"display":"summarize","sessionId":"%s"}\\n' % i)
    with open("$SBOX/summary/line", "w") as fh:
        fh.write(os.environ.get("SUMM_LINE", "") + "\\n")
    if not os.environ.get("SUMM_NODESC"):
        with open("$SBOX/summary/description.md", "w") as fh:
            fh.write("# What the role did\\n")
sys.exit(int(os.environ.get("JOIN_EXIT", "0")))
STUB
  chmod +x "$H/bin/summ-join"
}

@test "--summarize runs one headless turn of a new session in the role's sandbox, then deletes its transcript (#314)" {
  summ_setup
  # A turn with its own prompt, as a --serve turn: no [briefing] start, so its file is
  # not read -- a missing one refuses a launch, but not this turn.
  printf '[briefing]\nstart = nosuch.md\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  (cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  run_engine -- asb claude -p hello
  [[ "$output" == *"([briefing] start), which does not exist. Refusing"* ]]
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE=$'Pinned CUDA \e[31min CI' -- asb --summarize claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default': summarizing in its sandbox, one headless turn"* ]]
  # the turn: print mode, a fresh session id, no permission prompts, the engine's prompt last
  local id="" i
  for ((i = 0; i < ${#JOINV[@]}; i++)); do [[ "${JOINV[i]}" == --session-id ]] && id="${JOINV[i + 1]}"; done
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
  [[ " ${JOINV[*]} " == *"/claude -p --session-id $id --permission-mode bypassPermissions You are asked "* ]]
  # (the dump is one argument per line, and the prompt has several)
  local j
  j="$(cat "$H/join")"
  [[ "$j" == *$'\n'"bypassPermissions"$'\n'"You are asked to summarize the work of this role"* ]]
  [[ "$j" == *"the .jsonl files under "*"$H/home/.claude/projects/"*"This session is $id; its own $id.jsonl is not one of them"* ]]
  [[ "$j" == *"/run/agent-sandbox/summary/line: one line"*"/run/agent-sandbox/summary/description.md: "*"Reply with the line only." ]]
  # its transcript, its directory and its history record are gone; the role's own stay
  [ ! -e "$CONV/$id.jsonl" ]
  [ ! -e "$CONV/$id" ]
  [ -s "$CONV/mine.jsonl" ]
  [ "$(cat "$HIST")" = '{"display":"the role at work","sessionId":"mine"}' ]
  # the new line, as text, and the description's host path
  [[ "$output" == *"role 'default' summarized:"$'\n'"    Pinned CUDA [31min CI"$'\n'"    description: $SBOX/summary/description.md"* ]]
  run_engine TZ=UTC -- asb --list
  [[ "$output" == *$'\n'"    Pinned CUDA [31min CI"$'\n'"    # What the role did"$'\n'"To resume: "* ]]
  run_engine TZ=UTC -- asb --list-all
  [[ "$output" == *$'\n'"    Pinned CUDA [31min CI"$'\n'"    description: $SBOX/summary/description.md"$'\n'* ]]
}

@test "--summarize needs no command when one profile is installed, takes no agent arguments, and is not combined with another verb (#314)" {
  summ_setup
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE=line -- asb --role default --summarize
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' summarized:"* ]]
  run_engine -- asb --summarize claude -r
  [ "$status" -eq 2 ]
  [[ "$output" == *"--summarize takes no agent arguments"* ]]
  local v
  for v in --status --delete --shutdown --serve --list '--exec true'; do
    # shellcheck disable=SC2086 # --exec and its command are two words
    run_engine -- asb --summarize $v claude
    [ "$status" -eq 2 ]
    [[ "$output" == *"--summarize runs one turn in a stopped role's sandbox; it is not combined with"* ]]
  done
  [ ! -s "$H/join" ] # none of them ran a turn
}

@test "--summarize is refused while the role runs, naming --shutdown; for a role with no conversation; and under native (#314)" {
  summ_setup
  engine_bg -- asb claude --version
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" -- asb --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"role 'default' is running; summarize it once it has stopped: asb --role default --shutdown claude"* ]]
  release_bg
  [ ! -s "$H/join" ]
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" -- asb --role fresh --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"role 'fresh' has no conversation to summarize"* ]]
  rm "$CONV/mine.jsonl" # a transcript with no user record is no conversation either
  printf '{"type":"mode"}\n' >"$CONV/s.jsonl"
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" -- asb --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"role 'default' has no conversation to summarize"* ]]
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" -- asb --preset native --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--summarize is refused under --preset native"* ]]
  [ ! -s "$H/join" ]
}

@test "--summarize exits non-zero when the turn fails or leaves the line empty, and deletes the transcript all the same (#314)" {
  summ_setup
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE=line JOIN_EXIT=3 -- asb --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"role 'default': the summarizing turn ended with status 3"* ]]
  [[ "$output" != *"summarized:"* ]]
  [ "$(find "$CONV" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] # mine.jsonl alone
  [ "$(wc -l <"$HIST")" -eq 1 ]
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE= -- asb --summarize claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"role 'default': the turn left no new summary line in $SBOX/summary/line"* ]]
  [ "$(find "$CONV" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
  # a description older than the turn is not the turn's; none at all is said too
  touch -d '-1 hour' "$SBOX/summary/description.md"
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE=new SUMM_NODESC=1 -- asb --summarize claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"    new"$'\n'"    description: not rewritten by this turn; $SBOX/summary/description.md is an older one"* ]]
  rm "$SBOX/summary/description.md"
  run_engine AGENT_SANDBOX_JOIN="$H/bin/summ-join" SUMM_LINE=new SUMM_NODESC=1 -- asb --summarize claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"    new"$'\n'"    description: none written"* ]]
  # nor is a line older than the turn
  printf 'old\n' >"$SBOX/summary/line"
  touch -d '-1 hour' "$SBOX/summary/line"
  run_engine -- asb --summarize claude # the harness's own join stub writes nothing
  [ "$status" -eq 1 ]
  [[ "$output" == *"the turn left no new summary line"* ]]
}

@test "--list shows the description's first 5 non-blank lines, then its path when there is more; --list-all its path only; a link is not read (#314)" {
  list_fixture
  local sb d
  sb="$(store_dir "$PROJ" own)"
  d="$sb/summary/description.md"
  printf '# x\n' >"$H/elsewhere.md"
  ln -s "$H/elsewhere.md" "$d"
  run_engine TZ=UTC -- asb --list
  [[ "$output" != *"# x"* && "$output" != *"description"* ]]
  rm "$d"
  # short: shown whole, blank lines skipped, control characters dropped
  printf '# Summary\n\n  Pinned \e[31mCUDA\n\t\nOpen: arm64\n' >"$d"
  run_engine TZ=UTC -- asb --list
  [[ "$output" == *$'\n'"    My own line"$'\n'"    # Summary"$'\n'"      Pinned [31mCUDA"$'\n'"    Open: arm64"$'\n'"To resume: "* ]]
  [[ "$output" != *"description:"* ]]
  # exactly 5: still whole
  printf 'l1\nl2\n\nl3\nl4\nl5\n\n' >"$d"
  run_engine TZ=UTC -- asb --list
  [[ "$output" == *$'\n'"    My own line"$'\n'"    l1"$'\n'"    l2"$'\n'"    l3"$'\n'"    l4"$'\n'"    l5"$'\n'"To resume: "* ]]
  # longer: the first 5, then the path
  printf 'l1\nl2\n\nl3\nl4\nl5\nl6\nl7\n' >"$d"
  run_engine TZ=UTC -- asb --list
  [[ "$output" == *$'\n'"    l5"$'\n'"    full description: $d"$'\n'"To resume: "* ]]
  [[ "$output" != *"l6"* ]]
  # --list-all: the path, never the content
  run_engine TZ=UTC -- asb --list-all
  [[ "$output" == *$'\n'"    My own line"$'\n'"    description: $d"$'\n'* ]]
  [[ "$output" != *"l1"* ]]
  [ "$(grep -c 'description:' <<<"$output")" -eq 1 ]
}

@test "--list-all prints each project's line bold at a terminal, the slug line too; plain through a pipe (#314)" {
  list_fixture
  local sb
  sb="$(store_dir /no/record r)"
  conv "$sb" s "2026-10-20 08:00 UTC" "$(user_rec 'x' 2026-10-20T07:00:00Z)"
  mkdir -p "$H/nowhere"
  RUN_CWD="$H/nowhere" run_engine TZ=UTC -- asb --list-all
  [[ "$output" != *$'\e'* ]]
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the colour on"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" TZ=UTC script -qec "$(printf "%q " "${@:4}") --list-all" /dev/null' _ "$H/nowhere" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  output="${output//$'\r'/}"
  local B=$'\e[1m' R=$'\e[0m'
  [[ "$output" == "${B}/elsewhere/other${R}"$'\n'* ]]
  [[ "$output" == *$'\n'"${B}$PROJ${R}"$'\n'* ]]
  [[ "$output" == *$'\n'"${B}-no-record  (the path is not recorded; this is the store's slug)${R}"$'\n'* ]]
  [ "$(grep -o $'\e\\[1m' <<<"$output" | wc -l)" -eq 3 ]
  [[ "$output" == *$'\n'"To resume: cd PROJECT_DIR && "*" --role ROLE claude --continue" ]] # plain
}
