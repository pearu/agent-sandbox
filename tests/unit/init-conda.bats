#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: environments -- a re-run without --env (#427), conda bases (#432),
# --shared-env (#268), agent-sandbox's conda root.
# The helpers several of the init-*.bats files use: tests/helpers/init.bash.
load "$BATS_TEST_DIRNAME/../helpers/init"

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  git -C "$PROJ" init -q
  git -C "$PROJ" config user.name tester
  git -C "$PROJ" config user.email tester@example.org
  git -C "$PROJ" commit -q --allow-empty -m init
  cat >"$H/bin/conda-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CONDA_LOG:?}"
while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && { mkdir -p "$2/conda-meta"; break; }; shift; done
STUB
  chmod +x "$H/bin/conda-stub"
}

# a test that takes write permission away gives it back, so bats can clean up; the
# processes a faked running sandbox stood on (running, below) end
teardown() {
  [[ -z "${H:-}" ]] || chmod -R u+w "$H" 2>/dev/null || true
  local pid
  if [[ -n "${H:-}" && -f "$H/shm" ]]; then
    rm -rf -- "$(cat "$H/shm")"
  fi
  if [[ -n "${H:-}" && -f "$H/sleeps" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$H/sleeps"
  fi
  return 0
}
# roles_in FILE -- every role FILE names, one per line: a pattern's instance 1 for its `*`.
roles_in() {
  sed -n 's/^\[[a-z-]*:\([^]]*\)\].*/\1/p' "$1" | sed 's/\*/1/' | grep -vx default | sort -u
}
# sbx_check ROLE / sbx_launch ROLE -- `--check --role ROLE`, and a launch of it, under the
# sandbox base.
sbx_check() {
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_CONDA_BASE=sandbox "${@:4}" --profile claude --check --role "$0" 2>&1 </dev/null' \
    "$1" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}
sbx_launch() { run_engine AGENT_SANDBOX_CONDA_BASE=sandbox AGENT_SANDBOX_NET=open CONDA_LOG="$H/mm.log" -- asb --role "$1" claude --version; }

# sbx_model "MODEL ARGS" -- under agent-sandbox's conda root (sandbox_base first),
# `--init MODEL ARGS --env dev`, approved, and every role the file names passes --check,
# none refused as the control plane. Sets EP, the environment's prefix.
sbx_model() {
  local r df="$PROJ/.agent-sandbox"
  EP="$ROOT/envs/$PDIR/dev"
  # shellcheck disable=SC2086 # the model and its counts, as words
  init AGENT_SANDBOX_CONDA_BASE=sandbox CONDA_LOG="$H/mm.log" -- $1 --env dev
  [ "$status" -eq 0 ]
  [ -d "$EP" ]
  grep -qF "$EP" "$df"
  approve
  [ "$status" -eq 0 ]
  [[ "$output" != *"control plane"* ]]
  for r in $(roles_in "$df"); do
    sbx_check "$r"
    [ "$status" -eq 0 ]
    [[ "$output" != *"control plane"* ]]
  done
}
# sbx_launch_has ROLE -- a launch of ROLE under agent-sandbox's conda root succeeds.
sbx_launch_has() {
  sbx_launch "$1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"control plane"* ]]
}

# same NAME -- every file snap NAME hashed (below) as it was then: purpose files, the
# dot-file and the rest of .asb/ but the clones
same() {
  snap "$1.after"
  diff "$H/snap.$1" "$H/snap.$1.after"
}

@test "--init roles re-run without --env keeps the environment the file declares, in the purpose files too: byte for byte, none updated (#427)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local ep="$H/conda/envs/x-dev" f
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  snap first
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'roles' lines: --env x-dev ($ep)"* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  same first
  for f in supervisor setup; do
    grep -qF "$ep" "$PROJ/.asb/roles/$f.md"
    # no placeholder left: ENVPATH only where the model's own prose names the word
    [ "$(grep -c ENVPATH "$PROJ/.asb/roles/$f.md")" -eq "$(grep -c ENVPATH "$BATS_TEST_DIRNAME/../../models/roles/roles/$f.md")" ]
  done
  # a comment naming it changed by hand names no environment --env would take: the name
  # is the prefix's, as before
  sed -i -e 's/environment, x-dev:/environment, mine:/' -e 's/lands in x-dev,/lands in mine,/' "$PROJ/.agent-sandbox"
  grep -qF 'environment, mine:' "$PROJ/.agent-sandbox" && grep -qF 'lands in mine,' "$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"lines: --env x-dev ($ep)"* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  # the same run, by path (#427): a first --init given the environment by its path is
  # recovered by its path, which supervisor.md and the [conda] comments name
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env "$ep"
  [ "$status" -eq 0 ]
  grep -qF "The development environment \`$ep\`, at \`$ep\`" "$PROJ/.asb/roles/supervisor.md"
  snap bypath
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'roles' lines: --env $ep"$'\n'* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  same bypath
}

@test "--init github re-run without --env keeps the environment the file declares: gh-setup.md byte for byte (#427)" {
  local ep="$H/elsewhere/envs/gh-dev"
  mkdir -p "$ep/conda-meta"
  init MAMBA_ROOT_PREFIX="$H/conda" -- github --env "$ep"
  [ "$status" -eq 0 ]
  grep -qF "$ep" "$PROJ/.asb/roles/gh-setup.md"
  snap first
  init MAMBA_ROOT_PREFIX="$H/conda" -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'github' lines: --env $ep"$'\n'* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  same first
}

@test "two models, two environments, several regions each, a [conda] base of the user's: each model's re-run takes its own environment (#427)" {
  sandbox_base
  local rp="$ROOT/envs/$PDIR/dev" gp="$H/miniforge3/envs/asb-gh" df="$PROJ/.agent-sandbox"
  mkdir -p "$rp/conda-meta" "$gp/conda-meta"
  init CONDA_LOG="$H/mm.log" -- roles --env dev
  [ "$status" -eq 0 ]
  init CONDA_LOG="$H/mm.log" -- github --env "$gp"
  [ "$status" -eq 0 ]
  # more regions of each: github's prefix only in a later one (a section the re-run
  # adds again), an instance added later, and the user's own [conda] base
  sed -i '/^\[conda:gh-\*\]/,+1d' "$df"
  run ! grep -qF "prefix = $gp" "$df"
  init CONDA_LOG="$H/mm.log" -- github --env "$gp"
  [ "$status" -eq 0 ]
  [ "$(awk -v p="prefix = $gp" '/^# ---- (written|added) by asb --init /{ m = NR ":" $0 } index($0, p) == 1 { print m; exit }' "$df")" \
    = "$(grep -n '^# ---- added by asb --init github ----$' "$df" | tail -1)" ]
  [ "$(grep -n "^prefix = $gp" "$df" | cut -d: -f1)" -gt "$(grep -n '^\[connect:gh-setup\]' "$df" | cut -d: -f1)" ]
  init CONDA_LOG="$H/mm.log" -- roles implementer=2 --env dev
  [ "$status" -eq 0 ]
  printf '\n# ---- added by asb --init github ----\n[conda]\nbase = sandbox\n' >>"$df"
  [ "$(grep -c '^# ---- \(written\|added\) by asb --init roles ----$' "$df")" -ge 2 ]
  [ "$(grep -c '^# ---- \(written\|added\) by asb --init github ----$' "$df")" -ge 2 ]
  snap first
  init CONDA_LOG="$H/mm.log" -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'roles' lines: --env dev ($rp)"* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  init CONDA_LOG="$H/mm.log" -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'github' lines: --env $gp"$'\n'* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  same first
  grep -qF "$rp" "$PROJ/.asb/roles/setup.md"
  run ! grep -qF "$gp" "$PROJ/.asb/roles/setup.md"
  grep -qF "$gp" "$PROJ/.asb/roles/gh-setup.md"
  run ! grep -qF "$rp" "$PROJ/.asb/roles/gh-setup.md"
  # the base that applies now is the host's: the name the file has is still the root's
  # environment, as the file declares it, not the host base's of that name; and so is the
  # one a missing Implementer's is cloned from
  mkdir -p "$H/base/envs/dev/conda-meta"
  rm -rf "$PROJ/.asb/impl/1/.env"
  init CONDA_LOG="$H/conda.log" CONDA_EXE="$H/bin/conda-stub" MAMBA_ROOT_PREFIX="$H/base" AGENT_SANDBOX_CONDA_BASE=host -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment from .agent-sandbox's model 'roles' lines: --env dev ($rp)"* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  grep -qF -- "--clone $rp -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  run ! grep -qF -- "--clone dev " "$H/conda.log"
  [ -d "$PROJ/.asb/impl/1/.env/conda-meta" ]
  same first
}

@test "--shared-env: a re-run without it keeps the shared texts and the shared environment's path; no setup role comes back (#427)" {
  local ep="$H/conda/envs/torch-dev" m
  mkdir -p "$ep/conda-meta"
  for m in roles github; do
    rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
    init MAMBA_ROOT_PREFIX="$H/conda" -- $m --shared-env torch-dev
    [ "$status" -eq 0 ]
    snap first
    init MAMBA_ROOT_PREFIX="$H/conda" -- $m
    [ "$status" -eq 0 ]
    [[ "$output" == *"--init: the environment from .agent-sandbox's model '$m' lines: --shared-env torch-dev ($ep)"* ]]
    [[ "$output" == *"--init: torch-dev is another project's environment ($ep)"* ]]
    [[ "$output" != *"updated .asb/roles/"* ]]
    same first
    [ ! -e "$PROJ/.asb/roles/setup.md" ] && [ ! -e "$PROJ/.asb/roles/gh-setup.md" ]
    [ "$m" = github ] && continue
    # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
    grep -qF 'The environment `torch-dev` is another project' "$PROJ/.asb/roles/supervisor.md"
    # shellcheck disable=SC2016
    grep -qF 'Your environment: `torch-dev`, another project' "$PROJ/.asb/roles/implementer-1.md"
  done
}

@test "no environment ever: a re-run of a file --init wrote without one says none and keeps ENVPATH (#427)" {
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles
  [ "$status" -eq 0 ]
  snap first
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"the environment from .agent-sandbox"* ]]
  same first
  grep -q ENVPATH "$PROJ/.asb/roles/setup.md"
}

