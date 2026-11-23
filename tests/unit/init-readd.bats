#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: an instance added again -- its old clone backed up, whatever it is (#389).
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

@test "an instance added again: its old clone, untouched or not, is moved to a backup, both halves, and said; a fresh clone made (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  printf 'old\n' >"$PROJ/.asb/git/2/marker"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"--init: implementer-2 is added again: the clone it had before it was removed is moved to $b/ -- tree/ its working tree, git/ its history; tree/.git points at git/. It may hold implementer-2's work, and what becomes of it is yours (its git config and hooks were writable by the role: read them before you run git there); implementer-2 gets a fresh clone"* ]]
  [[ "$output" == *"cloned for implementer-2"* ]]
  [ "$(cat "$PROJ/$b/tree/.git")" = "gitdir: $PROJ/$b/git" ]
  [ "$(cat "$PROJ/$b/git/marker")" = old ]
  [ ! -e "$PROJ/.asb/git/2/marker" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
}

@test "an instance added again over a hostile old clone: a FIFO for HEAD, config a link to /dev/zero, hooks -- moved without a hang, nothing of it read or run (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  local g="$PROJ/.asb/git/2"
  printf '#!/bin/sh\ntouch %s/ran\n' "$H" >"$H/evil"
  chmod +x "$H/evil"
  for h in pre-commit post-checkout reference-transaction fsmonitor-watchman; do cp "$H/evil" "$g/hooks/$h"; done
  rm "$g/HEAD" "$g/config"
  mkfifo "$g/HEAD"
  ln -s /dev/zero "$g/config"
  printf '* filter=x\n' >"$PROJ/.asb/impl/2/.gitattributes"
  engine_cmd
  # shellcheck disable=SC2016 # the script's own arguments, expanded inside it
  run timeout 60 bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --init roles implementer=2 2>&1 </dev/null' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ] # 124: it hung
  [ ! -e "$H/ran" ]
  [[ "$output" == *"moved to $b/ -- tree/ its working tree, git/ its history; tree/.git points at git/."* ]]
  [ -p "$PROJ/$b/git/HEAD" ]
  [ "$(readlink "$PROJ/$b/git/config")" = /dev/zero ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
}

@test "an instance added again: a backup there already is never overwritten (#389)" {
  fixed_date
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  printf 'notes\n' >"$PROJ/.asb/impl/2/untracked"
  mkdir -p "$PROJ/.asb/backup/implementer-2-20260101T000000Z"
  printf 'earlier\n' >"$PROJ/.asb/backup/implementer-2-20260101T000000Z/keep"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to .asb/backup/implementer-2-20260101T000000Z-2/"* ]]
  [ "$(cat "$PROJ/.asb/backup/implementer-2-20260101T000000Z/keep")" = earlier ]
  [ ! -e "$PROJ/.asb/backup/implementer-2-20260101T000000Z/tree" ]
  [ "$(cat "$PROJ/.asb/backup/implementer-2-20260101T000000Z-2/tree/untracked")" = notes ]
  [ ! -e "$PROJ/.asb/impl/2/untracked" ]
}

@test "an instance added again over half a clone: a tree whose history is gone, or a history whose tree is gone, each backed up alone, no failure (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.asb/impl/2"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $b/ -- git/ its history (its working tree was gone). It may hold"* ]]
  [ -d "$PROJ/$b/git" ]
  [ ! -e "$PROJ/$b/tree" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
  init -- roles implementer=2 # and the next run has nothing in its way
  [ "$status" -eq 0 ]
  # the history gone, the tree left: the tree's .git never points at the fresh clone's
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.asb/git/2"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $b-2/ -- tree/ its working tree (its history was gone); tree/.git rewritten not to point at .asb/git/2, the fresh clone's history. It may hold"* ]]
  [ "$(cat "$PROJ/$b-2/tree/.git")" = "gitdir: $PROJ/$b-2/git" ]
  [ ! -e "$PROJ/$b-2/git" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
  [ -z "$(find "$PROJ/.asb/backup" -mindepth 1 -maxdepth 1 -empty)" ] # no empty backup
}

