#!/usr/bin/env bats
# The per-project .agent-sandbox file: parsing, the trust gate, and how it
# feeds --allow and [share-memory]. Stub bwrap, so these assert on the argv and
# the engine's messages, never a real sandbox.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  # Claude Code's scheme: every character outside [A-Za-z0-9-] becomes "-",
  # one for one (see _claude_project_slug and probes/slug-probe.sh).
  # shellcheck disable=SC2329 # called from the tests below
  slug() { printf '%s' "$1" | sed 's:[^A-Za-z0-9-]:-:g'; }
  C="$H/home/.claude"
  SBOX="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
}

# A store's name: the path with "/" for "_", as the engine's _as_iso_slug.
slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
# The role's own store of every project's state (#196). The harness runs `shared`, where
# memory is your native memory, bound back inside it.
projects_own() { printf '%s/projects/own/%s' "${1:-$SBOX}" "$(slugify "$C/projects")"; }

# Run `--trust` from inside the project, feeding $1 as the prompt answers.
run_trust() {
  local answers="$1"
  engine_cmd
  run bash -c '
    cd "$2" || exit 99
    printf "%b" "$3" | env -i HOME="$1/home" PATH="$1/bin:/usr/bin:/bin" USER=tester \
      AGENT_SANDBOX_SESSION_BASE="$1/base" "${@:4}" --profile claude --trust
  ' _ "$H" "$PROJ" "$answers" "${ENGINE_CMD[@]}"
}

# Run `--apply ARGS...` from inside the project, feeding $1 as the prompt answers; `-`
# for none at all (stdin closed).
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
    if [ "$a" = - ]; then exec <&-; else exec < <(printf "%b" "$a"); fi
    env -i HOME="$h/home" PATH="$h/bin:/usr/bin:/bin" USER=tester \
      AGENT_SANDBOX_SESSION_BASE="$h/base" "${e[@]}" --profile claude --apply "$@"
  ' _ "$H" "$PROJ" "$answers" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

# Record approval of $1/.agent-sandbox the way the engine's --trust would.
trust() {
  local d="$1" t="$CFG/trust"
  mkdir -p "$t"
  sha256sum -- "$d/.agent-sandbox" | cut -d' ' -f1 \
    >"$t/$(printf '%s' "$d" | sha256sum | cut -d' ' -f1)"
}

@test "an unapproved dot-file refuses the launch, naming --trust, and grants nothing (#143)" {
  local other="$H/other-proj" om
  mkdir -p "$other"
  om="$H/home/.claude/projects/$(slug "$other")/memory"
  mkdir -p "$om"
  printf '[allow]\nevil.example\n[share-memory]\n%s\n' "$other" >"$PROJ/.agent-sandbox"
  run_engine -- asb --allow good.example claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  [[ "$output" == *"printf y | asb --trust"* ]] # the way without a terminal
  [[ "$output" != *evil.example* ]]
}

@test "an approved dot-file adds its allow hosts and scopes memory to the current project" {
  printf '# my project policy\n[allow]\npypi.org\n.github.com   # for pip\n[share-memory]\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  mkdir -p "$H/home/.claude/projects/-other/memory"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist:"*"pypi.org"*".github.com"* ]]
  argv_has --bind "$(projects_own)" "$C/projects"
  local mem
  mem="$C/projects/$(slug "$PROJ")/memory"
  argv_has --bind "$mem" "$mem" # this project's memory, bound back
  run ! argv_has --ro-bind "$C/projects/-other/memory" "$C/projects/-other/memory"
  # every project's state is the role's own store before this project's is bound inside it
  [ "$(argv_index "$(projects_own)")" -lt "$(argv_index "$mem")" ]
}

@test "share-memory lists other projects: their memory is bound read-only, the rest stay hidden" {
  local other="$H/other-proj" secret="$H/secret-proj"
  mkdir -p "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$secret")/memory"
  printf '[share-memory]\n%s\n' "$other" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
  run ! argv_has "$H/home/.claude/projects/$(slug "$secret")/memory"
  run ! argv_has --bind "$H/home/.claude/projects/$(slug "$other")/memory" "$H/home/.claude/projects/$(slug "$other")/memory"
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
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$H/space/arrow")/memory" "$H/home/.claude/projects/$(slug "$H/space/arrow")/memory"
  argv_has --ro-bind "$H/home/.claude/projects/$(slug "$H/space/lib")/memory" "$H/home/.claude/projects/$(slug "$H/space/lib")/memory"
  run ! argv_has "$H/home/.claude/projects/$(slug "$H/space/scratch")/memory" # dir exists, no memory
  run ! argv_has "$H/home/.claude/projects/$(slug "$H/space-other")/memory"   # sibling, not under space/
}

@test "a wildcard that matches nothing with memory warns" {
  mkdir -p "$H/empty"
  printf '[share-memory]\n%s/*\n' "$H/empty" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"matched no project with memory"* ]]
  argv_has --bind "$(projects_own)" "$C/projects" # other projects still out of view
}

@test "a share naming this project is dropped, not rebound read-only over its own memory" {
  # the memory must EXIST, or the bind would be skipped for absence and the test
  # would pass without exercising the guard at all
  mkdir -p "$H/home/.claude/projects/$(slug "$PROJ")/memory"
  printf '[share-memory]\n%s\n' "$PROJ" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  # the project stays writable; its memory must not also appear as a read-only bind
  argv_has --bind "$H/home/.claude/projects/$(slug "$PROJ")/memory" "$H/home/.claude/projects/$(slug "$PROJ")/memory" # memory on top of the transcripts store
  run ! argv_has --ro-bind "$H/home/.claude/projects/$(slug "$PROJ")/memory" "$H/home/.claude/projects/$(slug "$PROJ")/memory"
}

@test "a wildcard matching only this project shares nothing and does not warn" {
  mkdir -p "$H/home/.claude/projects/$(slug "$PROJ")/memory"
  printf '[share-memory]\n%s/*\n' "$(dirname "$PROJ")" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"matched no project with memory"* ]] # it did match; it was our own
  run ! argv_has --ro-bind "$H/home/.claude/projects/$(slug "$PROJ")/memory" "$H/home/.claude/projects/$(slug "$PROJ")/memory"
}

@test "an approved dot-file adds declared paths and [env] names to the sandbox" {
  mkdir -p "$H/ro-a" "$H/ro-b" "$H/rw-a"
  printf '[connect]\n%s/ro-a = read-only\n%s/ro-b = read-only\n%s/rw-a = read-write\n[env]\nCUDA_VISIBLE_DEVICES\nMY_TOOL\n' "$H" "$H" "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MY_TOOL=on CUDA_VISIBLE_DEVICES=1 -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/ro-a" "$H/ro-a"
  argv_has --ro-bind "$H/ro-b" "$H/ro-b"
  argv_has --bind "$H/rw-a" "$H/rw-a"
  [ "$(setenv_value MY_TOOL)" = on ]
  [ "$(setenv_value CUDA_VISIBLE_DEVICES)" = 1 ]
}

@test "[env] in a project's file only forwards: a set or a refusal is the profile's, warned of at the review and ignored (#177)" {
  printf '[env]\nMY_TOOL\nPINNED = yes\n-HOME\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MY_TOOL=on -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value MY_TOOL)" = on ]
  run ! setenv_value PINNED
  run_review
  # claude ignores it; the sshd profile, which lets a project set a variable, sets it (#335)
  [[ "$output" == *"[env] PINNED = yes: sets PINNED inside, for every role, under the profile sshd; ignored under claude, where a project's file only forwards"* ]]
  [[ "$output" == *"[env] -HOME: a project's file only forwards"* ]]
}

