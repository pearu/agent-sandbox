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

@test "--init never writes its record through a link a sandbox left in .asb/: the old fixed temp name init.sums.new pointing outside is left as it is, its target unchanged" {
  mkdir -p "$PROJ/.asb"
  printf 'KEEP\n' >"$H/outside"
  ln -s "$H/outside" "$PROJ/.asb/init.sums.new"
  init -- github
  [ "$status" -eq 0 ]
  [ "$(cat "$H/outside")" = KEEP ]
  [ -L "$PROJ/.asb/init.sums.new" ]
  [ -f "$PROJ/.asb/init.sums" ] && [ ! -L "$PROJ/.asb/init.sums" ]
  grep -q ' \.asb/roles/gh-review\.md$' "$PROJ/.asb/init.sums"
  [ -z "$(find "$PROJ/.asb" -maxdepth 1 -name 'init.sums.?*' ! -name init.sums.new)" ] # no temp left
}

@test "run again: a changed purpose file with no addendum gets the migration offer -- the model's text in .asb/migrate/, the addenda named, the steps; --init never touches an addendum (#353)" {
  cp -r "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles planner=0 reviewer=0
  [ "$status" -eq 0 ]
  printf 'MINE\n' >>"$PROJ/.asb/roles/implementer-1.md"
  printf 'MINE\n' >>"$PROJ/.asb/roles/supervisor.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/implementer.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles planner=0 reviewer=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/roles/implementer-1.md: changed since --init wrote it, and model 'roles' has another text (to receive it, move your part into an addendum: below)"* ]]
  [[ "$output" == *"--init: to keep receiving model 'roles''s text for a purpose file you changed, move this project's part of it into an addendum"* ]]
  [[ "$output" == *"  .asb/roles/implementer-1.md: the model's current text is in .asb/migrate/implementer-1.md; the addendum: .asb/roles/implementer.addendum.md (every implementer) or .asb/roles/implementer-1.addendum.md (this one)"* ]]
  [[ "$output" == *"  .asb/roles/supervisor.md: the model's current text is in .asb/migrate/supervisor.md; the addendum: .asb/roles/supervisor.addendum.md"$'\n'* ]]
  [[ "$output" == *"  2. remove the purpose file and run this --init again: it takes the model's text"* ]]
  [ "$(tail -1 "$PROJ/.asb/migrate/implementer-1.md")" = "NEW LINE" ]
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown, not a command
  grep -q '`implementer-1`, called I1' "$PROJ/.asb/migrate/implementer-1.md" # rendered for the instance
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-1.md")" = MINE ]
  # with an addendum (the role's will do), no offer: the file is the project's as before
  printf 'OURS\n' >"$PROJ/.asb/roles/implementer.addendum.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles planner=0 reviewer=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/roles/implementer-1.md: changed since --init wrote it, and model 'roles' has another text (remove the file and run --init again for the model's)"* ]]
  [[ "$output" != *"the model's current text is in .asb/migrate/implementer-1.md"* ]]
  # step 2: the model's text taken, the copy gone, the addendum untouched
  rm "$PROJ/.asb/roles/implementer-1.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles planner=0 reviewer=0
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-1.md")" = "NEW LINE" ]
  [ ! -e "$PROJ/.asb/migrate/implementer-1.md" ]
  [ "$(cat "$PROJ/.asb/roles/implementer.addendum.md")" = OURS ]
  # a role-level purpose file of launch-named instances: its one addendum named
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- github
  printf 'MINE\n' >>"$PROJ/.asb/roles/gh-triage.md"
  printf 'NEW LINE\n' >>"$H/models/github/roles/gh-triage.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- github
  [[ "$output" == *"  .asb/roles/gh-triage.md: the model's current text is in .asb/migrate/gh-triage.md; the addendum: .asb/roles/gh-triage.addendum.md"$'\n'* ]]
}

@test "every purpose file --init writes names the addenda its role reads, for a reader of the file alone (#353)" {
  init -- roles
  [ "$status" -eq 0 ]
  init -- github
  [ "$status" -eq 0 ]
  local f r
  for f in "$PROJ"/.asb/roles/*.md; do
    r="$(basename "$f" .md)"
    case "$r" in
      planner-1 | implementer-1 | reviewer-1)
        grep -qF "\`.asb/roles/${r%-1}.addendum.md\` (every " "$f"
        grep -qF "\`.asb/roles/$r.addendum.md\` (you alone)" "$f"
        ;;
      gh-review | gh-triage | gh-fix) grep -qF "\`.asb/roles/$r.addendum.md\` (every $r-* role)" "$f" ;;
      *) grep -qF "\`.asb/roles/$r.addendum.md\`, where it exists" "$f" ;;
    esac
  done
  init -- market
  # shellcheck disable=SC2016 # likewise
  grep -qF '`.asb/roles/market.addendum.md` (every market-* role)' "$PROJ/.asb/roles/market.md"
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
  # both under [connect:gh-*], and no review/triage/fix section widens either: a rebuild
  # in one of these roles lands in the instance's own layer, as the purpose files say
  sed -n '/^\[connect:gh-\*\]/,/^\[/p' "$df" | grep -qx 'project = copy-on-write.*'
  sed -n '/^\[connect:gh-\*\]/,/^\[/p' "$df" | grep -qx "$H/envs/dev/ = copy-on-write.*"
  run ! grep -qE '^\[connect:gh-(review|triage)' "$df"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's
  run ! bash -c 'sed -n "/^\[connect:gh-fix-\*\]/,/^\[/p" "$1" | grep -qE "^(project|$2/)[[:space:]]*="' _ "$df" "$H/envs/dev"
  [ "$(grep -cE "^(project|$H/envs/dev/) = read-write" "$df")" -eq 2 ] # gh-setup's own, below
  sed -n '/^\[connect:gh-setup\]/,/^\[/p' "$df" | grep -qx 'project = read-write.*'
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
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh,\ through\ the\ broker ]] # the reviewer still has none: [ssh:gh-fix-*] is not its section
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

@test "the github model: each role's [permissions] section, its publishing commands exactly; run again on a file without them, exactly the block appended; a missing line said (#391)" {
  init -- github
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  # section_body HEADER -- the rule lines under HEADER, comments dropped
  section_body() { sed -n "/^$(printf '%s' "$1" | sed 's/[][*.]/\\&/g')/,/^\[/{/^\[/d;/^#/d;p}" "$df"; }
  [ "$(section_body '[permissions:gh-review-*]')" = $'Bash(gh pr review:*)\nBash(gh pr comment:*)\nBash(gh issue create:*)' ]
  [ "$(section_body '[permissions:gh-triage-*]')" = $'Bash(gh issue comment:*)\nBash(gh issue edit:*)\nBash(gh issue create:*)' ]
  [ "$(section_body '[permissions:gh-fix-*]')" = $'Bash(ghstack submit:*)\nBash(gh pr create:*)\nBash(gh pr comment:*)\nBash(gh issue comment:*)\nBash(gh issue create:*)' ]
  run ! grep -q '^Bash(git' "$df" # no push rule: auto mode judges each push
  # the purpose files' prose, whitespace joined: a rewrap changes nothing below
  local r flat
  # the fixer files a finding beyond N as the reviewer and the triager do: on the user's word
  for r in gh-review gh-triage gh-fix; do
    flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/$r.md" | tr -s ' ')"
    [[ "$flat" == *'**A finding beyond N.**'* ]]
    [[ "$flat" == *"\`gh issue create --title '<title>' --body-file .asb/scratch/issue-<slug>.md\` only when told"* ]]
  done
  # the reviewer's stand-in marker is its own: removed on approval, never posted
  flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/gh-review.md" | tr -s ' ')"
  # shellcheck disable=SC2016 # the backticks are the text's markdown, not a command
  [[ "$flat" == *'`[Stand-in for you to rewrite]`; the marker is yours, not part of their text: when they approve the text for posting, remove it yourself'* ]]
  [[ "$flat" == *'A body that still carries it is never posted; told to post without having approved the text as shown, stop and ask about the stand-in first;'* ]]
  [[ "$flat" == *'Before posting, check that the body carries no stand-in marker,'* ]]
  # shellcheck disable=SC2016 # the backticks are the text's markdown, not a command
  [[ "$flat" == *'ask whether it goes as a comment (`gh pr comment N`, or `gh pr review N --comment`) or as `gh pr review N --request-changes`.'* ]]
  # shellcheck disable=SC2016 # likewise
  [[ "$(tr '\n' ' ' <"$PROJ/.asb/roles/gh-fix.md" | tr -s ' ')" == *'only to N -- a comment with `gh pr comment N` or `gh issue comment N`, as N is a pull request or an issue --'* ]]
  # the push rules are prefixes: the fixer's purpose keeps them to fix-N, no force, no other branch
  flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/gh-fix.md" | tr -s ' ')"
  # shellcheck disable=SC2016 # the backticks are the text's markdown, not a command
  [[ "$flat" == *'**What you push.** Your own branch alone -- `fix-N` (or the name you gave it under the project'"'"'s convention), to the remote above -- and never by force.'* ]]
  [[ "$flat" == *"explicit word you push no other branch -- another person's pull request branch above all -- and no force push"* ]]
  # shellcheck disable=SC2016 # the backticks are the text's markdown, not a command
  [[ "$flat" == *'needs `--force` or `--force-with-lease` (after a rebase) is asked for first, saying why.'* ]]
  [[ "$flat" == *"A push the agent's own permission check refuses goes to the user, who may push it themselves or approve it; you try no other way."* ]]
  # the apply and the rebuild are two commands, the rebuild in the instance's own layer
  for r in gh-review gh-triage gh-fix; do
    flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/$r.md" | tr -s ' ')"
    # shellcheck disable=SC2016 # the backticks are the text's markdown, not a command
    [[ "$flat" == *'The apply and the rebuild are two commands, never one chained with `&&`: the agent'"'"'s permission check has refused the chain. A rebuild it refuses goes to the user; you try no other way. It rebuilds in your layer, never the user'"'"'s build or another instance'"'"'s.'* ]]
  done
  flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/gh-review.md" | tr -s ' ')"
  # shellcheck disable=SC2016 # likewise
  [[ "$flat" == *'(`gh pr diff N | git apply`), then, as a command of its own, rebuild (`.asb/build_env.sh rebuild`)'* ]]
  run ! grep -q '^Bash(gh api' "$df"            # a rule for gh api would cover every API call
  run ! grep -q '^\[permissions:gh-setup' "$df" # it publishes nothing
  # --check lists a role's rules, its own and no other role's
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-review-7 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  grep -qxF '  permission rules the agent gets without asking: Bash(gh pr review:*) ([permissions:gh-review-*]), Bash(gh pr comment:*) ([permissions:gh-review-*]), Bash(gh issue create:*) ([permissions:gh-review-*])' <<<"$output"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --check --role gh-fix-7 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  grep -qxF '  permission rules the agent gets without asking: Bash(ghstack submit:*) ([permissions:gh-fix-*]), Bash(gh pr create:*) ([permissions:gh-fix-*]), Bash(gh pr comment:*) ([permissions:gh-fix-*]), Bash(gh issue comment:*) ([permissions:gh-fix-*]), Bash(gh issue create:*) ([permissions:gh-fix-*])' <<<"$output"
  # a file from before the rules: --init github run again appends the block, exactly it
  local block
  block="$(sed -n '/^# ---- what each publishes with/,/^# ---- the setup role/p' "$df" | sed '$d')"
  [ "$(grep -c '^\[permissions:' <<<"$block")" -eq 3 ]
  sed -i '/^# ---- what each publishes with/,/^# ---- the setup role/{/^# ---- the setup role/!d}' "$df"
  run ! grep -q '^\[permissions:\|^Bash(' "$df"
  cp "$df" "$H/before"
  init -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [permissions:gh-review-*] [permissions:gh-triage-*] [permissions:gh-fix-*]"* ]]
  [[ "$output" == *"--trust            the review, then the approval"* ]]
  cmp <(head -n "$(wc -l <"$H/before")" "$df") "$H/before" # nothing before it changed
  [ "$(tail -n +"$(($(wc -l <"$H/before") + 1))" "$df")" = $'\n# ---- added by asb --init github ----\n'"$block" ]
  # a line gone from a section the file has: said, with its --apply line
  sed -i '/^\[permissions:gh-review-\*\]/,/^\[/{/^Bash(gh issue create:\*)$/d}' "$df"
  init -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: --init: 1 line model 'github' has now that your .agent-sandbox lacks -- --init does not write into an existing file; add it with:"* ]]
  grep -qxF "    agent-sandbox --apply '[permissions:gh-review-*]' 'Bash(gh issue create:*)'" <<<"$output"
}

@test "--env on a file --init wrote without it: the environment's lines completed as a first --env writes them, nothing else changed" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox" ep="$H/base/envs/dev"
  init -- github
  [ "$status" -eq 0 ]
  [[ "$output" == *"no --env: the environment's lines (the [conda] sections, the lines naming ENVPATH) are"* ]]
  [[ "$output" == *"--init github --env NAME, run again, completes them with NAME's prefix"* ]]
  # gh-setup, launched so, stops and asks for exactly that
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF 'When the prefix above reads `ENVPATH`' "$PROJ/.asb/roles/gh-setup.md"
  # shellcheck disable=SC2016 # likewise
  grep -qF 'run on the host `asb --init github --env NAME` (NAME a' "$PROJ/.asb/roles/gh-setup.md"
  cp "$df" "$H/noenv"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: completed in .agent-sandbox, for --env dev ($ep), the environment's lines --init wrote commented out without an environment:"* ]]
  [[ "$output" == *"    [connect:gh-*] $ep/ = copy-on-write"* && "$output" == *"    [conda:gh-*] prefix = $ep"* ]]
  [[ "$output" == *"--trust            the review, then the approval"* ]] # the file changed: a new review
  [[ "$output" != *"still commented out"* && "$output" != *"--apply"* && "$output" != *"no --env"* ]]
  # only the four environment lines changed, each from its commented-out form
  diff "$H/noenv" "$df" >"$H/diff" || true
  [ "$(grep -c '^<' "$H/diff")" -eq 4 ]
  [ "$(grep -c '^>' "$H/diff")" -eq 4 ]
  [ "$(grep '^<' "$H/diff" | sed 's/^< //' | sed 's/  *#.*//' | paste -sd'|')" = '# ENVPATH/ = copy-on-write|# [conda:gh-*]|# prefix = ENVPATH|# ENVPATH/ = read-write' ]
  # the same file a first --init with --env writes
  cp "$df" "$H/rerun"
  rm -rf "$df" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  cmp "$df" "$H/rerun"
  # and again: nothing left to complete, nothing changed
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"completed in .agent-sandbox"* ]]
  cmp "$df" "$H/rerun"
}