@test "a re-run without --env that cannot tell the environment: two prefixes, both kinds, or nothing to tell -- refused, exit 2, nothing written, the lines and both flags named (#427)" {
  local ep="$H/conda/envs/x-dev" op="$H/conda/envs/y-dev" df="$PROJ/.agent-sandbox"
  mkdir -p "$ep/conda-meta" "$op/conda-meta"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  # two environments: one [conda] section's prefix changed by hand
  sed -i "0,\|^prefix = $ep|s||prefix = $op|" "$df"
  cp "$df" "$H/df-two"
  snap two
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox's model 'roles' lines name 2 environments"*"nothing was written"*"--env NAME (the project's own) or --shared-env NAME (another project's):"* ]]
  [[ "$output" == *"    line "*": prefix = $op"* && "$output" == *"    line "*": prefix = $ep"* ]]
  same two
  # both kinds: the own file given a shared environment's layer by hand
  cp "$H/df-two" "$df"
  sed -i "s|^prefix = $op|prefix = $ep|" "$df"
  sed -i "/^\[connect:implementer-1\]/a $ep/ = copy-on-write" "$df"
  snap both
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"have both an environment of the project's own and one another project owns, at $ep"*"--env NAME (the project's own) or --shared-env NAME (another project's)"* ]]
  [[ "$output" == *"    line "*": $ep/ = copy-on-write"* && "$output" == *"    line "*": $ep/ = read-write"* ]]
  same both
  # nothing to tell: no Implementer and no setup role, so neither kind's own lines
  rm -rf "$df" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=0 setup=0 --env x-dev
  [ "$status" -eq 0 ]
  snap none
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"name the environment $ep, and nothing in them tells whether it is the project's own or another project's; nothing was written"*"--env NAME"*"--shared-env NAME"* ]]
  same none
  # the flag settles each
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=0 setup=0 --env x-dev
  [ "$status" -eq 0 ]
}