@test "[env] in a profile's dot-file sets, refuses and forwards; ~ in a value is HOME (#177)" {
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  printf '[env]\nFWD_ME\nPINNED = ~/pinned\n-NOPE\n' >"$H/profiles2/other/agent-sandbox"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" FWD_ME=1 -- agent-sandbox --profile other --exec true
  [ "$status" -eq 0 ]
  [ "$(setenv_value FWD_ME)" = 1 ]
  [ "$(setenv_value PINNED)" = "$H/home/pinned" ]
  # a refused name is not forwarded, whatever asks for it; the launch says so and goes on
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" AGENT_SANDBOX_FORWARD=NOPE NOPE=x -- agent-sandbox --profile other --exec true
  [ "$status" -eq 0 ]
  [[ "$output" == *"not forwarding NOPE"* ]]
  run ! setenv_value NOPE
  # and the claude profile's own: the pins and the refusal it used to set in code
  run_engine -- asb claude --version
  [ "$(setenv_value DISABLE_AUTOUPDATER)" = 1 ]
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/.claude" ]
  run_engine AGENT_SANDBOX_FORWARD=CLAUDE_CODE_PROJECT_DIR_NAME CLAUDE_CODE_PROJECT_DIR_NAME=x -- asb claude --version
  [[ "$output" == *"not forwarding CLAUDE_CODE_PROJECT_DIR_NAME"* ]]
  run ! setenv_value CLAUDE_CODE_PROJECT_DIR_NAME
}

@test "a dot-file path declaration still goes through the secret-store refusal" {
  mkdir -p "$H/home/.aws"
  printf '[connect]\n%s/home/.aws = read-write\n' "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [ ! -s "$H/argv" ]
}

@test "a declaration on the command line and one in the dot-file combine: both paths bind" {
  mkdir -p "$H/env-rw" "$H/file-rw"
  printf '[connect]\n%s/file-rw = read-write\n' "$H" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb --connect "$H/env-rw = read-write" claude --version
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
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
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

@test "[conda] a relative pkgs is the project's, like prefix: bound and in CONDA_PKGS_DIRS absolute" {
  # Reported from a roles project: `pkgs = .asb/scratch/conda-pkgs` reached
  # CONDA_PKGS_DIRS as written, and conda resolved it against its own cwd (the
  # Implementer's clone), giving .asb/scratch/.asb/scratch/conda-pkgs.
  local base="$H/conda"
  local env="$base/envs/proj-env" pkgs="$PROJ/.asb/scratch/conda-pkgs"
  mkdir -p "$env" "$base/pkgs"
  printf '[conda]\nname = proj-env\npkgs = .asb/scratch/conda-pkgs\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  [ -d "$pkgs" ]
  argv_has --bind "$pkgs" "$pkgs"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$pkgs,$base/pkgs" ]
}

@test "[conda] name replaces the shell's active env on PATH, rather than shadowing it" {
  local base="$H/conda"
  local env="$base/envs/proj-env" active="$base/envs/shell-env"
  mkdir -p "$env" "$active" "$base/pkgs"
  printf '[conda]\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  # launched from a shell with shell-env active, the way conda leaves PATH
  run_engine CONDA_PREFIX="$active" CONDA_DEFAULT_ENV=shell-env CONDA_SHLVL=1 \
    PATH="$active/bin:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = "proj-env" ]
  # swapped in place: the pinned env's bin is where the active one was, and the
  # active env is gone rather than merely outranked
  [ "$(setenv_value PATH)" = "$env/bin:$H/bin:/usr/bin:/bin" ]
  [[ "$(setenv_value PATH)" != *"$active/bin"* ]]
  # and it is the pinned env that gets bound (read-only: write mode is off here)
  argv_has --ro-bind "$env" "$env"
  run ! argv_has --ro-bind "$active" "$active"

  # The case that actually bit: launched from conda's BASE env, where
  # CONDA_PREFIX is the base itself and PATH carries <base>/bin, not an
  # <base>/envs/<name>/bin. The base's bin must give way to the pinned env too,
  # or the dot-file's env is bound but none of its tools are on PATH.
  mkdir -p "$base/bin"
  run_engine CONDA_PREFIX="$base" CONDA_DEFAULT_ENV=base CONDA_SHLVL=1 \
    PATH="$base/bin:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value PATH)" = "$env/bin:$H/bin:/usr/bin:/bin" ]
  [[ "$(setenv_value PATH)" != *"$base/bin:"* ]]
}

@test "[conda] prefix not built yet, no env active: the conda base is bound read-only, so it can be created there" {
  # The ey case: a shell with MAMBA_ROOT_PREFIX and no active env (CONDA_PREFIX
  # empty) launched a role whose prefix was an empty directory -- and found no conda.
  local base="$H/conda" pre="$PROJ/envs/x" pkgs="$H/home/.cache/agent-sandbox/conda-pkgs"
  mkdir -p "$base/condabin" "$base/pkgs" "$pre"
  printf '#!/bin/sh\n' >"$base/condabin/conda"
  chmod +x "$base/condabin/conda"
  printf '[conda]\nprefix = envs/x\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"conda prefix 'envs/x' is not a conda env yet (no conda-meta/ in $pre): the conda base $base is bound read-only, so it can be created there"* ]]
  argv_has --ro-bind "$base" "$base"
  argv_has --bind "$pkgs" "$pkgs"
  argv_has --tmpfs "$H/home/.conda"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$pkgs,$base/pkgs" ]
  [ "$(setenv_value MAMBA_ROOT_PREFIX)" = "$base" ]
  [ "$(setenv_value PATH)" = "$base/condabin:$H/bin:/usr/bin:/bin" ]
  run ! setenv_value CONDA_PREFIX # no env is active, none is bound
  run ! argv_has --ro-bind "$pre" "$pre"
  # condabin already on PATH (a shell that ran conda's hook): not added twice
  run_engine MAMBA_ROOT_PREFIX="$base" PATH="$H/bin:$base/condabin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value PATH)" = "$H/bin:$base/condabin:/usr/bin:/bin" ]
  # no root-prefix variable at all: the base from `conda info --base`, conda on PATH
  # shellcheck disable=SC2016 # $1 $2 are the stub's own arguments
  printf '#!/bin/sh\n[ "$1 $2" = "info --base" ] && echo %s\n' "$base" >"$H/bin/conda"
  chmod +x "$H/bin/conda"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"the conda base $base is bound read-only, so it can be created there"* ]]
  argv_has --ro-bind "$base" "$base"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$pkgs,$base/pkgs" ]
  run ! setenv_value MAMBA_ROOT_PREFIX
  # a name that is not under the base: the base too, so conda runs
  printf '[conda]\nname = nope\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"conda env 'nope' not found under $base/envs: the conda base $base is bound read-only, so conda runs"* ]]
  argv_has --ro-bind "$base" "$base"
}

# agent-sandbox's own micromamba, as install.sh leaves it in the fake HOME: the binary
# (a stub: the engine only binds its directory) and the empty conda root.
fake_micromamba() {
  MM="$H/home/.local/share/agent-sandbox/micromamba/bin"
  ROOT="$H/home/.local/share/agent-sandbox/conda"
  mkdir -p "$MM" "$ROOT"
  printf '#!/bin/sh\n' >"$MM/micromamba"
  chmod +x "$MM/micromamba"
}

# No conda base on the host -- and a CI runner has conda on PATH, so these stubs find none.
no_host_conda() {
  printf '#!/bin/sh\nexit 1\n' >"$H/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$H/bin/mamba"
  chmod +x "$H/bin/conda" "$H/bin/mamba"
}