@test "--env completing a no-env file: a line changed by hand is left and said; the user's lines unchanged" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox" ep="$H/base/envs/dev"
  init -- github
  [ "$status" -eq 0 ]
  sed -i 's|^# ENVPATH/ = copy-on-write.*|/mine/env/ = copy-on-write|' "$df"
  printf '# mine\n[allow:gh-*]\nexample.org\n' >>"$df"
  cp "$df" "$H/edited"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: 1 environment line not completed: your .agent-sandbox does not have it as --init wrote it without an environment (changed or removed since), so it is left as you have it; model 'github''s line for --env dev:"$'\n'"    [connect:gh-*] $ep/ = copy-on-write"* ]]
  [[ "$output" == *"the environment's line left above: yours to complete, by hand"* ]]
  [[ "$output" != *"--apply"* ]] # said once, not again as a line the model gained
  grep -qx '/mine/env/ = copy-on-write' "$df"
  run ! grep -q "^$ep/ = copy-on-write" "$df"
  grep -qx "prefix = $ep .*" "$df" # the others completed
  diff "$H/edited" "$df" >"$H/diff" || true
  [ "$(grep -c '^<' "$H/diff")" -eq 3 ] # [conda:gh-*], its prefix, gh-setup's prefix
  [ "$(tail -3 "$df")" = $'# mine\n[allow:gh-*]\nexample.org' ]
}

@test "--env completing a no-env file: a section whose header was changed by hand keeps every line, each said (github, roles)" {
  mkdir -p "$H/base/envs" "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  sed -i 's|^# \[conda:gh-\*\]$|# [conda:gh-*]   # ours|' "$df"
  grep -qx '# \[conda:gh-\*\]   # ours' "$df"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  grep -qx '# \[conda:gh-\*\]   # ours' "$df"
  [[ "$output" == *"--init: 2 environment lines not completed"*$'\n'"    [conda:gh-*]"$'\n'"    [conda:gh-*] prefix = $H/base/envs/dev"$'\n'* ]]
  [ "$(grep -c '^    \[conda:gh-\*\]$' <<<"$output")" -eq 1 ] # the header once
  grep -qx '# prefix = ENVPATH .*' "$df"                      # its line stays with it
  run ! grep -q "^prefix = " "$df"
  grep -q "^$H/base/envs/dev/ = copy-on-write" "$df" # the rest completed
  rm -rf "$df" "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  sed -i 's|^# \[conda:supervisor\]  *# main.*$|# [conda:supervisor]   # ours|' "$df"
  grep -qx '# \[conda:supervisor\]   # ours' "$df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  [ "$(grep -c '^    \[conda:supervisor\]$' <<<"$output")" -eq 2 ]  # the other copy completed, this one left
  [[ "$output" == *$'\n'"    [conda:supervisor] write = 1"$'\n'* ]] # with its line
  grep -qx "prefix = $H/conda/envs/x-dev .*" "$df"
  grep -qx '# write = 1' "$df" # stays under its header, not under [connect:supervisor]
  run ! grep -qx 'write = 1' "$df"
}

@test "--env completing a no-env roles file: every Implementer the file has, with its environment, whatever the count now" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles implementer=2
  [ "$status" -eq 0 ]
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  grep -qx '\[conda:implementer-1\].*' "$df"
  grep -qx '\[conda:implementer-2\].*' "$df"
  grep -qx 'prefix = \.asb/impl/2/\.env' "$df"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/2/.env" "$H/conda.log"
  cp "$df" "$H/rerun"
  rm -rf "$df" "$PROJ/.asb" "$H/conda.log"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 --env x-dev
  [ "$status" -eq 0 ]
  cmp "$df" "$H/rerun" # as a first --init implementer=2 --env writes it
}

@test "--env completing a no-env roles file makes no instance the file lacks: a comment naming one, a removed one" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles
  [ "$status" -eq 0 ]
  printf '# [connect:implementer-7]   # a note of mine\n' >>"$df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[connect:implementer-[0-9]*\]$' "$df")" -eq 1 ]
  [ ! -e "$PROJ/.asb/impl/2" ]
  [ ! -e "$PROJ/.asb/impl/7" ]
  [ "$(cat "$H/conda.log")" = "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env" ]
  # implementer-2 of three, removed by hand: not made again, not cloned for
  rm -rf "$df" "$PROJ/.asb" "$H/conda.log"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles implementer=3
  [ "$status" -eq 0 ]
  sed -i '/^\[connect:implementer-2\]$/,/^\[connect:implementer-3\]$/{/^\[connect:implementer-3\]$/!d}' "$df"
  run ! grep -q 'implementer-2\]' "$df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  run ! grep -q 'implementer-2\]' "$df"
  grep -qx '\[conda:implementer-3\].*' "$df"
  [ "$(sort "$H/conda.log" | paste -sd'|')" = "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env|create -q -y --clone x-dev -p $PROJ/.asb/impl/3/.env" ]
  # a count given adds above the highest present, as a first --init does; never fills the gap
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=4 --env x-dev
  [ "$status" -eq 0 ]
  has_section '[connect:implementer-4]' "$df"
  run ! grep -q 'implementer-2\]' "$df"
  # and a count of 0 drops none
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles implementer=0 --env x-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has every section for these roles; nothing added to it"* ]]
  grep -qx '\[conda:implementer-4\].*' "$df"
}

@test "a first --init github --env in a file the roles model wrote without one: nothing said about the roles model's lines" {
  mkdir -p "$H/base/envs"
  init MAMBA_ROOT_PREFIX="$H/base" -- roles
  [ "$status" -eq 0 ]
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not be completed"* && "$output" != *"not completed"* ]]
  grep -qx '# \[conda:planner-\*\].*' "$PROJ/.agent-sandbox" # not github's to complete
}

@test "--env completing a no-env file writes through no link a role left in the project" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  printf 'elsewhere\n' >"$H/target"
  ln -s "$H/target" "$df.init-new"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"completed in .agent-sandbox"* ]]
  [ "$(cat "$H/target")" = elsewhere ]
  grep -qx "prefix = $H/base/envs/dev .*" "$df"
}

@test "--env on a file written with it that lacks an environment's line: the --apply line, not 'left as you have it'" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox" ep="$H/base/envs/dev"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  sed -i "\\|^$ep/ = copy-on-write|d" "$df"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" != *"not completed"* && "$output" != *"left above"* && "$output" != *"completed in"* ]]
  [[ "$output" == *"--apply '[connect:gh-*]' '$ep/ = copy-on-write'"* ]]
}

@test "--env completing a no-env file keeps its mode, and no final newline it lacked" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  chmod 600 "$df"
  truncate -s -1 "$df" # no final newline
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"completed in .agent-sandbox"* ]]
  [ "$(stat -c %a "$df")" = 600 ]
  [ -n "$(tail -c1 "$df")" ]
  grep -qx "prefix = $H/base/envs/dev .*" "$df"
}

