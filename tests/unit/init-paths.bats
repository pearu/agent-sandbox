#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: symbolic links and paths --init refuses to write through; the checked read
# (#389).
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

@test "--init and --apply rewrite an existing .agent-sandbox in place, its inode and mode kept (#389)" {
  mkdir -p "$H/base/envs"
  local df="$PROJ/.agent-sandbox" ino
  init -- github
  [ "$status" -eq 0 ]
  chmod 640 "$df"
  ino="$(stat -c %i "$df")"
  init MAMBA_ROOT_PREFIX="$H/base" -- github --env dev
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$df")" = "$ino" ] # in place: a running sandbox's read-only bind of it holds
  [ "$(stat -c %a "$df")" = 640 ]
  ino="$(stat -c %i "$df")"
  engine_cmd
  run bash -c 'cd "$1" && printf "n\n" | env -i HOME="$2" PATH="$3" "${@:4}" --profile claude --apply "[allow]" example.org 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$(stat -c %i "$df")" = "$ino" ]
  [ "$(stat -c %a "$df")" = 640 ]
  grep -qx 'example.org' "$df"
  ls -A "$PROJ" >"$H/ls"
  run ! grep -q '^\.agent-sandbox\.' "$H/ls" # no temporary file left
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

@test "--init makes the declared paths it checked: a .agent-sandbox swapped in while it runs has its '..' key made nowhere (#389)" {
  local df="$PROJ/.agent-sandbox"
  init -- roles
  [ "$status" -eq 0 ]
  # git, as --init clones implementer-2, appends a '..' key to the file
  cat >"$H/bin/git" <<STUB
#!/usr/bin/env bash
/usr/bin/git "\$@" || exit
[[ "\$*" == *" clone "* ]] && printf '.asb/../../escape-dir/ = read-only\\n' >>"$df"
exit 0
STUB
  chmod +x "$H/bin/git"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned for implementer-2"* ]]
  grep -qF '.asb/../../escape-dir/' "$df" # the swap happened
  [ ! -e "$H/escape-dir" ]
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