@test "[conda] no conda on the host and no choice made: agent-sandbox's micromamba, and a refusal naming install.sh when it is not installed" {
  local pre="$PROJ/envs/x"
  mkdir -p "$pre"
  no_host_conda
  printf '[conda]\nprefix = envs/x\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"conda base = sandbox (default: no conda on this host), but agent-sandbox's micromamba is not installed ($H/home/.local/share/agent-sandbox/micromamba/bin/micromamba):"* ]]
  [[ "$output" == *"run install.sh, which installs it"* ]]
  fake_micromamba
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"conda prefix 'envs/x' is not a conda env yet (no conda-meta/ in $pre): agent-sandbox's conda root $ROOT is bound read-only, so it can be created there"* ]]
  argv_has --ro-bind "$ROOT" "$ROOT"
  argv_has --ro-bind "$MM" "$MM"
  [ "$(setenv_value MAMBA_ROOT_PREFIX)" = "$ROOT" ]
  [ "$(setenv_value PATH)" = "$MM:$H/bin:/usr/bin:/bin" ]
}

@test "[conda] base = sandbox: micromamba and its root read-only, the env under the root, and nothing of the host's conda" {
  fake_micromamba
  local base="$H/conda" active="$H/conda/envs/shell-env" env="$ROOT/envs/proj-env"
  local pkgs="$H/home/.cache/agent-sandbox/conda-pkgs"
  mkdir -p "$base/pkgs" "$active/bin" "$env/conda-meta"
  printf '[conda]\nbase = sandbox\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  # launched from a shell with a host env active, the way conda leaves it
  run_engine MAMBA_ROOT_PREFIX="$base" CONDA_PREFIX="$active" CONDA_DEFAULT_ENV=shell-env CONDA_SHLVL=1 \
    PATH="$active/bin:$base/condabin:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"using conda env 'proj-env' from .agent-sandbox"* ]]
  argv_has --ro-bind "$ROOT" "$ROOT"
  argv_has --ro-bind "$MM" "$MM"
  argv_has --ro-bind "$env" "$env" # read-only: write is off
  # the root before the env inside it, or the root's bind would hide the env's
  [ "$(argv_index "$ROOT")" -lt "$(argv_index "$env")" ]
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = proj-env ]
  [ "$(setenv_value MAMBA_ROOT_PREFIX)" = "$ROOT" ]
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$pkgs" ]
  # micromamba first, the env's bin where the host's active env was
  [ "$(setenv_value PATH)" = "$MM:$env/bin:$H/bin:/usr/bin:/bin" ]
  # the host's conda: not bound, not named
  run ! grep -qF "$base" "$H/argv"
  run ! setenv_value CONDA_SHLVL
  # write = 1 makes the env read-write, as under the host's conda
  printf '[conda]\nbase = sandbox\nname = proj-env\nwrite = 1\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$env" "$env"
  # an env active in the shell and none named: the host's env stays outside, micromamba is in
  printf '[conda]\nbase = sandbox\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" CONDA_PREFIX="$active" CONDA_DEFAULT_ENV=shell-env \
    PATH="$active/bin:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$ROOT" "$ROOT"
  argv_has --ro-bind "$MM" "$MM"
  run ! grep -qF "$base" "$H/argv"
  run ! setenv_value CONDA_PREFIX
  [ "$(setenv_value PATH)" = "$MM:$H/bin:/usr/bin:/bin" ]
}

@test "[conda] base: the shell's AGENT_SANDBOX_CONDA_BASE wins, the file's default is install.sh's answer, host with no conda falls back" {
  fake_micromamba
  local base="$H/conda"
  mkdir -p "$base/envs/proj-env" "$ROOT/envs/proj-env"
  printf '[conda]\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  # no file, a host base: the host's, as before
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$base" "$base"
  [ "$(setenv_value CONDA_PREFIX)" = "$base/envs/proj-env" ]
  run ! argv_has --ro-bind "$MM" "$MM"
  # the global file says sandbox
  mkdir -p "$CFG"
  echo sandbox >"$CFG/conda"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$ROOT/envs/proj-env" ]
  argv_has --ro-bind "$MM" "$MM"
  run ! argv_has --ro-bind "$base" "$base"
  # the shell's variable wins over the file
  run_engine MAMBA_ROOT_PREFIX="$base" AGENT_SANDBOX_CONDA_BASE=host -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$base/envs/proj-env" ]
  run ! argv_has --ro-bind "$MM" "$MM"
  # the dot-file's base wins over the file, and the shell's over the dot-file
  echo host >"$CFG/conda"
  printf '[conda]\nbase = sandbox\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$(setenv_value CONDA_PREFIX)" = "$ROOT/envs/proj-env" ]
  run_engine MAMBA_ROOT_PREFIX="$base" AGENT_SANDBOX_CONDA_BASE=host -- asb claude --version
  [ "$(setenv_value CONDA_PREFIX)" = "$base/envs/proj-env" ]
  # host, but the host has no conda: said, and the sandbox's is used
  printf '[conda]\nbase = host\nname = proj-env\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  no_host_conda
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[conda] base says host, but this host has no conda"*"agent-sandbox's micromamba is used"* ]]
  [ "$(setenv_value CONDA_PREFIX)" = "$ROOT/envs/proj-env" ]
}

@test "[conda:<glob>] base = sandbox applies to that role only" {
  fake_micromamba
  local base="$H/conda"
  mkdir -p "$base/envs/proj-env" "$ROOT/envs/proj-env"
  printf '[conda]\nname = proj-env\n[conda:gh-*]\nbase = sandbox\n[conda:default]\nbase = host\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --role gh-fix-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$ROOT/envs/proj-env" ]
  argv_has --ro-bind "$MM" "$MM"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$base/envs/proj-env" ]
  run ! argv_has --ro-bind "$MM" "$MM"
}

@test "--check names whose conda a role gets" {
  fake_micromamba
  local base="$H/conda"
  mkdir -p "$base/envs"
  printf '[conda]\nbase = sandbox\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"conda: agent-sandbox's micromamba, root ~/.local/share/agent-sandbox/conda -- [conda] base"* ]]
  rm "$MM/micromamba"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --check
  [[ "$output" == *"root ~/.local/share/agent-sandbox/conda (NOT INSTALLED: a launch with conda refuses; run install.sh)"* ]]
  printf '[conda]\nbase = host\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"conda: the host's at $base (conda) -- [conda] base"* ]]
}

