#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.

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

# has_section HEADER FILE -- FILE has a line that starts with HEADER (a comment may follow).
has_section() { grep -F -- "$1" "$2" | grep -q "^$(printf '%s' "$1" | sed 's/[][*.]/\\&/g')"; }

# init [VAR=value ...] -- ARGS: `asb --init ARGS` from the project, in a clean environment.
init() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  engine_cmd
  run bash -c 'proj="$1" home="$2" path="$3" n="$4"; shift 4; eng=("${@:1:n}"); shift "$n"; n="$1"; shift; envs=("${@:1:n}"); shift "$n"
    cd "$proj" && env -i HOME="$home" PATH="$path" "${envs[@]}" "${eng[@]}" --init "$@" 2>&1 </dev/null' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "${#envs[@]}" ${envs[@]+"${envs[@]}"} "$@"
}

@test "the roles model: every instance's sections, purpose files, clones, directories, the index and .asb/.gitignore" {
  init -- roles planner=2 implementer=2 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--trust"* && "$output" == *"--check --role NAME"* ]]
  local df="$PROJ/.agent-sandbox"
  for s in '[connect:planner-1]' '[connect:planner-2]' '[briefing:planner-*]' '[connect:implementer-1]' \
    '[connect:implementer-2]' '[connect:reviewer-1]' '[connect:supervisor]' '[net:supervisor]' '[briefing:supervisor]'; do
    has_section "$s" "$df"
  done
  run ! grep -qF '{' "$df"                     # every placeholder substituted
  grep -qx '# \[conda:implementer-1\].*' "$df" # no --env: the conda sections commented out
  grep -qx '\.asb/impl/2/ = read-write.*' "$df"
  # purpose files, one per instance, named and handled
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown, not a command
  head -1 "$PROJ/.asb/roles/implementer-2.md" | grep -q '`implementer-2`, called I2'
  # shellcheck disable=SC2016 # likewise
  grep -q '`.asb/impl/2/`' "$PROJ/.asb/roles/implementer-2.md"
  head -1 "$PROJ/.asb/roles/supervisor.md" | grep -q 'called S'
  # a clone per Implementer: its tree, its history apart, its branch, main's objects shared
  [ -f "$PROJ/.asb/impl/1/.git" ]
  grep -q "gitdir: $PROJ/.asb/git/1" "$PROJ/.asb/impl/1/.git"
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
  grep -q "$PROJ/./.git/objects" "$PROJ/.asb/git/1/objects/info/alternates"
  [ "$(git config -f "$PROJ/.asb/git/1/config" user.name)" = tester ] # your identity, for commits inside
  # every declared .asb/ path exists
  [ -d "$PROJ/.asb/review/reviewer-1" ] && [ -d "$PROJ/.asb/plan/planner-2" ] && [ -d "$PROJ/.asb/scratch" ]
  [ -d "$PROJ/.asb/coord/planner-1" ] # a role's messages: a directory, for Write's temp+rename
  grep -q '^| I1 | implementer-1 | .asb/coord/implementer-1/messages.md | .asb/handoff/implementer-1/, .asb/impl/1/, .asb/git/1/ |$' "$PROJ/.asb/coord/COORDINATION.md"
  grep -q '^| S | supervisor | .asb/coord/supervisor/messages.md |' "$PROJ/.asb/coord/COORDINATION.md"
  run ! grep -qF '.asb/coord/COORDINATION.md' "$PROJ/.agent-sandbox" # --init keeps the index
  # .asb/ kept out of git by its own .gitignore, and not by the repository's exclude
  [ "$(cat "$PROJ/.asb/.gitignore")" = '*' ]
  [ -z "$(git -C "$PROJ" status --porcelain --untracked-files=all -- .asb)" ]
  run ! grep -qF '.asb' "$PROJ/.git/info/exclude"
  [ ! -e "$H/home/.config/agent-sandbox/trust" ] # it approves nothing
}

@test "counts: none given is one of each; 0 leaves a role out; an unknown role, a bad count or two Supervisors are refused" {
  init -- roles reviewer=0
  [ "$status" -eq 0 ]
  grep -qxF '[connect:planner-1]' "$PROJ/.agent-sandbox"
  run ! grep -qF '[connect:planner-2]' "$PROJ/.agent-sandbox"
  run ! grep -qF 'reviewer' "$PROJ/.agent-sandbox"
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init -- roles tester=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no role 'tester' (it has: planner implementer reviewer supervisor gate setup)"* ]]
  init -- roles supervisor=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 or 1 for supervisor"* ]]
  init -- roles planner=x
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/.agent-sandbox" ]
}

@test "a model whose roles share an initial is refused; so is an unknown model, and a cloning model below a repository's top" {
  mkdir -p "$H/m/pairs"
  printf '[connect:planner-{n}]\n.asb/a/ = read-write\n[connect:prober-{n}]\n.asb/b/ = read-write\n' >"$H/m/pairs/agent-sandbox"
  init -- "$H/m/pairs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"roles 'planner' and 'prober'"*"share the initial P"* ]]
  init -- nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no model 'nosuch'"*"Shipped: github market roles"* ]]
  mkdir -p "$PROJ/sub"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --init roles 2>&1' _ "$PROJ/sub" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"model 'roles' clones the project"*"inside the one at $PROJ -- run it there"* ]]
}

