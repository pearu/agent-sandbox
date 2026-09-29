#!/usr/bin/env bats
# The role verbs (#126): --reset takes one channel or declared path back to the source,
# --delete removes every store of the role, --status shows what --shutdown would end.
# (--shutdown itself is in routing.bats, with the rest of #123.) Each does its work and
# exits; none launches the agent.

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

@test "--reset-connection is refused with its new name" {
  run_engine -- claude --reset-connection instructions
  [ "$status" -eq 2 ]
  [[ "$output" == *"--reset-connection was renamed: write --reset"* ]]
  [ ! -s "$H/argv" ]
}

@test "--reset CHANNEL re-seeds that channel and leaves the others" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native;skills=copy native' -- claude --version
  local ins sk
  ins="$SBOX/instructions/copy/$(slugify "$C/rules")"
  sk="$SBOX/skills/copy/$(slugify "$C/skills")"
  printf 'MINE\n' >"$ins/topic.md"
  printf 'MINE\n' >"$sk/s.md"
  run_engine -- claude --reset instructions
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset 'instructions'"* ]]
  [ ! -s "$H/argv" ] # nothing launched
  [ "$(cat "$ins/topic.md")" = NATIVE ]
  [ "$(cat "$sk/s.md")" = MINE ]
}

@test "--reset discards an own store too: its source's version is the empty start" {
  run_engine AGENT_SANDBOX_CONNECT='skills=own native' -- claude --version
  local own
  own="$SBOX/skills/own/$(slugify "$C/skills")"
  printf 'MINE\n' >"$own/x.md"
  run_engine -- claude --reset skills
  [ "$status" -eq 0 ]
  [ ! -e "$own/x.md" ]
}

@test "--reset PATH resets one declared path and leaves the others" {
  mkdir -p "$PROJ/scratch" "$PROJ/other"
  run_engine -- claude --connect './scratch/=own' --connect './other/=own' --version
  [ "$status" -eq 0 ]
  local s o
  s="$SBOX/@paths/own/$(slugify "$PROJ/scratch")"
  o="$SBOX/@paths/own/$(slugify "$PROJ/other")"
  printf 'MINE\n' >"$s/x"
  printf 'MINE\n' >"$o/x"
  run_engine -- claude --reset ./scratch/
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset './scratch/'"* ]]
  [ ! -e "$s" ]
  [ "$(cat "$o/x")" = MINE ]
}

@test "--reset of a path that holds nothing says so; of a protected path it refuses" {
  run_engine -- claude --reset ./nothing-here/
  [ "$status" -eq 0 ]
  [[ "$output" == *"holds nothing at './nothing-here/'"* ]]
  # shellcheck disable=SC2088 # the engine expands `~`, as a declaration's does
  run_engine -- claude --reset '~/.ssh/'
  [ "$status" -ne 0 ]
}

@test "--reset of a name that is neither a channel nor a path is refused, listing the channels" {
  run_engine -- claude --reset nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'nosuch'"*"It carries:"* ]]
}

@test "--delete removes every store of the role, and the next launch starts from the source" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --version
  printf 'MINE\n' >"$SBOX/instructions/copy/$(slugify "$C/rules")/topic.md"
  run_engine -- claude --delete
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted its stores"* ]]
  [ ! -s "$H/argv" ]
  [ ! -e "$SBOX" ]
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --version
  [ "$(cat "$SBOX/instructions/copy/$(slugify "$C/rules")/topic.md")" = NATIVE ]
}

@test "--delete of a role with nothing stored says so" {
  run_engine -- claude --role fresh --delete
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'fresh' has nothing stored"* ]]
}

@test "--delete is refused while anything is joined, naming --shutdown, and removes nothing" {
  engine_bg -- claude --version
  run_engine -- claude --delete
  [ "$status" -ne 0 ]
  [[ "$output" == *"is running; end it first with:"*"--shutdown"* ]]
  [ -d "$SBOX" ]
  release_bg
}

@test "--delete ends an idle keeper first, as a reset does" {
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 -- claude --version
  release_bg
  [ -e "$SBOX/keeper/id" ] # waiting out its grace
  run_engine -- claude --delete
  [ "$status" -eq 0 ]
  [ ! -e "$SBOX" ]
}

@test "--delete names only its own role" {
  run_engine -- claude --role keep --version
  run_engine -- claude --role gone --version
  run_engine -- claude --role gone --delete
  [ "$status" -eq 0 ]
  [ -d "${SBOX%/default}/keep" ]
  [ ! -e "${SBOX%/default}/gone" ]
}

@test "--status of a role that is not running says so, and where its stores are" {
  run_engine -- claude --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' of $PROJ: not running, and nothing stored"* ]]
  run_engine -- claude --version
  run_engine -- claude --status
  [[ "$output" == *"not running; its stores"*"$SBOX"* ]]
  [ ! -s "$H/argv" ]
}

@test "--status of a running role shows the keeper, its dot-file, and no daemon" {
  engine_bg -- claude --version
  run_engine -- claude --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' of $PROJ: running since"*"supervisor pid"* ]]
  [[ "$output" == *"dot-file: none approved when it started"* ]]
  [[ "$output" == *"no background daemon"* ]]
  [ ! -s "$H/argv" ] # it launched nothing
  release_bg
}
