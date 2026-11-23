#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: --env completing a file written without one; a project that tracks .env,
# --env-dir (#389).
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
  # a count given sets the role to 1..N, as a first --init does: the gap filled, its old
  # clone (nothing in it) out of the way (#389)
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=4 --env x-dev
  [ "$status" -eq 0 ]
  has_section '[connect:implementer-2]' "$df"
  has_section '[connect:implementer-4]' "$df"
  [[ "$output" == *"implementer-2 is added again: the clone it had before it was removed is moved to .asb/backup/implementer-2-"* ]]
  # and a count of 0 removes every one
  init MAMBA_ROOT_PREFIX="$H/conda" -- roles implementer=0 --env x-dev
  [ "$status" -eq 0 ]
  run ! grep -q 'implementer-[0-9]*\]' "$df"
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
  # without --env the re-run takes the file's environment (#427), so it clones it as a
  # re-run with --env does: at the name the clone's lines have
  init MAMBA_ROOT_PREFIX="$H/conda" CONDA_EXE="$H/bin/conda-stub" CONDA_LOG="$H/conda.log" -- roles implementer=2
  [ "$status" -eq 0 ]
  grep -qx 'prefix = \.asb/impl/1/\.env' "$df"
  grep -qx 'prefix = \.asb/impl/2/venv' "$df"
  [ -d "$PROJ/.asb/impl/2/venv/conda-meta" ]
  rm -rf "$PROJ/.asb/impl/2/venv"
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

@test "--env-dir for a model with no clone environments: refused, exit 2, nothing written (#389)" {
  init -- github --env-dir foo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: --env-dir: model 'github' has no clone environments to name"* ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
  [ ! -e "$PROJ/.asb" ]
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

@test "a project that tracks .env as a symbolic link, with no environment asked for: no refusal, every instance and path written, a re-run too (#389)" {
  printf 'SECRET=1\n' >"$PROJ/.env.dev"
  ln -s .env.dev "$PROJ/.env"
  git -C "$PROJ" add .env .env.dev
  git -C "$PROJ" commit -q -m env
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [ -L "$PROJ/.asb/impl/1/.env" ] # the clones have the project's link
  [ -L "$PROJ/.asb/impl/2/.env" ]
  [ -f "$PROJ/.asb/.gitignore" ]
  [ -f "$PROJ/.asb/coord/COORDINATION.md" ]
  [ -f "$PROJ/.asb/coord/to/implementer-2.md" ]
  [ -x "$PROJ/.asb/bin/inbox-wait" ]
  [ -d "$PROJ/.asb/handoff/implementer-2" ]
  init -- roles implementer=2
  [ "$status" -eq 0 ]
}

@test "a link of your own at a clone's environment path, with no environment asked for: no refusal, the link left (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  ln -s .env.example "$PROJ/.asb/impl/1/.env"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [ "$(readlink "$PROJ/.asb/impl/1/.env")" = .env.example ]
  [ -d "$PROJ/.asb/impl/2" ]
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