@test "--init and --apply refuse a symbolically linked .agent-sandbox, dangling or not: nothing written through it" {
  local df="$PROJ/.agent-sandbox"
  # a link to a file outside, as a sandbox with the project read-write could leave
  printf 'mine\n' >"$H/outside"
  ln -s "$H/outside" "$df"
  init -- github
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox is a symbolic link, and asb does not write through one: replace it with a regular file and run --init again"* ]]
  [ "$(cat "$H/outside")" = mine ]
  [ ! -e "$PROJ/.asb" ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[allow]" example.org 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply: .agent-sandbox is a symbolic link, and asb does not write through one"* ]]
  [ "$(cat "$H/outside")" = mine ]
  # a dangling one: its target is not made
  rm -f "$df"
  ln -s "$H/nowhere" "$df"
  init -- github
  [ "$status" -eq 2 ]
  [ ! -e "$H/nowhere" ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[allow]" example.org 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 2 ]
  [ ! -e "$H/nowhere" ]
}

@test "--init refuses a symbolic link a role left at a clone's path: .asb/impl, .asb/git, an Implementer's .env -- exit 2, nothing written (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta" "$H/out-impl" "$H/out-git"
  local df="$PROJ/.agent-sandbox"
  # a linked .asb/impl: no clone into it, and nothing else written either
  mkdir -p "$PROJ/.asb"
  ln -s "$H/out-impl" "$PROJ/.asb/impl"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/impl is a symbolic link, where --init makes a directory: what --init makes under .asb/ stays as it made it, and is never written through a link (a role with the project read-write can leave one; one you made is refused too). Remove the link (rm removes the link, not what it points to) and run --init again, which makes the directory anew; nothing was written"* ]]
  [ "$(grep -c 'is a symbolic link' <<<"$output")" -eq 1 ] # said once, and stopped
  [ -z "$(ls -A "$H/out-impl")" ]
  [ ! -e "$H/conda.log" ]
  [ ! -e "$df" ]
  [ "$(ls -A "$PROJ/.asb")" = impl ]
  # a linked .asb/git: no history written into it
  rm -rf "$PROJ/.asb"
  mkdir -p "$PROJ/.asb"
  ln -s "$H/out-git" "$PROJ/.asb/git"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/git is a symbolic link, where --init makes a directory"* ]]
  [ -z "$(ls -A "$H/out-git")" ]
  [ ! -e "$df" ]
  [ "$(ls -A "$PROJ/.asb")" = git ]
  # a dangling link at an Implementer's .env: conda is not aimed at it, the file not changed
  rm -rf "$PROJ/.asb"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles
  [ "$status" -eq 0 ]
  ln -s "$H/out-env" "$PROJ/.asb/impl/1/.env"
  cp "$df" "$H/df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/impl/1/.env is a symbolic link, where --init makes a directory"* ]]
  [[ "$output" != *"completed in .agent-sandbox"* ]]
  cmp "$df" "$H/df" # the environment's lines not completed: nothing was written
  [ ! -e "$H/out-env" ]
  [ ! -e "$H/conda.log" ]
}

@test "--init --env PATH inside the project under .asb/: a link on the way refused, exit 2, nothing made through it (#389)" {
  local df="$PROJ/.agent-sandbox"
  mkdir -p "$PROJ/.asb" "$H/out-envs"
  ln -s "$H/out-envs" "$PROJ/.asb/envs"
  init -- github --env .asb/envs/x
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/envs is a symbolic link, where --init makes a directory"*"; nothing was written"* ]]
  [ -z "$(ls -A "$H/out-envs")" ]
  [ ! -e "$df" ]
  # without the link, the prefix is made there, empty, for gh-setup to build into
  rm -f "$PROJ/.asb/envs"
  init -- github --env .asb/envs/x
  [ "$status" -eq 0 ]
  [ -d "$PROJ/.asb/envs/x" ]
  [ ! -L "$PROJ/.asb/envs" ]
}

@test "--init and --apply rewrite .agent-sandbox by renaming a new file over it, its mode kept" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox" ino
  init -- github
  [ "$status" -eq 0 ]
  chmod 640 "$df"
  ino="$(stat -c %i "$df")"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$df")" != "$ino" ] # a rename: a link planted meanwhile is replaced, not followed
  [ "$(stat -c %a "$df")" = 640 ]
  ino="$(stat -c %i "$df")"
  engine_cmd
  run bash -c 'cd "$1" && printf "n\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[allow]" example.org 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$(stat -c %i "$df")" != "$ino" ]
  [ "$(stat -c %a "$df")" = 640 ]
  grep -qx 'example.org' "$df"
  ls -A "$PROJ" >"$H/ls"
  run ! grep -q '^\.agent-sandbox\.' "$H/ls" # no temporary file left
}

# tree_of DIR -- every path under DIR but .git/, with a link's target and a file's hash: two
# runs compare equal when nothing under DIR was written.
tree_of() {
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [[ -L "$f" ]]; then
      printf '%s -> %s\n' "$f" "$(readlink "$f")"
    elif [[ -f "$f" ]]; then
      printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -c1-16)"
    else
      printf '%s/\n' "$f"
    fi
  done)
}

@test "--init refuses, exit 2 and nothing written, a path it makes under .asb/ that is a symbolic link or not what it makes (#389)" {
  local p kind c
  init -- roles
  [ "$status" -eq 0 ]
  cp -a "$PROJ" "$H/snap"
  printf 'outside\n' >"$H/out-file"
  mkdir -p "$H/out-dir"
  # PATH KIND: KIND is file (a link to a file outside), dangling, dir (a link to a
  # directory outside) or plain (a regular file where --init makes a directory)
  for c in \
    '.asb dir' '.asb/roles dir' '.asb/roles/planner-1.md file' '.asb/roles/reviewer-1.md dangling' \
    '.asb/.gitignore dangling' '.asb/init.sums dangling' '.asb/coord/COORDINATION.md file' \
    '.asb/coord/to/reviewer-1.md dangling' '.asb/coord/to dir' '.asb/plan/planner-1 dangling' \
    '.asb/serve/planner-1.md file' '.asb/start/planner.md dangling' '.asb/bin/inbox-wait file' \
    '.asb/tests dangling' '.asb/impl/1/.git file' '.asb/impl/1 plain' '.asb/migrate dir'; do
    p="${c% *}" kind="${c##* }"
    rm -rf "$PROJ" "$H/out-dir" "$H/dangling"
    cp -a "$H/snap" "$PROJ"
    mkdir -p "$H/out-dir" "$(dirname -- "$PROJ/$p")"
    rm -rf "${PROJ:?}/$p"
    case "$kind" in
      file) ln -s "$H/out-file" "$PROJ/$p" ;;
      dangling) ln -s "$H/dangling" "$PROJ/$p" ;;
      dir) ln -s "$H/out-dir" "$PROJ/$p" ;;
      plain) printf 'x\n' >"$PROJ/$p" ;;
    esac
    tree_of "$PROJ" >"$H/before"
    init -- roles implementer=2 # would add sections, a purpose file, a clone, an index row
    [ "$status" -eq 2 ] || {
      echo "$c: status $status: $output"
      return 1
    }
    if [[ "$kind" == plain ]]; then
      [[ "$output" == *"--init: $p is not a directory, which --init makes there: what --init makes under .asb/ stays as it made it. Move it away and run --init again; nothing was written"* ]]
    else
      [[ "$output" == *"--init: $p is a symbolic link, where --init makes a "*"; nothing was written"* ]] || {
        echo "$c: $output"
        return 1
      }
    fi
    tree_of "$PROJ" >"$H/after"
    cmp "$H/before" "$H/after"
    [ "$(cat "$H/out-file")" = outside ]
    [ -z "$(ls -A "$H/out-dir")" ]
    [ ! -e "$H/dangling" ]
  done
}

@test "--init with .asb/migrate linked to a directory outside: refused, the target's files survive (#389)" {
  local r="$PROJ/.asb/roles"
  init -- roles
  [ "$status" -eq 0 ]
  # the target has files named as --init's migration copies: planner-1.md, implementer-1.md
  mkdir -p "$H/mig"
  printf 'mine\n' >"$H/mig/planner-1.md"
  printf 'mine\n' >"$H/mig/implementer-1.md"
  rm -rf "$PROJ/.asb/migrate"
  ln -s "$H/mig" "$PROJ/.asb/migrate"
  init -- roles
  [ "$(cat "$H/mig/planner-1.md")" = mine ] # removed through the link before #389
  [ "$(cat "$H/mig/implementer-1.md")" = mine ]
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/migrate is a symbolic link, where --init makes a directory"* ]]
  # a purpose file the user changed, whose migration copy would go there: refused too
  printf 'changed\n' >>"$r/implementer-1.md"
  init -- roles
  [ "$status" -eq 2 ]
  [ "$(ls "$H/mig")" = $'implementer-1.md\nplanner-1.md' ]
  [ "$(cat "$H/mig/implementer-1.md")" = mine ]
}

@test "--init refuses a path declared under .asb/ with '..' in it, exit 2, the line named, nothing made outside (#389)" {
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  # as a sandbox with the project read-write can append them; ../.. from .asb/ is $H
  printf '[connect:gh-*]\n.asb/../../escape-dir/ = read-only\n.asb/../../escape-file = read-only\n' >>"$df"
  cp "$df" "$H/df"
  tree_of "$PROJ" >"$H/before"
  init -- github
  [ ! -e "$H/escape-dir" ] # made by --init before #389
  [ ! -e "$H/escape-file" ]
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox declares a path under .asb/ with '..' in it: '.asb/../../escape-dir/ = read-only'. --init makes the paths the file declares under .asb/, and only there: remove the line, or write the path without '..', and run --init again; nothing was written"* ]]
  cmp "$df" "$H/df"
  tree_of "$PROJ" >"$H/after"
  cmp "$H/before" "$H/after"
  # a name with two dots in it is no '..': made, inside .asb/
  cp "$H/df" "$df"
  sed -i '/escape/d' "$df"
  printf '.asb/x..y/ = read-only\n' >>"$df"
  init -- github
  [ "$status" -eq 0 ]
  [ -d "$PROJ/.asb/x..y" ]
}

