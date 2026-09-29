#!/usr/bin/env bats
# Roles (#129 step 7): a role is a named, persistent instance of a project under a policy.
# The name is the sandbox key's second half; the policy comes from the dot-file's
# role-suffixed sections, `[<section>:<glob>]`, applied after the unsuffixed ones, in file
# order, later overriding earlier PER KEY. Only [sandbox:...] and [connect:...] take the
# suffix in this step. There is no [role:...] section.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  C="$H/home/.claude"
  mkdir -p "$C/rules" "$C/skills"
  STATE="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}"
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}
dotfile() { # dotfile TEXT -- write and approve the project's dot-file
  printf '%s' "$1" >"$PROJ/.agent-sandbox"
  trust
}
own_bind() { argv_has --bind "$STATE/$1/$2/own/$(slugify "$3")" "$3"; }

@test "--role names the sandbox: two roles are two sandbox directories" {
  run_engine -- claude --role impl-1 --connect 'skills=own native' --version
  [ "$status" -eq 0 ]
  own_bind impl-1 skills "$C/skills"
  run_engine -- claude --role reviewer --connect 'skills=own native' --version
  own_bind reviewer skills "$C/skills"
  [ -d "$STATE/impl-1" ] && [ -d "$STATE/reviewer" ]
}

@test "no --role is the default role, and --role default is the same" {
  run_engine -- claude --connect 'skills=own native' --version
  own_bind default skills "$C/skills"
  run_engine -- claude --role default --connect 'skills=own native' --version
  own_bind default skills "$C/skills"
}

@test "the role takes three forms: flag over environment over [sandbox] role" {
  dotfile $'[sandbox]\nrole = from-file\n'
  run_engine -- claude --connect 'skills=own native' --version
  [ "$status" -eq 0 ]
  own_bind from-file skills "$C/skills"
  run_engine AGENT_SANDBOX_ROLE=from-env -- claude --connect 'skills=own native' --version
  own_bind from-env skills "$C/skills"
  run_engine AGENT_SANDBOX_ROLE=from-env -- claude --role from-flag --connect 'skills=own native' --version
  own_bind from-flag skills "$C/skills"
  run_engine -- claude --role=eq-form --connect 'skills=own native' --version
  own_bind eq-form skills "$C/skills"
}

@test "a role-suffixed [connect] applies to the roles its glob matches, and not to others" {
  dotfile $'[connect:impl-*]\nskills = own native\n\n[connect:*]\n'
  run_engine -- claude --role impl-7 --version
  [ "$status" -eq 0 ]
  own_bind impl-7 skills "$C/skills"
  run_engine -- claude --role reviewer --version
  [ "$status" -eq 0 ]
  run ! grep -qF "/reviewer/skills/own/" "$H/argv"
}

@test "later sections override earlier ones per key, and an unrelated key survives" {
  dotfile $'[connect]\nskills = own native\ninstructions = own native\n\n[connect:impl-*]\nskills = read-only native\n\n[connect:*]\n'
  run_engine -- claude --role impl-1 --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/skills" "$C/skills"  # the later, suffixed line won
  own_bind impl-1 instructions "$C/rules"     # the earlier key it did not name stays
  run_engine -- claude --role other --version # a role the suffix does not match
  own_bind other skills "$C/skills"
}

@test "[sandbox:<glob>] preset applies per role, after the unsuffixed one" {
  dotfile $'[sandbox]\npreset = shared\n\n[sandbox:iso-*]\npreset = isolated\n\n[sandbox:*]\n'
  TEST_PRESET='' run_engine -- claude --role iso-1 --version
  [ "$status" -eq 0 ]
  own_bind iso-1 skills "$C/skills"
  TEST_PRESET='' run_engine -- claude --role plain --version
  [ "$status" -eq 0 ]
  run ! grep -qF "/plain/skills/own/" "$H/argv"
}

@test "a name matching no suffixed section is refused, naming the sections that exist" {
  dotfile $'[connect:impl-*]\nskills = own native\n[sandbox:reviewer]\npreset = isolated\n'
  run_engine -- claude --role revewer --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'revewer' matches no role section"*"impl-*"*"reviewer"* ]]
  [ ! -s "$H/argv" ]
}

@test "without any suffixed section, any role name is the one policy, a separate instance" {
  dotfile $'[connect]\nskills = own native\n'
  run_engine -- claude --role scratch-42 --version
  [ "$status" -eq 0 ]
  own_bind scratch-42 skills "$C/skills"
}

@test "[connect:*] matches every role, so nothing is refused" {
  dotfile $'[connect:*]\nskills = own native\n'
  run_engine -- claude --role anything --version
  [ "$status" -eq 0 ]
}

@test "role names: letters, digits, . _ - after a letter or digit; nothing else" {
  local bad
  for bad in -lead 'a/b' 'a@b' 'a*b' 'a?b' '' '.dot'; do
    run_engine -- claude --role "$bad" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"role"* ]]
    [ ! -s "$H/argv" ]
  done
  run_engine -- claude --role "$(printf 'r%.0s' {1..201})" --version
  [ "$status" -ne 0 ]
  run_engine -- claude --role "A.b_c-9" --version
  [ "$status" -eq 0 ]
}

@test "role is a key of the unsuffixed [sandbox] only" {
  dotfile $'[sandbox:x]\nrole = y\n'
  run_engine -- claude --role x --version
  [[ "$output" == *"[sandbox:x] role"* ]]
}

@test "a suffix on a section that does not take one yet is said, not silently honoured" {
  dotfile $'[net:impl-*]\nmode = none\n'
  run_engine -- claude --role impl-1 --version
  [[ "$output" == *"[net:impl-*]"*"role suffix"* ]]
  argv_has --share-net # the skipped section's `mode = none` did not apply to anyone
}

@test "a non-default role with --bg runs in that role's launch (#123)" {
  run_engine -- claude --role impl-1 --connect 'skills=own native' --bg 'do it'
  [ "$status" -eq 0 ]
  own_bind impl-1 skills "$C/skills"
  join_has "$H/home/.local/share/claude/versions/2.1.300/claude" --bg 'do it'
}