@test "a re-run without --env of a file whose prefix is spelled with ~ by hand: refused, exit 2, nothing written, the line named (#427)" {
  local hm="$H/home" m df="$PROJ/.agent-sandbox"
  local ep="$hm/envs/x-dev"
  mkdir -p "$ep/conda-meta"
  for m in github roles; do
    rm -rf "$df" "$PROJ/.asb"
    init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- $m --env "$ep"
    [ "$status" -eq 0 ]
    sed -i "s|$hm/|~/|g" "$df"
    grep -q '^prefix = ~/envs/x-dev ' "$df"
    snap first
    init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- $m
    [ "$status" -eq 2 ]
    [[ "$output" == *"--init: .agent-sandbox's model '$m' lines spell the environment's prefix with '~', and --init writes and compares a prefix as the absolute path; nothing was written -- spell it as the absolute path, then run --init again:"* ]]
    [[ "$output" == *"    line $(grep -n '^prefix = ~/envs/x-dev ' "$df" | head -1 | cut -d: -f1): prefix = ~/envs/x-dev"* ]]
    [[ "$output" != *"the environment from .agent-sandbox"* ]]
    same first
    [ "$m" = roles ] || [ -f "$PROJ/.asb/roles/gh-setup.md" ]
  done
}

# ---- --env NAME under the base the model's roles launch with (#432) ----------------
# two_bases -- the host has conda ($H/base, empty), and agent-sandbox's conda root has this
# project's dev built; a stub micromamba clones as conda-stub does. ROOT, PDIR as
# sandbox_base; RP the root's dev, HP the host base's.
two_bases() {
  ROOT="$H/home/.local/share/agent-sandbox/conda" PDIR="$(project_env_dir "$PROJ")"
  RP="$ROOT/envs/$PDIR/dev" HP="$H/base/envs/dev"
  mkdir -p "$RP/conda-meta" "$H/base/envs" "$H/home/.local/share/agent-sandbox/micromamba/bin"
  cp "$H/bin/conda-stub" "$H/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
}
# hinit [VAR=value ...] -- ARGS: init with the host's conda (two_bases), conda's log in $H/conda.log
hinit() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  init MAMBA_ROOT_PREFIX="$H/base" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" ${envs[@]+"${envs[@]}"} "$@"
}

@test "--env NAME under the file's [conda] base = sandbox, where the host has conda: the root's environment, for github and roles; nothing made under the host's base (#432)" {
  two_bases
  local df="$PROJ/.agent-sandbox" m
  for m in github "roles planner=1 implementer=1 reviewer=1"; do
    rm -rf "$df" "$PROJ/.asb" "$H/conda.log"
    printf '[conda]\nbase = sandbox\n' >"$df"
    # shellcheck disable=SC2086 # the model and its counts, as words
    hinit -- $m --env dev
    [ "$status" -eq 0 ]
    grep -q "^prefix = $RP " "$df"
    run ! grep -qF "$HP" "$df"
    [[ "$output" != *"not built yet"* ]]
    [ ! -e "$HP" ]
  done
  # the Implementer's environment: cloned from the root's, by agent-sandbox's micromamba
  grep -qF -- "--clone $RP -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  [ -d "$PROJ/.asb/impl/1/.env/conda-meta" ]
  grep -qF "$RP" "$PROJ/.asb/roles/setup.md"
}

@test "--env NAME: AGENT_SANDBOX_CONDA_BASE over the file's [conda] base, and the file's base over install.sh's answer (#432)" {
  two_bases
  local df="$PROJ/.agent-sandbox"
  mkdir -p "$HP/conda-meta"
  printf '[conda]\nbase = sandbox\n' >"$df"
  hinit AGENT_SANDBOX_CONDA_BASE=host -- github --env dev
  [ "$status" -eq 0 ]
  grep -q "^prefix = $HP " "$df"
  run ! grep -qF "$RP" "$df"
  rm -rf "$df" "$PROJ/.asb"
  mkdir -p "$H/home/.config/agent-sandbox"
  echo sandbox >"$H/home/.config/agent-sandbox/conda"
  printf '[conda]\nbase = host\n' >"$df"
  hinit -- github --env dev
  [ "$status" -eq 0 ]
  grep -q "^prefix = $HP " "$df"
  run ! grep -qF "$RP" "$df"
  # install.sh's answer alone, as before: the root's
  rm -rf "$df" "$PROJ/.asb"
  hinit -- github --env dev
  [ "$status" -eq 0 ]
  grep -q "^prefix = $RP " "$df"
}

