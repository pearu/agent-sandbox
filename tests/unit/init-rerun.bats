#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: a re-run of --init -- counts, gaps, removals, headers, purpose files kept
# or migrated, an older model's lines (#389, #355).
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

# init_other ARGS -- `asb --init ARGS` in a second project named as $PROJ is ($H/other/proj),
# for a first --init to compare a re-run's result with.
init_other() {
  local keep="$PROJ"
  mkdir -p "$H/other/proj"
  PROJ="$(cd "$H/other/proj" && pwd -P)"
  if [[ ! -d "$PROJ/.git" ]]; then
    git -C "$PROJ" init -q
    git -C "$PROJ" -c user.name=tester -c user.email=tester@example.org commit -q --allow-empty -m init
  fi
  init -- "$@"
  PROJ="$keep"
}

# drop_instance N -- implementer-N's sections out of .agent-sandbox, by hand (a gap)
drop_instance() {
  awk -v n="$1" '/^(# )?\[/ { on = ($0 ~ "^(# )?\\[[a-z]+:implementer-" n "\\]") } !on' \
    "$PROJ/.agent-sandbox" >"$H/df.tmp"
  cat "$H/df.tmp" >"$PROJ/.agent-sandbox"
}

@test "counts on a first --init: none given is one instance, 0 is none, N is instances 1..N (#389)" {
  init -- roles planner=0 implementer=3
  [ "$status" -eq 0 ]
  run ! grep -q 'planner-[0-9]*\]' "$PROJ/.agent-sandbox"
  for n in 1 2 3; do has_section "[connect:implementer-$n]" "$PROJ/.agent-sandbox"; done
  run ! grep -qF '[connect:implementer-4]' "$PROJ/.agent-sandbox"
  has_section '[connect:reviewer-1]' "$PROJ/.agent-sandbox"
  run ! grep -qF '[connect:reviewer-2]' "$PROJ/.agent-sandbox"
}

@test "a re-run gives a numbered role with no count nothing and takes nothing: none, a gap, more than one -- the file byte for byte (#389)" {
  init -- roles planner=3 implementer=3 reviewer=0
  [ "$status" -eq 0 ]
  drop_instance 2
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles
  [ "$status" -eq 0 ]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [[ "$output" != *"removed"* ]]
  [ -f "$PROJ/.asb/roles/implementer-2.md" ] # its purpose file, not touched
  [ ! -e "$PROJ/.asb/roles/reviewer-1.md" ]
  [ -f "$PROJ/.asb/roles/planner-3.md" ]
}

@test "a re-run with ROLE=N fills the gaps below N: implementer=4 over 1 and 3 adds 2 and 4 (#389)" {
  init -- roles implementer=3
  [ "$status" -eq 0 ]
  drop_instance 2
  rm -rf "$PROJ/.asb/impl/2" "$PROJ/.asb/git/2" "$PROJ/.asb/roles/implementer-2.md"
  init -- roles implementer=4
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:implementer-2] [serve:implementer-2] [connect:implementer-4] [serve:implementer-4]"* ]]
  for n in 1 2 3 4; do
    [ "$(grep -cxF "[connect:implementer-$n]" "$PROJ/.agent-sandbox")" -eq 1 ]
    [ -f "$PROJ/.asb/roles/implementer-$n.md" ]
    [ "$(git -C "$PROJ/.asb/impl/$n" branch --show-current)" = "impl-$n" ]
    [ "$(grep -c "^| I$n |" "$PROJ/.asb/coord/COORDINATION.md")" -eq 1 ]
  done
}