@test "run again with more instances, it adds what is missing and touches nothing that exists" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cp "$PROJ/.agent-sandbox" "$H/before"
  printf 'NOTES\n' >"$PROJ/.asb/roles/implementer-1.md"
  init -- roles planner=1 implementer=2 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:implementer-2]"* ]]
  # the file as it was, plus the new instance at its end
  [ "$(head -c "$(stat -c %s "$H/before")" "$PROJ/.agent-sandbox" | sha256sum)" = "$(sha256sum <"$H/before")" ]
  [ "$(grep -cxF '[connect:implementer-1]' "$PROJ/.agent-sandbox")" -eq 1 ]
  grep -qxF '[connect:implementer-2]' "$PROJ/.agent-sandbox"
  [ "$(cat "$PROJ/.asb/roles/implementer-1.md")" = NOTES ] # an existing purpose file is the user's
  [ -f "$PROJ/.asb/roles/implementer-2.md" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
  [ "$(grep -c '^| I2 |' "$PROJ/.asb/coord/COORDINATION.md")" -eq 1 ]
  [ "$(cat "$PROJ/.asb/.gitignore")" = '*' ]
  # the same counts again: nothing to add
  init -- roles planner=1 implementer=2 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing added to it"* ]]
}

@test "run again: a purpose file --init wrote and nobody changed takes the model's text; a changed one is kept" {
  cp -r "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- github
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.asb/init.sums" ]
  printf 'MINE\n' >>"$PROJ/.asb/roles/gh-triage.md" # the user's change
  printf 'NEW LINE\n' >>"$H/models/github/roles/gh-review.md"
  printf 'NEW LINE\n' >>"$H/models/github/roles/gh-triage.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/gh-review.md from model 'github'"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/gh-review.md")" = "NEW LINE" ]
  [[ "$output" == *"kept .asb/roles/gh-triage.md: changed since --init wrote it"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/gh-triage.md")" = MINE ]
  # the same text: nothing said, nothing written
  [[ "$output" != *"wrote .asb/roles/gh-fix.md"* ]]
  [[ "$output" != *"updated .asb/roles/gh-fix.md from model"* ]]
  [[ "$output" != *"kept .asb/roles/gh-fix.md"* ]]
  [[ "$output" == *"--trust"* ]] # a changed purpose file needs the approval again
  # a file from before the record is kept, even when it is the model's old text
  printf 'NEWER\n' >>"$H/models/github/roles/gh-review.md"
  rm "$PROJ/.asb/init.sums"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- github
  [[ "$output" == *"kept .asb/roles/gh-review.md"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/gh-review.md")" = "NEW LINE" ]
}

@test "--env: the [conda:...] sections written, and an environment cloned from it at each Implementer's prefix" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=2 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  has_section '[conda:planner-*]' "$PROJ/.agent-sandbox"
  grep -qx "prefix = $H/conda/envs/x-dev .*" "$PROJ/.agent-sandbox"
  has_section '[conda:implementer-2]' "$PROJ/.agent-sandbox"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/2/.env" "$H/conda.log"
  [ "$(wc -l <"$H/conda.log")" -eq 2 ]
}

@test "the written file passes the review, and --check shows a reviewer nothing writable but its own" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* ]]
  [[ "$output" != *"ignoring"* && "$output" != *"unknown"* ]]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role reviewer-1 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  local writable
  writable="$(sed -n '/^Binds, outer first:/,$p' <<<"$output" | grep -E '^  \./\S+ +read-write' | awk '{print $1}' | sort | paste -sd' ')"
  [ "$writable" = "./.asb/coord/reviewer-1 ./.asb/review/reviewer-1" ]
  [[ "$output" =~ \./\.asb/scratch\ +own ]]
  [[ "$output" =~ \./\.asb/git\ +own ]]
}