@test "--env NAME with the file-wide [conda] base = sandbox in another model's region: resolved under the root, not refused as another environment, the purpose files unchanged (#432)" {
  two_bases
  local df="$PROJ/.agent-sandbox"
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- roles --env dev
  [ "$status" -eq 0 ]
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env dev
  [ "$status" -eq 0 ]
  printf '\n# ---- added by asb --init github ----\n[conda]\nbase = sandbox\n' >>"$df"
  [ "$(grep -c "^prefix = $RP " "$df")" -ge 2 ]
  snap first
  hinit -- roles --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"another environment"* ]]
  [[ "$output" != *"updated .asb/roles/"* ]]
  hinit -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"another environment"* ]]
  same first
  [ ! -e "$HP" ]
}

@test "--env NAME where a role-scoped [conda:GLOB] base gives some of the model's roles another base: refused, exit 2, nothing written, the lines and both ways out named; one that agrees is used (#432)" {
  two_bases
  local df="$PROJ/.agent-sandbox"
  local n
  # the roles model's file, as an --init wrote it; then the user's lines: the reviewers on the host
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --env dev
  [ "$status" -eq 0 ]
  # (and another model's roles' base, which none of these roles takes: not named)
  printf '[conda]\nbase = sandbox\n[conda:reviewer-*]   # the reviewers on the host\nbase = host\n[conda:gh-*]\nbase = host\n' >>"$df"
  n="$(wc -l <"$df")"
  rm -f "$H/conda.log"
  snap first
  hinit -- roles --env dev
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: --init: --env dev: .agent-sandbox gives the roles of model 'roles' two conda bases -- sandbox for planner-1 implementer-1 "*", host for reviewer-1 -- and one name cannot name one environment under both; nothing was written -- give the environment by its path, --env PATH, or set AGENT_SANDBOX_CONDA_BASE (host or sandbox) for this --init. The [conda] base lines:"$'\n'"    line $((n - 4)), in [conda]: base = sandbox"$'\n'"    line $((n - 2)), in [conda:reviewer-*]: base = host" ]]
  same first
  [ ! -e "$HP" ] && [ ! -e "$H/conda.log" ]
  hinit -- roles --shared-env dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --shared-env dev: "*"give the environment by its path, --shared-env PATH, or set AGENT_SANDBOX_CONDA_BASE"* ]]
  same first
  # a plain re-run takes the file's prefix (#427) and resolves no name: not refused
  hinit -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"two conda bases"* ]]
  same first
  # github's roles, every one under the user's [conda:gh-*]: host, all of them, used over
  # the file's sandbox (the section is the user's, so its prefix line is an --apply said)
  rm -rf "$df" "$PROJ/.asb"
  printf '[conda]\nbase = sandbox\n[conda:gh-*]\nbase = host\n' >"$df"
  hinit -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"created empty at $HP)"* && "$output" == *"--apply '[conda:gh-*]' 'prefix = $HP'"* ]]
  # a role-scoped base for some of github's, in a file an --init of it wrote: refused
  rm -rf "$df" "$PROJ/.asb"
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env dev
  [ "$status" -eq 0 ]
  printf '[conda]\nbase = sandbox\n[conda:gh-fix-*]\nbase = host\n' >>"$df"
  n="$(wc -l <"$df")"
  snap first
  hinit -- github --env dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env dev: .agent-sandbox gives the roles of model 'github' two conda bases -- sandbox for "*", host for gh-fix-1 -- "*"    line $((n - 2)), in [conda]: base = sandbox"$'\n'"    line $n, in [conda:gh-fix-*]: base = host" ]]
  same first
  # the ways out: the variable, or the path
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env dev
  [ "$status" -eq 0 ]
  hinit -- github --env "$RP"
  [ "$status" -eq 0 ]
  same first
  # a role-scoped base that agrees with the rest (the host has conda: host by default)
  rm -rf "$df" "$PROJ/.asb"
  mkdir -p "$HP/conda-meta"
  hinit -- roles --env dev
  [ "$status" -eq 0 ]
  printf '[conda:reviewer-*]\nbase = host\n' >>"$df"
  snap first
  hinit -- roles --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"two conda bases"* ]]
  grep -q "^prefix = $HP " "$df"
  run ! grep -qF "$RP" "$df"
  same first
  # a role this run writes nothing for (a count of 0, which removes its sections) has no say
  rm -rf "$df" "$PROJ/.asb"
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- roles reviewer=0 --env dev
  [ "$status" -eq 0 ]
  printf '[conda]\nbase = sandbox\n[conda:reviewer-*]\nbase = host\n' >>"$df"
  hinit -- roles reviewer=0 --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [conda:reviewer-*]"* && "$output" != *"two conda bases"* ]]
  grep -q "^prefix = $RP " "$df"
  run ! grep -qF "$HP" "$df"
}

