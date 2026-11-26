#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: the roles model -- its files, sections, purpose-file texts and
# docs/roles.md.
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

@test "the roles model: every instance's sections, purpose files, clones, directories, the index and .asb/.gitignore" {
  init -- roles planner=2 implementer=2 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--trust"* && "$output" == *"--check --role NAME"* ]]
  local df="$PROJ/.agent-sandbox"
  for s in '[connect:planner-1]' '[connect:planner-2]' '[briefing:planner-*]' '[connect:implementer-1]' \
    '[connect:implementer-2]' '[connect:reviewer-1]' '[connect:supervisor]' '[net:supervisor]' '[briefing:supervisor]'; do
    has_section "$s" "$df"
  done
  # every placeholder substituted, but a glob section's {role}, the launch's (#456, #485)
  run grep -F '{' "$df"
  [ "$output" = "$(printf 'context = .asb/coord/{role}/context # how full its context is: S reads it, and watches .level\nasking = .asb/coord/{role}/asking # there once it asks the user in its pane: S reads it\n%.0s' 1 2 3)" ]
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
  # the push by URL, two calls: the URL read on its own (read-only), then pushed to as written
  local flat
  flat="$(tr '\n' ' ' <"$PROJ/.asb/roles/gate.md" | tr -s ' ')"
  # shellcheck disable=SC2016 # the backticks are the purpose file's markdown, not a command
  [[ "$flat" == *'in two calls: read `origin`'"'"'s URL with `git config --get remote.origin.url` (read-only, so it needs no rule), then run `git push URL BRANCH` with that URL written out.'* ]]
  run ! grep -qF 'git remote get-url' "$PROJ/.asb/roles/gate.md"
  grep -qF "asb --apply '[ssh:gate]' HOST" "$PROJ/.asb/roles/gate.md"
  grep -qxF '  approves it, S restarts this role, which applies it.' "$PROJ/.asb/roles/gate.md"
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
  grep -qxF ".asb/bin/inbox-wait -s .asb/coord/planner-2/inbox-wait.state \\" "$PROJ/.asb/roles/planner-2.md"
  grep -qxF '  -a .asb/coord/planner-2/alive .asb/coord/to/planner-2.md' "$PROJ/.asb/roles/planner-2.md"
  # the closing line comes with the done N write, never before
  local r
  for r in planner-1 implementer-1 reviewer-1 gate; do
    # shellcheck disable=SC2016 # backquotes in the text, not an expansion
    tr '\n' ' ' <"$PROJ/.asb/roles/$r.md" | grep -qF '**Closing line.** "done; in my file; S has it" is said once, in the reply in which you append `done N` to your messages, and never before: a reply with work still pending (a suite running, a section unwritten) ends by naming what is pending and what follows.'
  done
  grep -qxF ".asb/bin/inbox-wait -f -i '^ack [0-9]+\$' -t 1790 \\" "$PROJ/.asb/roles/supervisor.md"
  grep -qxF "  -s .asb/coord/supervisor/inbox-wait.state \\" "$PROJ/.asb/roles/supervisor.md"
  grep -qxF "  -a .asb/coord/supervisor/alive .agent-sandbox \\" "$PROJ/.asb/roles/supervisor.md"
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

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: a stale alive is a reason to look, never a verdict -- the Supervisor checks at=, messages, the last commit and the summary line, and gives no launch line on alive alone; docs/roles.md says the same (#464)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" doc flat dflat
  doc="$(dirname "$ENGINE")/docs/roles.md"
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  dflat="$(tr '\n' ' ' <"$doc" | tr -s ' ')"
  # what alive means: a watcher waiting; at a terminal it is stale for a turn; a served loop's is not
  [[ "$flat" == *'read the age of `.asb/coord/<role>/alive`. It says a watcher is waiting for the next message.'* ]]
  [[ "$flat" == *'At a terminal, the role'"'"'s watcher touches it every second, but exits on the message that wakes the role, and the role arms it again, at the turn'"'"'s end at the latest: a stale `alive` there most often means a long turn.'* ]]
  [[ "$flat" == *'A served role'"'"'s loop touches it every second, its turns included.'* ]]
  # a reason to look; the four checks, in order
  [[ "$flat" == *'- Stale, or missing, is a reason to look, never a verdict. Look at the role'"'"'s `asking` file first: there, the role asked the user at its `since` and no hook has run since -- it waits in its pane, or runs a tool the user approved there -- so give the `asking` line of **At start.**, once per `since`: not "busy in a turn", not "it is asking you", and no launch line (the user then finding the pane gone is the last case below). Then check, in this order: the role'"'"'s `context` line'"'"'s `at=`; its `messages.md` and the time of its last change; for an Implementer, its clone'"'"'s last commit (`git -C .asb/impl/N log -1 --format=%cd`, the committer date, which an amend moves); its summary line, where you can see it.'* ]]
  # any moved: busy in a turn, no launch line
  [[ "$flat" == *'Any of them later than `alive`: say the role is "busy in a turn", and give no launch line.'* ]]
  # none moved: still none, and why; the user looks
  [[ "$flat" == *'None of them: still no launch line on `alive` alone -- `at=` moves only when the context'"'"'s numbers change, so a turn spent in one long tool call (a test suite) moves none of the four.'* ]]
  [[ "$flat" == *'Ask the user to look at the role'"'"'s terminal, or its `--serve` pane, and give its launch line from the index only when the user says the role is gone.'* ]]
  # the pickup is checked by a look, not an event: the stream skips acks (T39, P1's ruling)
  [[ "$flat" == *'- When you send, put the pending pickup in your summary line (e.g. `sent 143 to implementer-1, waiting for its ack`): your stream skips `ack N` lines, so no event tells you of a pickup.'* ]]
  [[ "$flat" == *'Look for `ack N` in the role'"'"'s messages instead: at your next wake or turn after the send, before you tell the user anything about that role, and at every re-arm of the stream.'* ]]
  [[ "$flat" == *'The ack found: the summary line moves on. A look that finds none a minute or more after the send: say in the chat that the role has not picked it up. Never send again on your own; the user decides.'* ]]
  run ! grep -qF 'within a minute: say the role' "$sup"
  # the old verdict is gone
  run ! grep -qF 'the role is not running -- say' "$sup"
  run ! grep -qF 'tell the user its launch line, as for any role' "$sup"
  [ "$(sed -n '/^- Before you send, and while you wait/,/the user decides\.$/p' "$sup" | awk 'length > 88' | wc -l)" -eq 0 ]
  # docs/roles.md: the same
  [[ "$dflat" == *'so the file says a watcher is waiting for the next message;'* ]]
  [[ "$dflat" == *'At a terminal the watcher exits on the message that wakes the role and runs again only once the role re-arms it -- at the turn'"'"'s end at the latest, where the Stop hook enforces it -- so `alive` can be stale for as long as a turn lasts (#464); a served role'"'"'s loop touches it every second, its turns included.'* ]]
  [[ "$dflat" == *'Stale is a reason to look, never a verdict: the Supervisor looks at the role'"'"'s asking file first (section 8) -- there, the role asked you something in its pane and no hook has run since, and it says so -- then checks the role'"'"'s `context` line'"'"'s `at=`, its messages, an Implementer'"'"'s last commit and its summary line, and says "busy in a turn" when any moved after `alive`.'* ]]
  [[ "$dflat" == *'It gives the launch line only when you say the role is gone, since a turn spent in one long tool call moves none of them.'* ]]
  [[ "$dflat" == *'each second, its turns included (a terminal'"'"'s watcher stops for the turn), so the Supervisor sees the role running.'* ]]
  [[ "$dflat" == *'Its stream skips `ack` lines, so after a send it looks for the `ack` -- at its next wake or turn, before it tells you anything about that role, and at every re-arm -- and its bar shows the pending pickup meanwhile.'* ]]
  [[ "$dflat" == *'None a minute or more after the send means the role has not picked it up: said in the chat, never sent again on the Supervisor'"'"'s own.'* ]]
  run ! grep -qF 'Stale means the role is not running' "$doc"
  run ! grep -qF 'as the watcher in a terminal does' "$doc"
  # docs/config.md and the watcher's own header: the same meaning
  local cfg
  cfg="$(tr '\n' ' ' <"$(dirname "$ENGINE")/docs/config.md" | tr -s ' ')"
  [[ "$cfg" == *'the loop touches `.asb/coord/ROLE/alive` every second, its turns included (a terminal role'"'"'s watcher stops for the turn).'* ]]
  run ! grep -qF 'as a terminal role'"'"'s watcher does' "$(dirname "$ENGINE")/docs/config.md"
  grep -qF '# ALIVE, a path, is touched at every poll, so its age says whether a watcher is' "$PROJ/.asb/bin/inbox-wait"
  grep -qF '# waiting: it goes stale while the role works a turn (#464).' "$PROJ/.asb/bin/inbox-wait"
  run ! grep -qF 'whether the role that waits' "$PROJ/.asb/bin/inbox-wait"
}

# shellcheck disable=SC2016 # backquotes are the purpose files' text, not ours
@test "the roles model: every watcher but the Supervisor's is a background Bash wait, re-run after each wake, never a Monitor; the Supervisor runs one stream over every other role's messages in the index, the Gate's too (#288)" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local r f sup="$PROJ/.asb/roles/supervisor.md" idx="$PROJ/.asb/coord/COORDINATION.md"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    grep -qxF ".asb/bin/inbox-wait -s .asb/coord/$r/inbox-wait.state \\" "$f"
    grep -qxF "  -a .asb/coord/$r/alive .asb/coord/to/$r.md" "$f"
    grep -qF 'with the Bash tool and' "$f"
    grep -qxF "\`run_in_background: true\`, and run it again after each wake; a change to your inbox" "$f"
    grep -qF 'background command has no time limit in a terminal session, so nothing expires.' "$f"
    grep -qF 'arm no watcher, read and act' "$f"
  done
  # the Gate arms one as the others do; it is never served, so no --serve rule
  f="$PROJ/.asb/roles/gate.md"
  grep -qxF ".asb/bin/inbox-wait -s .asb/coord/gate/inbox-wait.state \\" "$f"
  grep -qxF "  -a .asb/coord/gate/alive .asb/coord/to/gate.md" "$f"
  grep -qxF '**At start.** From the project directory, run this command with the Bash tool and' "$f"
  grep -qxF "\`run_in_background: true\`, and run it again after each wake; a change to your inbox" "$f"
  grep -qF 'background command has no time limit in a terminal session, so nothing expires.' "$f"
  grep -qxF 'At start and at every wake, read your inbox, `.asb/coord/to/gate.md`, from your' "$f"
  run ! grep -qE 'you have no watcher|opened when it is|arm no watcher|--serve' "$f"
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/gate.md" | wc -l)" -eq 0 ]
  # the Supervisor: one command, its paths from the index, every role's but its own
  grep -qxF -- "- Watch every role's messages with one stream, a command that keeps running and prints" "$sup"
  grep -qxF "  a line per change: \`.agent-sandbox\`, then one path per role in the index but" "$sup"
  grep -qxF "  yourself, then every role's \`context.level\`, yours included, then every role's" "$sup"
  grep -qxF ".asb/bin/inbox-wait -f -i '^ack [0-9]+\$' -t 1790 \\" "$sup"
  grep -qxF "  -s .asb/coord/supervisor/inbox-wait.state \\" "$sup"
  grep -qxF "  -a .asb/coord/supervisor/alive .agent-sandbox \\" "$sup"
  grep -qxF "  .asb/coord/planner-1/messages.md .asb/coord/implementer-1/messages.md ... \\" "$sup"
  grep -qxF "  .asb/coord/gate/messages.md \\" "$sup"
  # and every role's context level, its own first (#456)
  grep -qxF "  .asb/coord/supervisor/context.level .asb/coord/planner-1/context.level ... \\" "$sup"
  grep -qxF "  .asb/coord/gate/context.level \\" "$sup"
  # and every role's asking file but its own, last (#485)
  grep -qxF '  .asb/coord/planner-1/asking ... .asb/coord/gate/asking' "$sup"
  [ "$(grep -A1 -xF '  .asb/coord/planner-1/asking ... .asb/coord/gate/asking' "$sup" | sed -n 2p)" = '```' ]
  run ! grep -qE 'but the Gate|Gate has no watcher|only when it is its turn' "$sup"
  # a stream (T39): under the tool that takes each line as an event; armed again only when
  # it ends, never after an event; arming again is safe; alive fresh; the one-shot fallback
  local w
  w="$(sed -n '/^- Watch every role'"'"'s messages with one stream/,/^- Read the index/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$w" == *'`-i '"'"'^ack [0-9]+$'"'"'` drops a role'"'"'s `ack N` lines, which you never act on; every other change is a line:'* ]]
  [[ "$w" == *'Run it with the tool that takes each line of a command as an event (claude: `Monitor`, loaded with ToolSearch where it is deferred, `timeout_ms` at its maximum, 1800000, description "role reports, context levels, .agent-sandbox").'* ]]
  [[ "$w" == *'Each line is one wake: `PATH: LINE`, the last line appended there, or `PATH changed`. Act on it, and read the file when the line is not enough.'* ]]
  [[ "$w" == *'- Arm it again only when the stream ends -- its `-t`, an expiry, a failure, whatever its status -- never after an event, in one call.'* ]]
  [[ "$w" == *'Arming again is always safe: a line saying a watcher already runs means it is still armed.'* ]]
  [[ "$w" == *'- It polls through your turns too, so your own `alive` stays fresh while you work.'* ]]
  [[ "$w" == *'- Without such a tool: the same command without `-f`, `-i` and `-t`, with the Bash tool and `run_in_background: true`, run again after each wake. It exits at the first change, printing that file'"'"'s path; a background command has no time limit in a terminal session, so nothing expires.'* ]]
  [[ "$w" == *'- The waits on a `.reset` or `.restart` marker, below, stay one-shot Bash commands.'* ]]
  # its progress goes to the summary line, written with the shell in the work's call (T39)
  local sflat
  sflat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  [[ "$sflat" == *'- Progress that needs nothing from the user -- a message routed, a run partway, a wait -- goes in your summary line, which the bar of your pane shows; write it there with the shell, in the same reply as the work, in a call of its own, and do not reply with it.'* ]]
  # a report that ends a step with nothing for the user goes to the summary line; none is
  # reported in one line in the chat any more (P1's ruling)
  [[ "$sflat" == *'- Put each relayed message in your summary line -- what went where, the revision count,'* ]]
  [ "$(grep -c 'in one line' "$sup")" -eq 0 ]
  [[ "$sflat" == *'A reply in the chat is for what needs the user: a decision, a question, a result to act on, a problem.'* ]]
  # the Gate's turn: it wakes on its inbox; a stale alive is looked into, as any role's (#464)
  local flat
  flat="$(tr '\n' ' ' <"$sup" | tr -s ' ')"
  [[ "$flat" == *'`.asb/coord/to/gate.md` as above: the Gate wakes on its inbox like any role, and when its `alive` is stale, look before you say it is down, as for any role, and give its launch line only when the user says it is gone.'* ]]
  [[ "$flat" == *'is in `.asb/coord/gate/messages.md`, which your watcher sees; bring it to the user.'* ]]
  [[ "$flat" == *'A post that mentions a GitHub user (`@name`) the Gate posts only after the user approves it in the Gate'"'"'s terminal'* ]]
  run ! grep -qF "tell the user it is the Gate's turn" "$sup"
  for r in planner-1 planner-2 implementer-1 reviewer-1; do
    grep -q "^| [A-Z][0-9]* | $r | .asb/coord/$r/messages.md |" "$idx"
  done
  grep -q '^| G | gate | .asb/coord/gate/messages.md |' "$idx"
  # no Monitor watcher and no tail anywhere else the model wrote, nor a rule for it: the
  # stream is the Supervisor's alone (T39)
  for f in "$PROJ"/.asb/roles/*.md "$PROJ"/.asb/serve/*.md; do
    [[ "$f" == */roles/supervisor.md ]] && continue
    run ! grep -qE 'Monitor|timeout_ms|arm no Monitor|tail -n|inbox-wait -f' "$f"
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
  [ "$(grep -c '^command = ' "$PROJ/.agent-sandbox")" -eq 1 ] # no [agent:...] section sets one
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
@test "the roles model: the Supervisor watches .agent-sandbox -- its watcher's first file; an affected role is told to finish and answer ready or wait, the user gets the relaunch line when nobody takes the restart (#416)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md"
  grep -qxF ".asb/bin/inbox-wait -f -i '^ack [0-9]+\$' -t 1790 \\" "$sup"
  grep -qxF "  -s .asb/coord/supervisor/inbox-wait.state \\" "$sup"
  grep -qxF "  -a .asb/coord/supervisor/alive .agent-sandbox \\" "$sup"
  grep -qxF -- "- Watch \`.agent-sandbox\` too: add it to your watcher's files, and keep a copy in your" "$sup"
  # the bullet closes **Sending a message.**, before the Gate's turn
  [ "$(grep -B2 -xF "**The Gate's turn.** Publishing -- push, pull request, comment, issue, mail -- is the" "$sup" | head -1)" = "    user relaunches you." ]
  grep -qF 'line from the index with `--resume`' "$sup"
  grep -qF "not when it joins one still running" "$sup"
  grep -qF '(a served role: `asb --role R --shutdown`)' "$sup"
  [ "$(sed -n '/^- Watch `.agent-sandbox` too/,/relaunches you\.$/p' "$sup" | wc -l)" -eq 52 ] # 30 before #482, which adds 2 and its own bullet of 20
  [ "$(sed -n '/^- Watch `.agent-sandbox` too/,/relaunches you\.$/p' "$sup" | awk 'length > 88' | wc -l)" -eq 0 ]
}