@test "[net] mode from an approved dot-file selects the network mode; AGENT_SANDBOX_NET wins; unknown values are ignored and unapproved files refused" {
  printf '[net]\nmode = none\n' >"$PROJ/.agent-sandbox"
  run_engine -- asb claude --version # not yet approved: refused, nothing applied
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"using network mode 'none' from .agent-sandbox"* ]]
  run ! argv_has --share-net
  run ! setenv_value HTTPS_PROXY
  run_engine AGENT_SANDBOX_NET=proxy -- asb claude --version # the shell's knob wins
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENT_SANDBOX_NET=proxy overrides the .agent-sandbox network mode 'none'"* ]]
  argv_has --share-net
  [[ "$(setenv_value HTTPS_PROXY)" =~ ^http://[0-9a-f]{32}:x@127\.0\.0\.1:8888$ ]]
  printf '[net]\nmode = bogus\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$(setenv_value HTTPS_PROXY)" =~ ^http://[0-9a-f]{32}:x@127\.0\.0\.1:8888$ ]]
  [[ "$output" != *"unknown"* ]]
  run_review
  [[ "$output" == *"[net] mode 'bogus' unknown"* ]]
}

@test "[proxy-ca], [profile-dir] and [session-base] are refused in the dot-file" {
  printf '[proxy-ca]\n/tmp/x.pem\n[profile-dir]\n/tmp\n[session-base]\n/tmp\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --share-net
  [[ "$(setenv_value HTTPS_PROXY)" =~ ^http://[0-9a-f]{32}:x@127\.0\.0\.1:8888$ ]] # still proxied
  run_review
  [[ "$output" == *"[proxy-ca] is not allowed here"* ]]
  [[ "$output" == *"[profile-dir] is not allowed here"* ]]
  [[ "$output" == *"[session-base] is not allowed here"* ]]
}

@test "editing an approved dot-file refuses to launch until it is re-reviewed; the edit never applies unreviewed" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  printf '[allow]\npypi.org\nevil.example\n' >"$PROJ/.agent-sandbox" # the agent could do this
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has changed since you approved it"*"--trust"* ]]
  [[ "$output" != *"allowlist:"*evil.example* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
  run_trust 'y\n'    # the user reviews the new content and approves it
  [ "$status" -eq 0 ]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist:"*"evil.example"* ]]
}

@test "deleting an approved dot-file refuses to launch (the defaults could be wider); --trust can forget the approval" {
  local other="$H/other-proj" om
  mkdir -p "$other"
  om="$H/home/.claude/projects/$(slug "$other")/memory"
  mkdir -p "$om"
  # a policy that DIFFERS from the default, so "the dot-file applied" and "the
  # default applied" stay distinguishable: it shares another project's memory
  printf '[share-memory]\n%s\n' "$other" >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(projects_own)" "$C/projects"
  argv_has --ro-bind "$om" "$om" # the approved share is granted
  rm "$PROJ/.agent-sandbox"      # the agent could do this; falling back to defaults must not be silent
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"approved .agent-sandbox is missing"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  run_trust 'n\n' # keep the approval: still refused
  [ "$status" -eq 0 ]
  [[ "$output" == *"one was approved earlier"*"kept"* ]]
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  run_trust 'y\n' # forget it: the defaults apply again, knowingly
  [ "$status" -eq 0 ]
  [[ "$output" == *"approval forgotten"* ]]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  # the defaults apply again, knowingly: other projects still out of view, since that
  # is the default, but the share the dot-file used to grant is gone
  argv_has --bind "$(projects_own)" "$C/projects"
  run ! argv_has --ro-bind "$om" "$om"
}

@test "a dot-file that widens the sandbox says so at its review: the network open, seccomp off" {
  printf '[net]\nmode = open\n[seccomp]\nmode = off\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"network mode 'open': the egress allowlist is off"*"approve this"* ]]
  [[ "$output" == *"seccomp mode 'off': the default-deny syscall filter is off"*"approve this"* ]]
  trust "$PROJ"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb claude --version # approved: the launch does not repeat it
  [ "$status" -eq 0 ]
  [[ "$output" != *"is off for this project"* ]]
  # a mode that narrows is routine, and quiet (seccomp `on` is not tried here: the
  # harness has no compiled filter, and asking for one without it refuses)
  printf '[net]\nmode = none\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"using network mode"* ]]
}

@test "[seccomp] mode: an approved file turns the filter on; the shell knob wins; unapproved grants nothing" {
  local SC="$H/seccomp"
  mkdir -p "$SC"
  printf 'not-a-real-bpf' >"$SC/$(uname -m).bpf"
  printf '[seccomp]\nmode = on\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  [[ "$output" == *"using seccomp mode 'on' from .agent-sandbox"* ]]
  # an explicit knob in the launching shell wins, as it does for [net] mode
  run_engine AGENT_SANDBOX_SECCOMP=off AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"overrides the .agent-sandbox seccomp mode 'on'"* ]]
  run ! argv_has --seccomp
  # ...and without approval the file asks for nothing: a file never approved refuses
  # the launch (#143), so its `mode = off` never takes the filter away.
  printf '[seccomp]\nmode = off\n' >"$PROJ/.agent-sandbox"
  rm -f "$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"*
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  [[ "$output" != *"using seccomp mode 'off' from .agent-sandbox"* ]]
}

@test "[seccomp] mode: off is accepted; an unknown value or a malformed line is reported and leaves the default on" {
  local SC="$H/seccomp"
  mkdir -p "$SC"
  printf 'not-a-real-bpf' >"$SC/$(uname -m).bpf"
  printf '[seccomp]\nmode = off\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 0 ]
  # ...and the engine says it took the value from the file. The filter is on by
  # default, so its absence here is already the file's doing; the message is
  # what proves WHICH line did it rather than some other path to the same argv.
  [[ "$output" == *"using seccomp mode 'off' from .agent-sandbox"* ]]
  run ! argv_has --seccomp
  printf '[seccomp]\nmode = default\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 0 ] # ignored, not fatal: the file is data, the launch goes on
  # "ignored" means the built-in default stands, and that default is ON. A
  # malformed line must not read as `off` -- that would be a project file
  # switching the filter off by being wrong, the one outcome nobody asked for.
  argv_has --seccomp 10
  run_review
  [[ "$output" == *"[seccomp] mode 'default' unknown (on|off)"* ]]
  printf '[seccomp]\non\n' >"$PROJ/.agent-sandbox" # a list line, not key = value
  trust "$PROJ"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  run_review
  [[ "$output" == *"[seccomp] expects 'key = value'"* ]]
  printf '[seccomp]\nprofile = paranoid\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- asb claude --version
  argv_has --seccomp 10
  run_review
  [[ "$output" == *"unknown [seccomp] key 'profile'"* ]]
}

@test "an all entry keeps every project's state in view: projects = read-write" {
  printf '[share-memory]\nall\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$(projects_own)" "$H/argv"
  # and a project's own [connect] overrides the sugar
  printf '[share-memory]\nall\n[connect]\nprojects = own\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(projects_own)" "$C/projects"
}

@test "other projects are out of view with no dot-file present; unknown sections warn at the review" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(projects_own)" "$C/projects"
  # parsing feedback
  printf '[allow]\nok.example\n[bogus]\nx\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb claude --version
  [[ "$output" != *"[bogus]"* ]]
  run_review
  [[ "$output" == *"unknown section [bogus]"* ]]
}

# The constraints the broker loaded the key with: the `-h` arguments ssh-add was given.
ssh_constraints() { grep -A1 -x -- -h "$H/ssh-add.log" | grep -vx -e -h -e -- | sort | paste -sd' '; }

@test "[ssh]: an approved file's hosts reach the broker with --ssh's, one list; a bad host is said at the review and ignored" {
  make_ssh_stubs
  printf '[ssh]\ngithub.com\ngit@gitlab.example\nmy-alias\n-oProxyCommand=x\ntwo words\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[ssh] github.com: SSH to it as you, signed with your key through the broker, for every role"*"approve this"* ]]
  [[ "$output" == *"[ssh] git@gitlab.example: SSH to it as you"* ]]
  [[ "$output" == *"[ssh] bad host '-oProxyCommand=x'"*"; ignoring"* ]]
  [[ "$output" == *"[ssh] bad host 'two words'"* ]]
  run_engine -- asb claude --version # not approved: refused, and no agent started
  [ "$status" -ne 0 ]
  [ ! -s "$H/ssh-add.log" ]
  trust "$PROJ"
  run_engine -- asb --ssh flag.example claude --version
  [ "$status" -eq 0 ]
  [ "$(ssh_constraints)" = "flag.example git@gitlab.example github.com my-alias" ]
  sock="$(setenv_value SSH_AUTH_SOCK)"
  [[ "$sock" == */agent.sock ]] && argv_has --bind "$sock" "$sock"
  run ! grep -q ProxyCommand "$H/ssh-add.log"
  # a host both name is constrained once
  : >"$H/ssh-add.log"
  run_engine -- asb --ssh github.com claude --version
  [ "$(ssh_constraints)" = "git@gitlab.example github.com my-alias" ]
  # --ssh-key and --ssh-timeout apply to the file's hosts: they are the launch's
  : >"$H/ssh-add.log"
  : >"$H/other-key"
  run_engine -- asb --ssh-key "$H/other-key" --ssh-timeout 5m claude --version
  [ "$status" -eq 0 ]
  grep -qx -- "$H/other-key" "$H/ssh-add.log"
  grep -qx -- 5m "$H/ssh-add.log"
}

@test "[ssh]: no file, no flag, no broker; --ssh-unrestricted wins over the file's hosts, and says so" {
  make_ssh_stubs
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -s "$H/ssh-add.log" ]
  run ! argv_has --setenv SSH_AUTH_SOCK
  printf '[ssh]\ngithub.com\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb --ssh-unrestricted claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ssh-unrestricted: the key is loaded without a constraint, so the .agent-sandbox [ssh] hosts (github.com) are reachable with the rest"* ]]
  [ -s "$H/ssh-add.log" ]
  [ -z "$(ssh_constraints)" ]
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
  run_engine -- asb claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust never appends through a link a sandbox left in the repository: .git/info/exclude, .git/info or .git a symlink is said, and its target unchanged" {
  git init -q "$PROJ"
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  printf 'KEEP\n' >"$H/outside"
  rm -f "$PROJ/.git/info/exclude"
  ln -s "$H/outside" "$PROJ/.git/info/exclude"
  run_trust 'y\ny'
  [ "$(cat "$H/outside")" = KEEP ]
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* && "$output" == *"$PROJ/.git/info/exclude is a symlink; .agent-sandbox is not added to "* ]]
  # the directory a link: the same
  rm -rf "$PROJ/.git/info" "$CFG/trust"
  mkdir -p "$H/outdir"
  ln -s "$H/outdir" "$PROJ/.git/info"
  run_trust 'y\ny'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJ/.git/info is a symlink"* ]]
  [ ! -e "$H/outdir/exclude" ]
  # .git itself a link, to a repository outside: the same
  rm -rf "$PROJ/.git" "$CFG/trust"
  git init -q "$H/outrepo"
  printf 'KEEP\n' >"$H/outrepo/.git/info/exclude"
  ln -s "$H/outrepo/.git" "$PROJ/.git"
  run_trust 'y\ny'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJ/.git is a symlink"* ]]
  [ "$(cat "$H/outrepo/.git/info/exclude")" = KEEP ]
}