@test "--env PATH and a file with no [conda] base: unchanged by the file's base; --shared-env NAME under the file's base = sandbox refused as under the variable (#432)" {
  two_bases
  local df="$PROJ/.agent-sandbox" st
  mkdir -p "$HP/conda-meta"
  # --env PATH: the path, whatever the base
  printf '[conda]\nbase = sandbox\n' >"$df"
  hinit -- github --env "$HP"
  [ "$status" -eq 0 ]
  grep -q "^prefix = $HP " "$df"
  # no [conda] base in the file: the host's, as the default
  rm -rf "$df" "$PROJ/.asb"
  printf '[net]\nmode = open\n' >"$df"
  hinit -- github --env dev
  [ "$status" -eq 0 ]
  grep -q "^prefix = $HP " "$df"
  # --shared-env NAME: the variable's refusal, and its exit, from the file's base alone
  rm -rf "$df" "$PROJ/.asb"
  hinit AGENT_SANDBOX_CONDA_BASE=sandbox -- roles --shared-env dev
  st="$status"
  [ "$st" -ne 0 ]
  [[ "$output" == *"--init: --shared-env dev: under agent-sandbox's conda root each project's environments are its own,"* ]]
  printf '[conda]\nbase = sandbox\n' >"$df"
  cp "$df" "$H/dot"
  hinit -- roles --shared-env dev
  [ "$status" -eq "$st" ]
  [[ "$output" == *"--init: --shared-env dev: under agent-sandbox's conda root each project's environments are its own,"*"give the other project's environment by its path, --shared-env ~/.local/share/agent-sandbox/conda/envs/<project>-<hash>/dev"* ]]
  cmp "$df" "$H/dot"
  [ ! -e "$PROJ/.asb" ]
}

@test "--shared-env on a file --init wrote without an environment: the shared lines completed, the own ones left commented out" {
  shared_env torch-dev
  local df="$PROJ/.agent-sandbox" ep="$H/conda/envs/torch-dev"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --shared-env torch-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: completed in .agent-sandbox, for --env torch-dev ($ep)"* ]]
  [ "$(grep -c "^prefix = $ep " "$df")" -eq 5 ] # every role of the shared template activates it
  grep -qx '# \[conda:implementer-1\].*' "$df"  # the own environment's clone: not this one
  grep -qx '# write = 1' "$df"                  # nor the Supervisor's write into it
  [ ! -e "$H/conda.log" ]                       # nothing cloned
  # the shared template's own lines were never written: said as lines the model has
  [[ "$output" == *"--apply '[connect:implementer-1]' '$ep/ = copy-on-write'"* ]]
  # the setup role the no-env --init wrote: said, and left
  [[ "$output" == *"--init: .agent-sandbox has the setup role setup: a shared environment, built by the project that owns it, needs no setup role here. --init leaves it; to remove it, delete its sections from .agent-sandbox ([sandbox:setup] [connect:setup] "*"[net:setup] "*"[briefing:setup] [agent:setup]) and its purpose file .asb/roles/setup.md, then agent-sandbox --trust; agent-sandbox --role setup --delete claude removes its stores, if it was ever launched"* ]]
  [[ "$output" == *"  - the left-over setup role setup above: yours to remove"* ]]
  grep -qx '\[connect:setup\]' "$df"
  # its purpose file, kept, tells it what it sees then: a shared environment, nothing to build
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF "The other roles' \`[conda:...]\` sections (\`[conda:planner-*]\`, \`[conda:supervisor]\`," "$PROJ/.asb/roles/setup.md"
  grep -qF 'the project uses a shared environment, another project'"'"'s, built there, and there is' "$PROJ/.asb/roles/setup.md"
  # shellcheck disable=SC2016 # likewise
  grep -qF 'earlier `asb --init roles` without an environment and can be removed' "$PROJ/.asb/roles/setup.md"
  grep -qF 'asb --role setup --delete claude' "$PROJ/.asb/roles/setup.md"
  run ! grep -qF '{' "$PROJ/.asb/roles/setup.md"
}

@test "--shared-env on a file --init --env wrote: the setup role said without naming a no-env --init (#389)" {
  shared_env torch-dev
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 implementer=1 reviewer=1 --env own
  [ "$status" -eq 0 ]
  # the user moves the project to the shared environment by hand: --init refuses to rewrite a prefix
  sed -i "s|$H/conda/envs/own|$H/conda/envs/torch-dev|g" "$df"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 implementer=1 reviewer=1 --shared-env torch-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: .agent-sandbox has the setup role setup: a shared environment, built by the project that owns it, needs no setup role here. --init leaves it"* ]]
  [[ "$output" != *"without an environment: a shared"* ]]
  grep -qx '\[connect:setup\]' "$df"
}

@test "--shared-env after a no-env --init github: gh-setup said as left over, its purpose file says what to tell the user" {
  shared_env torch-dev
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  init MAMBA_ROOT_PREFIX="$H/conda" -- github --shared-env torch-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: .agent-sandbox has the setup role gh-setup: a shared environment, built by the project that owns it, needs no setup role here. --init leaves it; to remove it, delete its sections from .agent-sandbox ([connect:gh-setup] [net:gh-setup] [briefing:gh-setup] [agent:gh-setup]) and its purpose file .asb/roles/gh-setup.md, then agent-sandbox --trust; agent-sandbox --role gh-setup --delete claude removes its stores, if it was ever launched"* ]]
  grep -qx '\[connect:gh-setup\]' "$df" # not removed
  [ -f "$PROJ/.asb/roles/gh-setup.md" ]
  grep -qx "prefix = $H/conda/envs/torch-dev .*" "$df" # what gh-setup reads
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF -- '- Its `[conda:gh-*]` section active, with a `prefix = PATH` line naming another path' "$PROJ/.asb/roles/gh-setup.md"
  # shellcheck disable=SC2016 # likewise
  grep -qF '`.asb/roles/gh-setup.md`, then `asb --trust`; `asb --role gh-setup --delete claude`' "$PROJ/.asb/roles/gh-setup.md"
  # shellcheck disable=SC2016 # likewise
  grep -qF 'than the prefix above (which reads `ENVPATH`): the project uses a shared environment,' "$PROJ/.asb/roles/gh-setup.md"
  # shellcheck disable=SC2016 # likewise
  grep -qF -- '- Its `prefix = PATH` the same path as the prefix above, and that directory not there:' "$PROJ/.asb/roles/gh-setup.md"
  grep -qF -- '- Otherwise the project declares no environment. Stop at once and ask the user,' "$PROJ/.asb/roles/gh-setup.md"
  # a first --shared-env has no setup role to report
  rm -rf "$df" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/conda" -- github --shared-env torch-dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"left over"* ]]
}