@test "a re-run with ROLE=N removes the instances above N: sections, purpose files, prompts, records, index rows; clones and data left -- as a first --init with N writes it (#389)" {
  init -- roles implementer=3
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2] [conda:implementer-2] [serve:implementer-2] [connect:implementer-3] [conda:implementer-3] [serve:implementer-3]"* ]]
  [[ "$output" == *"removed .asb/roles/implementer-2.md"* ]]
  [[ "$output" == *"removed .asb/serve/implementer-3.md"* ]]
  [[ "$output" == *"removed from .asb/coord/COORDINATION.md: I2 I3"* ]]
  [[ "$output" == *"--init: removed implementer-2, implementer-3; left as they are"*".asb/impl/2/ .asb/git/2/"*".asb/coord/to/implementer-3.md"* ]]
  [[ "$output" == *"--trust"* ]]
  run ! grep -q 'implementer-[23]' "$PROJ/.agent-sandbox"
  for n in 2 3; do
    [ ! -e "$PROJ/.asb/roles/implementer-$n.md" ]
    [ ! -e "$PROJ/.asb/serve/implementer-$n.md" ]
    run ! grep -q "implementer-$n" "$PROJ/.asb/init.sums"
    run ! grep -q "^| I$n |" "$PROJ/.asb/coord/COORDINATION.md"
    # left: the clone, its history, the inbox and the data directories
    [ "$(git -C "$PROJ/.asb/impl/$n" branch --show-current)" = "impl-$n" ]
    [ -d "$PROJ/.asb/git/$n" ]
    [ -f "$PROJ/.asb/coord/to/implementer-$n.md" ]
    [ -d "$PROJ/.asb/coord/implementer-$n" ]
    [ -d "$PROJ/.asb/handoff/implementer-$n" ]
  done
  # equal to a first --init with implementer=1
  init_other roles implementer=1
  [ "$status" -eq 0 ]
  cmp "$H/other/proj/.agent-sandbox" "$PROJ/.agent-sandbox"
  diff -r "$H/other/proj/.asb/roles" "$PROJ/.asb/roles"
  diff -r "$H/other/proj/.asb/serve" "$PROJ/.asb/serve"
  cmp "$H/other/proj/.asb/coord/COORDINATION.md" "$PROJ/.asb/coord/COORDINATION.md"
  [ "$(cut -d' ' -f3 "$H/other/proj/.asb/init.sums" | sort)" = "$(cut -d' ' -f3 "$PROJ/.asb/init.sums" | sort)" ]
}

@test "a re-run with reviewer=0 removes every reviewer and the role's glob sections and start file: the file a first --init with reviewer=0 writes (#389)" {
  init -- roles reviewer=2
  [ "$status" -eq 0 ]
  init -- roles reviewer=0
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [sandbox:reviewer-*] [conda:reviewer-*] [connect:reviewer-*] [net:reviewer-*] [permissions:reviewer-*] [connect:reviewer-1] [serve:reviewer-1] [connect:reviewer-2] [serve:reviewer-2] [briefing:reviewer-*]"* ]]
  [[ "$output" == *"removed .asb/start/reviewer.md"* ]]
  run ! grep -q 'reviewer' "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.asb/start/reviewer.md" ]
  run ! grep -q 'reviewer' "$PROJ/.asb/init.sums"
  [ -d "$PROJ/.asb/review/reviewer-2" ] # its data, left
  init_other roles reviewer=0
  [ "$status" -eq 0 ]
  cmp "$H/other/proj/.agent-sandbox" "$PROJ/.agent-sandbox"
  diff -r "$H/other/proj/.asb/roles" "$PROJ/.asb/roles"
  diff -r "$H/other/proj/.asb/start" "$PROJ/.asb/start"
  cmp "$H/other/proj/.asb/coord/COORDINATION.md" "$PROJ/.asb/coord/COORDINATION.md"
  # and a re-run with no count leaves it at none
  init -- roles
  [ "$status" -eq 0 ]
  cmp "$H/other/proj/.agent-sandbox" "$PROJ/.agent-sandbox"
}

@test "a removed instance's section goes whatever you edited in it; its purpose file you changed is kept, and said (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  sed -i 's|^\.asb/handoff/implementer-2/ = read-write$|.asb/handoff/implementer-2/ = read-only   # mine|' "$PROJ/.agent-sandbox"
  sed -i '/^\[serve:implementer-2\]/a extra = line' "$PROJ/.agent-sandbox"
  printf 'MINE\n' >>"$PROJ/.asb/roles/implementer-2.md"
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2] [conda:implementer-2] [serve:implementer-2]"* ]]
  [[ "$output" == *"kept .asb/roles/implementer-2.md: changed since --init wrote it, and implementer-2 is removed"* ]]
  [[ "$output" == *"removed .asb/serve/implementer-2.md"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-2.md")" = MINE ]
  run ! grep -qE 'implementer-2|extra = line|# mine' "$PROJ/.agent-sandbox"
}

@test "a removal never follows a link: one at a file to be removed, or at .asb/backup, refuses with exit 2 and nothing changed (#389)" {
  init -- roles implementer=3
  [ "$status" -eq 0 ]
  printf 'SECRET\n' >"$H/outside"
  rm "$PROJ/.asb/roles/implementer-3.md"
  ln -s "$H/outside" "$PROJ/.asb/roles/implementer-3.md"
  cp "$PROJ/.agent-sandbox" "$H/before"
  cp "$PROJ/.asb/init.sums" "$H/sums"
  init -- roles implementer=1
  [ "$status" -eq 2 ]
  [[ "$output" == *".asb/roles/implementer-3.md is a symbolic link"*"nothing was written"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  cmp "$H/sums" "$PROJ/.asb/init.sums"
  [ -L "$PROJ/.asb/roles/implementer-3.md" ]
  [ "$(cat "$H/outside")" = SECRET ]
  [ -f "$PROJ/.asb/roles/implementer-2.md" ]
  # .asb/backup a link, where a clone in the way of an instance added again would go
  rm "$PROJ/.asb/roles/implementer-3.md"
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  mkdir "$H/elsewhere"
  ln -s "$H/elsewhere" "$PROJ/.asb/backup"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *".asb/backup is a symbolic link"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ -z "$(ls -A "$H/elsewhere")" ]
  [ -d "$PROJ/.asb/git/2" ]
}

@test "a spaced section header of yours is the section: a re-run reports no line of it missing (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  sed -i 's/^\[connect:implementer-2\]$/  [ connect:implementer-2 ]/' "$PROJ/.agent-sandbox"
  grep -qx '  \[ connect:implementer-2 \]' "$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  [[ "$output" != *"that your .agent-sandbox lacks"* ]]
  [[ "$output" == *"nothing added to it"* ]]
}