@test "the roles model: a role stops for the user's word with the question in its messages, addressed to S, and asks nothing in its terminal; the Gate asks there only about @name; the Supervisor ends with Send it?" {
  # #445: "your last line is the question" did not say whose last line, and a Planner
  # asked in its terminal as well as through S: two places for one decision.
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" r f old="your last line is the question"
  local q g
  q="- When you stop for the user's word, the question goes in your messages, addressed to
  S, as their last line or the last before your \`done N\`; S brings it to the user.
  Your terminal reply names it as pending, as a statement without a question mark
  (\"waiting for S on: whether ...\"), and asks nothing, nor do you open a question
  dialog (AskUserQuestion): an answer given here would bypass S. When the user talks
  to you here, answer here."
  # shellcheck disable=SC2016 # backticks: the text, not a command
  g='- When you stop for the user'"'"'s word, write why in your messages (`back N: ...`), as
  above. Ask in this terminal only what the user answers here -- a post that mentions
  `@name` -- and then the question is your reply'"'"'s last line.'
  # in **Sending a message.**, the bullet that shows the user the message
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- '- Show the user the message, whole, and the role it goes to, and end your reply with')" -eq 1 ]
  # shellcheck disable=SC2016 # backticks: the text, not a command
  grep -qxF -- '  the question, as its last line: `Send it?`; write it only on a yes. Then append it' "$sup"
  # the whole bullet, once, in **Protocol.**: the question goes to S, the reply asks nothing
  for r in planner-1 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -A5 -xF -- "${q%%$'\n'*}")" = "$q" ]
    [ "$(grep -cF -- "${q%%$'\n'*}" "$f")" -eq 1 ]
    run ! grep -qF -- "$old" "$f"
    run ! grep -qF -- "your reply's last line" "$f"
  done
  # the Gate's is in **Executing a message.**: it asks in its terminal only about @name
  f="$PROJ/.asb/roles/gate.md"
  [ "$(sed -n '/^\*\*Executing a message\.\*\*/,/^\*\*Closing line/p' "$f" | grep -A2 -xF -- "${g%%$'\n'*}")" = "$g" ]
  [ "$(grep -cF -- "When you stop for the user's word" "$f")" -eq 1 ]
  run ! grep -qF -- "$old" "$f"
  run ! grep -qF -- "$old" "$sup"
  run ! grep -qF -- "When you stop for the user's word" "$sup"
  for r in supervisor planner implementer reviewer gate; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
}

# effort_of HEADER FILE -- the effort line's value under HEADER in FILE, comments dropped.
effort_of() {
  sed -n "/^$(printf '%s' "$1" | sed 's/[][*.]/\\&/g')/,/^\[/{s/^effort = \([a-z]*\).*/\1/p}" "$2"
}

@test "the roles model: each role's effort level, an [agent:...] section of its own -- planners, implementers, reviewers and setup high, the Supervisor medium, the Gate low; none for setup under --shared-env" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  [ "$(effort_of '[agent:planner-*]' "$df")" = high ]
  [ "$(effort_of '[agent:implementer-*]' "$df")" = high ]
  [ "$(effort_of '[agent:reviewer-*]' "$df")" = high ]
  [ "$(effort_of '[agent:supervisor]' "$df")" = medium ]
  [ "$(effort_of '[agent:gate]' "$df")" = low ]
  [ "$(effort_of '[agent:setup]' "$df")" = high ]
  [ "$(grep -c '^effort = ' "$df")" -eq 6 ] # once per role pattern, never per instance
  # the review takes them; --check shows a role's, in the profile's words
  run_review
  [[ "$output" == *"[agent:gate] effort = low: the roles gate run at the effort level low"* ]]
  [[ "$output" != *"not an effort level"* ]]
  # under --shared-env there is no setup role, and no level for it
  rm -rf "$PROJ/.asb" "$df"
  shared_env torch-dev
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles planner=1 --shared-env torch-dev
  [ "$status" -eq 0 ]
  run ! grep -qF '[agent:setup]' "$df"
  [ "$(grep -c '^effort = ' "$df")" -eq 5 ]
}

@test "the roles model: each role's [agent:...] section says auto-compact = off beside its effort, the default made visible (#438); the review takes it; a file from before gets it per role as --apply lines" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" h
  for h in '[agent:planner-*]' '[agent:implementer-*]' '[agent:reviewer-*]' '[agent:supervisor]' '[agent:gate]' '[agent:setup]'; do
    # the line right after the section's effort line
    sed -n "/^$(printf '%s' "$h" | sed 's/[][*.]/\\&/g')/,/^\[/p" "$df" | grep -A1 '^effort = ' | tail -1 | grep -q '^auto-compact = off  *# '
  done
  [ "$(grep -c '^auto-compact = ' "$df")" -eq 6 ] # once per role pattern, never per instance
  # its comment proposes no compaction: a clear, from the role's saved state (#456)
  [ "$(grep -c '^auto-compact = off  *# at its context limit a turn stops: /clear, from saved state$' "$df")" -eq 6 ]
  run ! grep -qF '/compact' "$df"
  run ! grep -q '^auto-compact' <(sed -n '/^\[agent\]$/,/^\[/p' "$df") # not in the unsuffixed [agent]: a plain session keeps its own
  run_review
  [[ "$output" == *"[agent:gate] auto-compact = off: the roles gate run with auto-compact off"* ]]
  [[ "$output" != *"not a value"* ]]
  # a file with the comment from before #456: kept as it is, nothing offered for it
  sed -i 's|# at its context limit a turn stops: /clear, from saved state$|# at its context limit a turn stops: /compact or /clear|' "$df"
  [ "$(grep -c '/compact or /clear$' "$df")" -eq 6 ]
  cp "$df" "$H/before"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  [[ "$output" != *"auto-compact"* ]]
  # a file from before #438: the lines, per role, as --apply lines; the file unchanged
  sed -i '/^auto-compact = /d' "$df"
  cp "$df" "$H/before"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  for h in planner-\* implementer-\* reviewer-\* supervisor gate setup; do
    grep -qxF "    agent-sandbox --apply '[agent:$h]' 'auto-compact = off'" <<<"$output"
  done
}

@test "the roles model: each role's [briefing:...] section names its context file, .asb/coord/{role}/context, and its [agent:...] section the two levels after auto-compact (#456); a file from before gets them per role as --apply lines" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" h
  for h in '[briefing:planner-*]' '[briefing:implementer-*]' '[briefing:reviewer-*]'; do
    sed -n "/^$(printf '%s' "$h" | sed 's/[][*.]/\\&/g')/,/^\[/p" "$df" | grep -q '^context = \.asb/coord/{role}/context  *# '
  done
  sed -n '/^\[briefing:supervisor\]/,/^\[/p' "$df" | grep -q '^context = \.asb/coord/supervisor/context  *# '
  sed -n '/^\[briefing:gate\]/,/^\[/p' "$df" | grep -q '^context = \.asb/coord/gate/context  *# '
  [ "$(grep -c '^context = ' "$df")" -eq 5 ] # once per role pattern; not the setup role's, which has no coord directory
  for h in '[agent:planner-*]' '[agent:implementer-*]' '[agent:reviewer-*]' '[agent:supervisor]' '[agent:gate]'; do
    sed -n "/^$(printf '%s' "$h" | sed 's/[][*.]/\\&/g')/,/^\[/p" "$df" | grep -A2 '^auto-compact = ' >"$H/lv"
    sed -n 2p "$H/lv" | grep -q '^context-plan = 85%  *# '
    sed -n 3p "$H/lv" | grep -q '^context-rescue = 25000  *# '
  done
  [ "$(grep -c '^context-plan = ' "$df")" -eq 5 ]
  [ "$(grep -c '^context-rescue = ' "$df")" -eq 5 ]
  run_review
  [[ "$output" == *"[briefing:planner-*] context, for the roles planner-*: their agent's profile keeps .asb/coord/{role}/context"* ]]
  [[ "$output" != *"not a value"* ]]
  # a file written at the earlier default (60%): an existing line is the user's, kept,
  # and no --apply line offers the new one
  sed -i 's/^context-plan = 85% /context-plan = 60% /' "$df"
  [ "$(grep -c '^context-plan = 60% ' "$df")" -eq 5 ]
  cp "$df" "$H/before"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  [[ "$output" != *"context-plan"* ]]
  # a file from before #456: the lines, per role, as --apply lines; the file unchanged
  sed -i '/^context = /d; /^context-plan = /d; /^context-rescue = /d' "$df"
  cp "$df" "$H/before"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  for h in planner-\* implementer-\* reviewer-\*; do
    grep -qxF "    agent-sandbox --apply '[briefing:$h]' 'context = .asb/coord/{role}/context'" <<<"$output"
  done
  grep -qxF "    agent-sandbox --apply '[briefing:supervisor]' 'context = .asb/coord/supervisor/context'" <<<"$output"
  grep -qxF "    agent-sandbox --apply '[briefing:gate]' 'context = .asb/coord/gate/context'" <<<"$output"
  for h in planner-\* implementer-\* reviewer-\* supervisor gate; do
    grep -qxF "    agent-sandbox --apply '[agent:$h]' 'context-plan = 85%' 'context-rescue = 25000'" <<<"$output"
  done
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: every role's [briefing:...] section but the Supervisor's names its asking file; the Supervisor watches them, says each since once, in local time, and looks at the file first for a stale alive (#485); a file from before gets the lines as --apply lines" {
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox" h sup="$PROJ/.asb/roles/supervisor.md" w flat
  for h in '[briefing:planner-*]' '[briefing:implementer-*]' '[briefing:reviewer-*]'; do
    sed -n "/^$(printf '%s' "$h" | sed 's/[][*.]/\\&/g')/,/^\[/p" "$df" >"$H/sec"
    grep -qxF 'asking = .asb/coord/{role}/asking # there once it asks the user in its pane: S reads it' "$H/sec"
  done
  sed -n '/^\[briefing:gate\]/,/^\[/p' "$df" >"$H/sec"
  grep -qxF 'asking = .asb/coord/gate/asking # there once it asks the user in its pane: S reads it' "$H/sec"
  sed -n '/^\[briefing:supervisor\]/,/^\[/p' "$df" >"$H/sec"
  grep -q '^context = ' "$H/sec" # the range is the section
  run ! grep -q '^asking' "$H/sec"
  [ "$(grep -c '^asking = ' "$df")" -eq 4 ]
  run_review
  [[ "$output" == *"[briefing:planner-*] asking, for the roles planner-*: their agent's profile keeps .asb/coord/{role}/asking there from when the role asks the user something in its pane to its next hook event after the answer, where it can write. It widens nothing"* ]]
  [[ "$output" == *"[briefing:gate] asking, for the roles gate: their agent's profile keeps .asb/coord/gate/asking there"* ]]
  [[ "$output" != *"unknown [briefing] key"* ]]
  # the Supervisor's stream: every role's asking file but its own, last
  grep -qxF "  \`asking\` file but yours (a file not written yet is fine). \`-i '^ack [0-9]+\$'\` drops" "$sup"
  run ! grep -qF '.asb/coord/supervisor/asking' "$sup"
  # an asking event: read it; there, the chat line once per since, in local time; gone, no chat
  w="$(sed -n '/^- Watch every role'"'"'s messages with one stream/,/^- Read the index/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$w" == *'- An `asking` file changed: read it.'* ]]
  [[ "$w" == *'There: its role asked the user something in its pane -- a permission dialog, a question -- at its `since=`, and no hook has run since: it waits for the answer, or runs a tool the user approved there.'* ]]
  [[ "$w" == *'Tell the user in the chat, once per `since`, `<role> asked you something in its pane at <time>; go there if you have not answered it.`,'* ]]
  run ! grep -qF 'it is asking you something' "$sup"
  [[ "$w" == *'the time in local time (`date -d <since> +%H:%M`, the date too when it is not today'"'"'s), and nothing more: no guess at what it asks, and no launch line.'* ]]
  [[ "$w" == *'It needs the user, so it is a chat line, not your summary line.'* ]]
  [[ "$w" == *'A `since` you have said, seen again at a re-arm or a re-read, is not said again.'* ]]
  [[ "$w" == *'Gone: the wait has ended -- answered, or the role'"'"'s session ended or started anew; your summary line may say so, and the chat says nothing.'* ]]
  run ! grep -qF 'moved on' "$sup"
  # a stale alive: the asking file first, then the four checks
  flat="$(sed -n '/^- Stale, or missing, is a reason to look/,/^- When you send/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$flat" == *'is a reason to look, never a verdict. Look at the role'"'"'s `asking` file first: there, the role asked the user at its `since` and no hook has run since -- it waits in its pane, or runs a tool the user approved there -- so give the `asking` line of **At start.**, once per `since`: not "busy in a turn", not "it is asking you", and no launch line (the user then finding the pane gone is the last case below). Then check, in this order:'* ]]
  # docs/roles.md: what the file says, the measured gap, and S's line
  local d
  d="$(sed -n '/^### The asking file$/,/^Add to the dot-file/p' "$(dirname "$ENGINE")/docs/roles.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$d" == *'It says the role asked you something at `since` and no hook has run since.'* ]]
  [[ "$d" == *'Claude Code runs no hook at the answer itself (2.1.321, measured): after an approval it stays until the approved command ends'* ]]
  [[ "$d" == *'A denial or a reply removes it at the next event.'* ]]
  [[ "$d" == *'once per `since`: "<role> asked you something in its pane at <time>; go there if you have not answered it.", in your local time, and nothing more.'* ]]
  [[ "$d" == *'When it goes, the wait has ended -- answered, or the role'"'"'s session ended or started anew: its summary line may say so.'* ]]
  [[ "$d" == *'a refused one goes on working, and removes the file; a question the role asked in that turn is then not flagged).'* ]]
  run ! grep -qF 'the role has moved on' "$(dirname "$ENGINE")/docs/roles.md"
  run ! grep -qiE 'exactly while the role waits|it is asking you something' "$(dirname "$ENGINE")/docs/roles.md"
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
  # a file from before #485: the lines, per role, as --apply lines; the file unchanged
  sed -i '/^asking = /d' "$df"
  cp "$df" "$H/before"
  init -- roles planner=2 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  for h in planner-\* implementer-\* reviewer-\*; do
    grep -qxF "    agent-sandbox --apply '[briefing:$h]' 'asking = .asb/coord/{role}/asking'" <<<"$output"
  done
  grep -qxF "    agent-sandbox --apply '[briefing:gate]' 'asking = .asb/coord/gate/asking'" <<<"$output"
  [[ "$output" != *"'[briefing:supervisor]' 'asking"* ]]
}

@test "--init keeps {role} for the launch in a glob section's context and asking lines only: another key's {role} there is substituted as before (#456, #485)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  sed -i 's|^start = \.asb/start/planner\.md |start = .asb/start/{role}.md |' "$H/models/roles/agent-sandbox"
  grep -q '^start = \.asb/start/{role}\.md ' "$H/models/roles/agent-sandbox"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  sed -n '/^\[briefing:planner-\*\]/,/^\[/p' "$PROJ/.agent-sandbox" >"$H/sec"
  grep -q '^start = \.asb/start/planner\.md ' "$H/sec"
  grep -q '^context = \.asb/coord/{role}/context ' "$H/sec"
  grep -q '^asking = \.asb/coord/{role}/asking ' "$H/sec"
}

@test "the roles model on a file written before the effort levels: --init adds the [agent:...] sections it lacks, and an existing [agent:ROLE] section without effort gets its --apply line" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  # a file from before: no [agent:...] section; the gate's agent named by the user
  sed -i '/^\[agent:/,/^auto-compact = /d; /^context-plan = /d; /^context-rescue = /d' "$df"
  run ! grep -q '^effort = ' "$df"
  printf '[agent:gate]\ncommand = claude --model x\n' >>"$df"
  cp "$df" "$H/before"
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [agent:planner-*] [agent:implementer-*] [agent:reviewer-*] [agent:supervisor] [agent:setup]"* ]]
  cmp <(head -n "$(wc -l <"$H/before")" "$df") "$H/before" # nothing before it changed
  [ "$(effort_of '[agent:supervisor]' "$df")" = medium ]
  grep -qxF "    agent-sandbox --apply '[agent:gate]' 'effort = low' 'auto-compact = off' 'context-plan = 85%' 'context-rescue = 25000'" <<<"$output"
}

@test "the roles model with a role's effort = - (no level, the agent's own): a second --init leaves the file byte-identical, the section being there, and offers no --apply line for it" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  sed -i '/^\[agent:gate\]$/,/^effort = /s/^effort = .*/effort = -/' "$df"
  [ "$(effort_of '[agent:gate]' "$df")" = "" ] # (effort_of reads letters: - is none of them)
  grep -A1 -x '\[agent:gate\]' "$df" | grep -qx 'effort = -'
  cp "$df" "$H/before"
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  cmp "$df" "$H/before"
  [[ "$output" != *"[agent:gate]"* ]]
  # and the review accepts it
  run_review
  [[ "$output" == *"[agent:gate] effort = -: the roles gate run at their agent's own effort level"* ]]
  [[ "$output" != *"not an effort level"* ]]
}

@test "the github model: every role's effort level high, gh-setup's with an environment of the project's own; the market model's high" {
  init -- github
  [ "$status" -eq 0 ]
  local df="$PROJ/.agent-sandbox"
  [ "$(effort_of '[agent:gh-review-*]' "$df")" = high ]
  [ "$(effort_of '[agent:gh-triage-*]' "$df")" = high ]
  [ "$(effort_of '[agent:gh-fix-*]' "$df")" = high ]
  [ "$(effort_of '[agent:gh-setup]' "$df")" = high ]
  [ "$(grep -c '^effort = ' "$df")" -eq 4 ]
  rm -rf "$PROJ/.asb" "$df"
  init -- market
  [ "$status" -eq 0 ]
  [ "$(effort_of '[agent:market-*]' "$df")" = high ]
  [ "$(grep -c '^effort = ' "$df")" -eq 1 ]
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
@test "the roles model: a move to another account (#482) -- the Supervisor moves a role only on the user's word, per role, through the handshake, by a rename; [agent] accounts restarts nobody; a move lasts the session; the watching roles' start texts say their account in their messages" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" m r flat
  m="$(dirname "$ENGINE")/models/roles"
  flat="$(sed -n '/^- Watch `.agent-sandbox` too/,/^\*\*The Gate/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$flat" == *'a change to `[agent] accounts` alone names none: the host reads it only at a move to another account (below), so it restarts nobody.'* ]]
  [[ "$flat" == *'**Moving a role to another account:** only on the user'"'"'s word, naming the role or roles and the account;'* ]]
  [[ "$flat" == *'never because you were moved, nor because a role reports a usage limit: tell the user, and ask.'* ]]
  [[ "$flat" == *'Roles the user did not name stay where they are.'* ]]
  [[ "$flat" == *'Each named role goes through the handshake above, one at a time: its `ready`, then the marker,'* ]]
  [[ "$flat" == *'`account=NAME` on one line (NAME the account, or `-` for the user'"'"'s own login), written in one step, by a rename, so that the host never reads it half written:'* ]]
  grep -qxF "    printf 'account=%s\n' NAME >.asb/coord/to/ROLE.restart.new \\" "$sup"
  grep -qxF '      && mv -T .asb/coord/to/ROLE.restart.new .asb/coord/to/ROLE.restart' "$sup"
  [[ "$flat" == *'Then as for any restart: gone means relaunched; a reason means refused: tell the user, then remove the marker.'* ]]
  [[ "$flat" == *'A reason naming `[agent] accounts` is the user'"'"'s to fix, with the `asb --apply` line it gives;'* ]]
  [[ "$flat" == *'"not logged in" or "expired", with the login line it gives.'* ]]
  [[ "$flat" == *'Check that the move took: the role'"'"'s line in its messages, `launched on the account '"'"'NAME'"'"'`, names it; a served role writes none, so ask it which account its briefing names.'* ]]
  [[ "$flat" == *'A move lasts for this `asb --roles` session; for a lasting one, the user puts the account on the line or in the file.'* ]]
  # among the restart's bullets, before "never your own", which stands for a move too
  [[ "$flat" == *'**Moving a role to another account:**'*'Never your own `.restart`'* ]]
  # the marker it writes is the one the engine takes (_as_roles_restart_kind)
  [ "$(grep -c 'account=' "$sup")" -ge 2 ]
  # the four watching roles' start texts: the line, as the briefing's "Your agent" says
  # (`You run as AGENT on the account 'NAME'`, or `on the user's own login`); none in S's
  for r in planner implementer reviewer gate; do
    flat="$(tr '\n' ' ' <"$m/start/$r.md" | tr -s ' ')"
    [[ "$flat" == *'Arm your watcher as your purpose file says, unless one is already running (a background shell of yours). Then append one line to your messages, as your briefing'"'"'s "Your agent" says: `launched on the account '"'"'NAME'"'"'`, or `launched on the user'"'"'s own login`. Then read your inbox from your cursor'* ]]
    [ "$(awk 'length > 88' "$m/start/$r.md" | wc -l)" -eq 0 ]
  done
  run ! grep -qF 'launched on the' "$m/start/supervisor.md"
  grep -qF "on the user's own login." "$(dirname "$ENGINE")/agent-sandbox"
  grep -qF "on the account '\$n'." "$(dirname "$ENGINE")/agent-sandbox"
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: a restart after an approved policy change -- every role but the Supervisor answers ready or wait; the Supervisor writes .restart on ready and waits for it, one at a time, never with a .reset, never its own; the waits agree with the engine's (#416)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" gate="$PROJ/.asb/roles/gate.md" r f q g w flat docs
  q='- A restart question from S (an approved change to your policy or purpose file, which
  only a relaunch applies): answer `ready` in your messages once no turn'"'"'s work is in
  flight and no background command but your watcher runs, after writing there what
  the relaunched session must pick up -- the step you are in, and what is pending;
  otherwise answer `wait:` with what you are finishing, and about how long. S restarts
  you as soon as it reads `ready`, so write N to your cursor first, then `ready` and
  `done N` in one append. The relaunch resumes this conversation and re-arms your
  watcher from its start text, so saving is your messages and your usual memory rule,
  nothing more.'
  # the whole bullet, once, in **Protocol.**
  for r in planner-1 implementer-1 reviewer-1; do
    f="$PROJ/.asb/roles/$r.md"
    [ "$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$f" | grep -A8 -xF -- "${q%%$'\n'*}")" = "$q" ]
    [ "$(grep -cF -- 'A restart question from S' "$f")" -eq 1 ]
  done
  # the Gate's, in **Executing a message.**; its SSH request names no restart of its own
  g='- A restart question from S (an approved change to your policy or purpose file, which
  only a relaunch applies): answer `ready` in your messages once no message is in hand
  and no background command but your watcher runs, after writing there what is
  pending; otherwise answer `wait:` with what you are finishing, and about how long.
  S restarts you as soon as it reads `ready`, so write N to your cursor first, then
  `ready` and `done N` in one append. The relaunch resumes this conversation and
  re-arms your watcher from its start text, so saving is your messages, nothing more.'
  [ "$(sed -n '/^\*\*Executing a message\.\*\*/,/^\*\*Closing line/p' "$gate" | grep -A6 -xF -- "${g%%$'\n'*}")" = "$g" ]
  grep -qxF -- '  approves it, S restarts this role, which applies it.' "$gate"
  run ! grep -qF -- '--shutdown' "$gate"
  # the Supervisor's, in the bullet that watches .agent-sandbox: the question, the marker
  # without asking again, its wait and its three outcomes, one at a time, never its own
  run ! grep -qF -- 'A restart question from S' "$sup"
  flat="$(sed -n '/^- Watch `.agent-sandbox` too/,/^\*\*The Gate/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$flat" == *'A running role keeps the policy and the purpose file it was launched with, through a `/clear` (a `.reset`) too: only a relaunch applies a change, the restart below.'* ]]
  [[ "$flat" == *'answer `ready` or `wait: <what, and about how long>`.'* ]]
  [[ "$flat" == *'On `ready`: write an empty `.asb/coord/to/<role>.restart` -- without asking again: the user approved the change, and the restart only applies it -- then wait with `.asb/bin/inbox-wait -t 60 .asb/coord/to/<role>.restart`.'* ]]
  [[ "$flat" == *'Gone: put it in your summary line. Not empty: the host'"'"'s reason, one line; tell the user, then remove the marker. Still there and empty: nobody takes restarts for this role'* ]]
  [[ "$flat" == *'so remove the marker -- left, the next `asb --roles` with the role takes it -- and give the user the relaunch:'* ]]
  [[ "$flat" == *'One `.restart` at a time: the next once the last has gone or been answered. Never a `.restart` and a `.reset` for one role at once: the restart'"'"'s marker is gone first, then a `.reset` when the role'"'"'s next Task needs one.'* ]]
  [[ "$flat" == *'On `wait`: tell the user that the role asked to wait, and why;'* ]]
  [[ "$flat" == *'Never your own `.restart`: it would end you in the turn that wrote it.'* ]]
  # the waits, from the engine: its wait for a live keeper and --shutdown's 15 s, which
  # the Supervisor's 60 s outlasts with the second between looks, and the docs say so
  w="$(sed -n 's/^  local w="\${AGENT_SANDBOX_RESTART_WAIT:-\([0-9][0-9]*\)}"$/\1/p' "$ENGINE")"
  [ "$w" = 30 ]
  grep -qxF '  for ((i = 0; i < 1500; i++)); do' "$ENGINE" # _as_keeper_shutdown: 1500 x 0.01 s
  ((60 > 15 + w + 1))
  [[ "$flat" == *"up to 15 s to end it, $w s to see it run and 1 s to look, inside the 60."* ]]
  docs="$(tr '\n' ' ' <"$(dirname "$ENGINE")/docs/roles.md" | tr -s ' ')"
  [[ "$docs" == *"it waits up to $w s for the role's keeper to be live, then removes the marker."* ]]
  [[ "$docs" == *"waits up to 60 s for it: more than the 15 s an end may take, the $w s of the relaunch and the second between looks;"* ]]
  for r in supervisor planner implementer reviewer gate; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
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
  [[ "$flat" == *'When the Reviewer accepts the Handoff -- a Review with no findings, the first one or the one that ends the revision loop -- append the acceptance to the Planner on your own, asking for its confirmation that the step is ready, and put it in your summary line.'* ]]
  [[ "$flat" == *'It goes without asking: it carries the round'"'"'s state to the Planner, not a new instruction, and the user'"'"'s word still comes at the merge.'* ]]
  # the CI bullet, in **Sending a message.**
  [ "$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | grep -cxF -- "- After the Gate's push, arm a Monitor on the CI run it reported and, in the same reply,")" -eq 1 ]
  [[ "$flat" == *'The Planner can begin on the merged `main`;'* ]]
  [[ "$flat" == *'The step is done when the run is green, not at the push.'* ]]
  [[ "$flat" == *'Green: append the notice to the Planner on your own -- the merged commit, the run'"'"'s URL, and that the step is done -- and put it in your summary line.'* ]]
  [[ "$flat" == *'Like the Reviewer'"'"'s acceptance (above), it goes without asking: it closes a step the user approved, the merge and the push.'* ]]
  [[ "$flat" == *'A red run is a finding on `main`: propose the message to the Implementer and wait for the user; the Reviewer reviews the revision, and the Planner rules only for a reason **The relay.** lists (below).'* ]]
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
@test "the roles model: the Supervisor watches the relay for convergence and hands a stuck loop to the Planner, who rules only for a reason; a Review settles facts before prose, and a revision changes no more than its findings name (#459)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" pl="$PROJ/.asb/roles/planner-1.md"
  local rev="$PROJ/.asb/roles/reviewer-1.md" imp="$PROJ/.asb/roles/implementer-1.md"
  local relay p r
  # the Supervisor, in **The relay.**: the loop also ends when it is not converging
  relay="$(sed -n '/^\*\*The relay\.\*\*/,/^\*\*Context\.\*\*/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$relay" == *'go without a question, on that word, round after round, until the Reviewer accepts, the Implementer objects, or the loop is not converging (below).'* ]]
  # the one-line report's two new items
  [[ "$relay" == *'what the Reviewer still holds open, counted by kind (e.g. "R1 holds 2 factual, 3 prose"),'* ]]
  [[ "$relay" == *'whether its findings are new or follow-ups to the last fix,'* ]]
  [[ "$relay" == *'and how much the change (its diff against `main`) and the Handoff grew since the last round (lines, or `git diff --stat` totals) -- and ask nothing.'* ]]
  # the signs, a guide and not a counter
  [[ "$relay" == *'- Watch every round for convergence. The signs that the loop is not converging, a guide and not a counter:'* ]]
  [[ "$relay" == *'- new factual findings in a third revision or later (prose findings do not count);'* ]]
  [[ "$relay" == *'- steady growth of the change itself, its diff against `main` -- not of the Handoff, which gains a section each revision by design;'* ]]
  [[ "$relay" == *'- factual findings drifting into finer and finer detail;'* ]]
  [[ "$relay" == *'- prose findings still arriving after more than two prose rounds.'* ]]
  # stops relaying, and the message to the Planner
  [[ "$relay" == *'On any of them, stop relaying.'* ]]
  [[ "$relay" == *'Propose a message to the Planner, asked about as any message to it is, saying why the loop looks stuck and pointing at what the Implementer and the Reviewer found: the Reviews, the Handoffs, your measurements.'* ]]
  [[ "$relay" == *"Relaying resumes only on the user's word, after the Planner's answer."* ]]
  # the Planner stays out otherwise: the reasons list
  [[ "$relay" == *'- The Planner stays out of the loop otherwise: findings that come with a clear fix go from the Reviewer to the Implementer under the relay, without it.'* ]]
  [[ "$relay" == *'Ask the Planner to rule only when there is a reason, and only on that point:'* ]]
  [[ "$relay" == *'- the loop is not converging (above);'* ]]
  [[ "$relay" == *"- a finding changes the Task's scope, such as a bug that predates the Task;"* ]]
  [[ "$relay" == *'- a finding conflicts with the plan or an earlier ruling;'* ]]
  [[ "$relay" == *'- the Implementer and the Reviewer disagree: an Objection goes to the user, as below, and with it propose a message asking the Planner to rule on the point in dispute;'* ]]
  [[ "$relay" == *'- a design choice is left open, or either of them asks for a ruling.'* ]]
  [[ "$relay" == *'an Objection (it goes to the user),'* ]]
  [[ "$relay" == *"This holds outside the relay too, a red run's finding included."* ]]
  [[ "$relay" == *"The Reviewer's acceptance and the notice of a green run still go to the Planner as above, and its confirmation that the step is ready still comes before a merge."* ]]
  # one rule, stated once: the red run refers to it
  [[ "$(tr '\n' ' ' <"$sup" | tr -s ' ')" == *'the Reviewer reviews the revision, and the Planner rules only for a reason **The relay.** lists (below).'* ]]
  run ! grep -qF 'the Planner rules only when the Implementer' "$sup"
  # the Planner, in **Protocol.**: asked only for those reasons, and a stuck loop
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$pl" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'rule on deviations and open questions as they come, and when the Reviewer accepts, say so.'* ]]
  [[ "$p" == *'- S brings you only those: findings that come with a clear fix go from the Reviewer to the Implementer without you.'* ]]
  [[ "$p" == *'You are asked to rule only on the point that needs it:'* ]]
  [[ "$p" == *'- the revision loop is not converging (below);'* ]]
  [[ "$p" == *"- a finding changes the Task's scope, such as a bug that predates the Task;"* ]]
  [[ "$p" == *'- a finding conflicts with the plan or an earlier ruling;'* ]]
  [[ "$p" == *'- the Implementer and the Reviewer disagree: an Objection, which the user decides; you rule on the point in dispute when the user sends it;'* ]]
  [[ "$p" == *'- a design choice is left open, or either of them asks for a ruling.'* ]]
  [[ "$p" == *'- A loop S hands you as not converging: find why -- most often the plan was too open, or the Implementer and the Reviewer found facts it did not have.'* ]]
  [[ "$p" == *'Revise the plan with what they learned, or narrow it, and make concrete what "done" means;'* ]]
  [[ "$p" == *'then either the loop resumes on the revised plan, or the Task is split.'* ]]
  [[ "$p" == *'Write the result in the Task file, as with any ruling.'* ]]
  # the Reviewer, in **Protocol.**: facts first, prose last, marked
  r="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$rev" | tr '\n' ' ' | tr -s ' ')"
  [[ "$r" == *'- Facts first, prose last. A Review first settles the facts: correctness, behaviour, tests, and claims that can be checked.'* ]]
  [[ "$r" == *'Prose -- wording, style and structure -- comes in the last revision, or a few at most, once the facts hold.'* ]]
  [[ "$r" == *'Mark each prose finding `(prose)`, and raise none while a factual finding is open.'* ]]
  run ! grep -qi 'severity' "$rev" # no severity is defined to put the mark beside
  [[ "$r" == *'A prose finding names what is wrong, not more to add, so its fix does not grow the text.'* ]]
  # the Implementer, in **Protocol.**: facts first, and no more than the findings name
  r="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$imp" | tr '\n' ' ' | tr -s ' ')"
  [[ "$r" == *'- In a revision, settle the factual findings first, and answer prose findings, marked `(prose)`, in the last revision, or a few at most.'* ]]
  [[ "$r" == *'Change what each finding names and no more:'* ]]
  [[ "$r" == *'a revision that grows the text beyond its findings is a sign S watches for, of a loop that is not converging.'* ]]
  for r in supervisor planner implementer reviewer; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
}