@test "the github model: appended once to a plain file, one shared block, three purpose files, the env layered by path" {
  printf '[allow]\nexample.org\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$H/envs/dev/conda-meta"
  init -- github --env "$H/envs/dev"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--role gh-review-<N> claude"* && "$output" == *"--role gh-fix-<N> claude"* ]]
  local df="$PROJ/.agent-sandbox"
  [ "$(head -2 "$df")" = $'[allow]\nexample.org' ] # what was there stays
  has_section '[connect:gh-*]' "$df"
  has_section '[net:gh-fix-*]' "$df"
  has_section '[connect:default]' "$df" # the unnamed role keeps the project's policy
  [ "$(grep -c '^\[connect:gh-\*\]' "$df")" -eq 1 ]
  grep -qx 'project = copy-on-write.*' "$df"
  grep -qx "$H/envs/dev/ = copy-on-write.*" "$df"
  run ! grep -qE '\[[a-z]+:gh-[a-z]+-[0-9]' "$df" # no per-number section
  grep -qx '# ~/\.ghstackrc = read-only .*' "$df" # ghstack's login (a token) is opt-in
  run ! grep -qE '^[[:space:]]*~/\.ghstackrc' "$df"
  has_section '[ssh:gh-fix-*]' "$df" # SSH for the push is opt-in: the host commented,
  grep -qx '# github\.com .*' "$df"  # with the command that turns it on
  grep -qxF "#   asb --apply '[ssh:gh-fix-*]' github.com" "$df"
  run ! grep -qE '^[[:space:]]*github\.com' "$df"
  for k in gh-review gh-triage gh-fix; do
    [ -f "$PROJ/.asb/roles/$k.md" ]
    run ! grep -qF '{' "$PROJ/.asb/roles/$k.md"
  done
  init -- github --env "$H/envs/dev"
  [[ "$output" == *"nothing added to it"* ]]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  # a reviewer fetches only and has no SSH; a fixer may push; the default role is admitted
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-review-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git transport: fetch only"* ]]
  [[ "$output" == *"briefed from: .asb/roles/gh-review.md"* ]]
  engine_cmd
  printf 'token\n' >"$H/home/.ghstackrc" # there, and still not bound
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-fix-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" != *"git transport: fetch only"* ]]
  local policy
  policy="$(sed -n '/^Policy:/,$p' <<<"$output")" # the table and binds, not the file shown
  [[ "$policy" == *"briefed from:"* && "$policy" != *ghstackrc* ]]
  [[ "$output" == *"briefed from: .asb/roles/gh-fix.md"* ]]
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh ]] # no host until applied
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[ssh:gh-fix-*]" github.com 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to [ssh:gh-fix-*]: github.com"*"approved."* ]]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-fix-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ SSH\ +github\.com\ \(\.agent-sandbox\ \[ssh:gh-fix-\*\]\)\ --\ through\ the\ broker ]]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-review-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" =~ SSH\ +no\ --\ --ssh\ is\ refused\ for\ this\ role ]] # the reviewer still has none
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"matches no role section"* ]]
}

@test "the github model without --env: the environment's lines written commented out; a missing --env made empty under the base" {
  init -- github
  [ "$status" -eq 0 ]
  grep -qx '# ENVPATH/ = copy-on-write.*' "$PROJ/.agent-sandbox"
  grep -qx '# \[conda:gh-\*\].*' "$PROJ/.agent-sandbox"
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -q '^1\. Check the build: `ENVPATH`' "$PROJ/.asb/roles/gh-review.md" # prose, not commented out
  # A model with a setup role accepts a missing NAME, made empty under the conda base
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env nosuch-env
  [ "$status" -eq 0 ] && [ -d "$H/base/envs/nosuch-env" ]
}

@test "--init --env NAME under agent-sandbox's micromamba: the prefix is under its conda root, and the message says so" {
  local root="$H/home/.local/share/agent-sandbox/conda"
  # no conda on the host -- and a CI runner has conda on PATH, so these stubs find none:
  # the default is the sandbox's own
  printf '#!/bin/sh\nexit 1\n' >"$H/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$H/bin/mamba"
  chmod +x "$H/bin/conda" "$H/bin/mamba"
  init -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"environment dev is not built yet (created empty at $root/envs/dev, under agent-sandbox's conda root)"*"--role gh-setup claude builds it"* ]]
  [ -d "$root/envs/dev" ] && [ -z "$(ls -A "$root/envs/dev")" ]
  grep -A3 -xF '[connect:gh-setup]' "$PROJ/.agent-sandbox" | grep -qx "$root/envs/dev/ = read-write.*"
  # a host base, but install.sh's answer was sandbox: the root, not the host's base
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  mkdir -p "$H/base/envs" "$H/home/.config/agent-sandbox"
  echo sandbox >"$H/home/.config/agent-sandbox/conda"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev2
  [ "$status" -eq 0 ]
  [ -d "$root/envs/dev2" ] && [ ! -e "$H/base/envs/dev2" ]
  # and the shell's variable wins over the file
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/base" AGENT_SANDBOX_CONDA_BASE=host -- github --env dev3
  [ "$status" -eq 0 ]
  [ -d "$H/base/envs/dev3" ] && [ ! -e "$root/envs/dev3" ]
  # an Implementer's clone is micromamba's, under the root
  local mm="$H/home/.local/share/agent-sandbox/micromamba/bin"
  mkdir -p "$mm"
  cp "$H/bin/conda-stub" "$mm/micromamba"
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  mkdir -p "$root/envs/x-dev/conda-meta"
  init CONDA_LOG="$H/mm.log" -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  grep -qx "create -q -y -r $root --clone x-dev -p $PROJ/.asb/impl/1/.env" "$H/mm.log"
}

