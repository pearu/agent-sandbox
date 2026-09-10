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
  printf '[allow]\nevil.example\n[share-memory]\n' >"$PROJ/.agent-sandbox"
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
  printf '# my project policy\n[allow]\npypi.org\n.github.com   # for pip\n[share-memory]\n' >"$PROJ/.agent-sandbox"
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
  printf '[share-memory]\n%s\n' "$other" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
  ! argv_has "$H/home/.claude/projects/$(slug "$secret")/memory"
  ! argv_has --bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
}

@test "share-memory takes a wildcard: children with memory are shared, siblings and memory-less dirs are not" {
  # real project dirs under a parent, plus a look-alike sibling
  mkdir -p "$H/space/arrow" "$H/space/lib" "$H/space/scratch" "$H/space-other"
  mkdir -p "$H/home/.claude/projects/$(slug "$H/space/arrow")/memory"
  mkdir -p "$H/home/.claude/projects/$(slug "$H/space/lib")/memory"
  # scratch exists as a dir but has no memory; space-other is a sibling, not under space/
  mkdir -p "$H/home/.claude/projects/$(slug "$H/space-other")/memory"
  printf '[share-memory]\n%s/*\n' "$H/space" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$H/space/arrow")/memory" "$H/home/.claude/projects/$(slug "$H/space/arrow")/memory"
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$H/space/lib")/memory" "$H/home/.claude/projects/$(slug "$H/space/lib")/memory"
  ! argv_has "$H/home/.claude/projects/$(slug "$H/space/scratch")/memory" # dir exists, no memory
  ! argv_has "$H/home/.claude/projects/$(slug "$H/space-other")/memory"   # sibling, not under space/
}

@test "a wildcard that matches nothing with memory warns" {
  mkdir -p "$H/empty"
  printf '[share-memory]\n%s/*\n' "$H/empty" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"matched no project with memory"* ]]
  argv_has --tmpfs "$H/home/.claude/projects" # still scoped to the current project
}

@test "an approved dot-file adds [ro]/[rw] paths and [forward] names to the sandbox" {
  mkdir -p "$H/ro-a" "$H/ro-b" "$H/rw-a"
  printf '[ro]\n%s/ro-a\n%s/ro-b\n[rw]\n%s/rw-a\n[forward]\nCUDA_VISIBLE_DEVICES\nMY_TOOL\n' "$H" "$H" "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MY_TOOL=on CUDA_VISIBLE_DEVICES=1 -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/ro-a" "$H/ro-a"
  argv_has --ro-bind "$H/ro-b" "$H/ro-b"
  argv_has --bind "$H/rw-a" "$H/rw-a"
  [ "$(setenv_value MY_TOOL)" = on ]
  [ "$(setenv_value CUDA_VISIBLE_DEVICES)" = 1 ]
}

@test "dot-file [ro]/[rw] paths still go through the secret-store refusal" {
  mkdir -p "$H/home/.aws"
  printf '[rw]\n%s/home/.aws\n' "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [ ! -s "$H/argv" ]
}

@test "a command-line env knob and the dot-file combine: RW paths union" {
  mkdir -p "$H/env-rw" "$H/file-rw"
  printf '[rw]\n%s/file-rw\n' "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_RW="$H/env-rw" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/env-rw" "$H/env-rw"
  argv_has --bind "$H/file-rw" "$H/file-rw"
}

@test "[conda] write and name are applied; name pins the env, write makes it writable" {
  local base="$H/conda"
  local env="$base/envs/proj-env"
  mkdir -p "$env" "$base/pkgs" "$H/pkgs"
  printf '[conda]\nname = proj-env\nwrite = 1\npkgs = %s/pkgs\n' "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"using conda env 'proj-env' from .agent-sandbox"* ]]
  argv_has --ro-bind "$base" "$base"
  argv_has --bind "$env" "$env"
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$H/pkgs,$base/pkgs" ]
  # PATH must agree with CONDA_PREFIX, or the pinned env's own tools are not
  # found inside. No env was active here, so its bin is prepended.
  [ "$(setenv_value PATH)" = "$env/bin:$H/bin:/usr/bin:/bin" ]
}

@test "[conda] name replaces the shell's active env on PATH, rather than shadowing it" {
  local base="$H/conda"
  local env="$base/envs/proj-env" active="$base/envs/shell-env"
  mkdir -p "$env" "$active" "$base/pkgs"
  printf '[conda]\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  # launched from a shell with shell-env active, the way conda leaves PATH
  run_engine CONDA_PREFIX="$active" CONDA_DEFAULT_ENV=shell-env CONDA_SHLVL=1 \
    PATH="$active/bin:$H/bin:/usr/bin:/bin" -- claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = "proj-env" ]
  # swapped in place: the pinned env's bin is where the active one was, and the
  # active env is gone rather than merely outranked
  [ "$(setenv_value PATH)" = "$env/bin:$H/bin:/usr/bin:/bin" ]
  [[ "$(setenv_value PATH)" != *"$active/bin"* ]]
  # and it is the pinned env that gets bound (read-only: write mode is off here)
  argv_has --ro-bind "$env" "$env"
  ! argv_has --ro-bind "$active" "$active"

  # The case that actually bit: launched from conda's BASE env, where
  # CONDA_PREFIX is the base itself and PATH carries <base>/bin, not an
  # <base>/envs/<name>/bin. The base's bin must give way to the pinned env too,
  # or the dot-file's env is bound but none of its tools are on PATH.
  mkdir -p "$base/bin"
  run_engine CONDA_PREFIX="$base" CONDA_DEFAULT_ENV=base CONDA_SHLVL=1 \
    PATH="$base/bin:$H/bin:/usr/bin:/bin" -- claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value PATH)" = "$env/bin:$H/bin:/usr/bin:/bin" ]
  [[ "$(setenv_value PATH)" != *"$base/bin:"* ]]
}