@test "--trust makes no git-ignore offer for a file the repository tracks" {
  git init -q "$PROJ"
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  git -C "$PROJ" add .agent-sandbox
  git -C "$PROJ" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm x
  run_trust 'y\ny' # a second answer: an offer that came back would append the line
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* ]]
  [[ "$output" != *"info/exclude"* ]] # the offer names the file it would append to
  [ ! -f "$PROJ/.git/info/exclude" ] || ! grep -qx '/.agent-sandbox' "$PROJ/.git/info/exclude"
  run_engine -- asb claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust refuses a file with control characters (nothing can hide a line from the review) and shows non-ASCII escaped" {
  printf '[allow]\npypi.org\n\033[8m[rw]\n/\033[0m\n' >"$PROJ/.agent-sandbox" # an ESC sequence would conceal the [rw] line
  run_trust 'y\n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"control characters"* && "$output" == *"not approved"* ]]
  [ ! -d "$CFG/trust" ] || [ -z "$(ls -A "$CFG/trust")" ]
  trust "$PROJ" # even a hash recorded by other means does not get such a file honoured
  run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
  printf '[allow]\npypi.org\r\n' >"$PROJ/.agent-sandbox" # a carriage return counts
  run_trust 'y\n'
  [ "$status" -eq 1 ] && [[ "$output" == *"control characters"* ]]
  printf '[allow]\npypi.org   # n\303\244ide\n' >"$PROJ/.agent-sandbox" # UTF-8 in a comment: shown escaped, accepted
  run_trust 'y\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *'M-CM-$'* && "$output" == *"approved."* ]]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ] && [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--trust declined records nothing" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not approved"* ]]
  [ ! -d "$CFG/trust" ] || [ -z "$(ls -A "$CFG/trust")" ]
}

@test "--apply creates a missing file with the section and the line, then runs --trust's review" {
  run_apply 'y\n' '[allow]' pypi.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to [allow]: pypi.org"* && "$output" == *"created $PROJ/.agent-sandbox"* ]]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[allow]\npypi.org' ]
  [[ "$output" == *"approve this .agent-sandbox"*"approved."* ]]
  [[ "$output" == *"the change applies at the next launch of every role"* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
  [ -f "$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)" ]
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "--apply appends only the missing lines at the end of their section, the rest byte-identical, and the review shows the diff" {
  printf '# policy\n[allow]\npypi.org   # pip\n\n# what is denied\n[deny]\nevil.example\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\n'
  [ "$status" -eq 0 ]
  run_apply 'y\n' '[allow]' pypi.org github.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in [allow]: pypi.org"* && "$output" == *"added to [allow]: github.com"* ]]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'# policy\n[allow]\npypi.org   # pip\ngithub.com\n\n# what is denied\n[deny]\nevil.example' ]
  [[ "$output" == *"has changed since you approved it"*$'\n+github.com\n'*"approved."* ]]
  run_engine -- asb claude --version
  [[ "$output" == *"session allowlist: pypi.org github.com"* ]]
}

@test "--apply adds an absent section at the end of the file, after a blank line" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_apply 'y\n' '[deny]' evil.example
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[allow]\npypi.org\n\n[deny]\nevil.example' ]
  [[ "$output" == *"approved."* ]]
}

@test "--apply a second time adds nothing and, approved as it stands, asks nothing" {
  run_apply 'y\n' '[allow]' pypi.org
  [ "$status" -eq 0 ]
  local before
  before="$(cat "$PROJ/.agent-sandbox")"
  run_apply - '[allow]' '  pypi.org  # again'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in [allow]: pypi.org"* && "$output" == *"nothing to add"* ]]
  [[ "$output" == *"already approved"* && "$output" != *"approve this"* ]]
  [ "$(cat "$PROJ/.agent-sandbox")" = "$before" ]
}

@test "--apply declined keeps the edit in the file, unapproved, and says so" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\n'
  run_apply 'n\n' '[allow]' github.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"not approved"* && "$output" == *"stays in .agent-sandbox, unapproved"* ]]
  grep -qx github.com "$PROJ/.agent-sandbox"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
}

@test "--apply warns at a file's first role section, and goes on to the review" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_apply 'y\n' '[allow:gh-setup]' x.org
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning — [allow:gh-setup] is this file's first role section"*"[connect:*]"* ]]
  [[ "$output" == *"approved."* && "$output" == *"the roles matching 'gh-setup'"* ]]
  run_apply 'y\n' '[allow:gh-*]' y.org # a second role section is not the first
  [ "$status" -eq 0 ]
  [[ "$output" != *"first role section"* ]]
}

@test "--apply adds a [permissions:ROLE] rule, and the review names it" {
  printf '[connect:gate]\n' >"$PROJ/.agent-sandbox"
  run_apply 'y\n' '[permissions:gate]' 'Bash(git push:*)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[permissions:gate] Bash(git push:*): a permission rule the agent gets without asking you, for the roles gate"* ]]
  [[ "$output" == *"approved."* ]]
  grep -A1 -xF '[permissions:gate]' "$PROJ/.agent-sandbox" | grep -qxF 'Bash(git push:*)'
}

@test "--apply refuses an unknown section, a suffix the section does not take, and fewer than two words" {
  run_apply - '[bogus]' x
  [ "$status" -eq 2 ]
  [[ "$output" == *"[bogus] is not a section of .agent-sandbox"*"[allow]"*"[connect]"*"[claude]"* ]]
  run_apply - '[seccomp:r]' 'mode = off'
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not take a role suffix"* ]]
  run_apply - allow x
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a section header"* ]]
  run_apply - '[allow]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply needs a section and a line"* ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
}

@test "--apply runs on the host: inside a sandbox it is refused, and the file is untouched" {
  # Inside is pid 1 being bubblewrap (_as_inside_sandbox), which a unit test cannot
  # arrange; the engine is sourced and that one test answered yes.
  # shellcheck disable=SC2016 # expanded by the inner bash
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" bash -c '
    cd "$1" && source "$2" && _as_inside_sandbox() { return 0; } && agent_sandbox --apply "[allow]" x.org
  ' _ "$PROJ" "$ENGINE" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"--apply runs on the host"* ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
}

