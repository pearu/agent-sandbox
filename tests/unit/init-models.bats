#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: the github and market models, and two models composed in one file (#267).
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

@test "every model: a command a [permissions] rule names is written in its purpose files as one call -- no \$(…), separator, pipe or redirect -- and each ruled role is told one command per call" {
  # A Bash(PREFIX:*) rule approves PREFIX run on its own: in a compound line each part is
  # matched, and a $(…) in the arguments defeats the rule (Claude Code 2.1.311), so the
  # command prompts or goes to auto mode's classifier (docs/design.md, Residual risks).
  # Not seen: a verb named in prose only. A double-quoted operator is flagged: a safe false positive.
  local models model f c p s r part hit seen=0 bad=""
  models="$(dirname "$ENGINE")/models"
  local -a prefixes sections parts
  for model in "$models"/*; do
    [ -d "$model" ] || continue
    # the rules and the section suffixes of every [permissions] section, #@own/#@shared too
    mapfile -t prefixes < <(sed -E 's/^#@[a-z]+ //' "$model/agent-sandbox" \
      | awk '/^\[/ { p = /^\[permissions(:[^]]*)?\]/; next }
           p && /^Bash\(.*:\*\)/ { sub(/^Bash\(/, ""); sub(/:\*\).*$/, ""); print }' | sort -u)
    mapfile -t sections < <(sed -E 's/^#@[a-z]+ //' "$model/agent-sandbox" \
      | sed -n 's/^\[permissions:\([^]]*\)\].*/\1/p')
    for f in "$model"/roles/*.md "$model"/start/*.md "$model"/serve/*.md; do
      [ -f "$f" ] || continue
      # its commands: each line of a fenced block (a trailing \ joins the next), and each
      # inline code span of the prose joined into one line, so a span may wrap
      while IFS= read -r c; do
        [[ "$c" != BACKTICKS-UNPAIRED ]] || bad+="$f: an odd number of backticks in its prose"$'\n'
        # a single-quoted word and a <placeholder> hold no operator
        s="$(sed -E "s/'[^']*'//g; s/<[A-Za-z][A-Za-z0-9_-]*>//g" <<<"$c")"
        # where a command can start: the span's start, and after each operator
        mapfile -t parts < <(sed -E 's/[;&|()]/\n/g' <<<"$s" | sed -E 's/^[ ]+//')
        for p in "${prefixes[@]}"; do
          hit=""
          for part in "${parts[@]}"; do
            if [[ "$part" == "$p" || "$part" == "$p "* ]]; then hit=1; fi
          done
          [ -n "$hit" ] || continue
          seen=$((seen + 1))
          # shellcheck disable=SC2016 # the $( is the text looked for, not a substitution
          case "$s" in *'$('* | *';'* | *'&'* | *'|'* | *'>'* | *'<'*) bad+="$f: $c"$'\n' ;; esac
        done
      done < <(awk '
        { sub(/^#@[a-z]+ /, "") }
        /^[ \t]*```/ { fence = !fence; next }
        fence {
          line = $0
          if (sub(/\\$/, "", line)) { cont = cont line " "; next }
          out[++n] = cont line; cont = ""; next
        }
        { text = text " " $0 }
        END {
          k = split(text, part, "`")
          if (k % 2 == 0) print "BACKTICKS-UNPAIRED"
          for (i = 2; i <= k; i += 2) out[++n] = part[i]
          for (i = 1; i <= n; i++) {
            gsub(/[ \t]+/, " ", out[i]); sub(/^ /, "", out[i]); sub(/ $/, "", out[i])
            print out[i]
          }
        }' "$f")
    done
    # every role a suffixed section gives rules is told to run them one call each
    for r in "${sections[@]}"; do
      f="$model/roles/${r%-\*}.md"
      grep -qF '**One command per call.** Run each command your `[permissions:' "$f" \
        || bad+="$f: no **One command per call.** for [permissions:$r]"$'\n'
    done
  done
  printf '%s' "$bad" >&2
  [ -z "$bad" ]
  # the scan saw them: the Gate's push and its gh verbs, the Supervisor's fetch, the
  # github roles' posts, the watcher of every roles-model role
  [ "$seen" -ge 20 ]
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
  [[ "$output" == *"--init: this .agent-sandbox has model 'roles''s common sections unsuffixed, written by an earlier --init"*"remove its unsuffixed [connect] block at line 1 and [net] block at line 3 (or start from a fresh file) and run --init again"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.asb" ]
  # any model's --init: github's on an old roles file, whose [net] would reach gh-*
  init -- github
  [ "$status" -ne 0 ]
  [[ "$output" == *"has model 'roles''s common sections unsuffixed"*"remove its unsuffixed [connect] block at line 1 and [net] block at line 3 ("* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  # an unsuffixed section of your own, with nothing of the model's, is yours: kept
  printf '[net]\nmode = strict\n' >"$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
}

@test "unsuffixed sections of the user's own beside the roles model's role sections are the user's: --init goes on and leaves them" {
  sandbox_base
  init AGENT_SANDBOX_CONDA_BASE=sandbox CONDA_LOG="$H/mm.log" -- roles --env dev
  [ "$status" -eq 0 ]
  printf '\n[conda]\nbase = sandbox\n\n[conda]\nname = x\n' >>"$PROJ/.agent-sandbox"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init AGENT_SANDBOX_CONDA_BASE=sandbox CONDA_LOG="$H/mm.log" -- roles --env dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing added to it"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
}

@test "the old --init's unsuffixed block is told by its lines and named by the line of its header, commented out or not; a section of the user's beside it is not named" {
  local df="$PROJ/.agent-sandbox"
  printf '[connect:planner-*]\n.asb/plan/ = read-write\n[conda]\nprefix   =   /x/env   # the env\n[connect]\n.asb/coord/ = read-only\n# [net]\n# mode = strict\n' >"$df"
  cp "$df" "$H/before"
  init -- roles
  [ "$status" -ne 0 ]
  [[ "$output" == *"remove its unsuffixed [conda] block at line 3, [connect] block at line 5 and [net] block at line 7 (or start from a fresh file)"* ]]
  cmp "$H/before" "$df"
  # the user's [conda] beside an old [connect]: only the [connect] is named
  printf '[connect:planner-*]\n.asb/plan/ = read-write\n[conda]\nbase = sandbox\n[connect]\nproject = read-only\n' >"$df"
  cp "$df" "$H/before"
  init -- roles
  [ "$status" -ne 0 ]
  [[ "$output" == *"remove its unsuffixed [connect] block at line 5 (or start from a fresh file)"* ]]
  cmp "$H/before" "$df"
}