@test "--init --env NAME under agent-sandbox's micromamba: the prefix is in the project's directory under its conda root, and the message says so" {
  local root="$H/home/.local/share/agent-sandbox/conda" s
  s="$(project_env_dir "$PROJ")"
  # no conda on the host -- and a CI runner has conda on PATH, so these stubs find none:
  # the default is the sandbox's own
  printf '#!/bin/sh\nexit 1\n' >"$H/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$H/bin/mamba"
  chmod +x "$H/bin/conda" "$H/bin/mamba"
  init -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"environment dev is not built yet (created empty at $root/envs/$s/dev, under agent-sandbox's conda root)"*"--role gh-setup claude builds it"* ]]
  [ -d "$root/envs/$s/dev" ] && [ -z "$(ls -A "$root/envs/$s/dev")" ]
  grep -A3 -xF '[connect:gh-setup]' "$PROJ/.agent-sandbox" | grep -qx "$root/envs/$s/dev/ = read-write.*"
  # a host base, but install.sh's answer was sandbox: the root, not the host's base
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  mkdir -p "$H/base/envs" "$H/home/.config/agent-sandbox"
  echo sandbox >"$H/home/.config/agent-sandbox/conda"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev2
  [ "$status" -eq 0 ]
  [ -d "$root/envs/$s/dev2" ] && [ ! -e "$H/base/envs/dev2" ]
  # and the shell's variable wins over the file
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/base" AGENT_SANDBOX_CONDA_BASE=host -- github --env dev3
  [ "$status" -eq 0 ]
  [ -d "$H/base/envs/dev3" ] && [ ! -e "$root/envs/$s/dev3" ] && [ ! -e "$root/envs/dev3" ]
  # an Implementer's clone is micromamba's, under the root
  local mm="$H/home/.local/share/agent-sandbox/micromamba/bin"
  mkdir -p "$mm"
  cp "$H/bin/conda-stub" "$mm/micromamba"
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  mkdir -p "$root/envs/$s/x-dev/conda-meta"
  init CONDA_LOG="$H/mm.log" -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  grep -qx "create -q -y -r $root --clone $root/envs/$s/x-dev -p $PROJ/.asb/impl/1/.env" "$H/mm.log"
}

@test "--shared-env: another project's env, read-only for every role, never cloned or built here; a layer over it for the roles that install; its editable sources declared (#268)" {
  shared_env torch-dev
  local ep="$H/conda/envs/torch-dev" df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --shared-env torch-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"(P1 I1 R1 S G)"* ]] # no setup role: the env is built by the project that owns it
  [[ "$output" == *"--init: torch-dev is another project's environment ($ep): activated read-only, never cloned or built here"* ]]
  [[ "$output" == *"it imports from $H/src/torch, $H/src/vision (editable installs)"* ]]
  [ ! -e "$H/conda.log" ] && [ ! -e "$PROJ/.asb/impl/1/.env" ] # nothing cloned
  run ! grep -qE '^\[(connect|net|briefing):setup\]' "$df"
  [ ! -e "$PROJ/.asb/roles/setup.md" ]
  run ! grep -qE '^write = 1' "$df"             # the Supervisor does not write into it
  run ! grep -qF 'prefix = .asb/impl/' "$df"    # no Implementer env of its own
  [ "$(grep -c "^prefix = $ep " "$df")" -eq 5 ] # every role activates it
  [ "$(grep -c "^$H/src/torch/ = read-only" "$df")" -eq 5 ]
  [ "$(grep -c "^$H/src/vision/ = read-only" "$df")" -eq 5 ]
  run ! grep -qF "$ep/lib" "$df" # a path inside the env is not a source
  grep -A8 -xF '[connect:implementer-1]' "$df" | grep -q "^$ep/ = copy-on-write"
  sed -n '/^\[connect:supervisor\]$/,/^\[/p' "$df" | grep -q "^$ep/ = copy-on-write"
  grep -qF "\`torch-dev\`, another project's, read-only to" "$PROJ/.asb/roles/implementer-1.md"
  run ! grep -qF 'conda env update -p' "$PROJ/.asb/roles/implementer-1.md"
  grep -qF "\`torch-dev\` is another project's: you do not" "$PROJ/.asb/roles/supervisor.md"
  run ! grep -qF '#@' "$PROJ/.asb/roles/supervisor.md"
}

@test "--shared-env refuses an env that is not built, and one --env or --shared-env only; the github model drops gh-setup under it (#268)" {
  mkdir -p "$H/conda/envs"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 --shared-env missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"--shared-env missing: no conda environment at $H/conda/envs/missing -- an environment another project owns is built there, by that project, not here"* ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
  shared_env torch-dev
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 --env torch-dev --shared-env torch-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"one environment: --env NAME (this project's own) or --shared-env NAME (another project's), once"* ]]
  init MAMBA_ROOT_PREFIX="$H/conda" -- github --shared-env torch-dev
  [ "$status" -eq 0 ]
  run ! grep -qF 'gh-setup' "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.asb/roles/gh-setup.md" ]
  sed -n '/^\[connect:gh-\*\]/,/^\[/p' "$PROJ/.agent-sandbox" | grep -q "^$H/src/torch/ = read-only"
}

