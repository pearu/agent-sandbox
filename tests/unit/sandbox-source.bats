#!/usr/bin/env bats
# The `sandbox:` source (#200): another role's store as what a channel or a path shows.
# `sandbox:@ROLE` is this project's role, `sandbox:PATH@ROLE` another project's, the
# role `default` when none is named. A store is found from that role's RECORD of its
# last launch; with no record the project never ran sandboxed there, and the source is
# the native path. Stub bwrap: these pin the argv and the refusals.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  C="$H/home/.claude"
  mkdir -p "$C/rules" "$C/skills"
  STATE="$H/home/.local/state/agent-sandbox"
  PROJ="$(cd "$H/proj" && pwd -P)"
  PSLUG="${PROJ//[^A-Za-z0-9-]/-}"
  MEM="$C/projects/$PSLUG/memory"
  CFG="$H/home/.config/agent-sandbox"
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
# role_dir PROJECT ROLE -- that role's state directory
role_dir() { printf '%s/claude/%s/%s' "$STATE" "${1//[^A-Za-z0-9-]/-}" "$2"; }
trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$1/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}

@test "a launch records what it bound at each channel path: mode and store" {
  TEST_PRESET=inherit run_engine -- asb --role impl claude --version
  [ "$status" -eq 0 ]
  local rec
  rec="$(role_dir "$PROJ" impl)/record.tsv"
  [ -f "$rec" ]
  # memory is the role's own under inherit (#196): its slot
  grep -qxF "memory	own	$MEM	$(role_dir "$PROJ" impl)/memory/own/$(slugify "$MEM")" "$rec"
  # instructions are an overlay there: not one store to read
  grep -qxF "instructions	copy-on-write	$C/rules	-" "$rec"
}

@test "memory = read-only sandbox:@impl: this project's reviewer reads the implementer's memory (#55)" {
  TEST_PRESET=inherit run_engine -- asb --role impl claude --version
  [ "$status" -eq 0 ]
  TEST_PRESET=inherit run_engine -- asb --role reviewer --connect 'memory = read-only sandbox:@impl' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(role_dir "$PROJ" impl)/memory/own/$(slugify "$MEM")" "$MEM"
  run ! grep -qF "$(role_dir "$PROJ" reviewer)/memory/own" "$H/argv" # it has none of its own there
}

@test "memory = copy sandbox:@impl: the reviewer's own copy, seeded from the implementer's store" {
  TEST_PRESET=inherit run_engine -- asb --role impl claude --version
  printf 'IMPL NOTE\n' >"$(role_dir "$PROJ" impl)/memory/own/$(slugify "$MEM")/MEMORY.md"
  TEST_PRESET=inherit run_engine -- asb --role reviewer --connect 'memory = copy sandbox:@impl' claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$(role_dir "$PROJ" reviewer)/memory/copy/$(slugify "$MEM")"
  argv_has --bind "$slot" "$MEM"
  [ "$(cat "$slot/MEMORY.md")" = "IMPL NOTE" ]
}

@test "a role that never launched is its native state: the source is the native path, until it launches" {
  printf 'NATIVE SKILL\n' >"$C/skills/s.md"
  run_engine -- asb --connect 'skills = read-only sandbox:@ghost' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/skills" "$C/skills"
  # once it has launched, its record says where its skills are: its own store
  TEST_PRESET=isolated run_engine -- asb --role ghost claude --version
  run_engine -- asb --connect 'skills = read-only sandbox:@ghost' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(role_dir "$PROJ" ghost)/skills/own/$(slugify "$C/skills")" "$C/skills"
  run ! argv_has --ro-bind "$C/skills" "$C/skills"
}

@test "a store that is an overlay is refused at the launch, not read as something else" {
  TEST_PRESET=inherit run_engine -- asb --role impl claude --version
  TEST_PRESET=inherit run_engine -- asb --role reviewer --connect 'instructions = read-only sandbox:@impl' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"keeps 'instructions' at copy-on-write, which is not one store to read"* ]]
}

