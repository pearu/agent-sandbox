#!/usr/bin/env bats
# The `transcripts` and `logs` channels (#120, #129 step 8). A role's conversations
# (this project's `projects/<slug>/`), file history, plans and prompt history are its
# own under every preset but `native`, and so are the logs your hooks write. Nothing
# is merged back into the native ~/.claude when a launch ends. Memory, inside
# `projects/<slug>/`, is a channel of its own (#196), bound on top of the store by depth.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  C="$H/home/.claude"
  SLUG="${PROJ//[^A-Za-z0-9-]/-}"
  CONV="$C/projects/$SLUG"
  SBOX="$H/home/.local/state/agent-sandbox/claude/$SLUG/default"
  mkdir -p "$CONV/memory" "$C/file-history/s1" "$C/plans"
  printf 'NATIVE-CONV\n' >"$CONV/old-session.jsonl"
  printf 'MEM\n' >"$CONV/memory/MEMORY.md"
  printf 'SNAP\n' >"$C/file-history/s1/f"
  printf '{"display":"MINE","project":"%s"}\n{"display":"OTHER","project":"/elsewhere"}\n' "$PROJ" >"$C/history.jsonl"
  printf 'LOG\n' >"$C/responses.log"
  cp "$C/history.jsonl" "$H/history-before"
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
store() { printf '%s/%s/%s/%s' "$SBOX" "$1" "$2" "$(slugify "$3")"; }
idx_of_bind() { # idx_of_bind SRC DEST -> the argv index of "--bind SRC DEST", or -1
  local i
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --bind && "${ARGV[i + 1]}" == "$1" && "${ARGV[i + 2]}" == "$2" ]] && {
      echo "$i"
      return
    }
  done
  echo -1
}

@test "transcripts and logs are channels the profile declares" {
  run_engine -- asb --connect 'transcripts=own native' --connect 'logs=own native' claude --version
  [ "$status" -eq 0 ]
}

@test "under inherit every transcripts path is the role's own store, and the native files are untouched" {
  TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(store transcripts own "$CONV")" "$CONV"
  argv_has --bind "$(store transcripts own "$C/file-history")" "$C/file-history"
  argv_has --bind "$(store transcripts own "$C/plans")" "$C/plans"
  argv_has --bind "$(store transcripts own "$C/history.jsonl")" "$C/history.jsonl"
  [ ! -e "$(store transcripts own "$CONV")/old-session.jsonl" ] # nothing seeded
  [ ! -s "$(store transcripts own "$C/history.jsonl")" ]
  cmp "$C/history.jsonl" "$H/history-before"
}

@test "isolated and shared give transcripts and logs their own stores too" {
  local p
  for p in isolated shared; do
    TEST_PRESET=$p run_engine -- asb claude --version
    [ "$status" -eq 0 ]
    argv_has --bind "$(store transcripts own "$CONV")" "$CONV"
    argv_has --bind "$(store logs own "$C/responses.log")" "$C/responses.log"
    argv_has --bind "$(store logs own "$C/alerts.log")" "$C/alerts.log"
  done
}

@test "memory is a channel, the role's own under inherit and isolated: bound by depth, inside the transcripts store, inside the projects store" {
  local p pr t m
  for p in inherit isolated; do
    TEST_PRESET=$p run_engine -- asb claude --version
    [ "$status" -eq 0 ]
    pr="$(idx_of_bind "$(store projects own "$C/projects")" "$C/projects")"
    t="$(idx_of_bind "$(store transcripts own "$CONV")" "$CONV")"
    m="$(idx_of_bind "$(store memory own "$CONV/memory")" "$CONV/memory")"
    [ "$pr" -ge 0 ]
    [ "$t" -gt "$pr" ]
    [ "$m" -gt "$t" ]
    # the native memory is not in view: the default changed with #196
    [ "$(idx_of_bind "$CONV/memory" "$CONV/memory")" -eq -1 ]
  done
}

@test "under shared, memory is your native memory, bound back over the role's stores; a missing one is created" {
  rm -rf "$CONV/memory"
  TEST_PRESET=shared run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local t m
  t="$(idx_of_bind "$(store transcripts own "$CONV")" "$CONV")"
  m="$(idx_of_bind "$CONV/memory" "$CONV/memory")"
  [ "$t" -ge 0 ]
  [ "$m" -gt "$t" ]
  [ -d "$CONV/memory" ]
}

@test "memory = copy-on-write reads your native memory through the role's store" {
  TEST_PRESET=inherit run_engine -- asb --connect 'memory = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$CONV/memory"
}

@test "nothing is staged for a merge-back: no transcripts or logs path is bound from the launch directory" {
  TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local p i
  for p in "$C/file-history" "$C/plans" "$C/history.jsonl" "$C/responses.log" "$C/alerts.log"; do
    for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
      if [[ "${ARGV[i + 2]}" == "$p" && "${ARGV[i + 1]}" == "$H/base/"* ]]; then
        echo "$p is bound from the launch directory: ${ARGV[i + 1]}"
        return 1
      fi
    done
  done
}

@test "transcripts = seed-only seeds once: this project's conversations and history, and no other project's prompts" {
  run_engine -- asb --connect 'transcripts=seed-only native' claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$(store transcripts seed-only "$CONV")/old-session.jsonl")" = NATIVE-CONV ]
  [ "$(cat "$(store transcripts seed-only "$C/file-history")/s1/f")" = SNAP ]
  local h
  h="$(store transcripts seed-only "$C/history.jsonl")"
  grep -q MINE "$h"
  run ! grep -q OTHER "$h"
}

@test "transcripts = read-write is the native files themselves: no store is bound" {
  run_engine -- asb --connect 'transcripts=read-write native' claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$SBOX/transcripts/" "$H/argv"
  argv_has --bind "$CONV" "$CONV" # memory scoping binds this project's native directory, as in 0.3
}

@test "under native nothing of transcripts or logs is bound from a store" {
  run_engine -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$SBOX/transcripts/" "$H/argv"
  run ! grep -qF "$SBOX/logs/" "$H/argv"
}

@test "two roles have two conversation stores" {
  TEST_PRESET=inherit run_engine -- asb --role a claude --version
  argv_has --bind "$H/home/.local/state/agent-sandbox/claude/$SLUG/a/transcripts/own/$(slugify "$CONV")" "$CONV"
  TEST_PRESET=inherit run_engine -- asb --role b claude --version
  argv_has --bind "$H/home/.local/state/agent-sandbox/claude/$SLUG/b/transcripts/own/$(slugify "$CONV")" "$CONV"
}