@test "an instance added again over a link at its tree: the link is moved as it is, what it points to outside untouched (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  mkdir "$H/outside"
  printf 'mine\n' >"$H/outside/keep"
  rm -rf "$PROJ/.asb/impl/2"
  ln -s "$H/outside" "$PROJ/.asb/impl/2"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $b/ -- tree, where its working tree was, a symbolic link (moved as it is; what it points to is untouched), git/ its history. It may hold"* ]]
  [[ "$output" != *"tree/.git points at"* ]]
  [ -L "$PROJ/$b/tree" ]
  [ "$(readlink "$PROJ/$b/tree")" = "$H/outside" ]
  [ "$(ls -A "$H/outside")" = keep ]
  [ "$(cat "$H/outside/keep")" = mine ]
  [ -d "$PROJ/$b/git" ]
  [ ! -L "$PROJ/.asb/impl/2" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
}

@test "an instance added again over a link at its history: moved as it is, its target untouched; the tree's .git pointed away from the fresh history (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  mkdir "$H/outside"
  printf 'mine\n' >"$H/outside/keep"
  rm -rf "$PROJ/.asb/git/2"
  ln -s "$H/outside" "$PROJ/.asb/git/2"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $b/ -- tree/ its working tree, git, where its history was, a symbolic link (moved as it is; what it points to is untouched); tree/.git rewritten not to point at .asb/git/2, the fresh clone's history. It may hold"* ]]
  [ -L "$PROJ/$b/git" ]
  [ "$(readlink "$PROJ/$b/git")" = "$H/outside" ]
  [ "$(ls -A "$H/outside")" = keep ]
  [ "$(cat "$PROJ/$b/tree/.git")" = "gitdir: $PROJ/$b/git" ]
  [ -d "$PROJ/.asb/git/2" ]
  [ ! -L "$PROJ/.asb/git/2" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
}

@test "an instance added again over a tree whose .git is a directory, or a tree that is a FIFO: backed up as they are, said (#389)" {
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  rm "$PROJ/.asb/impl/2/.git"
  mkdir "$PROJ/.asb/impl/2/.git"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved to $b/ -- tree/ its working tree, git/ its history; tree/.git is a directory, not a file --init wrote, and is left as it is. It may hold"* ]]
  [ -d "$PROJ/$b/tree/.git" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
  # a FIFO where the tree was
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.asb/impl/2"
  mkfifo "$PROJ/.asb/impl/2"
  engine_cmd
  # shellcheck disable=SC2016 # the script's own arguments, expanded inside it
  run timeout 60 bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --init roles implementer=2 2>&1 </dev/null' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ] # 124: it hung
  [[ "$output" == *"moved to $b-2/ -- tree, where its working tree was, a FIFO, git/ its history. It may hold"* ]]
  [ -p "$PROJ/$b-2/tree" ]
  [ "$(git -C "$PROJ/.asb/impl/2" branch --show-current)" = impl-2 ]
}

@test "an old clone that cannot be moved: nothing written, the run fails, and the next one tries again (a tree; a history, the tree put back) (#389)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the permissions this takes away"
  fixed_date
  local b=.asb/backup/implementer-2-20260101T000000Z
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  printf 'old\n' >"$PROJ/.asb/impl/2/old.txt"
  cp "$PROJ/.agent-sandbox" "$H/before"
  chmod a-w "$PROJ/.asb/impl/2"
  init -- roles implementer=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"moving implementer-2's old clone .asb/impl/2 to $b/tree failed; nothing was written (.agent-sandbox unchanged)"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.asb/roles/implementer-2.md" ]
  [ -z "$(find "$PROJ/.asb/backup" -mindepth 1)" ]
  chmod u+w "$PROJ/.asb/impl/2"
  init -- roles implementer=2 # the same state: it tries again
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/$b/tree/old.txt")" = old ]
  # the history unmovable: the tree, moved first, is put back
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  printf 'old2\n' >"$PROJ/.asb/impl/2/old.txt"
  cp "$PROJ/.agent-sandbox" "$H/before"
  chmod a-w "$PROJ/.asb/git/2"
  init -- roles implementer=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"moving implementer-2's old history .asb/git/2 to $b-2/git failed; nothing was written (.agent-sandbox unchanged)"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
  [ "$(cat "$PROJ/.asb/impl/2/old.txt")" = old2 ]
  [ ! -e "$PROJ/$b-2" ]
  chmod u+w "$PROJ/.asb/git/2"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/$b-2/tree/old.txt")" = old2 ]
  [ -d "$PROJ/$b-2/git" ]
}