@test "a project that tracks .env: --env refused, exit 2, nothing written; --env-dir names the clones' environment directory, kept by a re-run (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  printf 'SECRET=1\n' >"$PROJ/.env"
  git -C "$PROJ" add .env
  git -C "$PROJ" commit -q -m env
  tree_of "$PROJ" >"$H/before"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: the project tracks .env, where --init makes implementer-1's environment (.asb/impl/1/.env): run --init again with --env-dir OTHER, a name the project does not track (e.g. --env-dir _env); nothing was written"* ]]
  tree_of "$PROJ" >"$H/after"
  cmp "$H/before" "$H/after"
  [ ! -e "$H/conda.log" ]
  # another name: the prefix lines, the clone's environment and the purpose files say it
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev --env-dir _env
  [ "$status" -eq 0 ]
  grep -qx 'prefix = \.asb/impl/1/_env' "$df"
  run ! grep -qF 'impl/1/.env' "$df"
  [ -d "$PROJ/.asb/impl/1/_env/conda-meta" ]
  [ -f "$PROJ/.asb/impl/1/.env" ] # the project's own, untouched
  grep -qF 'conda env update -p .asb/impl/1/_env -f environment.yml --prune' "$PROJ/.asb/roles/implementer-1.md"
  grep -qF '.asb/impl/N/_env/bin/...' "$PROJ/.asb/roles/reviewer-1.md"
  grep -qF "with its _env" "$df"
  # a re-run without --env-dir keeps the name the file records
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 --env x-dev
  [ "$status" -eq 0 ]
  grep -qx 'prefix = \.asb/impl/2/_env' "$df"
  [ -d "$PROJ/.asb/impl/2/_env/conda-meta" ]
  # another name, where the environments are built at this one: refused, --init never moves one
  cp "$df" "$H/df"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env x-dev --env-dir other
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir other: implementer-"?"'s environment is built at .asb/impl/"?"/_env, a name .agent-sandbox has for it, and --init never moves an environment -- run it without --env-dir (each clone keeps its name), or move that environment and its lines yourself first"* ]]
  cmp "$df" "$H/df"
}

@test "a project that tracks .env, its file written without an environment: --env refused, --env-dir renames the clones' lines and takes it (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  printf 'SECRET=1\n' >"$PROJ/.env"
  git -C "$PROJ" add .env
  git -C "$PROJ" commit -q -m env
  # the file records .env, commented out: what main's --init writes too (the same bytes)
  init -- roles
  [ "$status" -eq 0 ]
  grep -qx '# prefix = \.asb/impl/1/\.env' "$df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: the project tracks .env, where --init makes implementer-1's environment"* ]]
  # nothing is built at .env (the project's file is there), so --env-dir renames it
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev --env-dir _env
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: renamed in .agent-sandbox the environment's directory of implementer-1 to _env (--env-dir; none was built at the old name)"* ]]
  [[ "$output" == *"completed in .agent-sandbox"* ]]
  grep -qx 'prefix = \.asb/impl/1/_env' "$df"
  run ! grep -qF 'impl/1/.env' "$df"
  grep -q "^\.asb/impl/1/ = read-write .*# its clone's tree, with its _env\$" "$df" # its comment too
  run ! grep -qF "with its .env" "$df"
  [ -d "$PROJ/.asb/impl/1/_env/conda-meta" ]
  [ "$(cat "$PROJ/.asb/impl/1/.env")" = SECRET=1 ]
  grep -qF 'conda env update -p .asb/impl/1/_env -f environment.yml --prune' "$PROJ/.asb/roles/implementer-1.md"
  grep -qF '.asb/impl/N/_env/bin/...' "$PROJ/.asb/roles/reviewer-1.md"
}

@test "each clone keeps the environment directory its lines name: one changed by hand is no refusal, with --env or without (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 --env x-dev
  [ "$status" -eq 0 ]
  # the user moves implementer-2's environment to another name, its line with it
  sed -i 's|^prefix = \.asb/impl/2/\.env|prefix = .asb/impl/2/venv|' "$df"
  rm -rf "$PROJ/.asb/impl/2/.env"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  grep -qx 'prefix = \.asb/impl/1/\.env' "$df"
  grep -qx 'prefix = \.asb/impl/2/venv' "$df"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 --env x-dev
  [ "$status" -eq 0 ]
  [ -d "$PROJ/.asb/impl/2/venv/conda-meta" ] # its environment made at its own name
  grep -qF 'conda env update -p .asb/impl/2/venv -f' "$PROJ/.asb/roles/implementer-2.md"
  grep -qF 'conda env update -p .asb/impl/1/.env -f' "$PROJ/.asb/roles/implementer-1.md"
  # --env-dir over names with environments built at them: refused
  cp "$df" "$H/df"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env x-dev --env-dir _env
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir _env: implementer-"?"'s environment is built at .asb/impl/"*", a name .agent-sandbox has for it, and --init never moves an environment"* ]]
  cmp "$df" "$H/df"
}

@test "a path the file declares without '/' keeps the host's kind, no refusal; one with '/' over a file refuses, exit 2, nothing written (#389)" {
  local df="$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  mkdir "$PROJ/.asb/notes"
  printf 'mine\n' >"$PROJ/.asb/notes/keep"
  printf '.asb/notes = read-only\n' >>"$df"
  init -- roles
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.asb/notes/keep")" = mine ] # the directory left as it is, its file in it
  # the mirror: a key with '/' is a directory --init makes, and a file there refuses it
  # before anything is written (on main, the write's mkdir failed late, exit 1)
  printf 'mine\n' >"$PROJ/.asb/x"
  printf '.asb/x/ = read-only\n' >>"$df"
  cp "$df" "$H/df"
  init -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/x is not a directory, which --init makes there: what --init makes under .asb/ stays as it made it. Move it away and run --init again; nothing was written"* ]]
  [ "$(cat "$PROJ/.asb/x")" = mine ]
  cmp "$df" "$H/df"
  # a declared path without '/' replaced by a link: refused, said as the file's path
  rm -rf "$PROJ/.asb/notes" "$PROJ/.asb/x"
  sed -i '/^\.asb\/x\/ = read-only$/d' "$df"
  ln -s "$H/elsewhere" "$PROJ/.asb/notes"
  init -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/notes is a symbolic link, a path .agent-sandbox declares under .asb/, and --init never writes through a link there"*"; nothing was written"* ]]
  [ ! -e "$H/elsewhere" ]
}

@test "a directory the model declares, replaced by a file: a re-run that would add an instance refuses, exit 2, the tree unchanged (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.asb/plan/planner-1"
  printf 'x\n' >"$PROJ/.asb/plan/planner-1"
  tree_of "$PROJ" >"$H/before"
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .asb/plan/planner-1 is not a directory, which --init makes there"*"; nothing was written"* ]]
  tree_of "$PROJ" >"$H/after"
  cmp "$H/before" "$H/after"
}

@test "every other role's text names the clones' environment directory only when they share it: ENVDIR when they differ (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox" r="$PROJ/.asb/roles"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2 reviewer=2 --env x-dev
  [ "$status" -eq 0 ]
  grep -qF '.asb/impl/N/.env/bin/...' "$r/reviewer-1.md"
  grep -qF '.asb/impl/N/.env/bin/...' "$r/reviewer-2.md"
  # implementer-2's environment moved to venv, its line with it
  sed -i 's|^prefix = \.asb/impl/2/\.env|prefix = .asb/impl/2/venv|' "$df"
  mv "$PROJ/.asb/impl/2/.env" "$PROJ/.asb/impl/2/venv"
  init -- roles implementer=2 reviewer=2
  [ "$status" -eq 0 ]
  grep -qF 'conda env update -p .asb/impl/1/.env -f' "$r/implementer-1.md"
  grep -qF 'conda env update -p .asb/impl/2/venv -f' "$r/implementer-2.md"
  # a reviewer's text is about every clone: wrong for none
  grep -qF '.asb/impl/N/ENVDIR/bin/...' "$r/reviewer-1.md"
  grep -qF '.asb/impl/N/ENVDIR/bin/...' "$r/reviewer-2.md"
  run ! grep -qF 'venv' "$r/reviewer-2.md"
}

@test "an instance with its old prefix line commented out and a new one active: the active one is its name; --env-dir refused while any of its names has an environment (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  # the user moves implementer-1's environment to venv: the old line commented out, a new one below
  sed -i 's|^prefix = \.asb/impl/1/\.env\(.*\)$|# prefix = .asb/impl/1/.env\1\nprefix = .asb/impl/1/venv|' "$df"
  mv "$PROJ/.asb/impl/1/.env" "$PROJ/.asb/impl/1/venv"
  rm -f "$H/conda.log"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env x-dev
  [ "$status" -eq 0 ]
  grep -qx '# prefix = \.asb/impl/1/\.env.*' "$df" # left commented out
  grep -qx 'prefix = \.asb/impl/1/venv' "$df"
  [ "$(grep -c '^prefix = \.asb/impl/1/' "$df")" -eq 1 ]
  [ ! -e "$PROJ/.asb/impl/1/.env" ] # no second environment
  [ ! -e "$H/conda.log" ]
  grep -qF 'conda env update -p .asb/impl/1/venv -f' "$PROJ/.asb/roles/implementer-1.md"
  # --env-dir: the active name has an environment -- refused
  cp "$df" "$H/df"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env-dir _env
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir _env: implementer-1's environment is built at .asb/impl/1/venv, a name .agent-sandbox has for it"* ]]
  cmp "$df" "$H/df"
  # ...and so does the commented-out one, back where it was: refused, its active line kept
  mv "$PROJ/.asb/impl/1/venv" "$PROJ/.asb/impl/1/.env"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env-dir _env
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir _env: implementer-1's environment is built at .asb/impl/1/.env, a name .agent-sandbox has for it"* ]]
  cmp "$df" "$H/df"
}

@test "the tracked-name refusal suggests a name the project does not track (#389)" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  printf 'SECRET=1\n' >"$PROJ/.env"
  mkdir -p "$PROJ/_env"
  printf 'x\n' >"$PROJ/_env/file"
  git -C "$PROJ" add .env _env
  git -C "$PROJ" commit -q -m env
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env x-dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"(e.g. --env-dir .env-asb); nothing was written"* ]]
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --env x-dev --env-dir _env
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: the project tracks _env, where --init makes implementer-1's environment (.asb/impl/1/_env)"*"(e.g. --env-dir .env-asb)"* ]]
}

@test "--env-dir with --shared-env: refused, exit 2, nothing written (#389)" {
  shared_env torch-dev
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles --shared-env torch-dev --env-dir _env
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir with --shared-env: a shared environment is not cloned, so the clones have no environment directory to name"* ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
  [ ! -e "$PROJ/.asb" ]
}

@test "--env naming a built environment through a link of yours in the project: no refusal, outside .asb/ the static rule has nothing to say (#389)" {
  mkdir -p "$H/bigdisk/env/conda-meta" "$H/bigdisk/envs/dev/conda-meta"
  ln -s "$H/bigdisk/env" "$PROJ/venv"
  init CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles --env ./venv
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  ln -s "$H/bigdisk/envs" "$PROJ/envs"
  init -- github --env ./envs/dev
  [ "$status" -eq 0 ]
  grep -qF "$PROJ/envs/dev" "$PROJ/.agent-sandbox"
}