# shellcheck disable=SC2016 # backquotes are the doc's text, not ours
@test "docs/roles.md: the Supervisor watches the relay for convergence and hands a stuck loop to the Planner, who rules only for a reason; facts first, prose last (#459)" {
  local docs
  docs="$(tr '\n' ' ' <"$(dirname "$ENGINE")/docs/roles.md" | tr -s ' ')"
  # section 2's table and section 3, the roles
  [[ "$docs" == *'each with its evidence, facts first and prose last (section 5);'* ]]
  grep -qF '| **Handoff** | Implementer | Reviewer, you; the Planner, when asked to rule (section 5) |' "$(dirname "$ENGINE")/docs/roles.md"
  grep -qF '| **Review** | Reviewer | Implementer (through you, or relayed: section 5), you; the Planner, when asked to rule (section 5) |' "$(dirname "$ENGINE")/docs/roles.md"
  grep -qF '| **Objection** | Implementer | you; the Planner, when you send it (section 5) |' "$(dirname "$ENGINE")/docs/roles.md"
  [[ "$docs" == *'you decide it, and may first send it to the Planner for a ruling on the point in dispute |'* ]]
  [[ "$docs" == *'its earlier Measurements; an Objection, when you send it, and the Handoffs and Reviews of a point it is asked to rule on (section 5) |'* ]]
  grep -qxF '                    (the Planner rules on it when you send it)' "$(dirname "$ENGINE")/docs/roles.md"
  [[ "$docs" == *"Within a Task's revision loop, rule only on the point the Supervisor brings, for a reason section 5 lists;"* ]]
  [[ "$docs" == *'A revision settles the facts first, and changes what each finding names and no more (section 5).'* ]]
  [[ "$docs" == *'A Review settles the facts first; prose findings, marked as such, come last (section 5).'* ]]
  [[ "$docs" == *'watching the loop for convergence: a loop that is not converging it stops, and proposes handing it to the Planner.'* ]]
  # section 4, the round
  [[ "$docs" == *'The Planner stays out of the revision loop unless there is a reason for it to rule -- a loop that is not converging above all (section 5).'* ]]
  # section 5, the relay: the report, the signs, the stop
  [[ "$docs" == *'until the Reviewer accepts, the Implementer objects, or the loop is not converging (below).'* ]]
  [[ "$docs" == *'what the Reviewer still holds open, counted by kind ("R1 holds 2 factual, 3 prose"),'* ]]
  [[ "$docs" == *'whether its findings are new or follow-ups to the last fix, and how much the change (its diff against `main`) and the Handoff grew since the last round -- and asks nothing.'* ]]
  [[ "$docs" == *'So the Supervisor watches each round for the signs, a guide and not a counter: new factual findings in a third revision or later;'* ]]
  [[ "$docs" == *'steady growth of the change itself, its diff against `main` (not of the Handoff, which gains a section each revision by design);'* ]]
  [[ "$docs" == *'factual findings drifting into finer and finer detail; prose findings still arriving after more than two prose rounds.'* ]]
  [[ "$docs" == *'Prose arrives late and new by design (below), so new prose findings alone are no sign.'* ]]
  [[ "$docs" == *'On any of them it stops relaying and proposes a message to the Planner, asked about as any message to a Planner is,'* ]]
  [[ "$docs" == *'The Planner finds why, revises the plan with what they learned or narrows it, with what "done" means made concrete, and the loop resumes on the revised plan, or the Task is split.'* ]]
  [[ "$docs" == *"The relay resumes only on your word, after the Planner's answer."* ]]
  # the Planner, only for a reason
  [[ "$docs" == *'- **The Planner, only for a reason.** Findings that come with a clear fix go from the Reviewer to the Implementer without the Planner.'* ]]
  [[ "$docs" == *"The Supervisor asks the Planner to rule only on the point that needs it: the loop is not converging; a finding changes the Task's scope, such as a bug that predates the Task; a finding conflicts with the plan or an earlier ruling;"* ]]
  [[ "$docs" == *'the Implementer and the Reviewer disagree -- an Objection, which still comes to you to decide, and with it the Supervisor proposes asking the Planner to rule on the point in dispute;'* ]]
  [[ "$docs" == *'a design choice is left open, or either asks for a ruling.'* ]]
  [[ "$docs" == *"The same holds outside the relay, for a red run's finding too;"* ]]
  # facts first, prose last
  [[ "$docs" == *'- **Facts first, prose last.** A Review first settles the facts: correctness, behaviour, tests, and claims that can be checked.'* ]]
  [[ "$docs" == *'Prose -- wording, style and structure -- comes in the last revision, or a few at most, once the facts hold:'* ]]
  [[ "$docs" == *'the Reviewer marks each prose finding `(prose)`, raises none while a factual finding is open, and names what is wrong rather than more to add.'* ]]
  [[ "$docs" != *'severity'* ]]
  # section 9's walk-through: the relay's three ends
  [[ "$docs" == *'until R1 accepts, I1 objects, or the loop is not converging (section 5).'* ]]
  [[ "$docs" != *'until R1 accepts or I1 objects'* ]]
  [[ "$docs" == *'The Implementer settles the factual findings first and changes what each finding names and no more;'* ]]
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: throwaway work goes in .asb/scratch/<task>/, out of every tree, and is cleared once the Task has landed; the Supervisor reminds the Implementer and the Reviewer in the next Task's message" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local imp="$PROJ/.asb/roles/implementer-1.md" rev="$PROJ/.asb/roles/reviewer-1.md"
  local pl="$PROJ/.asb/roles/planner-1.md" sup="$PROJ/.asb/roles/supervisor.md" p r
  # the Implementer, in **Protocol.**: where, never in its tree, worktrees, the clearing
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$imp" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- Throwaway work goes in `.asb/scratch/<task>/`, never inside your tree or a directory the roles share: worktrees, copies of a tree, mutants, measurement and coverage outputs.'* ]]
  [[ "$p" == *'A git worktree can live there too, named by an absolute path, since git runs in your tree: from the project directory, `git -C .asb/impl/1 worktree add "$PWD/.asb/scratch/<task>/wt" BRANCH`.'* ]]
  [[ "$p" == *'Once the Task has landed, delete its directory and run `git -C .asb/impl/1 worktree prune`; keep only what an open Task still needs, and say in your messages what you kept and why.'* ]]
  [ "$(grep -cF -- '.asb/scratch/<task>/' "$imp")" -eq 3 ] # and the branch-in-clone bullet's (#456)
  # git runs in the clone: a relative worktree path would land inside it (T34, F1)
  run ! grep -qE 'worktree add \.?\.?/?\.asb/' "$imp"
  run ! grep -qF '`git worktree' "$imp"
  # the Reviewer, in **Protocol.**: no history, so no worktrees; its deliverables stay put
  r="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$rev" | tr '\n' ' ' | tr -s ' ')"
  [[ "$r" == *'- Throwaway work goes in `.asb/scratch/<task>/`, never in a directory the roles share: copies of a tree, mutants, measurement and coverage outputs.'* ]]
  [[ "$r" == *'What another role must run is a deliverable, not scratch, and stays in your Review directory.'* ]]
  [[ "$r" == *'Once the Task has landed, delete its scratch directory; keep only what an open Task still needs, and say in your messages what you kept and why.'* ]]
  run ! grep -qF 'worktree' "$rev"
  # the Planner, in **Protocol.**: cited measurements in its directory, the rest scratch
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$pl" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- A measurement a Task cites goes in your directory; throwaway runs go in `.asb/scratch/<task>/`, deleted once the Task has landed.'* ]]
  # the Supervisor, in **Sending a message.**: a line of the next Task's message, at green
  p="$(sed -n '/^\*\*Sending a message\.\*\*/,/^\*\*The Gate/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *"- Once a step's run is green, the message that opens the next Task for its Implementer and for its Reviewer carries one line more: clear the landed Task's scratch (\`.asb/scratch/<task>/\`, its worktrees pruned), keeping only what an open Task still needs."* ]]
  [[ "$p" == *'It is a line of that message, not a message of its own.'* ]]
  for r in supervisor planner implementer reviewer; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
}

# shellcheck disable=SC2016 # backquotes are the doc's text, not ours
@test "docs/roles.md: a role's throwaway work goes in .asb/scratch/<task>/ and is cleared once the Task lands; why: the trust review's link scan walks the clones, not the scratch (#401)" {
  local f docs
  f="$(dirname "$ENGINE")/docs/roles.md"
  docs="$(tr '\n' ' ' <"$f" | tr -s ' ')"
  [[ "$docs" == *'- **Scratch is cleared once its Task lands.** A role'"'"'s throwaway work (worktrees, copies of a tree, mutants, measurement and coverage outputs) goes in `.asb/scratch/<task>/`, never in a clone or a directory the roles share, and is deleted once the Task has landed;'* ]]
  [[ "$docs" == *'the Supervisor reminds the Implementer and the Reviewer in the message that opens their next Task.'* ]]
  [[ "$docs" == *'Why: `asb --trust` and `--apply` scan every directory a role binds from the host for symbolic links (#401), so leftovers in a clone cost every approval:'* ]]
  [[ "$docs" == *'`.asb/scratch/` is each role'"'"'s own store, which the scan does not enter, so clearing it frees the disk; it does not speed the review.'* ]]
  [ "$(sed -n '/^- \*\*Scratch is cleared once its Task lands\.\*\*/,/^- \*\*Builds\.\*\*/p' "$f" | awk 'length > 88' | wc -l)" -eq 0 ]
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
  [[ "$flat" == *'On yes, at green: write the `.reset` marker if the user said fresh, append the message once the marker is gone, put it in your summary line, and ask no second question.'* ]]
  [[ "$flat" == *'Red: the finding goes to the Implementer in its context, the Reviewer keeps its context for the revision'"'"'s review, a yes given ahead lapses, and the waiting Task opens after the fix is merged and its run is green, asked about again then.'* ]]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
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

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: the Supervisor watches every role's context level and acts on plan, rescue and stopped; a clear needs the user's word; never /compact; its own context goes to reminders.md, read first at a fresh start (#456)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local sup="$PROJ/.asb/roles/supervisor.md" ctx at
  # **Context.**, its own section, after **The relay.**
  [ "$(grep -c '^\*\*Context\.\*\* ' "$sup")" -eq 1 ]
  [ "$(grep -B1 '^\*\*Context\.\*\* ' "$sup" | head -1)" = '' ]
  [ "$(grep -n '^\*\*The relay\.\*\* ' "$sup" | cut -d: -f1)" -lt "$(grep -n '^\*\*Context\.\*\* ' "$sup" | cut -d: -f1)" ]
  ctx="$(sed -n '/^\*\*Context\.\*\*/,/^\*\*What you never/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$ctx" == *'**Context.** Each role'"'"'s `.asb/coord/<role>/context` says how full its context is, one line (`level=… tokens=… left=… turn=… maxturn=…`), and `context.level` beside it the level alone, rewritten only when it changes: `ok`; `plan`, at `context-plan` of the stop (85 % by default); `rescue`, at `context-rescue` tokens or fewer left before the stop (25000 by default); `stopped`, at the stop.'* ]]
  [[ "$ctx" == *'When a `.level` file wakes you, read it with the role'"'"'s `context` line, and act:'* ]]
  [[ "$ctx" == *'- `plan`, another role'"'"'s: at its next Task boundary, bring the user the choice -- keep the context, save what matters then clear, or clear outright -- with the Planner'"'"'s view when the Task is long.'* ]]
  [[ "$ctx" == *'It joins the fresh-or-keep question before that Task.'* ]]
  [[ "$ctx" == *'- `rescue`, another role'"'"'s: its own Stop hook tells it, once, to save its working state.'* ]]
  [[ "$ctx" == *'The `.level` change comes before the save; the role writes `.asb/coord/<role>/state.md`, then a line in its messages, `state.md saved at rescue, N tokens left`, which wakes you after it.'* ]]
  [[ "$ctx" == *'On that wake, put the save in your summary line, and append to your messages the tuning line: the role, the `left` before (its N), and the `context` line'"'"'s `left` and `turn=` as you read them then -- `turn=` is the whole turn'"'"'s growth, the save included, counted from the turn'"'"'s prompt, so it bounds the save'"'"'s cost from above; the save'"'"'s own cost is the `left` before less the `left` after, once the `context` line has moved past the save, and until then write `after: pending` and fill it in from the next `context` line you read.'* ]]
  [[ "$ctx" == *'Then:'* ]]
  [[ "$ctx" == *'- on a single Task, let the role go on in the room left;'* ]]
  [[ "$ctx" == *'- when its next step will not fit, ask the Planner to split the rest into smaller Tasks;'* ]]
  [[ "$ctx" == *'- when its context also carries earlier Tasks (it was kept at the Task'"'"'s start), propose, once it stops, clearing it and restarting the current Task from `state.md`.'* ]]
  [[ "$ctx" == *'- `stopped`: name the context limit as the cause, and propose the reset from the role'"'"'s `state.md`: its `.reset`, then a message that restarts the Task from it.'* ]]
  [[ "$ctx" == *'With no `state.md`, propose `--summarize`, and say it is the last resort.'* ]]
  [[ "$ctx" == *'- A clear always needs the user'"'"'s word, the relay notwithstanding: the message that restarts a Task from `state.md` is asked about as any that opens a Task.'* ]]
  [[ "$ctx" == *'When waiting would block the work, the user may hand you the decision: then act, and tell them.'* ]]
  [[ "$ctx" == *'- Never `/compact`, and never propose it: compaction is no remedy here.'* ]]
  [[ "$ctx" == *'- Your own, `.asb/coord/supervisor/context`: at `plan`, at a quiet moment -- no step of a round in flight, nothing awaiting the user'"'"'s word -- and at once at `rescue` (your Stop hook says so too), bring `.asb/scratch/reminders.md` up to date: the round'"'"'s state, the open Tasks and their steps, the user'"'"'s standing words, and what you wait on.'* ]]
  [[ "$ctx" == *'Then suggest a `/clear` of your session; the user types it.'* ]]
  # /compact only where it is refused
  [ "$(grep -c '/compact' "$sup")" -eq 1 ]
  # **At start.**: reminders.md first, its first bullet; and the start text says it too
  [ "$(sed -n '/^\*\*At start\.\*\*$/{n;p;}' "$sup")" = '- At a fresh start, read `.asb/scratch/reminders.md` first, where it exists: what you' ]
  at="$(sed -n '/^\*\*At start\.\*\*/,/^\*\*Where things/p' "$sup" | tr '\n' ' ' | tr -s ' ')"
  [[ "$at" == *'- At a fresh start, read `.asb/scratch/reminders.md` first, where it exists: what you saved before your last `/clear` (**Context.**, below).'* ]]
  [[ "$(tr '\n' ' ' <"$PROJ/.asb/start/supervisor.md" | tr -s ' ')" == *'Do what your purpose file says at start -- at a fresh start, read `.asb/scratch/reminders.md` first where it exists; print the launch lines, arm your watcher (a stream, as your purpose file says; arming again is safe) -- then read every role'"'"'s messages'* ]]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/supervisor.md" | wc -l)" -eq 0 ]
  [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/start/supervisor.md" | wc -l)" -eq 0 ]
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: asked to save its working state -- by its Stop hook or by S -- a role writes .asb/coord/<role>/state.md, an Implementer after a commit; at a fresh start it reads it first (#456)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local p r
  # planner-1, in **Protocol.**
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$PROJ/.asb/roles/planner-1.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- When you are asked to save your working state -- by your Stop hook at the rescue level, or by S -- write `.asb/coord/planner-1/state.md`, the whole file each time: the Task (its inbox N) and its base, the step you are in, what is done and where (commits, files), what is pending and the next action, and the decisions not yet in any artefact.'* ]]
  [[ "$p" == *'Then append one line to your messages: `state.md saved at rescue, N tokens left`, N from the hook'"'"'s reason, or `state.md saved` when S asked.'* ]]
  [[ "$p" == *'Then go on if the step fits in the room left, or stop at a clean point and say in your messages what is left.'* ]]
  [[ "$p" == *'- At a fresh start, if `state.md` names the Task your latest inbox message opens or continues, read it first.'* ]]
  [ "$(grep -c '^- When you are asked to save your working state' "$PROJ/.asb/roles/planner-1.md")" -eq 1 ]
  # implementer-1, in **Protocol.**
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$PROJ/.asb/roles/implementer-1.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- When you are asked to save your working state -- by your Stop hook at the rescue level, or by S -- commit your work in progress, then write `.asb/coord/implementer-1/state.md`, the whole file each time: the Task (its inbox N) and its base, the step you are in, what is done and where (the commit, files), what is pending and the next action, and the decisions not yet in any artefact.'* ]]
  [[ "$p" == *'Then append one line to your messages: `state.md saved at rescue, N tokens left`, N from the hook'"'"'s reason, or `state.md saved` when S asked.'* ]]
  [[ "$p" == *'Then go on if the step fits in the room left, or stop at a clean point and say in your messages what is left.'* ]]
  [[ "$p" == *'- At a fresh start, if `state.md` names the Task your latest inbox message opens or continues, read it first.'* ]]
  [ "$(grep -c '^- When you are asked to save your working state' "$PROJ/.asb/roles/implementer-1.md")" -eq 1 ]
  # reviewer-1, in **Protocol.**
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$PROJ/.asb/roles/reviewer-1.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- When you are asked to save your working state -- by your Stop hook at the rescue level, or by S -- write `.asb/coord/reviewer-1/state.md`, the whole file each time: the Task (its inbox N) and its base, the step you are in, what is done and where (commits, files), what is pending and the next action, and the decisions not yet in any artefact.'* ]]
  [[ "$p" == *'Then append one line to your messages: `state.md saved at rescue, N tokens left`, N from the hook'"'"'s reason, or `state.md saved` when S asked.'* ]]
  [[ "$p" == *'Then go on if the step fits in the room left, or stop at a clean point and say in your messages what is left.'* ]]
  [[ "$p" == *'- At a fresh start, if `state.md` names the Task your latest inbox message opens or continues, read it first.'* ]]
  [ "$(grep -c '^- When you are asked to save your working state' "$PROJ/.asb/roles/reviewer-1.md")" -eq 1 ]
  # gate, in **Executing a message.**
  p="$(sed -n '/^\*\*Executing a message\.\*\*/,/^\*\*Closing line/p' "$PROJ/.asb/roles/gate.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- When you are asked to save your working state -- by your Stop hook at the rescue level, or by S -- write `.asb/coord/gate/state.md`, the whole file each time: the message you are handling (its inbox N), the step you are in, what is done and where, what is pending and the next action, and the decisions not yet in any artefact.'* ]]
  [[ "$p" == *'Then append one line to your messages: `state.md saved at rescue, N tokens left`, N from the hook'"'"'s reason, or `state.md saved` when S asked.'* ]]
  [[ "$p" == *'Then go on if the step fits in the room left, or stop at a clean point and say in your messages what is left.'* ]]
  [[ "$p" == *'- At a fresh start, if `state.md` names the message your latest inbox message is or continues, read it first.'* ]]
  [ "$(grep -c '^- When you are asked to save your working state' "$PROJ/.asb/roles/gate.md")" -eq 1 ]
  # the Gate writes it too: where it writes says so
  p="$(tr '\n' ' ' <"$PROJ/.asb/roles/gate.md" | tr -s ' ')"
  [[ "$p" == *'the only place you write, beside your scratch, `.asb/scratch/`, and your saved state, `.asb/coord/gate/state.md`.'* ]]
  [[ "$p" == *'write anywhere but your messages, your state.md and your scratch.'* ]]
  for r in planner implementer reviewer gate; do
    [ "$(awk 'length > 88' "$(dirname "$ENGINE")/models/roles/roles/$r.md" | wc -l)" -eq 0 ]
  done
}

# shellcheck disable=SC2016 # backquotes are the purpose file's text, not ours
@test "the roles model: the branch under review is checked out in the Implementer's clone, the tree the Reviewer reads, and the Handoff carries the commit message; a Reviewer that finds the clone's tree is not main plus the Handoff's diff says so and stops (#456)" {
  init -- roles planner=1 implementer=1 reviewer=1
  [ "$status" -eq 0 ]
  local p r
  # the Implementer, in **Protocol.**, right after the scratch bullet
  p="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$PROJ/.asb/roles/implementer-1.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$p" == *'- The branch under review is checked out in your clone, `.asb/impl/1/` -- the tree the Reviewer reads -- before you write the Handoff, and stays checked out while the review runs; a branch is checked out in one tree at a time, so first remove or detach a worktree that holds it.'* ]]
  [[ "$p" == *'Only throwaway worktrees go to `.asb/scratch/<task>/`.'* ]]
  [[ "$p" == *'The Handoff names the branch and its commit and carries its commit message, verbatim: the Reviewer sees no history.'* ]]
  [ "$(grep -A1 -F 'needs, and say in your messages what you kept and why.' "$PROJ/.asb/roles/implementer-1.md" | sed -n 2p)" = '- The branch under review is checked out in your clone, `.asb/impl/1/` -- the tree the' ]
  # the Reviewer, in **Protocol.**
  r="$(sed -n '/^\*\*Protocol\.\*\*/,/^\*\*What you never/p' "$PROJ/.asb/roles/reviewer-1.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$r" == *'- The Implementer'"'"'s clone, `.asb/impl/N/`, holds the Handoff'"'"'s branch while you review: its tree is `main` plus the Handoff'"'"'s diff (its history is hidden from you; compare the trees).'* ]]
  [[ "$r" == *'If it is not, say so in your messages and stop: do not review `main` plus the diff instead.'* ]]
}

# shellcheck disable=SC2016 # backquotes are the doc's text, not ours
@test "docs/roles.md: what the context levels set off -- the Supervisor's acts, state.md and who saves, the user's word on a clear, no compaction, the Supervisor's own context; the branch under review in the clone (#456)" {
  local f docs
  f="$(dirname "$ENGINE")/docs/roles.md"
  docs="$(tr '\n' ' ' <"$f" | tr -s ' ')"
  [[ "$docs" == *'### What the levels set off The Supervisor watches every role'"'"'s `context.level`, its own included, beside the messages, and reads each change with the role'"'"'s `context` line (#456):'* ]]
  [[ "$docs" == *'- **`plan`, at a Task boundary.** Before the role'"'"'s next Task, the Supervisor brings you three choices, with the Planner'"'"'s view when the Task is long: keep the context, save what matters and then clear, or clear outright.'* ]]
  [[ "$docs" == *'At 85 % of the stop this comes late, when it matters; where every Implementer and Reviewer Task opens fresh anyway, it matters most for long Tasks and for the single roles, the Planner, the Gate and the Supervisor.'* ]]
  [[ "$docs" == *'- **`rescue`, at once.** The role saves its working state for the Task in `.asb/coord/<role>/state.md`, rewritten at each save: the Task (its inbox N) and its base, the step it is in, what is done and where, what is pending and the next action, and the decisions not yet in any artefact.'* ]]
  [[ "$docs" == *'An Implementer commits its work in progress first and names the commit.'* ]]
  [[ "$docs" == *'Its own `Stop` hook tells it to, once, at the turn that crosses into `rescue` ([profiles.md](profiles.md)), so the save comes in that same turn, at a terminal and in a served role alike, and ends it with one line in its messages, `state.md saved at rescue, N tokens left` (`state.md saved` when the Supervisor asked), which wakes the Supervisor after the save.'* ]]
  [[ "$docs" == *'It puts the save in its summary line, and notes in its messages the `left` before and after and the turn'"'"'s `turn=`, the figures a later retune of `context-rescue` needs: `turn=` is the whole turn'"'"'s growth, an upper bound on the save'"'"'s cost; the save'"'"'s own is the `left` before less the `left` after.'* ]]
  [[ "$docs" == *'On a single Task the role goes on in the room left; when its next step will not fit, the Planner splits the rest into smaller Tasks; when its context also carries earlier Tasks, the Supervisor proposes, once it stops, clearing it and restarting the Task from `state.md`.'* ]]
  [[ "$docs" == *'A role starting fresh reads `state.md` first when it names the Task its latest inbox message opens or continues.'* ]]
  [[ "$docs" == *'- **`stopped`.** The Supervisor names the context limit as the cause and proposes the reset from `state.md`; with none, `--summarize`, as the last resort.'* ]]
  [[ "$docs" == *'- **A clear always needs your word.** When waiting would block the work, you may hand the decision to the Supervisor; it then acts and tells you.'* ]]
  [[ "$docs" == *'- **No compaction.** `/compact` is never the remedy; a role'"'"'s context is saved by the role, in its own words, then cleared.'* ]]
  [[ "$docs" == *'- **The Supervisor'"'"'s own context.** At `plan`, at a quiet moment (no step of a round in flight, nothing awaiting your word), and at once at `rescue`, it brings `.asb/scratch/reminders.md` up to date -- the round'"'"'s state, the open Tasks and their steps, your standing words, what it waits on -- and suggests a `/clear` of its session, which you type.'* ]]
  [[ "$docs" == *'At a fresh start it reads `reminders.md` first.'* ]]
  [[ "$docs" == *'Add to the dot-file what a round turns out to need, when it does; `asb --trust` then reviews the change.'* ]]
  [[ "$docs" == *'- **The branch under review is in the clone.** The Implementer checks it out in `.asb/impl/N/`, the tree the Reviewer reads, before the Handoff, and keeps it there while the review runs; only throwaway worktrees go to `.asb/scratch/<task>/`.'* ]]
  [[ "$docs" == *'The Handoff carries the commit message, verbatim, since the Reviewer sees no history.'* ]]
  [[ "$docs" == *'A Reviewer that finds the clone'"'"'s tree is not `main` plus the Handoff'"'"'s diff says so and stops, rather than review `main` plus the diff.'* ]]
  [[ "$docs" == *'context fills stops at its next request ("Context limit reached"); the Supervisor then proposes a reset from the role'"'"'s saved state, never `/compact` (the context levels, below).'* ]]
  run ! grep -qF 'you type `/compact`' "$f"
  [ "$(sed -n '/^### What the levels set off$/,/^## 9\. /p' "$f" | awk 'length > 88' | wc -l)" -eq 0 ]
  [ "$(sed -n '/^- \*\*The branch under review is in the clone\.\*\*/,/^- \*\*Builds\.\*\*/p' "$f" | awk 'length > 88' | wc -l)" -eq 0 ]
}