@test "the github model takes an --env not built yet: its prefix made empty, gh-setup to build it, the others to check it" {
  mkdir -p "$H/base/envs"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env missing
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" ep="$H/base/envs/missing"
  [[ "$output" == *"environment missing is not built yet (created empty at $ep)"*"--role gh-setup claude builds it"* ]]
  [ -d "$ep" ] && [ -z "$(ls -A "$ep")" ]
  grep -A3 -xF '[connect:gh-setup]' "$df" | grep -qx 'project = read-write.*'
  grep -A3 -xF '[connect:gh-setup]' "$df" | grep -qx "$ep/ = read-write.*"
  grep -A2 -xF '[net:gh-setup]' "$df" | grep -qx 'retrieve-only = on.*'
  run ! grep -qF '#@' "$df"
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF "The environment's prefix, \`$ep\`, read-write" "$PROJ/.asb/roles/gh-setup.md"
  run ! grep -qF '{' "$PROJ/.asb/roles/gh-setup.md"
  grep -qF 'What you cannot retrieve' "$PROJ/.asb/roles/gh-setup.md"
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF '`~/git/<org>/<repo>/ = copy-on-write` under `[connect:gh-*]`' "$PROJ/.asb/roles/gh-setup.md"
  grep -qF 'build_env.sh' "$PROJ/.asb/roles/gh-setup.md"
  grep -qF '.asb/build_env.sh rebuild' "$PROJ/.asb/roles/gh-review.md"
  grep -qF 'is never restated' "$PROJ/.asb/roles/gh-review.md"
  for k in gh-review gh-triage gh-fix; do
    grep -qF "1. Check the build: \`$ep\` has \`conda-meta/\`" "$PROJ/.asb/roles/$k.md"
  done
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env missing # again: the empty prefix is still accepted
  [ "$status" -eq 0 ]
  [[ "$output" == *"environment missing is not built yet (empty at $ep)"* ]]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-setup 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  grep -qE '^  project +read-write +the working tree +\.agent-sandbox \[connect:gh-setup\]' <<<"$output"
  grep -E '^  \S+ +read-write +the same path +\.agent-sandbox \[connect:gh-setup\]' <<<"$output" | grep -qF "  $ep/ "
  grep -qE '^  gh +own +native +\.agent-sandbox \[connect:gh-setup\]' <<<"$output"
  [[ "$output" == *"network: retrieve-only"* && "$output" == *"git transport: refused"* ]]
  [[ "$output" == *"briefed from: .asb/roles/gh-setup.md"* ]]
}

@test "a model without a setup role still refuses an --env not built yet" {
  mkdir -p "$H/base/envs"
  init MAMBA_ROOT_PREFIX="$H/base" -- market --env missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"--env missing: no conda environment at $H/base/envs/missing"* ]]
  [ ! -e "$H/base/envs/missing" ]
}

@test "the market model in a repository's subdirectory: written there, .asb/ ignored, the repository's own files untouched" {
  mkdir -p "$PROJ/market"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --init market 2>&1 </dev/null' _ "$PROJ/market" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/market/.agent-sandbox" ]
  [ -f "$PROJ/market/.asb/roles/market.md" ]
  [ ! -e "$PROJ/.asb" ]
  # git sees the dot-file (yours to commit or not) and nothing of .asb/
  [ "$(git -C "$PROJ" status --porcelain --untracked-files=all)" = '?? market/.agent-sandbox' ]
  run ! grep -qF '.asb' "$PROJ/.git/info/exclude"
}

@test "the market model: in a directory that is no git repository; every public host, nothing of yours, no git, no GPU" {
  rm -rf "$PROJ/.git"
  mkdir -p "$H/envs/an/conda-meta"
  init -- roles # a model that clones needs a repository
  [ "$status" -ne 0 ]
  [[ "$output" == *"model 'roles' clones the project"*"is not in one"* ]]
  init -- market --env "$H/envs/an"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--role market-<N> claude"* ]]
  local df="$PROJ/.agent-sandbox"
  has_section '[net:market-*]' "$df"
  grep -qx 'hosts = public.*' "$df"
  grep -qx "$H/envs/an/ = copy-on-write.*" "$df"
  [ -f "$PROJ/.asb/roles/market.md" ]
  run ! grep -qF '{' "$PROJ/.asb/roles/market.md"
  [ ! -e "$PROJ/.git" ] # no repository made
  [ "$(cat "$PROJ/.asb/.gitignore")" = '*' ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[net] hosts = public: every public host is reachable"* ]]
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role market-laptops 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"network: every public host"* ]]
  [[ "$output" == *"git transport: refused"* ]]
  [[ "$output" == *"gpu: off"* ]]
  [[ "$output" == *"briefed from: .asb/roles/market.md"* ]]
}

@test "--disable-gpu / --enable-gpu write a [gpu:...] line for the model's roles, the broadest patterns only" {
  init -- github --disable-gpu
  [ "$status" -eq 0 ]
  has_section '[gpu:gh-*]' "$PROJ/.agent-sandbox"
  run ! grep -qF '[gpu:gh-fix-*]' "$PROJ/.agent-sandbox" # covered by gh-*
  grep -A1 -F '[gpu:gh-*]' "$PROJ/.agent-sandbox" | grep -qx 'mode = off'
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init -- roles planner=1 implementer=1 reviewer=1 --enable-gpu
  [ "$status" -eq 0 ]
  for p in 'planner-*' 'implementer-*' 'reviewer-*' 'supervisor'; do
    has_section "[gpu:$p]" "$PROJ/.agent-sandbox"
  done
  grep -A1 -F '[gpu:supervisor]' "$PROJ/.agent-sandbox" | grep -qx 'mode = on'
}