@test "a project that tracks .env, with no environment asked for: nothing made there, no refusal, a re-run too (#389)" {
  printf 'SECRET=1\n' >"$PROJ/.env"
  git -C "$PROJ" add .env
  git -C "$PROJ" commit -q -m env
  init -- roles
  [ "$status" -eq 0 ]
  grep -qx '# prefix = \.asb/impl/1/\.env' "$PROJ/.agent-sandbox"
  [ "$(cat "$PROJ/.asb/impl/1/.env")" = SECRET=1 ] # the clone has the project's file
  init -- roles
  [ "$status" -eq 0 ]
}

@test "--env-dir takes one directory name: a path, '.', '..', '.git' or nothing refused, exit 2, nothing written (#389)" {
  local d
  for d in a/b /abs . .. .git '' 'a b' 'x#y'; do
    init -- roles --env-dir "$d"
    [ "$status" -eq 2 ] || {
      echo "'$d': $status $output"
      return 1
    }
    [[ "$output" == *"--init: --env-dir '$d': a directory name -- letters, digits, '.', '_' and '-', not '.', '..' or '.git'"* ]]
    [ ! -e "$PROJ/.agent-sandbox" ]
    [ ! -e "$PROJ/.asb" ]
  done
  init -- roles --env-dir
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir needs a directory name"* ]]
}

@test "--init stops with exit 2 at a symbolic link that appears while it runs, its target not written (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  printf 'outside\n' >"$H/out-file"
  # git, as --init clones implementer-2, plants a link at the index --init then adds a row to
  cat >"$H/bin/git" <<STUB
#!/usr/bin/env bash
/usr/bin/git "\$@" || exit
[[ "\$*" == *" clone "* ]] && ln -sfn "$H/out-file" "$PROJ/.asb/coord/COORDINATION.md"
exit 0
STUB
  chmod +x "$H/bin/git"
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"cloned for implementer-2"* ]]
  [[ "$output" == *"--init: .asb/coord/COORDINATION.md became a symbolic link while --init ran: stopped before writing .asb/coord/COORDINATION.md; remove the link and run --init again"* ]]
  [ "$(cat "$H/out-file")" = outside ]
  [ -L "$PROJ/.asb/coord/COORDINATION.md" ]
}

# swap_run SECRET ARGS... -- the engine sourced, its _as_dotfile_read made to swap the file
# it is given for a symbolic link to SECRET at its SWAP_AT-th call (default the first: a
# link planted between the check and the read), then run with ARGS from the project; n
# answers a question.
swap_run() {
  local secret="$1"
  shift
  cat >"$H/swap.bash" <<'EOF'
# shellcheck disable=SC1090
source "$ENGINE"
eval "_as_dotfile_read_real() $(declare -f _as_dotfile_read | tail -n +2)"
_as_dotfile_read() {
  local c=0
  [[ -f "$SWAP_COUNT" ]] && c="$(<"$SWAP_COUNT")"
  printf '%s\n' $((c + 1)) >"$SWAP_COUNT"
  ((c + 1 == SWAP_AT)) && ln -sfn "$SECRET" "$1"
  _as_dotfile_read_real "$@"
}
agent_sandbox "$@"
EOF
  rm -f "$H/swap.count"
  run bash -c 'cd "$1" && printf "n\n" | env -i HOME="$2" PATH="$3" ENGINE="$4" SECRET="$5" MAMBA_ROOT_PREFIX="$6" SWAP_COUNT="$7" SWAP_AT="$8" bash "$9" "${@:10}" 2>&1' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE" "$secret" "$H/base" "$H/swap.count" "${SWAP_AT:-1}" "$H/swap.bash" "$@"
}

@test "--init reads .agent-sandbox through the checked read, completing the environment's lines and appending sections: a link swapped in is refused, exit 2 (#389)" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  cp "$df" "$H/df.github"
  # the secret looks like the file, so a by-path read would copy it into the new one
  sed 's/^/# /' "$df" >"$H/secret"
  printf 'SECRET-TOKEN\n' >>"$H/secret"
  cp "$H/secret" "$H/secret.orig"
  swap_run "$H/secret" --init github --env dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox became a symbolic link while --init ran; nothing written"* ]]
  [[ "$output" != *"completed in .agent-sandbox"* ]]
  cmp "$H/secret" "$H/secret.orig"
  [ -L "$df" ] # nothing renamed over the link
  run ! grep -rqF SECRET-TOKEN "$PROJ/.asb"
  # the roles model reads it for its clones' environment directories (the first read)...
  rm -f "$df"
  cp "$H/df.github" "$df"
  swap_run "$H/secret" --init roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox became a symbolic link while --init ran; nothing written"* ]]
  cmp "$H/secret" "$H/secret.orig"
  [ -L "$df" ]
  # ...and the append of its sections reads it so too (the second): refused, exit 2
  rm -f "$df"
  cp "$H/df.github" "$df"
  SWAP_AT=2 swap_run "$H/secret" --init roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: .agent-sandbox became a symbolic link while --init ran; nothing added to it"* ]]
  cmp "$H/secret" "$H/secret.orig"
  [ -L "$df" ]
}

@test "--apply reads .agent-sandbox through the checked read: a link swapped in is refused, exit 2, nothing written (#389)" {
  local df="$PROJ/.agent-sandbox"
  printf '[allow]\nexample.com\n' >"$df"
  printf '[allow]\nSECRET-TOKEN\n' >"$H/secret"
  cp "$H/secret" "$H/secret.orig"
  # into the section that is there (the insert), and as a new section (the append)
  swap_run "$H/secret" --profile claude --apply '[allow]' example.org
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply: .agent-sandbox became a symbolic link while --apply ran; nothing added to it"* ]]
  cmp "$H/secret" "$H/secret.orig"
  [ -L "$df" ]
  rm -f "$df"
  printf '[allow]\nexample.com\n' >"$df"
  swap_run "$H/secret" --profile claude --apply '[deny]' example.net
  [ "$status" -eq 2 ]
  cmp "$H/secret" "$H/secret.orig"
  [ -L "$df" ]
}

@test "--env on a no-env file without its --init mark, or with CR LF lines: not completed, the lines named for the user" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox"
  init -- github
  [ "$status" -eq 0 ]
  sed -i '/^# ---- written by asb --init github ----$/d' "$df"
  cp "$df" "$H/nomark"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: the environment's lines in .agent-sandbox could not be completed for --env dev: it has no '# ---- written by asb --init github ----' line to find model 'github''s sections by; complete these by hand:"* ]]
  [[ "$output" == *"    line "*":# [conda:gh-*]"* && "$output" == *":# ENVPATH/ = read-write"* ]]
  [[ "$output" == *"the environment's lines left above: yours to complete, by hand"* ]]
  cmp "$df" "$H/nomark"
  rm -rf "$df" "$PROJ/.asb"
  init -- github
  [ "$status" -eq 0 ]
  sed -i 's/$/\r/' "$df"
  cp "$df" "$H/crlf"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"line to find model 'github''s sections by (its lines end in CR LF); complete these by hand:"* ]]
  cmp "$df" "$H/crlf"
}

@test "--env on a file whose environment's lines name another environment: refused, nothing written" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  cp "$df" "$H/dev"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env other
  [ "$status" -ne 0 ]
  [[ "$output" == *"--init: .agent-sandbox's [conda:gh-*] has 'prefix = $H/base/envs/dev', another environment than --env other ($H/base/envs/other): --init never rewrites an environment's prefix"* ]]
  cmp "$df" "$H/dev"
  [ ! -e "$H/base/envs/other" ]
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
  [[ "$output" == *"--init: .agent-sandbox has the setup role setup: a shared environment, built by the project that owns it, needs no setup role here. --init leaves it; to remove it, delete its sections from .agent-sandbox ([sandbox:setup] [connect:setup] "*"[net:setup] "*"[briefing:setup]) and its purpose file .asb/roles/setup.md, then agent-sandbox --trust; agent-sandbox --role setup --delete claude removes its stores, if it was ever launched"* ]]
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
  [[ "$output" == *"--init: .agent-sandbox has the setup role gh-setup: a shared environment, built by the project that owns it, needs no setup role here. --init leaves it; to remove it, delete its sections from .agent-sandbox ([connect:gh-setup] [net:gh-setup] [briefing:gh-setup]) and its purpose file .asb/roles/gh-setup.md, then agent-sandbox --trust; agent-sandbox --role gh-setup --delete claude removes its stores, if it was ever launched"* ]]
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
    grep -qF "\`## Readiness\` section names a host-side" "$PROJ/.asb/roles/$k.md" # gh-setup's readiness record, read at start
  done
  # main moved under the layer: each re-syncs at its start; the fixer rebases its branch,
  # the reviewer re-applies the diff, the triager resets
  for k in gh-review gh-triage gh-fix; do
    grep -qF 'the ones you touched keep your versions. Re-sync before anything' "$PROJ/.asb/roles/$k.md"
  done
  grep -qF "\`git reset --hard fix-N\`" "$PROJ/.asb/roles/gh-fix.md"
  for k in gh-fix gh-review; do # --fork-point: a rewritten main replays only the role's commits
    grep -qF "\`git rebase --fork-point main\` (\`--fork-point\`: when the host rewrote" "$PROJ/.asb/roles/$k.md"
  done
  grep -qF "\`git reset --hard main\`; apply the" "$PROJ/.asb/roles/gh-review.md"
  grep -qF "\`git reset --hard main\`; then rebuild." "$PROJ/.asb/roles/gh-triage.md"
  # a finding beyond N becomes a new issue on the user's word, posted nowhere else
  for k in gh-review gh-triage; do
    grep -qF '**A finding beyond N.**' "$PROJ/.asb/roles/$k.md"
    grep -qF "gh issue list --search '<terms>' --state all" "$PROJ/.asb/roles/$k.md"
    grep -qF "\`gh issue create --title '<title>' --body-file .asb/scratch/issue-<slug>.md\` only" "$PROJ/.asb/roles/$k.md"
    grep -qF 'anywhere but N and the issues the user told you to file' "$PROJ/.asb/roles/$k.md"
  done
  # main is the default branch, master where that is its name
  for k in gh-setup gh-review gh-triage gh-fix; do
    grep -qF "(the default branch;" "$PROJ/.asb/roles/$k.md"
    grep -qF "\`master\` where that is" "$PROJ/.asb/roles/$k.md"
  done
  grep -qF '**Last, readiness.**' "$PROJ/.asb/roles/gh-setup.md"
  grep -qF "under \`## Readiness\`" "$PROJ/.asb/roles/gh-setup.md"
  # the fixer pushes over HTTPS with the gh login; SSH is ghstack's
  grep -qF "git -c credential.helper='!gh auth git-credential' push https://github.com/<owner>/<repo>.git <branch>" "$PROJ/.asb/roles/gh-fix.md"
  grep -qF "ghstack pushes through \`origin\` as it is" "$PROJ/.asb/roles/gh-fix.md"
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
  run ! grep -q '^#devices = ' "$PROJ/.agent-sandbox" # an example for GPUs that are off: none
  rm -rf "$PROJ/.agent-sandbox" "$PROJ/.asb"
  init -- roles planner=1 implementer=1 reviewer=1 --enable-gpu
  [ "$status" -eq 0 ]
  for p in 'planner-*' 'implementer-*' 'reviewer-*' 'supervisor'; do
    has_section "[gpu:$p]" "$PROJ/.agent-sandbox"
  done
  grep -A1 -F '[gpu:supervisor]' "$PROJ/.agent-sandbox" | grep -qx 'mode = on'
  # and, commented out, how to give the role one card instead of every one (#335)
  grep -A2 -F '[gpu:implementer-*]' "$PROJ/.agent-sandbox" \
    | grep -qxF '#devices = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia0'
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