@test "the modes that write or overlay a sandbox's store, and own, are refused at the parse" {
  run_engine -- asb --connect 'memory = read-write sandbox:@impl' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-write sandbox:@impl' is refused"* ]]
  run_engine -- asb --connect 'memory = copy-on-write sandbox:@impl' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"not implemented in this engine (#200)"* ]]
  run_engine -- asb --connect 'memory = own sandbox:@impl' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"own is the sandbox's own storage"* ]]
  [ ! -s "$H/argv" ]
}

@test "a sandbox source names a role and a project the way the grammar says, and never this very role" {
  run_engine -- asb --connect 'memory = read-only sandbox:rel/dir@impl' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute or under '~', or empty for this one"* ]]
  run_engine -- asb --connect 'memory = read-only sandbox:@-bad' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'-bad' is not a role name"* ]]
  run_engine -- asb --connect 'memory = read-only sandbox:@default' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"names this very role"* ]]
  [ ! -s "$H/argv" ]
}

@test "a path declaration takes a sandbox source too: another project's store at that project's path" {
  local other="$H/other" oslug omem
  mkdir -p "$other"
  other="$(cd "$other" && pwd -P)"
  oslug="${other//[^A-Za-z0-9-]/-}"
  omem="$C/projects/$oslug/memory"
  RUN_CWD="$other" TEST_PRESET=inherit run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run_engine -- asb --connect "{base}/projects/{slug:$other}/memory/ = read-only sandbox:$other" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(role_dir "$other" default)/memory/own/$(slugify "$omem")" "$omem"
}

@test "[share-memory] P reads P's role store; P never sandboxed, its native memory" {
  local a="$H/a" b="$H/b" aslug bslug
  mkdir -p "$a" "$b"
  a="$(cd "$a" && pwd -P)" b="$(cd "$b" && pwd -P)"
  aslug="${a//[^A-Za-z0-9-]/-}" bslug="${b//[^A-Za-z0-9-]/-}"
  RUN_CWD="$a" TEST_PRESET=inherit run_engine -- asb claude --version # a ran sandboxed
  mkdir -p "$C/projects/$bslug/memory"                                # b only natively
  printf '[share-memory]\n%s\n%s\n' "$a" "$b" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(role_dir "$a" default)/memory/own/$(slugify "$C/projects/$aslug/memory")" "$C/projects/$aslug/memory"
  argv_has --ro-bind "$C/projects/$bslug/memory" "$C/projects/$bslug/memory"
}

@test "a wildcard share matches the projects whose memory resolves: a role store or native" {
  mkdir -p "$H/space/x" "$H/space/y" "$H/space/z"
  local x y
  x="$(cd "$H/space/x" && pwd -P)" y="$(cd "$H/space/y" && pwd -P)"
  RUN_CWD="$x" TEST_PRESET=inherit run_engine -- asb claude --version # x: a role store
  mkdir -p "$C/projects/${y//[^A-Za-z0-9-]/-}/memory"                  # y: native memory
  printf '[share-memory]\n%s/*\n' "$H/space" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  grep -qF "$(role_dir "$x" default)/memory/own" "$H/argv"
  argv_has --ro-bind "$C/projects/${y//[^A-Za-z0-9-]/-}/memory" "$C/projects/${y//[^A-Za-z0-9-]/-}/memory"
  run ! grep -qF "${H//[^A-Za-z0-9-]/-}-space-z" "$H/argv" # z: nothing to share
}

@test "the review says when another sandbox's agent authors what this one loads as yours" {
  printf '[connect]\nskills = read-only sandbox:@impl\nmemory = read-only sandbox:@impl\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"'skills = read-only sandbox:@impl': what that role's agent wrote into its skills becomes what this sandbox reads as yours"* ]]
  [[ "$output" != *"'memory = read-only sandbox:@impl': what that role's agent wrote"* ]]
}

@test "the connection report names the sandbox source" {
  TEST_PRESET=inherit run_engine -- asb --role impl claude --version
  TEST_PRESET=inherit run_engine -- asb --role reviewer --connect 'memory = read-only sandbox:@impl' claude --version
  [[ "$output" == *"connect: memory = read-only sandbox:@impl (--connect)"* ]]
}