@test "--apply never writes through a link a sandbox left in the project: the old fixed temp name .agent-sandbox.apply.tmp pointing outside is left as it is, its target unchanged" {
  # A role with the project read-write can leave any name there; --apply runs on the host.
  printf '[allow]\npypi.org\n\n[deny]\nevil.example\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\n'
  printf 'KEEP\n' >"$H/outside"
  ln -s "$H/outside" "$PROJ/.agent-sandbox.apply.tmp"
  run_apply 'y\n' '[allow]' github.com
  [ "$status" -eq 0 ]
  [ "$(cat "$H/outside")" = KEEP ]
  [ -L "$PROJ/.agent-sandbox.apply.tmp" ]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[allow]\npypi.org\ngithub.com\n\n[deny]\nevil.example' ]
  [[ "$output" == *"approved."* ]]
  # no temp of its own left behind
  [ "$(find "$PROJ" -maxdepth 1 -name '.agent-sandbox.?*' | wc -l)" -eq 1 ]
}

@test "--apply that cannot write the file fails and leaves no temp behind" {
  [ "$(id -u)" -ne 0 ] || skip "root writes a file of mode 444"
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  chmod 444 "$PROJ/.agent-sandbox" # the file is written in place (#389): its mode is what refuses
  run_apply - '[allow]' github.com
  chmod 644 "$PROJ/.agent-sandbox"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-sandbox: $PROJ/.agent-sandbox could not be written: it is not writable (mode 444); nothing was written"* ]]
  [[ "$output" != *"added to [allow]"* ]] # said only once the file has it
  [[ "$output" != *"dd:"* ]]              # refused before any write
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[allow]\npypi.org' ]
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agent-sandbox.?*')" ]
  # a new file in a directory that refuses it: nothing made, no temp
  rm "$PROJ/.agent-sandbox"
  chmod 555 "$PROJ"
  run_apply - '[allow]' github.com
  chmod 755 "$PROJ"
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/.agent-sandbox" ]
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agent-sandbox.?*')" ]
}

@test "--apply writes an existing file in place: the same inode, its mode kept, so a running sandbox's read-only bind of it holds (#389)" {
  printf '[allow]\npypi.org\n\n[deny]\nevil.example\n' >"$PROJ/.agent-sandbox"
  chmod 640 "$PROJ/.agent-sandbox"
  local ino
  ino="$(stat -c %i "$PROJ/.agent-sandbox")"
  run_apply 'y\n' '[allow]' github.com
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[allow]\npypi.org\ngithub.com\n\n[deny]\nevil.example' ]
  [ "$(stat -c %i "$PROJ/.agent-sandbox")" = "$ino" ]
  [ "$(stat -c %a "$PROJ/.agent-sandbox")" = 640 ]
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agent-sandbox.?*')" ] # no temp beside it
}

@test "_as_dotfile_write: an existing file in place, cut to the new text; a new file made; a link replaced, its target untouched (#389)" {
  source_engine
  local d="$H/wr" ino
  mkdir -p "$d"
  printf 'a much longer old text\nwith two lines\n' >"$d/.agent-sandbox"
  ino="$(stat -c %i "$d/.agent-sandbox")"
  printf 'new\n' | _as_dotfile_write "$d/.agent-sandbox"
  [ "$(stat -c %i "$d/.agent-sandbox")" = "$ino" ]
  [ "$(od -An -c "$d/.agent-sandbox" | tr -d ' ')" = 'new\n' ] # no tail of the old text
  printf 'grown to a longer text\n' | _as_dotfile_write "$d/.agent-sandbox"
  [ "$(stat -c %i "$d/.agent-sandbox")" = "$ino" ]
  [ "$(cat "$d/.agent-sandbox")" = 'grown to a longer text' ]
  printf 'fresh\n' | _as_dotfile_write "$d/new"
  [ "$(cat "$d/new")" = fresh ]
  [ "$(stat -c %a "$d/new")" = "$(printf '%o' $((0666 & ~0$(umask))))" ]
  printf 'KEEP\n' >"$d/target"
  ln -s "$d/target" "$d/link"
  printf 'policy\n' | _as_dotfile_write "$d/link"
  [ "$(cat "$d/target")" = KEEP ]
  [ ! -L "$d/link" ]
  [ "$(cat "$d/link")" = policy ]
  [ -z "$(find "$d" -name '.agent-sandbox.?*')" ]
}

@test "_as_dotfile_write: a write that fails once begun says the file may be half-written and keeps the intended text in a file it names; a file swapped for a link after the check is not written through (#389)" {
  source_engine
  local d="$H/w f" t # a space in the path: the recovery command quotes it
  mkdir -p "$d"
  printf 'old text\n' >"$d/.agent-sandbox"
  # shellcheck disable=SC2329 # called by _as_dotfile_write, not here
  truncate() { return 1; } # the cut fails after the text is written
  run _as_dotfile_write "$d/.agent-sandbox" < <(printf 'new\n')
  unset -f truncate
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: $d/.agent-sandbox could not be written in full, and may be half-written now. The text it was to have is kept in "* ]]
  t="${output#*is kept in }" t="${t%%: put it*}"
  [ "$(cat "$t")" = new ]
  # the command it prints, run as printed, puts the text in place
  local cmd="${output#*put it in place with  }"
  cmd="${cmd%%  (or restore*}"
  bash -c "$cmd"
  [ "$(cat "$d/.agent-sandbox")" = new ]
  rm -f "$t"
  # shellcheck disable=SC2329 # called by _as_dotfile_write, not here
  dd() { return 1; } # the write itself fails
  run _as_dotfile_write "$d/.agent-sandbox" < <(printf 'other\n')
  unset -f dd
  [ "$status" -eq 1 ]
  [[ "$output" == *"may be half-written now"* ]]
  t="${output#*is kept in }" t="${t%%: put it*}"
  [ "$(cat "$t")" = other ]
  rm -f "$t"
  # a link put at the file between the check and the open: its target is never written
  printf 'old\n' >"$d/.agent-sandbox"
  printf 'KEEP\n' >"$d/target"
  # shellcheck disable=SC2329 # called by _as_dotfile_write, not here
  mktemp() { rm -f "$d/.agent-sandbox" && ln -s "$d/target" "$d/.agent-sandbox" && command mktemp "$@"; }
  run _as_dotfile_write "$d/.agent-sandbox" < <(printf 'evil\n')
  unset -f mktemp
  [ "$status" -eq 1 ]
  [[ "$output" == *"$d/.agent-sandbox became a symbolic link or another file while it was written; nothing was written"* ]]
  [ "$(cat "$d/target")" = KEEP ]
  # ...and one put back as a regular file right after the open, so the path is no link
  # when it is looked at again: the descriptor is not the file's, and nothing is written
  rm -f "$d/.agent-sandbox"
  printf 'old\n' >"$d/.agent-sandbox"
  # shellcheck disable=SC2329 # called by _as_dotfile_write, not here
  mktemp() { rm -f "$d/.agent-sandbox" && ln -s "$d/target" "$d/.agent-sandbox" && command mktemp "$@"; }
  # shellcheck disable=SC2329 # called by _as_dotfile_write, not here
  stat() {
    local r
    r="$(command stat "$@")"
    if [[ -L "$d/.agent-sandbox" ]]; then rm -f "$d/.agent-sandbox" && printf 'back\n' >"$d/.agent-sandbox"; fi
    printf '%s\n' "$r"
  }
  run _as_dotfile_write "$d/.agent-sandbox" < <(printf 'evil\n')
  unset -f mktemp stat
  [ "$status" -eq 1 ]
  [[ "$output" == *"became a symbolic link or another file while it was written; nothing was written"* ]]
  [ "$(cat "$d/target")" = KEEP ]
  [ "$(cat "$d/.agent-sandbox")" = back ]
}