@test "the roles model without --env: setup asks for --init roles --env NAME; that run completes the file as a first --env writes it, and clones" {
  mkdir -p "$H/conda/envs/x-dev/conda-meta"
  local df="$PROJ/.agent-sandbox"
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown
  grep -qF 'run on the host `asb --init roles --env NAME` (NAME a' "$PROJ/.asb/roles/setup.md"
  grep -qF 'asb --role setup --shutdown' "$PROJ/.asb/roles/setup.md"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: completed in .agent-sandbox, for --env x-dev"* ]]
  grep -qx "create -q -y --clone x-dev -p $PROJ/.asb/impl/1/.env" "$H/conda.log"
  cp "$df" "$H/rerun"
  rm -rf "$df" "$PROJ/.asb" "$H/conda.log"
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles planner=1 implementer=1 reviewer=1 --env x-dev
  [ "$status" -eq 0 ]
  cmp "$df" "$H/rerun"
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
  grep -qF 'asb --role gate --shutdown claude`, then its launch again' "$PROJ/.asb/roles/gate.md"
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
  grep -qxF '.asb/bin/inbox-wait -a .asb/coord/planner-2/alive .asb/coord/to/planner-2.md' "$PROJ/.asb/roles/planner-2.md"
  # the closing line comes with the done N write, never before
  local r
  for r in planner-1 implementer-1 reviewer-1 gate; do
    # shellcheck disable=SC2016 # backquotes in the text, not an expansion
    tr '\n' ' ' <"$PROJ/.asb/roles/$r.md" | grep -qF '**Closing line.** "done; in my file; S has it" is said once, in the reply in which you append `done N` to your messages, and never before: a reply with work still pending (a suite running, a section unwritten) ends by naming what is pending and what follows.'
  done
  grep -qxF ".asb/bin/inbox-wait -a .asb/coord/supervisor/alive .agent-sandbox \\" "$PROJ/.asb/roles/supervisor.md"
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

# shellcheck disable=SC2016 # backquotes are the purpose files' text, not ours
@test "the roles model: every watcher is a background Bash wait, re-run after each wake, never a Monitor; the Supervisor runs one over every other role's messages in the index, the Gate's too (#288)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local r f sup="$PROJ/.asb/roles/supervisor.md" idx="$PROJ/.asb/coord/COORDINATION.md"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    grep -qxF ".asb/bin/inbox-wait -a .asb/coord/$r/alive .asb/coord/to/$r.md" "$f"
    grep -qF 'with the Bash tool and' "$f"
    grep -qxF "\`run_in_background: true\`, and run it again after each wake; a change to your inbox" "$f"
    grep -qF 'background command has no time limit in a terminal session, so nothing expires.' "$f"
    grep -qF 'arm no watcher, read and act' "$f"
  done
  # the Gate arms one as the others do; it is never served, so no --serve rule
  f="$PROJ/.asb/roles/gate.md"
  grep -qxF ".asb/bin/inbox-wait -a .asb/coord/gate/alive .asb/coord/to/gate.md" "$f"
  grep -qxF '**At start.** From the project directory, run this command with the Bash tool and' "$f"
  grep -qxF "\`run_in_background: true\`, and run it again after each wake; a change to your inbox" "$f"
  grep -qF 'background command has no time limit in a terminal session, so nothing expires.' "$f"
  grep -qxF 'At start and at every wake, read your inbox, `.asb/coord/to/gate.md`, from your' "$f"
  run ! grep -qE 'you have no watcher|opened when it is|arm no watcher|--serve' "$f"
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/gate.md" | wc -l)" -eq 0 ]
  # the Supervisor: one command, its paths from the index, every role's but its own
  grep -qxF "  \`run_in_background: true\`, and run it again after each wake: \`.agent-sandbox\`, then" "$sup"
  grep -qxF '  one path per role in the index but yourself; a change to any of them wakes you:' "$sup"
  grep -qxF ".asb/bin/inbox-wait -a .asb/coord/supervisor/alive .agent-sandbox \\" "$sup"
  grep -qxF "  .asb/coord/planner-1/messages.md .asb/coord/implementer-1/messages.md ... \\" "$sup"
  grep -qxF '  .asb/coord/gate/messages.md' "$sup"
  run ! grep -qE 'but the Gate|Gate has no watcher|only when it is its turn' "$sup"
  # the Gate's turn: it wakes on its inbox; a stale alive gets its launch line, as any role's
  local flat
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  [[ "$flat" == *'`.asb/coord/to/gate.md` as above: the Gate wakes on its inbox like any role, and when its `alive` is stale, tell the user its launch line, as for any role.'* ]]
  [[ "$flat" == *'is in `.asb/coord/gate/messages.md`, which your watcher sees; bring it to the user.'* ]]
  [[ "$flat" == *'A post that mentions a GitHub user (`@name`) the Gate posts only after the user approves it in the Gate'"'"'s terminal'* ]]
  run ! grep -qF "tell the user it is the Gate's turn" "$sup"
  grep -qF 'background command has no time limit in a terminal session, so nothing expires.' "$sup"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    grep -q "^| [A-Z][0-9]* | $r | .asb/coord/$r/messages.md |" "$idx"
  done
  grep -q '^| G | gate | .asb/coord/gate/messages.md |' "$idx"
  # no Monitor watcher and no tail anywhere the model wrote, nor a rule for it
  for f in "$PROJ"/.asb/roles/*.md "$PROJ"/.asb/serve/*.md; do
    run ! grep -qE 'Monitor tool|timeout_ms|arm no Monitor|tail -n' "$f"
  done
  run ! grep -qF 'Bash(tail:*)' "$PROJ/.agent-sandbox"
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: the Supervisor prints every launch line with --resume and no command, and one asb --roles line with every other role; the file names every role's agent (#317, #355)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local flat
  flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/supervisor.md" | tr -s ' ')"
  [[ "$flat" == *'one line each, for the user to run in a terminal of its own: `asb --role NAME --resume` (it starts the role'"'"'s session when it has none, and resumes it when it has; the role'"'"'s agent is the one `.agent-sandbox` names).'* ]]
  [[ "$flat" == *'one line that opens them all at once, a tmux pane per role, with every role of the index but yourself, in the index'"'"'s order: `asb --roles NAME NAME ... --resume`.'* ]]
  [[ "$flat" == *'then its launch line from the index with `--resume`.'* ]]
  # no launch line naming the agent or its own resume flag is left
  run ! grep -qE '`asb --role NAME claude`|claude --continue|with `--continue`' "$PROJ/.asb/roles/supervisor.md"
  # what those lines resolve: an unsuffixed [agent], written once, not per role pattern
  [ "$(sed -n '/^\[agent\]$/,/^\[/p' "$PROJ/.agent-sandbox" | grep -cx 'command = claude')" -eq 1 ]
  run ! grep -q '^\[agent:' "$PROJ/.agent-sandbox"
  # and the review reads it as every role's agent
  run_review
  [[ "$output" == *"[agent] command = claude: the agent of every role is claude (the profile claude, installed here), with no fixed arguments"* ]]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
}

@test "the roles model: what another role must run is in the Review directory, never in scratch; the Implementer runs it from there" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  grep -qF -- '- Anything another role must run -- a probe, a reproduction, a measurement script --' "$PROJ/.asb/roles/reviewer-1.md"
  grep -qF -- "- A probe the Reviewer names in its Review is in \`.asb/review/<reviewer>/\`: run it from" "$PROJ/.asb/roles/implementer-1.md"
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
@test "the roles model: a [serve:ROLE] per Planner, Implementer and Reviewer, its prompt file written and kept; the Gate's watch only; none for the Supervisor or setup (#277)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" r m
  m="$(dirname "$ENGINE")/models/roles"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    [ "$(section "[serve:$r]" "$df")" = "$(printf 'watch = .asb/coord/to/%s.md\nprompt = .asb/serve/%s.md' "$r" "$r")" ]
    cmp -s "$PROJ/.asb/serve/$r.md" "$m/serve/${r%-*}.md"
    grep -qF 'Under `--serve` (no terminal) each message is a turn of your own' "$PROJ/.asb/roles/$r.md"
  done
  grep -qxF '[serve:implementer-1]           # no terminal: asb --role implementer-1 --serve' "$df"
  for r in supervisor setup; do
    run ! grep -qF "[serve:$r]" "$df"
    [ ! -e "$PROJ/.asb/serve/$r.md" ]
  done
  # the Gate: watch alone -- its watcher enforced, never served
  [ "$(section '[serve:gate]' "$df")" = 'watch = .asb/coord/to/gate.md' ]
  [ ! -e "$PROJ/.asb/serve/gate.md" ]
  # the Supervisor names both forms, and the terminal on a served session
  # (no command: the role's agent from [agent], as integration/serve.bats runs it)
  grep -qF '`asb --role NAME --serve`,' "$PROJ/.asb/roles/supervisor.md"
  run ! grep -qF -- '--serve claude' "$PROJ/.asb/roles/supervisor.md"
  grep -qF "the role's agent with its resume-by-id flag (claude:" "$PROJ/.asb/roles/supervisor.md"
  grep -qF '`asb --role NAME claude --resume $(cat .asb/coord/NAME/session)`' "$PROJ/.asb/roles/supervisor.md"
  # the review says what each loop waits on and reads; --check names the role's
  approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"[serve:implementer-1], for the roles implementer-1: \`asb --role ROLE --serve CMD\` holds the role's launch on the host and, at each change to .asb/coord/to/implementer-1.md, runs one turn of the role's session in its sandbox, told the text of .asb/serve/implementer-1.md"* ]]
  [[ "$output" == *"[serve:gate], for the roles gate: watch only -- the watcher on .asb/coord/to/gate.md is enforced, the role is not served"* ]]
  [[ "$output" != *"[serve:gate] has no"* ]]
  check implementer-1
  [[ "$output" == *"--serve: a turn of its session per change to .asb/coord/to/implementer-1.md, told the text of .asb/serve/implementer-1.md"$'\n'* ]]
  check gate
  [[ "$output" == *"  --serve: watch only -- the watcher on .asb/coord/to/gate.md is enforced, the role is not served"$'\n'* ]]
  [[ "$output" == *"  watcher: a turn does not end while .asb/coord/to/gate.md has no watcher running (the Stop hook refuses once)"$'\n'* ]]
  # run again: a prompt you changed is kept
  printf 'mine\n' >"$PROJ/.asb/serve/planner-1.md"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/serve/planner-1.md: changed since --init wrote it"* ]]
  [ "$(cat "$PROJ/.asb/serve/planner-1.md")" = mine ]
}

@test "the roles model: a [briefing] start for the Planners, Implementers, Reviewers, the Supervisor and the Gate, its file written from the model's start/ and kept; none for setup" {
  init -- roles planner=2 implementer=1 reviewer=0
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" r m sec
  m="$(dirname "$ENGINE")/models/roles"
  for r in planner implementer supervisor gate; do
    sec="[briefing:$r-*]"
    [[ "$r" == supervisor || "$r" == gate ]] && sec="[briefing:$r]"
    section "$sec" "$df" | sed 's/[[:space:]]*#.*//' | grep -qxF "start = .asb/start/$r.md"
    cmp -s "$PROJ/.asb/start/$r.md" "$m/start/$r.md"
    [ "$(awk 'length > 88' "$m/start/$r.md" | wc -l)" -eq 0 ]
  done
  [ "$(awk '/^start = / && length > 88' "$df" | wc -l)" -eq 0 ]
  grep -qF 'Arm your watcher as your purpose file says' "$PROJ/.asb/start/planner.md"
  grep -qF "read every role's messages" "$PROJ/.asb/start/supervisor.md"
  cmp -s "$PROJ/.asb/start/gate.md" "$m/start/planner.md" # the watching roles' text
  # no Reviewer instance: no file for it; setup starts as typed
  [ ! -e "$PROJ/.asb/start/reviewer.md" ]
  run ! grep -qE '^start = ' <(section "[briefing:setup]" "$df")
  [ ! -e "$PROJ/.asb/start/setup.md" ]
  # the review names each; --check names a Planner's
  approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"[briefing:planner-*] start, for the roles planner-*: its first turn at every start is the text of .asb/start/planner.md"* ]]
  [[ "$output" == *"[briefing:supervisor] start, for the roles supervisor: its first turn at every start is the text of .asb/start/supervisor.md"* ]]
  [[ "$output" == *"[briefing:gate] start, for the roles gate: its first turn at every start is the text of .asb/start/gate.md"* ]]
  check planner-2
  [[ "$output" == *"  first turn at every start: the text of .asb/start/planner.md"$'\n'* ]]
  # run again: a start text you changed is kept, one nobody changed takes the model's
  printf 'mine\n' >"$PROJ/.asb/start/planner.md"
  init -- roles planner=2 implementer=1 reviewer=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/start/planner.md: changed since --init wrote it"* ]]
  [ "$(cat "$PROJ/.asb/start/planner.md")" = mine ]
  cmp -s "$PROJ/.asb/start/implementer.md" "$m/start/implementer.md"
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: the Supervisor watches .agent-sandbox -- its watcher's first file; an affected role is told to finish and say ready, the user gets the relaunch line" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md"
  grep -qxF ".asb/bin/inbox-wait -a .asb/coord/supervisor/alive .agent-sandbox \\" "$sup"
  grep -qxF -- "- Watch \`.agent-sandbox\` too: add it to your watcher's files, and keep a copy in your" "$sup"
  # the bullet closes **Sending a message.**, before the Gate's turn
  [ "$(grep -B2 -xF "**The Gate's turn.** Publishing -- push, pull request, comment, issue, mail -- is the" "$sup" | head -1)" = "  so: the user relaunches you." ]
  grep -qF 'line from the index with `--resume`' "$sup"
  grep -qF "not when it joins one still running" "$sup"
  grep -qF '(a served role: `asb --role R --shutdown`)' "$sup"
  [ "$(sed -n '/^- Watch `.agent-sandbox` too/,/relaunches you\.$/p' "$sup" | wc -l)" -eq 10 ]
  [ "$(sed -n '/^- Watch `.agent-sandbox` too/,/relaunches you\.$/p' "$sup" | awk 'length > 88' | wc -l)" -eq 0 ]
}