# section HEADER FILE -- the lines of every section FILE has under HEADER.
section() { awk -v h="$1" '$1 == h { on = 1; next } /^(# )?\[/ { on = 0 } on' "$2"; }
# check ROLE -- `asb --check --role ROLE` from the project.
check() {
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --profile claude --check --role "$0" 2>&1 </dev/null' \
    "$1" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
}
approve() {
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}

@test "the roles model's common block is scoped to its roles: a copy per role pattern, the instances' sections after them, a role's own key winning (#267)" {
  mkdir -p "$H/conda/envs/E/conda-meta"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env E
  [ "$status" -eq 0 ]
  [[ "$output" == *"(P1 I1 R1 S G setup)"* ]] # the setup role has no handle
  local df="$PROJ/.agent-sandbox" p last first
  run ! grep -qE '^(# )?\[(sandbox|conda|connect|net)\]' "$df" # nothing reaches another model's roles
  head -1 "$df" | grep -qxF '# ---- written by asb --init roles ----'
  for p in 'planner-*' 'implementer-*' 'reviewer-*'; do
    section "[sandbox:$p]" "$df" | grep -qx 'preset = inherit'
    section "[conda:$p]" "$df" | grep -qx "prefix = $H/conda/envs/E .*"
    section "[connect:$p]" "$df" | grep -qx 'project = read-only .*'
    section "[connect:$p]" "$df" | grep -qx '\./\.git/ = own .*'
    section "[connect:$p]" "$df" | grep -qx 'gh = read-only .*'
    section "[net:$p]" "$df" | grep -qx 'retrieve-only = on'
    section "[net:$p]" "$df" | grep -qx 'git = refuse'
  done
  # a single role's copy leaves out what its own section of that header sets
  section '[connect:supervisor]' "$df" | grep -qx '\.asb/coord/ = read-only .*'
  [ "$(section '[connect:supervisor]' "$df" | grep -c '^project = ')" -eq 1 ]
  section '[connect:supervisor]' "$df" | grep -qx 'project = read-write .*'
  run ! grep -qF '[net:setup]                       # every role' "$df" # nothing of it left for setup
  # every copy before the first instance's section
  last="$(grep -n '^\[connect:setup\]' "$df" | head -1 | cut -d: -f1)" # the last pattern's copy
  first="$(grep -n '^\[connect:planner-1\]' "$df" | cut -d: -f1)"
  ((last < first))
  # the setup role: no index row, its purpose file
  run ! grep -q '| setup |' "$PROJ/.asb/coord/COORDINATION.md"
  grep -qF "the environment at \`$H/conda/envs/E\`" "$PROJ/.asb/roles/setup.md"
  run ! grep -qF '{' "$PROJ/.asb/roles/setup.md"
  approve
  [ "$status" -eq 0 ]
  [[ "$output" != *"set twice"* ]]
  check implementer-1
  [ "$status" -eq 0 ]
  grep -qE '^  project +read-only +the working tree +\.agent-sandbox \[connect:implementer-\*\]' <<<"$output"
  grep -qE '^  \./\.git/ +read-only +the same path +\.agent-sandbox \[connect:implementer-1\]' <<<"$output"
  [[ "$output" == *"network: retrieve-only"* && "$output" == *"git transport: refused"* ]]
  [[ "$output" != *"set twice"* ]]
  # the instance's prefix over the scoped one: its clone is the env a launch activates
  run_engine MAMBA_ROOT_PREFIX="$H/conda" AGENT_SANDBOX_NET=open -- asb --role implementer-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$PROJ/.asb/impl/1/.env" ]
  run_engine MAMBA_ROOT_PREFIX="$H/conda" AGENT_SANDBOX_NET=open -- asb --role planner-1 claude --version
  [ "$(setenv_value CONDA_PREFIX)" = "$H/conda/envs/E" ]
  check planner-1
  [ "$status" -eq 0 ]
  grep -qE '^  project +read-only +the working tree +\.agent-sandbox \[connect:planner-\*\]' <<<"$output"
  grep -qE '^  \./\.git/ +own +the same path +\.agent-sandbox \[connect:planner-\*\]' <<<"$output"
  [[ "$output" == *"network: retrieve-only"* && "$output" == *"git transport: refused"* ]]
  check setup
  [ "$status" -eq 0 ]
  grep -qE '^  project +read-write +the working tree +\.agent-sandbox \[connect:setup\]' <<<"$output"
  grep -qE '^  \./\.git/ +read-only +the same path +\.agent-sandbox \[connect:setup\]' <<<"$output"
  grep -E '^  \S+ +read-write +the same path +\.agent-sandbox \[connect:setup\]' <<<"$output" | grep -qF "  $H/conda/envs/E/ "
  grep -qE '^  gh +own +native +\.agent-sandbox \[connect:setup\]' <<<"$output"
  [[ "$output" == *"network: retrieve-only"* && "$output" == *"git transport: refused"* ]]
  [[ "$output" == *"briefed from: .asb/roles/setup.md"* ]]
}