@test "--check names an active env's editable sources a role cannot read, with the --apply line; a declared one is not named (#268)" {
  shared_env torch-dev
  local ep="$H/conda/envs/torch-dev"
  printf '[conda]\nprefix = %s\n' "$ep" >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --profile claude --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"The conda env $ep imports from source trees this role cannot read (editable installs):"* ]]
  [[ "$output" == *"  $H/src/torch -- its imports fail inside; to declare it: "*"--apply '[connect]' '$H/src/torch/ = read-only'"* ]]
  [[ "$output" == *"  $H/src/vision -- its imports fail inside"* ]]
  printf '[connect]\n%s/src/torch/ = read-only\n' "$H" >>"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --profile claude --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$H/src/torch -- its imports fail"* ]]
  [[ "$output" == *"$H/src/vision -- its imports fail"* ]]
}

# ---- environments under agent-sandbox's conda root: a directory per project ----------
@test "under agent-sandbox's conda root, the roles model's every role passes --check, and its setup role and a role with no line of the environment launch" {
  sandbox_base
  sbx_model "roles planner=1 implementer=1 reviewer=1"
  sbx_launch_has setup
  argv_has --bind "$EP" "$EP" # it builds the environment
  sbx_launch_has planner-1
  # its [conda] prefix only, no line of its own: not built yet, so not activated
  [[ "$output" == *"is not a conda env yet (no conda-meta/ in $EP)"* ]]
  run ! argv_has --bind "$EP" "$EP"
  run ! argv_has --overlay-src "$EP"
}

@test "under agent-sandbox's conda root, the github model's every role passes --check, and gh-setup and a gh-* role over the environment launch" {
  sandbox_base
  sbx_model github
  sbx_launch_has gh-setup
  argv_has --bind "$EP" "$EP"
  sbx_launch_has gh-review-1
  argv_has --overlay-src "$EP" # its layer over it
}

@test "under agent-sandbox's conda root, the market model's every role passes --check, and a market role over the environment launches" {
  sandbox_base
  mkdir -p "$ROOT/envs/$PDIR/dev/conda-meta" # no setup role: it takes a built one
  sbx_model market
  sbx_launch_has market-1
  argv_has --overlay-src "$EP"
}

@test "under agent-sandbox's conda root, two projects' --env of one name are two environments, each made empty in its project's directory, even where their paths differ only in punctuation" {
  sandbox_base
  local p d
  local -a dirs=()
  for p in my_proj my-proj my.proj; do
    mkdir -p "$H/$p" && git -C "$H/$p" init -q
    p="$(cd "$H/$p" && pwd -P)" d="$(project_env_dir "$p")"
    PROJ="$p" init AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"environment dev is not built yet (created empty at $ROOT/envs/$d/dev, under agent-sandbox's conda root)"* ]]
    [[ "$d" == "${p##*/}-"???????????? ]] # the basename, a -, 12 hex digits
    [ -d "$ROOT/envs/$d/dev" ] && [ -z "$(ls -A "$ROOT/envs/$d/dev")" ]
    grep -qx "prefix = $ROOT/envs/$d/dev .*" "$p/.agent-sandbox"
    dirs+=("$d")
  done
  [ "$(printf '%s\n' "${dirs[@]}" | sort -u | wc -l)" -eq 3 ]
  [ ! -e "$ROOT/envs/dev" ]
}

@test "under agent-sandbox's conda root, a long project path still gives a short prefix; a name that makes it longer than 255 characters is refused" {
  sandbox_base
  local long="$H" i d name
  for i in 1 2 3 4 5 6; do long+="/a-rather-long-directory-name-number-$i-of-several"; done
  long+="/and-a-project-directory-whose-own-name-is-long-too"
  mkdir -p "$long" && git -C "$long" init -q && long="$(cd "$long" && pwd -P)"
  ((${#long} > 255))
  d="$(project_env_dir "$long")"
  [ "${#d}" -eq 45 ] # 32 of the basename, a -, 12 hex digits
  PROJ="$long" init AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env dev
  [ "$status" -eq 0 ]
  [ -d "$ROOT/envs/$d/dev" ]
  # NAME is the rest: a prefix past conda's 255-byte placeholder is refused, nothing made
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  name="$(printf 'n%.0s' $(seq 1 $((256 - ${#ROOT} - ${#PDIR} - 7))))"
  ((${#ROOT} + 6 + ${#PDIR} + 1 + ${#name} == 256)) # <root>/envs/<dir>/<name>
  init AGENT_SANDBOX_CONDA_BASE=sandbox -- github --env "$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: --env $name: the conda prefix $ROOT/envs/$PDIR/$name is 256 bytes, longer than 255: conda packages' binaries are relocated through a 255-byte placeholder, so binaries installed there would break -- use a shorter path, or ask for the feature at https://github.com/pearu/agent-sandbox/issues"* ]]
  [ ! -e "$ROOT/envs/$PDIR/$name" ] && [ ! -e "$PROJ/.agent-sandbox" ]
  # an --env PATH, under any base, likewise
  mkdir -p "$long/env/conda-meta"
  init AGENT_SANDBOX_CONDA_BASE=host -- market --env "$long/env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: --env $long/env: the conda prefix $long/env is $((${#long} + 4)) bytes, longer than 255"* ]]
  # and at launch, a [conda] name that does the same
  printf '[conda]\nbase = sandbox\nname = %s\n' "$name" >"$PROJ/.agent-sandbox"
  approve
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *".agent-sandbox: [conda] name = $name: the conda prefix $ROOT/envs/$PDIR/$name is 256 bytes, longer than 255"* ]]
}