@test "the roles model: a reply that stops for the user's word ends with the question -- the Supervisor's Send it?, a bullet in every other role's file" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" r f q="- When you stop for the user's word, your last line is the question."
  # in **Sending a message.**, the bullet that shows the user the message
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- '- Show the user the message, whole, and the role it goes to, and end your reply with')" -eq 1 ]
  # shellcheck disable=SC2016 # backticks: the text, not a command
  grep -qxF -- '  the question, as its last line: `Send it?`; write it only on a yes. Then append it' "$sup"
  for r in planner-1 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -cxF -- "$q")" -eq 1 ]
  done
  # the Gate's is in **Executing a message.**
  [ "$(sed -n '/^\*\*Executing a message\.\*\*/,/^\*\*Closing line/p' "$PROJ/.asb/roles/gate.md" | grep -cxF -- "$q")" -eq 1 ]
  run ! grep -qF -- "$q" "$sup"
  for r in supervisor planner implementer reviewer gate; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
}

@test "the roles model: a Task may start fresh -- the Supervisor asks the user before a new Task, writes the reset marker and sends once it is gone, or asks for /clear when nobody took it; every other role writes to its memory before done, and resumes a turn cut short without asking" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" r f
  # in **Sending a message.**
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -c '^- Before a message that opens a new Task for a role, ask the user whether the role$')" -eq 1 ]
  local flat
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  # shellcheck disable=SC2016 # backticks: the text, not a command
  [[ "$flat" == *'Fresh: write an empty `.asb/coord/to/<role>.reset`, and append the message only once the marker is gone: a served role'"'"'s loop and the host side of `asb --roles` each take it within a second, and `.asb/bin/inbox-wait -t 10 .asb/coord/to/<role>.reset` waits for that.'* ]]
  # shellcheck disable=SC2016 # backticks: the text, not a command
  [[ "$flat" == *'Still there after it: nobody takes resets for this role (it was opened in a terminal of its own), so tell the user to type `/clear` in that role'"'"'s terminal, and send when they say it is done.'* ]]
  [[ "$flat" != *'/start'* ]]
  [ "$(sed -n '/^- Before a message that opens a new Task/,/role'"'"'s own memory\.$/p' "$sup" | wc -l)" -eq 9 ]
  [ "$(sed -n '/^- Before a message that opens a new Task/,/role'"'"'s own memory\.$/p' "$sup" | awk 'length > 88' | wc -l)" -eq 0 ]
  # the next bullet: the relay is asked about with the message that opens a Task (#326)
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- '- With the message that opens a Task for an Implementer, ask too, in the same reply,')" -eq 1 ]
  # shellcheck disable=SC2016 # backticks: the text, not a command
  [[ "$flat" == *'whether the messages between it and its Reviewer are relayed for this Task without asking (**The relay.**, below); `Send it?` stays the last line.'* ]]
  for r in planner-1 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    grep -qxF -- "- Before you report a Task done, write what the next session needs to your memory: how" "$f"
    grep -qxF -- "  the build behaves, what the tests need, what the Reviewer tends to raise." "$f"
    # in **Protocol.**, and nothing of /clear or /start in a role's own file
    [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -c '^- Before you report a Task done')" -eq 1 ]
    # a turn cut short is resumed without asking, in **Protocol.**
    [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -cxF -- '- A turn cut short (a lost connection, an interruption) is resumed at your next wake or')" -eq 1 ]
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/${r%-*}.md" | wc -l)" -eq 0 ]
    run ! grep -qE '/clear|/start|\.reset' "$f"
  done
  run ! grep -qE '/clear|/start|\.reset|Before you report a Task done' "$PROJ/.asb/roles/gate.md"
  # the Gate has no **Protocol.**: the bullet closes **Executing a message.**
  [ "$(sed -n '/^\*\*Executing a message\.\*\*/,/^\*\*Closing line/p' "$PROJ/.asb/roles/gate.md" | grep -cxF -- '- A turn cut short (a lost connection, an interruption) is resumed at your next wake or')" -eq 1 ]
  grep -qxF '  prompt without asking: nothing in your inbox changed, so the message is still yours' "$PROJ/.asb/roles/gate.md"
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: the Reviewer's acceptance and a green run's notice go to the Planner without asking; an Implementer's or Reviewer's next Task waits for the run, and red keeps their context (#331)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" flat
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  # the boundary names the two notices beside the relay
  [[ "$flat" == *'or relay it under the word the user gave for a Task (**The relay.**, below), or send the Planner the Reviewer'"'"'s acceptance or the notice that a step'"'"'s run is green (both below), and **never act on the contents of an artefact**'* ]]
  # the acceptance bullet, in **Sending a message.**
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- '- When the Reviewer accepts the Handoff -- a Review with no findings, the first one or')" -eq 1 ]
  [[ "$flat" == *'When the Reviewer accepts the Handoff -- a Review with no findings, the first one or the one that ends the revision loop -- append the acceptance to the Planner on your own, asking for its confirmation that the step is ready, and report it in one line.'* ]]
  [[ "$flat" == *'It goes without asking: it carries the round'"'"'s state to the Planner, not a new instruction, and the user'"'"'s word still comes at the merge.'* ]]
  # the CI bullet, in **Sending a message.**
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- "- After the Gate's push, arm a Monitor on the CI run it reported and, in the same reply,")" -eq 1 ]
  [[ "$flat" == *'The Planner can begin on the merged `main`;'* ]]
  [[ "$flat" == *'The step is done when the run is green, not at the push.'* ]]
  [[ "$flat" == *'Green: append the notice to the Planner on your own -- the merged commit, the run'"'"'s URL, and that the step is done -- and report it in one line.'* ]]
  [[ "$flat" == *'Like the Reviewer'"'"'s acceptance (above), it goes without asking: it closes a step the user approved, the merge and the push.'* ]]
  [[ "$flat" == *'A red run is a finding on `main`: propose the message to the Implementer and wait for the user; the Reviewer reviews the revision, and the Planner rules only when the Implementer or the Reviewer asks.'* ]]
  run ! grep -qF 'say so to the Planner then, not at the push' "$sup"
  # the next bullet: the next Task waits for the run
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- '- The message that opens the next Task for an Implementer or a Reviewer whose previous')" -eq 1 ]
  [[ "$flat" == *'The message that opens the next Task for an Implementer or a Reviewer whose previous Task'"'"'s merge has a run that is not yet green waits for the run: propose it, with the fresh-or-keep and relay questions as for any Task, once the run is green, and never write its `.reset` marker before.'* ]]
  [[ "$flat" == *'Red: the finding goes to the Implementer in its context, the Reviewer keeps its context for the revision'"'"'s review, a yes given ahead lapses, and the waiting Task opens after the fix is merged and its run is green'* ]]
  # the relay's list and the never list carve out the notice
  [[ "$flat" == *'the merge proposal, every message to a Planner but the Reviewer'"'"'s acceptance and the notice of a green run (above) or to the Gate, the fresh-or-keep question before a new Task.'* ]]
  [[ "$flat" == *'write an instruction the user has not approved here, unless the relay covers it or it is the Reviewer'"'"'s acceptance or the notice of a green run to the Planner;'* ]]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: after the Gate's push the Supervisor's reply ends on the Planner's step or a question, never on the watch; a Task already written for the waiting Implementer is asked about ahead and goes at green (#333)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" flat
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  # the CI bullet, in **Sending a message.**: the Planner's step in the same reply
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- "- After the Gate's push, arm a Monitor on the CI run it reported and, in the same reply,")" -eq 1 ]
  [[ "$flat" == *'After the Gate'"'"'s push, arm a Monitor on the CI run it reported and, in the same reply, propose the Planner'"'"'s next step: the next Task to plan, or, where that Task is already written, planning ahead -- the Task after it, an outline whose base commit is filled in later.'* ]]
  [[ "$flat" == *'The Planner can begin on the merged `main`; only the Implementer'"'"'s and the Reviewer'"'"'s next Task wait for the run (below).'* ]]
  [[ "$flat" == *'Your reply ends on that proposal or on a question, never on the watch alone.'* ]]
  run ! grep -qF 'propose the next step without waiting' "$sup"
  # the next-Task bullet: a Task already written is asked about ahead
  [[ "$flat" == *'When the Planner has already written the waiting Implementer'"'"'s next Task, do not wait to ask: say so, and ask now, with the fresh-or-keep and relay questions as for any Task, whether it goes to the Implementer when the run is green.'* ]]
  [[ "$flat" == *'That yes is the user'"'"'s word on that one message, given ahead and conditioned on the run: the message is still asked about, not one that goes without asking.'* ]]
  [[ "$flat" == *'On yes, at green: write the `.reset` marker if the user said fresh, append the message once the marker is gone, report it in one line, and ask no second question.'* ]]
  [[ "$flat" == *'Red: the finding goes to the Implementer in its context, the Reviewer keeps its context for the revision'"'"'s review, a yes given ahead lapses, and the waiting Task opens after the fix is merged and its run is green, asked about again then.'* ]]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
}