@test "two models compose in one file, either order: github's roles keep github's policy, the roles model's its own (#267)" {
  mkdir -p "$H/conda/envs/E/conda-meta"
  local order
  for order in "github roles" "roles github"; do
    rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
    for m in $order; do
      if [[ "$m" == roles ]]; then
        init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env E
      else
        init MAMBA_ROOT_PREFIX="$H/conda" -- github --env E
      fi
      [ "$status" -eq 0 ]
    done
    grep -qxF '# ---- added by asb --init '"${order#* }"' ----' "$PROJ/.agent-sandbox"
    approve
    [ "$status" -eq 0 ]
    check gh-review-1
    [ "$status" -eq 0 ]
    grep -qE '^  project +copy-on-write +the working tree +\.agent-sandbox \[connect:gh-\*\]' <<<"$output"
    [[ "$output" == *"git transport: fetch only"* ]]
    [[ "$output" != *"network: retrieve-only"* ]]
    run ! grep -qE '^  \./\.git/ ' <<<"$output" # no history of its own: the project's, in its layer
    run ! grep -qE '^  \.asb/coord/ ' <<<"$output"
    check planner-1
    [ "$status" -eq 0 ]
    grep -qE '^  project +read-only +the working tree +\.agent-sandbox \[connect:planner-\*\]' <<<"$output"
    [[ "$output" == *"network: retrieve-only"* && "$output" == *"git transport: refused"* ]]
    check gh-setup
    [ "$status" -eq 0 ]
    grep -qE '^  project +read-write +the working tree +\.agent-sandbox \[connect:gh-setup\]' <<<"$output"
    check setup
    [ "$status" -eq 0 ]
    grep -qE '^  project +read-write +the working tree +\.agent-sandbox \[connect:setup\]' <<<"$output"
  done
}