@test "memory scoping uses Claude Code's slug scheme, so a project path with a dot still finds its own state" {
  # The bats temp paths have no dots, so the plain "/"-only rule passed for years
  # while being wrong. A project directory with characters Claude Code converts
  # is the case that matters: get the slug wrong and the engine binds a directory
  # that does not exist, leaving the project's own memory and transcripts hidden.
  local proj="$H/proj.x+y"
  mkdir -p "$proj"
  printf '[share-memory]\n' >"$proj/.agent-sandbox"
  trust "$proj"
  local real s wrong
  real="$(cd "$proj" && pwd -P)"
  s="$(slug "$real")"
  [[ "$s" != *.* && "$s" != *+* ]] # the slug itself converts . and +
  [[ "$s" == *"-proj-x-y" ]]
  wrong="${real//\//-}" # what the old "/"-only rule produced
  [[ "$wrong" == *.* ]] # and that one still carries the dot
  RUN_CWD="$proj" run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local sbox="$H/home/.local/state/agent-sandbox/claude/${real//[^A-Za-z0-9-]/-}/default"
  argv_has --bind "$(projects_own "$sbox")" "$C/projects"
  argv_has --bind "$C/projects/$s/memory" "$C/projects/$s/memory" # the channel's path is this slug's
  run ! grep -qF "$C/projects/$wrong" "$H/argv"
}

@test "the review prints each [gpu] devices list as written, per section, refuses an entry outside /dev/ or with '..', and notes CUDA's driver nodes (#335)" {
  printf '%s\n' '[gpu]' 'devices = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1' \
    '[gpu:impl-*]' 'devices = /dev/nvidia0 /etc/passwd /dev/../etc/shadow' \
    '[gpu:rev]' 'devices = /dev/nvidia*' '[gpu:none]' 'devices =' >"$PROJ/.agent-sandbox"
  run_trust 'n\nn\n'
  [[ "$output" == *"agent-sandbox: .agent-sandbox: [gpu] devices: only these GPU device nodes are passed in, for every role, in place of the default list: /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1"* ]]
  [[ "$output" == *"agent-sandbox: .agent-sandbox: [gpu:impl-*] devices '/etc/passwd': not a node under /dev/; ignoring it"* ]]
  [[ "$output" == *"agent-sandbox: .agent-sandbox: [gpu:impl-*] devices '/dev/../etc/shadow': a '..' component; ignoring it"* ]]
  [[ "$output" == *"agent-sandbox: .agent-sandbox: [gpu:impl-*] devices: only these GPU device nodes are passed in, for the roles impl-*, in place of the default list: /dev/nvidia0"$'\n'* ]]
  [[ "$output" == *"agent-sandbox: .agent-sandbox: [gpu:impl-*] devices names an NVIDIA card without /dev/nvidiactl /dev/nvidia-uvm: CUDA needs /dev/nvidiactl and /dev/nvidia-uvm (and /dev/nvidia-uvm-tools) as well"* ]]
  [[ "$output" == *"[gpu:rev] devices: only these GPU device nodes are passed in, for the roles rev, in place of the default list: /dev/nvidia*"* ]]
  [[ "$output" == *"[gpu:none] devices: no GPU device node is passed in, for the roles none"* ]]
  # the card is listed with its driver nodes ([gpu]), or a glob that names them ([gpu:rev]): no note
  [ "$(grep -c 'CUDA needs' <<<"$output")" -eq 1 ]
}

@test "--check prints the GPU nodes a launch binds, and the [gpu] devices list as written with its source (#335)" {
  printf '[gpu]\ndevices = /dev/null /dev/nvidia-absent-335\n[gpu:impl]\ndevices = /dev/zero\n[gpu:default]\nmode = on\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  gpu: on -- /dev/null\n  gpu devices: /dev/null /dev/nvidia-absent-335 -- [gpu] devices\n'* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role impl 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  gpu: on -- /dev/zero\n  gpu devices: /dev/zero -- [gpu:impl] devices\n'* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_GPU_DEVICES=/dev/full "${@:4}" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  gpu: on -- /dev/full\n  gpu devices: /dev/full -- AGENT_SANDBOX_GPU_DEVICES\n'* ]]
}

# ---- [agent] and [agent:<glob>] (#355) ----

@test "[agent] command: parsed with its section's glob, in file order; the unsuffixed one is every role's (#355)" {
  printf '[agent]\ncommand = claude\n[agent:r]\ncommand = claude --model x\n[agent:q*]\ncommand =\n' >"$PROJ/.agent-sandbox"
  run bash -c '
    source "$1"
    _df_role_globs=() _df_agent=()
    _as_dotfile_parse "$2"
    printf "agent=%s\n" "${_df_agent[@]}"
    printf "glob=%s\n" "${_df_role_globs[@]}"
  ' _ "$ENGINE" "$PROJ/.agent-sandbox"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'agent=*\tcommand\tclaude\nagent=r\tcommand\tclaude --model x\n'* ]]
  [[ "$output" == *"[agent] command names no agent"* ]] # the empty one is said, not kept
  [[ "$output" != *$'agent=q*'* ]]
  # each suffix defines a role, as [sandbox:<glob>] does
  [[ "$output" == *$'glob=r\nglob=q*'* ]]
}

@test "a profile's own dot-file: [agent] is still the profile's section, its keys read; [agent:<glob>] is skipped (#355)" {
  source_engine
  # shellcheck disable=SC2034 # the profile contract, read by _as_profile_dotfile
  local profile=claude profile_base="" profile_base_env="" profile_base_from="" profile_command=claude profile_clear=""
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
  [ "$profile_clear" = /clear ]
  [ "${profile_serve_new[*]}" = "-p --session-id {id} --permission-mode bypassPermissions" ]
  # a suffixed [agent] in a profile's file is not the profile's, and no role section
  local f="$H/prof-agent-sandbox"
  printf '[agent]\ncommand = one\n[agent:r]\ncommand = two\n' >"$f"
  run _as_profile_dotfile "$f"
  [[ "$output" == *"[agent:r] -- a profile's [agent] section does not take a role suffix"* ]]
  _as_profile_dotfile "$f" 2>/dev/null
  [ "$profile_command" = one ]
}

@test "the review says each [agent] line: the roles, whether AGENT names an installed profile, the fixed arguments; an unknown key (#355)" {
  printf '[agent]\ncommand = claude\naccount = work\nlogin = x\n[agent:planner-*]\ncommand = codex --model gpt\n[agent:gate]\ncommand = claude --permission-mode bypassPermissions\n[agent:fixer]\ncommand = claude --dangerously-skip-permissions\n' >"$PROJ/.agent-sandbox"
  run_trust 'n\n'
  [[ "$output" == *"[agent] command = claude: the agent of every role is claude (the profile claude, installed here), with no fixed arguments"* ]]
  [[ "$output" == *"[agent:planner-*] command = codex --model gpt: the agent of the roles planner-* is codex (no profile codex is installed here; it may be where the roles run), always given the native arguments: --model gpt"* ]]
  [[ "$output" == *"ignoring unknown [agent] key 'login'"* ]]
  [[ "$output" == *"[agent] account = work: every role run on the account 'work'"* ]] # #355, P6
  [[ "$output" == *"[agent:gate] command: --permission-mode bypassPermissions turns off the agent's own permission prompts, for the roles gate"* ]]
  [[ "$output" == *"[agent:fixer] command: --dangerously-skip-permissions turns off the agent's own permission prompts, for the roles fixer"* ]]
  # said where the fixed arguments hold either flag, and only there
  [ "$(grep -c 'turns off the agent' <<<"$output")" -eq 2 ]
}