@test "a count is decimal: 08, 09, 010 and 00 on a re-run set the role to 8, 9, 10 and none; a single role's 01 is 1 (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=08
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great"* ]]
  [ "$(grep -c '^\[connect:implementer-[0-9]*\]$' "$PROJ/.agent-sandbox")" -eq 8 ]
  has_section '[connect:implementer-8]' "$PROJ/.agent-sandbox"
  init -- roles implementer=010
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[connect:implementer-[0-9]*\]$' "$PROJ/.agent-sandbox")" -eq 10 ]
  init -- roles implementer=09
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[connect:implementer-[0-9]*\]$' "$PROJ/.agent-sandbox")" -eq 9 ]
  run ! grep -qF '[connect:implementer-10]' "$PROJ/.agent-sandbox"
  init -- roles implementer=00
  [ "$status" -eq 0 ]
  run ! grep -q 'implementer-[0-9]*\]' "$PROJ/.agent-sandbox"
  init -- roles supervisor=02
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 or 1 for supervisor"* ]]
  init -- roles supervisor=01
  [ "$status" -eq 0 ]
}

@test "a header is read as a launch reads it: a section of yours, indented, ends a removed one and is kept; a spaced instance header is removed and named (#389)" {
  init -- roles implementer=3
  [ "$status" -eq 0 ]
  sed -i 's/^\[connect:implementer-3\]$/[ connect:implementer-3 ]/' "$PROJ/.agent-sandbox"
  sed -i '/^\[ connect:implementer-3 \]$/i # my hosts\n  [allow]\n  example.org' "$PROJ/.agent-sandbox"
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2] [conda:implementer-2] [serve:implementer-2] [connect:implementer-3] [conda:implementer-3] [serve:implementer-3]"* ]]
  grep -qx '# my hosts' "$PROJ/.agent-sandbox"
  grep -qx '  \[allow\]' "$PROJ/.agent-sandbox"
  grep -qx '  example.org' "$PROJ/.agent-sandbox"
  run ! grep -q 'implementer-[23]' "$PROJ/.agent-sandbox"
}

@test "an instance is known by its header alone: a comment added to or removed from it changes nothing on a re-run, and a count still removes it (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  sed -i 's/^\[connect:implementer-2\]$/[connect:implementer-2]   # mine/; s/^\(\[serve:implementer-2\]\) .*/\1/
    s/^\(# \[conda:implementer-2\]\) .*/\1/' "$PROJ/.agent-sandbox"
  grep -qx '\[serve:implementer-2\]' "$PROJ/.agent-sandbox"
  grep -qx '# \[conda:implementer-2\]' "$PROJ/.agent-sandbox"
  printf 'work\n' >"$PROJ/.asb/impl/2/notes"
  cp "$PROJ/.agent-sandbox" "$H/before"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" != *"clone implementer-2 had"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ "$(cat "$PROJ/.asb/impl/2/notes")" = work ] # the live clone, where it was
  [ ! -e "$PROJ/.asb/backup" ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2] [conda:implementer-2] [serve:implementer-2]"* ]]
  run ! grep -q 'implementer-2' "$PROJ/.agent-sandbox"
}

@test "a section named as a removed instance's but outside the model's marked region is yours, and stays (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  {
    printf '[connect:implementer-2]\n.asb/mine/ = read-only\n'
    cat "$PROJ/.agent-sandbox"
  } >"$H/df"
  cat "$H/df" >"$PROJ/.agent-sandbox"
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2] [conda:implementer-2] [serve:implementer-2]"* ]]
  [ "$(head -2 "$PROJ/.agent-sandbox")" = $'[connect:implementer-2]\n.asb/mine/ = read-only' ]
  [ "$(grep -c '^\[connect:implementer-2\]' "$PROJ/.agent-sandbox")" -eq 1 ]
  run ! grep -qF '[serve:implementer-2]' "$PROJ/.agent-sandbox"
}

@test "run again: a purpose file --init wrote and nobody changed takes the model's text; a changed one is kept" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
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
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
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