@test "role patterns of two models must not collide, naming both; the same model run again adds its instances (#267)" {
  init -- github
  [ "$status" -eq 0 ]
  cp "$PROJ/.agent-sandbox" "$H/before"
  mkdir -p "$H/m/ghx" "$H/m/bot" "$H/m/sup"
  printf '[connect:gh-{n}]\n.asb/x-{n}/ = read-write\n' >"$H/m/ghx/agent-sandbox"
  printf '[connect:gh-review-bot]\n.asb/bot/ = read-write\n' >"$H/m/bot/agent-sandbox"
  printf '[connect:supervisor]\n.asb/sup/ = read-write\n' >"$H/m/sup/agent-sandbox"
  init AGENT_SANDBOX_MODELS_DIR="$H/m" -- ghx
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: model 'ghx' uses role pattern gh-*, and this .agent-sandbox already has sections for gh-* (another model, or an earlier --init): two models need distinct role names"* ]]
  init AGENT_SANDBOX_MODELS_DIR="$H/m" -- bot
  [ "$status" -ne 0 ]
  [[ "$output" == *"model 'bot' uses role pattern gh-review-bot, and this .agent-sandbox already has sections for gh-*"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox" # refused before anything is written
  # the shipped models are disjoint; the same model again only adds
  init -- roles planner=1
  [ "$status" -eq 0 ]
  init -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing added to it"* ]]
  init -- roles planner=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:planner-2] [serve:planner-2] [connect:planner-3] [serve:planner-3]"* ]]
  init AGENT_SANDBOX_MODELS_DIR="$H/m" -- sup
  [ "$status" -ne 0 ]
  [[ "$output" == *"model 'sup' uses role pattern supervisor, and this .agent-sandbox already has sections for supervisor"* ]]
}

@test "a file with no --init line is a model's own when it has one of the model's role sections: github from before gh-setup (#267)" {
  printf '[connect:gh-*]\nproject = copy-on-write\n[briefing:gh-review-*]\nfile = .asb/roles/gh-review.md\n' >"$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  has_section '[connect:gh-setup]' "$PROJ/.agent-sandbox" # what it lacked is added
  [ "$(grep -c '^\[connect:gh-\*\]' "$PROJ/.agent-sandbox")" -eq 1 ]
  # a marker-less file of another model's roles is still a collision
  printf '[connect:gh-review-bot]\n' >"$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -ne 0 ]
  [[ "$output" == *"uses role pattern gh-*, and this .agent-sandbox already has sections for gh-review-bot"* ]]
}

@test "a file the old --init wrote, its common block unsuffixed, is refused by any model's --init, naming the blocks to remove (#267)" {
  printf '[connect]\nproject = read-only\n[net]\nretrieve-only = on\n[connect:planner-*]\n.asb/plan/ = read-write\n' >"$PROJ/.agent-sandbox"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: this .agent-sandbox has model 'roles''s common sections unsuffixed, written by an earlier --init"*"remove its unsuffixed [connect]/[net] blocks (or start from a fresh file) and run --init again"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.asb" ]
  # any model's --init: github's on an old roles file, whose [net] would reach gh-*
  init -- github
  [ "$status" -ne 0 ]
  [[ "$output" == *"has model 'roles''s common sections unsuffixed"*"remove its unsuffixed [connect]/[net] blocks"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  # an unsuffixed section of your own, with nothing of the model's, is yours: kept
  printf '[net]\nmode = strict\n' >"$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
}

@test "the roles model takes an --env not built yet: the prefix made empty, setup to build it, no clone until it has (#267)" {
  mkdir -p "$H/conda/envs"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env missing
  [ "$status" -eq 0 ]
  local ep="$H/conda/envs/missing"
  [ -d "$ep" ] && [ -z "$(ls -A "$ep")" ]
  [[ "$output" == *"environment missing is not built yet (created empty at $ep)"*"--role setup claude builds it"* ]]
  [[ "$output" == *"--init: no environment for implementer-1 yet: missing is not built, so there is nothing to clone into .asb/impl/1/.env; once agent-sandbox --role setup claude has built it, run --init again and it clones it"* ]]
  [ ! -e "$H/conda.log" ] && [ ! -e "$PROJ/.asb/impl/1/.env" ]
  [ -f "$PROJ/.asb/impl/1/.git" ] # the clone of the project is made all the same
  mkdir "$ep/conda-meta"          # what the setup role does
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env missing
  [ "$status" -eq 0 ]
  grep -qx "create -q -y --clone missing -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
}

# shared_env NAME -- a built env under $H/conda/envs/NAME whose editable installs import from
# $H/src/torch (direct_url.json, pip install -e) and $H/src/vision (an .egg-link, setup.py
# develop); a .pth line inside the env itself is not a source.
shared_env() {
  local ep="$H/conda/envs/$1" sp
  sp="$ep/lib/python3.12/site-packages"
  mkdir -p "$ep/conda-meta" "$sp/torch-2.15.dist-info" "$sp/extra" "$H/src/torch" "$H/src/vision"
  printf '{"url": "file://%s/src/torch", "dir_info": {"editable": true}}\n' "$H" >"$sp/torch-2.15.dist-info/direct_url.json"
  printf '%s/src/vision\n.\n' "$H" >"$sp/torchvision.egg-link"
  printf '%s\n' "$sp/extra" >"$sp/extra.pth"
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

@test "the roles model: the Gate publishes and the Supervisor does not -- [ssh:gate] commented out with its --apply line, the Gate's network, no [ssh:supervisor] (#274)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  grep -A2 -xF '[ssh:gate]' "$df" | grep -qF "#   asb --apply '[ssh:gate]' github.com"
  run ! grep -qE '^github\.com' "$df"
  run ! grep -qF '[ssh:supervisor]' "$df"
  # the Supervisor's network is the common block's: it reads, and publishes nothing
  section '[net:supervisor]' "$df" | grep -qx 'retrieve-only = on'
  section '[net:supervisor]' "$df" | grep -qx 'git = refuse'
  run ! grep -qx 'retrieve-only = off' <<<"$(section '[net:supervisor]' "$df")"
  [ "$(grep -c '^\[net:supervisor\]' "$df")" -eq 1 ]
  # the Gate's: strict, writes allowed, git allowed; main and its history read-only
  section '[net:gate]' "$df" | grep -qx 'mode = strict'
  section '[net:gate]' "$df" | grep -qx 'retrieve-only = off'
  section '[net:gate]' "$df" | grep -qx 'git = allow'
  section '[connect:gate]' "$df" | grep -qx 'project = read-only .*'
  section '[connect:gate]' "$df" | grep -qx '\./\.git/ = read-only .*'
  section '[connect:gate]' "$df" | grep -qx 'gh = read-only .*'
  section '[connect:gate]' "$df" | grep -qx '\.asb/coord/gate/ = read-write .*'
  section '[briefing:gate]' "$df" | grep -qx 'file = .asb/roles/gate.md'
  head -1 "$PROJ/.asb/roles/gate.md" | grep -q 'called G: the Gate of'
  grep -qF "git push \"\$(git remote get-url origin)\" BRANCH" "$PROJ/.asb/roles/gate.md"
  grep -qF "asb --apply '[ssh:gate]' HOST" "$PROJ/.asb/roles/gate.md"
  run ! grep -qF 'publish -- push the branch' "$PROJ/.asb/roles/supervisor.md"
  grep -q '^| G | gate | .asb/coord/gate/messages.md | - |$' "$PROJ/.asb/coord/COORDINATION.md"
}

@test "the roles model: an inbox per role under .asb/coord/to/, only the Supervisor's to write; the watcher shipped executable, kept when changed (#274)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" r
  for r in planner-1 planner-2 implementer-1 reviewer-1 gate; do
    [ -f "$PROJ/.asb/coord/to/$r.md" ] && [ ! -s "$PROJ/.asb/coord/to/$r.md" ]
  done
  [ ! -e "$PROJ/.asb/coord/to/supervisor.md" ] && [ ! -e "$PROJ/.asb/coord/to/setup.md" ]
  [ ! -e "$PROJ/.asb/coord/planner-1/alive" ] # the watcher makes it
  # the Supervisor alone writes the inboxes; every other role reads them with .asb/coord/
  [ "$(grep -c '^\.asb/coord/to/ = read-write' "$df")" -eq 1 ]
  section '[connect:supervisor]' "$df" | grep -q '^\.asb/coord/to/ = read-write'
  run ! grep -qF '#@' "$df"
  grep -q '^| S | supervisor | .asb/coord/supervisor/messages.md | .asb/coord/to/ |$' "$PROJ/.asb/coord/COORDINATION.md"
  # the watcher, and the rules that run it without a prompt, for every role
  [ -x "$PROJ/.asb/bin/inbox-wait" ]
  cmp -s "$PROJ/.asb/bin/inbox-wait" "$(dirname "$ENGINE")/models/roles/bin/inbox-wait"
  for r in 'planner-*' 'implementer-*' 'reviewer-*' supervisor gate; do
    section "[permissions:$r]" "$df" | grep -qxF 'Bash(.asb/bin/inbox-wait:*)'
  done
  grep -A6 -xF '[permissions:gate]                # the verbs it executes, each from an approved message' "$df" | grep -qxF 'Bash(git push:*)'
  # the purpose files arm it, with the role's own inbox and alive file
  grep -qxF 'while .asb/bin/inbox-wait .asb/coord/to/planner-2.md 0 .asb/coord/planner-2/alive' "$PROJ/.asb/roles/planner-2.md"
  grep -qF 'done; in my file; S has it' "$PROJ/.asb/roles/reviewer-1.md"
  grep -qxF 'while .asb/bin/inbox-wait .asb/coord/ROLE/messages.md 0' "$PROJ/.asb/roles/supervisor.md"
  # run again: an inbox with messages, and a changed watcher, are kept
  printf '## 1\nread P1\n' >"$PROJ/.asb/coord/to/planner-1.md"
  printf '#!/bin/sh\nexit 0\n' >"$PROJ/.asb/bin/inbox-wait"
  rm "$PROJ/.asb/coord/to/reviewer-1.md"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/bin/inbox-wait: changed since --init wrote it"* ]]
  [ "$(cat "$PROJ/.asb/coord/to/planner-1.md")" = $'## 1\nread P1' ]
  [ -f "$PROJ/.asb/coord/to/reviewer-1.md" ] # a missing one is made again
  [ "$(cat "$PROJ/.asb/bin/inbox-wait")" = $'#!/bin/sh\nexit 0' ]
}

@test "the written roles file passes the review: each [permissions] rule named, the Gate's too (#274)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"[permissions:gate] Bash(git push:*): a permission rule the agent gets without asking you, for the roles gate"* ]]
  [[ "$output" == *"[permissions:planner-*] Bash(.asb/bin/inbox-wait:*): a permission rule"* ]]
  [[ "$output" != *"bad rule"* && "$output" != *"set twice"* ]]
}

# shellcheck disable=SC2016 # backquotes and $(...) are the purpose files' text, not ours
@test "the roles model: a [serve:ROLE] per Planner, Implementer and Reviewer, its prompt file written and kept; none for the Supervisor, the Gate or setup (#277)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" r m
  m="$(dirname "$ENGINE")/models/roles"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    [ "$(section "[serve:$r]" "$df")" = "$(printf 'watch = .asb/coord/to/%s.md\nprompt = .asb/serve/%s.md' "$r" "$r")" ]
    cmp -s "$PROJ/.asb/serve/$r.md" "$m/serve/${r%-*}.md"
    grep -qF 'Under `--serve` (no terminal) each message is a turn of your own' "$PROJ/.asb/roles/$r.md"
  done
  grep -qxF '[serve:implementer-1]           # no terminal: asb --role implementer-1 --serve claude' "$df"
  for r in supervisor gate setup; do
    run ! grep -qF "[serve:$r]" "$df"
    [ ! -e "$PROJ/.asb/serve/$r.md" ]
  done
  # the Supervisor names both forms, and the terminal on a served session
  grep -qF '`asb --role NAME --serve claude`' "$PROJ/.asb/roles/supervisor.md"
  grep -qF '`asb --role NAME claude --resume $(cat .asb/coord/NAME/session)`' "$PROJ/.asb/roles/supervisor.md"
  # the review says what each loop waits on and reads; --check names the role's
  approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"[serve:implementer-1], for the roles implementer-1: \`asb --role ROLE --serve CMD\` holds the role's launch on the host and, at each change to .asb/coord/to/implementer-1.md, runs one turn of the role's session in its sandbox, told the text of .asb/serve/implementer-1.md"* ]]
  check implementer-1
  [[ "$output" == *"--serve: a turn of its session per change to .asb/coord/to/implementer-1.md, told the text of .asb/serve/implementer-1.md"$'\n'* ]]
  # run again: a prompt you changed is kept
  printf 'mine\n' >"$PROJ/.asb/serve/planner-1.md"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/serve/planner-1.md: changed since --init wrote it"* ]]
  [ "$(cat "$PROJ/.asb/serve/planner-1.md")" = mine ]
}
