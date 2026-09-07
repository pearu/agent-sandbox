#!/usr/bin/env bats
# The per-project .agent-sandbox file: parsing, the trust gate, and how it
# feeds --allow and memory scoping. Stub bwrap, so these assert on the argv and
# the engine's messages, never a real sandbox.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  slug() { printf '%s' "$1" | sed 's:/:-:g'; }
}

# Run `--trust` from inside the project, feeding $1 as the prompt answers.
run_trust() {
  local answers="$1"
  run bash -c '
    cd "$2" || exit 99
    printf "%b" "$3" | env -i HOME="$1/home" PATH="$1/bin:/usr/bin:/bin" USER=tester \
      AGENT_SANDBOX_SESSION_BASE="$1/base" "$4" --profile claude --trust
  ' _ "$H" "$PROJ" "$answers" "$ENGINE"
}

# Record approval of $1/.agent-sandbox the way the engine's --trust would.
trust() {
  local d="$1" t="$CFG/trust"
  mkdir -p "$t"
  sha256sum -- "$d/.agent-sandbox" | cut -d' ' -f1 \
    >"$t/$(printf '%s' "$d" | sha256sum | cut -d' ' -f1)"
}

@test "an unapproved dot-file is ignored, with a pointer to --trust; a command-line --allow still works" {
  printf 'allow = evil.example\nshare-memory =\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$H/home/.claude/projects/-other/memory"
  run_engine -- claude --allow good.example --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"present but not approved"* ]]
  [[ "$output" == *"--trust"* ]]
  [[ "$output" == *"session allowlist: good.example"* ]]
  [[ "$output" != *evil.example* ]]
  ! argv_has --tmpfs "$H/home/.claude/projects" # share-memory not applied either
}

@test "an approved dot-file adds its allow hosts and scopes memory to the current project" {
  printf '# my project policy\nallow = pypi.org, .github.com\nshare-memory =\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  mkdir -p "$H/home/.claude/projects/-other/memory"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist:"*"pypi.org"*".github.com"* ]]
  argv_has --tmpfs "$H/home/.claude/projects"
  argv_has --bind "$H/home/.claude/projects/$(slug "$PROJ")" "$H/home/.claude/projects/$(slug "$PROJ")"
  ! argv_has --ro-bind "$H/home/.claude/projects/-other/memory" "$H/home/.claude/projects/-other/memory"
  # tmpfs hides projects before the current one is rebound
  [ "$(argv_index --tmpfs)" -lt "$(argv_index "$H/home/.claude/projects/$(slug "$PROJ")")" ]
}

@test "share-memory lists other projects: their memory is bound read-only, the rest stay hidden" {
  local other="$H/other-proj" secret="$H/secret-proj"
  mkdir -p "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$secret")/memory"
  printf 'share-memory = %s\n' "$other" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
  ! argv_has "$H/home/.claude/projects/$(slug "$secret")/memory"
  ! argv_has --bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
}

@test "editing an approved dot-file re-blocks it until re-approval" {
  printf 'allow = pypi.org\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  printf 'allow = pypi.org, evil.example\n' >"$PROJ/.agent-sandbox" # the agent could do this
  run_engine -- claude --version
  [[ "$output" == *"present but not approved"* ]]
  [[ "$output" != *evil.example* ]]
}

@test "share-memory = all keeps every project's memory visible even when the global default is scoped" {
  printf 'memory_default = scoped\n' >"$CFG/config" 2>/dev/null || {
    mkdir -p "$CFG"
    printf 'memory_default = scoped\n' >"$CFG/config"
  }
  printf 'share-memory = all\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --tmpfs "$H/home/.claude/projects"
}

@test "the global default scopes memory with no dot-file present; unknown keys and ssh warn" {
  mkdir -p "$CFG"
  printf 'memory_default = scoped\n' >"$CFG/config"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$H/home/.claude/projects"
  # parsing feedback
  printf 'allow = ok.example\nssh = h\nbogus = 1\n= noKey\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [[ "$output" == *"'ssh' is not supported yet"* ]]
  [[ "$output" == *"unknown key 'bogus'"* ]]
}

@test "--trust reviews and approves the file, offers to git-ignore it, and never launches the agent" {
  git init -q "$PROJ"
  printf 'allow = pypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\ny'
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow = pypi.org"* ]] # shown for review
  [[ "$output" == *"approved."* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
  [ -f "$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)" ]
  grep -q '/.agent-sandbox' "$PROJ/.git/info/exclude"
  # and now the engine honours it
  run_engine -- claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust declined records nothing" {
  printf 'allow = pypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not approved"* ]]
  [ ! -d "$CFG/trust" ] || [ -z "$(ls -A "$CFG/trust")" ]
}