@test "run again on a file from an older model: the lines the model gained that an existing section lacks, one --apply per section, loud" {
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"your .agent-sandbox lacks"* && "$output" != *"--apply line"* ]] # a fresh file: nothing
  grep -qxF 'Bash(gh pr comment:*)' "$PROJ/.agent-sandbox"
  # the file as an older model wrote it: no start line for the Gate, one rule fewer
  sed -i -e '/^\[briefing:gate\]/,/^\[/{/^start = /d}' -e '/^Bash(gh pr comment:\*)$/d' "$PROJ/.agent-sandbox"
  run ! grep -q '^start = .asb/start/gate.md' "$PROJ/.agent-sandbox"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles
  [ "$status" -eq 0 ]
  cmp "$H/before" "$PROJ/.agent-sandbox" # an existing section is never changed
  [[ "$output" == *"agent-sandbox: --init: 2 lines model 'roles' has now that your .agent-sandbox lacks -- --init does not write into an existing file; add them with:"* ]]
  [ "$(grep -c '^    agent-sandbox --apply ' <<<"$output")" -eq 2 ]
  grep -qxF "    agent-sandbox --apply '[permissions:gate]' 'Bash(gh pr comment:*)'" <<<"$output"
  grep -qxF "    agent-sandbox --apply '[briefing:gate]' 'start = .asb/start/gate.md'" <<<"$output"
  # before the summary, which points at it
  [ "$(grep -n 'lacks -- --init does not write' <<<"$output" | cut -d: -f1)" -lt "$(grep -n '^Next, yours:' <<<"$output" | cut -d: -f1)" ]
  [[ "$output" == *"  - the --apply lines above: what model 'roles' gained that your existing sections lack"* ]]
}

@test "run again: a common section the file lacks is said with its --apply line, not written; one with another value is the user's (#355)" {
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"your .agent-sandbox lacks"* ]]
  # a project an earlier --init wrote: no [agent] block
  sed -i '/^\[agent\]$/{N;d}' "$PROJ/.agent-sandbox"
  run ! grep -q '^\[agent\]' "$PROJ/.agent-sandbox"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles
  [ "$status" -eq 0 ]
  cmp "$H/before" "$PROJ/.agent-sandbox" # said, never written
  [[ "$output" == *"agent-sandbox: --init: 1 line model 'roles' has now that your .agent-sandbox lacks -- --init does not write into an existing file; add it with:"* ]]
  [ "$(grep -c '^    agent-sandbox --apply ' <<<"$output")" -eq 1 ]
  grep -qxF "    agent-sandbox --apply '[agent]' 'command = claude'" <<<"$output"
  # the section with another agent: the key is there, so nothing is said
  printf '[agent]\ncommand = codex --model x\n' >>"$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"your .agent-sandbox lacks"* && "$output" != *"--apply line"* ]]
}

@test "run again: a line the file has commented out, or a key with another value, is the user's -- nothing said" {
  init -- roles
  [ "$status" -eq 0 ]
  sed -i -e '/^\[briefing:gate\]/,/^\[/s/^start = .*/# start = .asb\/start\/gate.md/' \
    -e '/^\[briefing:supervisor\]/,/^\[/s/^start = .*/start = other.md/' \
    -e 's/^Bash(gh pr comment:\*)$/# Bash(gh pr comment:*)/' "$PROJ/.agent-sandbox"
  grep -qxF '# start = .asb/start/gate.md' "$PROJ/.agent-sandbox"
  grep -qxF 'start = other.md' "$PROJ/.agent-sandbox"
  grep -qxF '# Bash(gh pr comment:*)' "$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing added to it"* ]]
  [[ "$output" != *"your .agent-sandbox lacks"* && "$output" != *"--apply line"* ]]
}

@test "run again on a composed file: only the model being initialised is reported (#267)" {
  init -- github
  [ "$status" -eq 0 ]
  init -- roles
  [ "$status" -eq 0 ]
  # appended to a file: its own role sections are new; its common [agent] is written only
  # with a new file, so the line it lacks is said (#355)
  [[ "$output" == *"agent-sandbox: --init: 1 line model 'roles' has now that your .agent-sandbox lacks"* ]]
  [ "$(grep -c '^    agent-sandbox --apply ' <<<"$output")" -eq 1 ]
  grep -qxF "    agent-sandbox --apply '[agent]' 'command = claude'" <<<"$output"
  run ! grep -qx '\[agent\]' "$PROJ/.agent-sandbox"
  grep -qxF 'file = .asb/roles/gh-fix.md' "$PROJ/.agent-sandbox"
  sed -i -e '/^file = .asb\/roles\/gh-fix.md$/d' -e '/^\[briefing:gate\]/,/^\[/{/^start = /d}' "$PROJ/.agent-sandbox"
  printf '[agent]\ncommand = claude\n' >>"$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: --init: 1 line model 'roles' has now that your .agent-sandbox lacks -- --init does not write into an existing file; add it with:"* ]]
  [ "$(grep -c '^    agent-sandbox --apply ' <<<"$output")" -eq 1 ]
  grep -qxF "    agent-sandbox --apply '[briefing:gate]' 'start = .asb/start/gate.md'" <<<"$output"
  [[ "$output" == *"  - the --apply line above: what model 'roles' gained"* ]]
  init -- github
  [ "$status" -eq 0 ]
  [ "$(grep -c '^    agent-sandbox --apply ' <<<"$output")" -eq 1 ]
  grep -qxF "    agent-sandbox --apply '[briefing:gh-fix-*]' 'file = .asb/roles/gh-fix.md'" <<<"$output"
}

# shellcheck disable=SC2016 # backquotes are the purpose files' text, not ours
@test "the roles model: .asb/tests, the project's iterate and final commands, written empty and kept once filled; the purpose files tell the test economy (#301)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local t="$PROJ/.asb/tests" m r f
  m="$(dirname "$ENGINE")/models/roles"
  [[ "$output" == *"wrote .asb/tests"* ]]
  cmp -s "$t" "$m/tests"
  [ "$(grep -v '^#' "$t")" = $'iterate =\nfinal =' ]
  grep -qxF '# The project'"'"'s test commands for the roles (docs/roles.md, "Test economy"). Fill in' "$t"
  grep -qF '# iterate: what an iterating round runs: the tests the change affects' "$t"
  grep -qF '# final: the whole suite, run once by the Reviewer when it would accept with zero' "$t"
  [ "$(awk 'length > 88' "$m/tests" | wc -l)" -eq 0 ]
  # the purpose files: each sentence in its section, its file wrapped at 88
  f="$PROJ/.asb/roles/implementer-1.md"
  [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -cxF -- '- Tests, while iterating: run the `iterate` command of `.asb/tests` (the tests your')" -eq 1 ]
  [[ "$(tr '\n' ' ' <"$f" | tr -s ' ')" == *'The whole suite is the Reviewer'"'"'s, once, at acceptance; a failure there comes back as a finding.'* ]]
  f="$PROJ/.asb/roles/reviewer-1.md"
  [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -cxF -- '- Tests, per round: run the `iterate` command of `.asb/tests` on the Handoff'"'"'s changed')" -eq 1 ]
  [[ "$(tr '\n' ' ' <"$f" | tr -s ' ')" == *'run the `final` command once, the whole suite, before you accept, and report it in that Review; a failure is a finding, not an acceptance. Nobody else runs the whole suite in a round.'* ]]
  f="$PROJ/.asb/roles/supervisor.md"
  [[ "$(sed -n '/^- After a merge, run the suite only when/,/^- After the Gate/p' "$f" | tr '\n' ' ' | tr -s ' ')" == *'Build `main` either way. You may ask the Reviewer for the `final` run at any point; the rounds themselves run only the affected tests (`.asb/tests`).'* ]]
  f="$PROJ/.asb/roles/planner-1.md"
  [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -cxF -- '- A Task names what its tests cover only when the project'"'"'s `.asb/tests` does not; the')" -eq 1 ]
  for r in planner implementer reviewer supervisor; do
    [ "$(awk 'length > 88' "$m/roles/$r.md" | wc -l)" -eq 0 ]
  done
  # run again: an unchanged file stays the model's, a filled one is kept and said
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" != *".asb/tests"* ]]
  cmp -s "$t" "$m/tests"
  sed -i -e 's/^iterate =$/iterate = scripts\/test-affected.sh/' -e 's/^final =$/final = pytest/' "$t"
  cp "$t" "$H/filled"
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/tests: changed since --init wrote it"* ]]
  [[ "$output" != *"lacks -- --init never"* ]] # not a dot-file section: no --apply report
  cmp -s "$t" "$H/filled"
}

@test "a model without a tests file writes no .asb/tests (#301)" {
  init -- github
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.asb/tests" ]
}