@test "an Implementer's clone at a prefix longer than 255 bytes is refused by --init, where it would be made" {
  sandbox_base
  # a project path that leaves the environment's prefix short but its clone's long:
  # <project>/.asb/impl/1/.env is 17 bytes more than the project's path
  local p="$H/p" d
  while ((${#p} < 245)); do p+="x"; done
  mkdir -p "$p" && git -C "$p" init -q && p="$(cd "$p" && pwd -P)"
  ((${#p} + 17 > 255))
  d="$(project_env_dir "$p")"
  mkdir -p "$ROOT/envs/$d/E/conda-meta"
  PROJ="$p" init AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --env E
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: implementer-1's environment: the conda prefix $p/.asb/impl/1/.env is $((${#p} + 17)) bytes, longer than 255"*"or ask for the feature at https://github.com/pearu/agent-sandbox/issues"* ]]
  [ ! -e "$p/.asb/impl/1/.env" ]
}

@test "under agent-sandbox's conda root, --shared-env takes another project's environment by its path; a bare name is refused, the layout said" {
  sandbox_base
  local other="$ROOT/envs/-elsewhere-torch/torch-dev" df="$PROJ/.agent-sandbox" r
  mkdir -p "$other/conda-meta" "$ROOT/envs/$PDIR/torch-dev/conda-meta"
  init AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --shared-env torch-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: --shared-env torch-dev: under agent-sandbox's conda root each project's environments are its own, ~/.local/share/agent-sandbox/conda/envs/<project>-<hash>/<name> (~/.local/share/agent-sandbox/conda/envs/$PDIR/torch-dev is this project's torch-dev), so a name cannot say whose: give the other project's environment by its path, --shared-env ~/.local/share/agent-sandbox/conda/envs/<project>-<hash>/torch-dev"* ]]
  [ ! -e "$df" ]
  init AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --shared-env "$other"
  [ "$status" -eq 0 ]
  grep -qx "$other/ = copy-on-write .*" "$df"
  approve
  [ "$status" -eq 0 ]
  for r in implementer-1 supervisor; do
    sbx_check "$r"
    [ "$status" -eq 0 ]
    [[ "$output" != *"control plane"* ]]
    sbx_launch "$r"
    [ "$status" -eq 0 ]
    argv_has --overlay-src "$other"
    [ "$(setenv_value CONDA_PREFIX)" = "$other" ]
  done
}

@test "the Supervisor updates the environment by its prefix, with conda or agent-sandbox's micromamba, under either base; its permissions name both" {
  local sup="$PROJ/.asb/roles/supervisor.md" df="$PROJ/.agent-sandbox" ep
  # the host's base: <base>/envs/E
  mkdir -p "$H/conda/envs/E/conda-meta"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env E
  [ "$status" -eq 0 ]
  ep="$H/conda/envs/E"
  grep -qF "\`conda env update -p $ep -f environment.yml --prune\`" "$sup"
  grep -qF "\`micromamba env update -y -p $ep -f environment.yml --prune\`" "$sup"
  run ! grep -qF -- '-n E' "$sup"
  section '[permissions:supervisor]' "$df" | grep -qx 'Bash(conda env update:\*)'
  section '[permissions:supervisor]' "$df" | grep -qx 'Bash(micromamba env update:\*)'
  grep -qF 'micromamba env update -y -p .asb/impl/1/.env -f environment.yml --prune' "$PROJ/.asb/roles/implementer-1.md"
  # agent-sandbox's conda root: the project's own directory there
  rm -rf "$df" "$PROJ/.asb"
  sandbox_base
  init AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --env dev
  [ "$status" -eq 0 ]
  ep="$ROOT/envs/$PDIR/dev"
  grep -qF "\`conda env update -p $ep -f environment.yml --prune\`" "$sup"
  grep -qF "\`micromamba env update -y -p $ep -f environment.yml --prune\`" "$sup"
  run ! grep -qF -- '-n dev' "$sup"
  run ! grep -qE '\{(env|envpath)\}' "$sup"
  section '[permissions:supervisor]' "$df" | grep -qx 'Bash(micromamba env update:\*)'
}

@test "under agent-sandbox's conda root, a model whose Implementers clone the environment but whose file has no {envpath} line clones this project's environment, by its path" {
  sandbox_base
  cp -r "$REPO_ROOT/models/roles" "$H/roles-noenvpath"
  sed -i '/{envpath}/d' "$H/roles-noenvpath/agent-sandbox"
  run ! grep -qF '{envpath}' "$H/roles-noenvpath/agent-sandbox"
  mkdir -p "$ROOT/envs/$PDIR/x-dev/conda-meta"
  init AGENT_SANDBOX_CONDA_BASE=sandbox CONDA_LOG="$H/mm.log" -- "$H/roles-noenvpath" planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  grep -qx "create -q -y -r $ROOT --clone $ROOT/envs/$PDIR/x-dev -p $PROJ/.asb/impl/1/.env" "$H/mm.log"
}

@test "under agent-sandbox's conda root, a clone that fails says what was run: micromamba create --clone of the environment's prefix" {
  sandbox_base
  printf '#!/bin/sh\nexit 1\n' >"$H/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  mkdir -p "$ROOT/envs/$PDIR/x-dev/conda-meta"
  init AGENT_SANDBOX_CONDA_BASE=sandbox -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: 'micromamba create --clone $ROOT/envs/$PDIR/x-dev -p .asb/impl/1/.env' failed (conda base = sandbox, "* ]]
}