@test "--apply '[agent:planner-1]' 'command = codex' writes the section and the review shows it (#355)" {
  printf '[connect:*]\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\n'
  run_apply 'y\n' '[agent:planner-1]' 'command = codex'
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[connect:*]\n\n[agent:planner-1]\ncommand = codex' ]
  [[ "$output" == *$'\n+[agent:planner-1]\n+command = codex\n'* ]]
  [[ "$output" == *"[agent:planner-1] command = codex: the agent of the roles planner-1 is codex"* ]]
  [[ "$output" == *"approved."* ]]
}

@test "--apply '[agent:planner-1]' 'account = work' writes the section and the review shows it (#355)" {
  printf '[connect:*]\n' >"$PROJ/.agent-sandbox"
  run_trust 'y\n'
  run_apply 'y\n' '[agent:planner-1]' 'account = work'
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[connect:*]\n\n[agent:planner-1]\naccount = work' ]
  [[ "$output" == *"[agent:planner-1] account = work: the roles planner-1 run on the account 'work'"* ]]
  [[ "$output" == *"approved."* ]]
}

@test "the review says a later [agent:<glob>] account line takes a role an earlier section names exactly (#355)" {
  printf '[agent:r1]\naccount = work\n[agent:r*]\naccount = personal\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[agent:r1] account = work: role r1 takes the later [agent:r*] account = personal instead"* ]]
}

@test "--check lists the role's [agent] lines and a key set twice in one section (#355)" {
  printf '[agent]\ncommand = claude\n[agent:r*]\ncommand = codex\ncommand = claude -x\n[agent:q]\ncommand = other\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb --check --role r1
  [ "$status" -eq 0 ]
  [[ "$output" == *$'  agent: [agent] command = claude\n  agent: [agent:r*] command = codex\n  agent: [agent:r*] command = claude -x\n'* ]]
  [[ "$output" != *"agent: [agent:q]"* ]] # another role's
  [[ "$output" == *"[agent:r*] command: set twice; the earlier 'command = codex' never applies"* ]]
}

@test "a launch with no command runs the role's [agent:<glob>] command, its fixed arguments first; --resume after them (#355)" {
  printf '[agent:r]\ncommand = claude --model x\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb --role r
  [ "$status" -eq 0 ]
  [ "${JOINV[0]##*/}" = claude ]
  [ "${JOINV[*]:1}" = "--model x" ]
  run_engine -- asb --role r --resume
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "--model x --continue" ]
  # the record: where it was named, then its words; --status prints it
  local sb="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/r"
  [ "$(cat "$sb/agent")" = $'dotfile:[agent:r]\nclaude --model x' ]
  run_engine -- asb --role r --status
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  agent: claude --model x -- .agent-sandbox [agent:r]"* ]]
  # a command typed on the line is the line's, the word alone
  run_engine -- asb --role r claude --model y
  [ "${JOINV[*]:1}" = "--model y" ]
  [ "$(cat "$sb/agent")" = $'line\nclaude' ]
}

@test "the role's agent: [agent] is every role's; [agent:<glob>] beats it whatever the order; among suffixed lines the later wins (#355)" {
  # [connect:*]: every role name is one of this file's (the suffixes define roles)
  printf '[connect:*]\n[agent:r*]\ncommand = claude -a\n[agent:r1]\ncommand = claude -b\n[agent]\ncommand = claude -u\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  run_engine -- asb --role q
  [ "$status" -eq 0 ]
  [ "${JOINV[*]:1}" = "-u" ]
  run_engine -- asb --role r2
  [ "${JOINV[*]:1}" = "-a" ]
  run_engine -- asb --role r1
  [ "${JOINV[*]:1}" = "-b" ]
  # the line beats the file, its fixed arguments included
  run_engine -- asb --role r1 --agent claude
  [ "$status" -eq 0 ]
  [ "${#JOINV[@]}" -eq 1 ]
  [ "$(cat "$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/r1/agent")" = $'line\nclaude' ]
}

@test "the role's agent: an unapproved file is not read, and no agent anywhere names both places; at a terminal it is asked about once (#355)" {
  printf '[agent]\ncommand = claude -u\n' >"$PROJ/.agent-sandbox"
  run_engine -- asb --role r
  [ "$status" -eq 2 ]
  [[ "$output" == *"no agent for role 'r'. Name it on the line, asb --agent AGENT, or a command"*"or in .agent-sandbox, [agent:r] command = AGENT"* ]]
  [[ "$output" == *".agent-sandbox is not approved, so it was not read: asb --trust"* ]]
  [ ! -s "$H/argv" ]
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the review on"
  run_engine_tty 'y\n' -- asb --role r
  [ "$status" -eq 0 ]
  [ "$(grep -c 'approve this .agent-sandbox' <<<"$output")" -eq 1 ]
  [[ "$output" == *"approved."* ]]
  [[ "$(cat "$H/join")" == *$'\n-u'* ]]
}

@test "the role's agent at a terminal: an unapproved file is asked about once, declined too, with --agent (#355)" {
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the review on"
  printf '[agent]\ncommand = claude -u\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'n\nn\n' -- asb --role r --agent claude
  [ "$(grep -c 'approve this .agent-sandbox' <<<"$output")" -eq 1 ]
  [[ "$output" == *"not approved."* ]]
  [ ! -s "$H/argv" ]
}

@test "the role's agent: with the file changed since approval and the role running, a launch with no command says so (#355)" {
  printf '[agent]\ncommand = claude -u\n' >"$PROJ/.agent-sandbox"
  trust "$PROJ"
  engine_bg -- asb --role r claude
  printf '# edited\n' >>"$PROJ/.agent-sandbox"
  run_engine -- asb --role r
  release_bg
  [ "$status" -eq 2 ]
  [[ "$output" == *"role r is running; .agent-sandbox changed since you approved it: re-approve with asb --trust, or type the command"* ]]
  # not running: the plain sentence
  run_engine -- asb --role r
  [[ "$output" == *".agent-sandbox is not approved, so it was not read: asb --trust"* ]]
}

@test "the review says when a later [agent:<glob>] line takes a role an earlier section names exactly; --check shows the agent that wins (#355)" {
  printf '[agent:r1]\ncommand = claude -exact\n[agent:r*]\ncommand = claude -glob\n[agent:q1]\ncommand = claude -q\n[agent:q*]\ncommand = claude -qq\n[agent:q1]\ncommand = claude -q2\n' >"$PROJ/.agent-sandbox"
  run_trust 'n\n'
  [[ "$output" == *"[agent:r1] command = claude -exact: role r1 takes the later [agent:r*] command = claude -glob instead (among suffixed sections the later line wins)"* ]]
  # q1 is named again after the glob: its own later line is what it takes, nothing to say
  [[ "$output" != *"role q1 takes"* ]]
  trust "$PROJ"
  run_engine -- asb --check --role r1
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  agent: claude -glob -- .agent-sandbox [agent:r*] wins"$'\n'"  agent: [agent:r1] command = claude -exact"$'\n'* ]]
  run_engine -- asb --check --role r1 --agent claude
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"  agent: claude -- named on the line, over any line below"$'\n'"  agent: [agent:r1] command = claude -exact"$'\n'* ]]
}

@test "_as_dotfile_read: a regular file's text; a symbolic link, to a file or dangling, refused with nothing read" {
  source_engine
  local d="$H/rd"
  mkdir -p "$d"
  printf 'a\nb' >"$d/.agent-sandbox"
  run _as_dotfile_read "$d/.agent-sandbox"
  [ "$status" -eq 0 ]
  [ "$output" = $'a\nb' ]
  printf 'secret\n' >"$d/secret"
  rm -f "$d/.agent-sandbox"
  ln -s "$d/secret" "$d/.agent-sandbox"
  run _as_dotfile_read "$d/.agent-sandbox"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  rm -f "$d/.agent-sandbox"
  ln -s "$d/nowhere" "$d/.agent-sandbox"
  run _as_dotfile_read "$d/.agent-sandbox"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
