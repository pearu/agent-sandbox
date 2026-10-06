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
  run bash -c 'proj="$1" home="$2" path="$3" eng="$4"; shift 4; n="$1"; shift; envs=("${@:1:n}"); shift "$n"
    cd "$proj" && env -i HOME="$home" PATH="$path" "${envs[@]}" "$eng" --init "$@" 2>&1 </dev/null' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE" "${#envs[@]}" ${envs[@]+"${envs[@]}"} "$@"
}

@test "the roles model: every instance's sections, purpose files, clones, directories, the index and the exclude" {
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
  [ -f "$PROJ/.asb/coord/planner-1.md" ]
  grep -q '^| I1 | implementer-1 | .asb/coord/implementer-1.md | .asb/handoff/implementer-1/, .asb/impl/1/, .asb/git/1/ |$' "$PROJ/.asb/coord/COORDINATION.md"
  grep -q '^| S | supervisor |' "$PROJ/.asb/coord/COORDINATION.md"
  [ "$(grep -cxF '/.asb/' "$PROJ/.git/info/exclude")" -eq 1 ]
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
  [[ "$output" == *"has no role 'tester' (it has: planner implementer reviewer supervisor)"* ]]
  init -- roles supervisor=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 or 1 for supervisor"* ]]
  init -- roles planner=x
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/.agent-sandbox" ]
}

@test "a model whose roles share an initial is refused; so is an unknown model, and a directory that is not a repository's top" {
  mkdir -p "$H/m/pairs"
  printf '[connect:planner-{n}]\n.asb/a/ = read-write\n[connect:prober-{n}]\n.asb/b/ = read-write\n' >"$H/m/pairs/agent-sandbox"
  init -- "$H/m/pairs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"roles 'planner' and 'prober'"*"share the initial P"* ]]
  init -- nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no model 'nosuch'"*"Shipped: github roles"* ]]
  mkdir -p "$PROJ/sub"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --init roles 2>&1' _ "$PROJ/sub" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"top of a git repository"* ]]
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
  [ "$(grep -cxF '/.asb/' "$PROJ/.git/info/exclude")" -eq 1 ]
  # the same counts again: nothing to add
  init -- roles planner=1 implementer=2 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing added to it"* ]]
}

@test "--env: the [conda] sections written, and an environment cloned from it at each Implementer's prefix" {
  init CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=2 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  grep -qxF '[conda]' "$PROJ/.agent-sandbox"
  grep -qx 'name = x-dev.*' "$PROJ/.agent-sandbox"
  has_section '[conda:implementer-2]' "$PROJ/.agent-sandbox"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/2/.env" "$H/conda.log"
  [ "$(wc -l <"$H/conda.log")" -eq 2 ]
}

@test "the written file passes the review, and --check shows a reviewer nothing writable but its own" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "$4" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* ]]
  [[ "$output" != *"ignoring"* && "$output" != *"unknown"* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --profile claude --check --role reviewer-1 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  local writable
  writable="$(sed -n '/^Binds, outer first:/,$p' <<<"$output" | grep -E '^  \./\S+ +read-write' | awk '{print $1}' | sort | paste -sd' ')"
  [ "$writable" = "./.asb/coord/reviewer-1.md ./.asb/review/reviewer-1" ]
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
  for k in gh-review gh-triage gh-fix; do
    [ -f "$PROJ/.asb/roles/$k.md" ]
    run ! grep -qF '{' "$PROJ/.asb/roles/$k.md"
  done
  init -- github --env "$H/envs/dev"
  [[ "$output" == *"nothing added to it"* ]]
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "$4" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  # a reviewer fetches only and has no SSH; a fixer may push; the default role is admitted
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --profile claude --check --role gh-review-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git transport: fetch only"* ]]
  [[ "$output" == *"briefed from: .asb/roles/gh-review.md"* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --profile claude --check --role gh-fix-1234 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [[ "$output" != *"git transport: fetch only"* ]]
  [[ "$output" == *"briefed from: .asb/roles/gh-fix.md"* ]]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --profile claude --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"matches no role section"* ]]
}

@test "the github model without --env: the environment's lines written commented out; a bad --env refused" {
  init -- github
  [ "$status" -eq 0 ]
  grep -qx '# ENVPATH/ = copy-on-write.*' "$PROJ/.agent-sandbox"
  grep -qx '# \[conda:gh-\*\].*' "$PROJ/.agent-sandbox"
  init -- github --env nosuch-env
  [ "$status" -ne 0 ]
  [[ "$output" == *"--env nosuch-env: no conda environment"* ]]
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