@test "[net] mode from an approved dot-file selects the network mode; AGENT_SANDBOX_NET wins; unknown values and unapproved files are ignored" {
  printf '[net]\nmode = none\n' >"$PROJ/.agent-sandbox"
  run_engine -- claude --version # not yet approved: still the default, proxy
  [ "$status" -eq 0 ]
  [[ "$output" == *"present but not approved"* ]]
  argv_has --share-net
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"using network mode 'none' from .agent-sandbox"* ]]
  ! argv_has --share-net
  ! setenv_value HTTPS_PROXY
  run_engine AGENT_SANDBOX_NET=proxy -- claude --version # the shell's knob wins
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT_SANDBOX_NET=proxy overrides the .agent-sandbox network mode 'none'"* ]]
  argv_has --share-net
  [ "$(setenv_value HTTPS_PROXY)" = "http://127.0.0.1:8888" ]
  printf '[net]\nmode = bogus\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[net] mode 'bogus' unknown"* ]]
  [ "$(setenv_value HTTPS_PROXY)" = "http://127.0.0.1:8888" ]
}

@test "[proxy-ca], [profile-dir] and [session-base] are refused in the dot-file" {
  printf '[proxy-ca]\n/tmp/x.pem\n[profile-dir]\n/tmp\n[session-base]\n/tmp\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[proxy-ca] is not allowed here"* ]]
  [[ "$output" == *"[profile-dir] is not allowed here"* ]]
  [[ "$output" == *"[session-base] is not allowed here"* ]]
  argv_has --share-net
  [ "$(setenv_value HTTPS_PROXY)" = "http://127.0.0.1:8888" ] # still proxied
}

@test "editing an approved dot-file refuses to launch until it is re-reviewed; the edit never applies unreviewed" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  printf '[allow]\npypi.org\nevil.example\n' >"$PROJ/.agent-sandbox" # the agent could do this
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has changed since you approved it"*"--trust"* ]]
  [[ "$output" != *"allowlist:"*evil.example* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
  run_trust 'y\n'    # the user reviews the new content and approves it
  [ "$status" -eq 0 ]
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist:"*"evil.example"* ]]
}

@test "deleting an approved dot-file refuses to launch (the defaults could be wider); --trust can forget the approval" {
  printf '[share-memory]\n' >"$PROJ/.agent-sandbox" # scoped: this project only
  trust "$PROJ"
  mkdir -p "$H/home/.claude/projects/-other/memory"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$H/home/.claude/projects"
  rm "$PROJ/.agent-sandbox" # the agent could do this; the default (shared) would widen its view
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"approved .agent-sandbox is missing"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  run_trust 'n\n' # keep the approval: still refused
  [ "$status" -eq 0 ]
  [[ "$output" == *"one was approved earlier"*"kept"* ]]
  run_engine -- claude --version
  [ "$status" -eq 1 ]
  run_trust 'y\n' # forget it: the defaults apply again, knowingly
  [ "$status" -eq 0 ]
  [[ "$output" == *"approval forgotten"* ]]
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --tmpfs "$H/home/.claude/projects"
}

@test "an all entry keeps every project's memory visible even when the global default is scoped" {
  printf 'memory_default = scoped\n' >"$CFG/config" 2>/dev/null || {
    mkdir -p "$CFG"
    printf 'memory_default = scoped\n' >"$CFG/config"
  }
  printf '[share-memory]\nall\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --tmpfs "$H/home/.claude/projects"
}

@test "the global default scopes memory with no dot-file present; unknown sections and ssh warn" {
  mkdir -p "$CFG"
  printf 'memory_default = scoped\n' >"$CFG/config"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$H/home/.claude/projects"
  # parsing feedback
  printf '[allow]\nok.example\n[ssh]\nignored.host\n[bogus]\nx\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- claude --version
  [[ "$output" == *"[ssh] is not supported yet"* ]]
  [[ "$output" == *"unknown section [bogus]"* ]]
}

@test "--trust reviews and approves the file, offers to git-ignore it, and never launches the agent" {
  git init -q "$PROJ"
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\ny'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[allow]"* && "$output" == *pypi.org* ]] # shown for review
  [[ "$output" == *"approved."* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
  [ -f "$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)" ]
  grep -q '/.agent-sandbox' "$PROJ/.git/info/exclude"
  # and now the engine honours it
  run_engine -- claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust refuses a file with control characters (nothing can hide a line from the review) and shows non-ASCII escaped" {
  printf '[allow]\npypi.org\n\033[8m[rw]\n/\033[0m\n' >"$PROJ/.agent-sandbox" # an ESC sequence would conceal the [rw] line
  run_trust 'y\n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"control characters"* && "$output" == *"not approved"* ]]
  [ ! -d "$CFG/trust" ] || [ -z "$(ls -A "$CFG/trust")" ]
  trust "$PROJ" # even a hash recorded by other means does not get such a file honoured
  run_engine -- claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
  printf '[allow]\npypi.org\r\n' >"$PROJ/.agent-sandbox" # a carriage return counts
  run_trust 'y\n'
  [ "$status" -eq 1 ] && [[ "$output" == *"control characters"* ]]
  printf '[allow]\npypi.org   # n\303\244ide\n' >"$PROJ/.agent-sandbox" # UTF-8 in a comment: shown escaped, accepted
  run_trust 'y\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *'M-CM-$'* && "$output" == *"approved."* ]]
  run_engine -- claude --version
  [ "$status" -eq 0 ] && [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust declined records nothing" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not approved"* ]]
  [ ! -d "$CFG/trust" ] || [ -z "$(ls -A "$CFG/trust")" ]
}
