#!/usr/bin/env bats
# asb --init MODEL [ROLE=N ...] [--env NAME] (#225): a project's .agent-sandbox, .asb/,
# purpose files, coord index and clones, written from a development model. Real git;
# conda is a stub that records what it was asked and makes the prefix.
# This file: a running sandbox of the project and a re-run -- binds, refusals, in-place
# writes (#389).
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

# ---- a running sandbox of the project and a re-run (#389) ----

# running ROLE [PROFILE] < RECORD -- a faked running sandbox of the project: its keeper's
# id names a live process of this test's (a sleep, ended in teardown) as its supervisor
# and its payload, as _as_keeper_live checks them, and RECORD is its keeper/binds, as
# `DIR<TAB>MODE<TAB>SELF<TAB>PATH` lines (written NUL-separated, as _as_keeper_binds does). With RUNNING_OLD=1 a keeper an
# older asb started: no binds, RECORD is its keeper/policy, and the project's
# .agent-sandbox as it is now its dotfile.copy. Sets RUN_PID, and RUN_SB, its directory
# (keeper/policy there: its declarations, for a test to write). RUN_PROJ: the sandbox's
# project, when it is not this one.
running() {
  local p="${RUN_PROJ:-$PROJ}" sb st
  sb="$H/home/.local/state/agent-sandbox/${2:-claude}/$(source_engine && _as_path_slug "$p")/$1"
  mkdir -p "$sb/keeper"
  printf '%s\n' "$p" >"$sb/project" # as a keeper's start writes it
  sleep 600 >/dev/null 2>&1 3>&- &
  RUN_PID=$!
  RUN_SB="$sb"
  printf '%s\n' "$RUN_PID" >>"$H/sleeps"
  st="$(awk '{ print $22 }' "/proc/$RUN_PID/stat")"
  printf '%s %s %s %s %s %s\n' "$RUN_PID" "$st" "$RUN_PID" "$st" "$RUN_PID" "$st" >"$sb/keeper/id"
  if [[ -n "${RUNNING_OLD:-}" ]]; then
    cat >"$sb/keeper/policy"
    cp "$PROJ/.agent-sandbox" "$sb/keeper/dotfile.copy"
  else
    tr '\t\n' '\0\0' >"$sb/keeper/binds"
  fi
}

# stopped -- the last faked sandbox's process ends, as after --shutdown
stopped() {
  kill "$RUN_PID"
  wait "$RUN_PID" 2>/dev/null || true
}

@test "a re-run that changes .agent-sandbox writes it in place: the same inode and mode, so a running sandbox's read-only bind of it holds (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.agent-sandbox" ]
  chmod 640 "$PROJ/.agent-sandbox"
  local ino
  ino="$(stat -c %i "$PROJ/.agent-sandbox")"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:implementer-2]"* ]]
  [ "$(stat -c %i "$PROJ/.agent-sandbox")" = "$ino" ]
  [ "$(stat -c %a "$PROJ/.agent-sandbox")" = 640 ]
  init -- roles implementer=1 # the removal is a rewrite too
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed from .agent-sandbox: [connect:implementer-2]"* ]]
  [ "$(stat -c %i "$PROJ/.agent-sandbox")" = "$ino" ]
  run ! grep -qF '[connect:implementer-2]' "$PROJ/.agent-sandbox"
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agent-sandbox.?*')" ] # no temp beside it
}

# binds_of FILE -- a keeper/binds record as `DIR<TAB>PATH` lines
binds_of() {
  local dir mode self path
  while IFS= read -r -d '' dir && IFS= read -r -d '' mode && IFS= read -r -d '' self && IFS= read -r -d '' path; do
    printf '%s\t%s\t%s\t%s\n' "$dir" "$mode" "$self" "$path"
  done <"$1"
}

@test "a launch records the single-file mounts that sit on a host file: in a read-write project for one role, a read-only one for another (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  (cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  local st="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}"
  engine_bg AGENT_SANDBOX_NET=none -- asb --role supervisor claude
  binds_of "$st/supervisor/keeper/binds" >"$H/b.sup"
  grep -qxF "rw"$'\t'"ro"$'\t'"y"$'\t'"$PROJ/.agent-sandbox" "$H/b.sup"
  grep -qxF "rw"$'\t'"ro"$'\t'"y"$'\t'"$PROJ/.asb/roles/supervisor.md" "$H/b.sup"
  release_bg
  engine_bg AGENT_SANDBOX_NET=none -- asb --role implementer-1 claude
  binds_of "$st/implementer-1/keeper/binds" >"$H/b.impl"
  grep -qxF "ro"$'\t'"ro"$'\t'"y"$'\t'"$PROJ/.agent-sandbox" "$H/b.impl"
  grep -qxF "ro"$'\t'"ro"$'\t'"y"$'\t'"$PROJ/.asb/roles/implementer-1.md" "$H/b.impl"
  release_bg
}

@test "_as_keeper_binds: the mount point's host path, whatever the source; hidden by a later mount, none; under an overlay, none; --remount-ro; symbolic links resolved; a newline kept in one field (#389)" {
  source_engine
  local d="$BATS_TEST_TMPDIR/k"
  mkdir -p "$d/p/sub" "$d/q" "$d/n"$'\n'"l"
  printf 'x\n' >"$d/p/f"
  printf 'x\n' >"$d/p/sub/g"
  printf 'x\n' >"$d/q/h"
  printf 'x\n' >"$d/n"$'\n'"l/f"
  ln -s p "$d/plink"
  binds() { _as_keeper_binds "$@" | while IFS= read -r -d '' a && IFS= read -r -d '' b && IFS= read -r -d '' c && IFS= read -r -d '' e; do printf '%s|%s|%s|%s\n' "$a" "$b" "$c" "$e"; done; }
  run binds --setenv A --bind --bind "$d/p" "$d/p" --ro-bind "$d/p/f" "$d/p/f" --ro-bind "$d/p/sub/g" "$d/p/sub/g" \
    --tmpfs "$d/p/sub" --bind "$d/q/h" "$d/p/h2" --clearenv --overlay-src "$d/q" --overlay "$d/u" "$d/w" "$d/q" \
    --ro-bind "$d/q/h" "$d/q/h"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "rw|ro|y|$d/p/f" ]
  [ "${lines[1]}" = "rw|rw|n|$d/p/h2" ] # another file's copy over p/h2: the mount sits on p/h2
  [ "${#lines[@]}" -eq 2 ]              # p/sub/g under the later tmpfs; q/h on the overlay
  # an overlay project: a read-write bind of a host file over itself is recorded (`-`),
  # a read-only one, or a copy, is not
  run binds --overlay-src "$d/p" --overlay "$d/u" "$d/w" "$d/p" --bind "$d/p/f" "$d/p/f" --ro-bind "$d/p/sub/g" "$d/p/sub/g" --bind "$d/q/h" "$d/p/h3"
  [ "$output" = "-|rw|y|$d/p/f" ]
  run binds --bind "$d/p" "$d/p" --ro-bind "$d/p/f" "$d/p/f2"
  [ "$output" = "rw|ro|n|$d/p/f2" ] # another name: its mount point, not its source
  run binds --bind "$d/p" "$d/p" --ro-bind "$d/p/f" "$d/p/f" --remount-ro "$d/p"
  [ "$output" = "ro|ro|y|$d/p/f" ]
  run binds --ro-bind "$d/p" "$d/p" --bind "$d/p/f" "$d/p/f"
  [ "$output" = "ro|rw|y|$d/p/f" ]
  run binds --ro-bind "$d/p" "$d/p" --bind "$d/p/f" "$d/p/f" --remount-ro "$d/p/f"
  [ "$output" = "ro|ro|y|$d/p/f" ]
  run binds --bind "$d/plink" "$d/plink" --ro-bind "$d/plink/f" "$d/plink/f"
  [ "$output" = "rw|ro|y|$d/p/f" ] # spelled through a link: the host's own path
  run binds --bind "$d" "$d" --ro-bind "$d/n"$'\n'"l/f" "$d/n"$'\n'"l/f"
  [ "$output" = "rw|ro|y|$d/n"$'\n'"l/f" ]
}

@test "_as_bwrap_options is bwrap's own list: every option of the installed bwrap's --help with its argument count, and (for 0.12, which it was written from) no other (#389)" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  source_engine
  local ver
  bwrap --help 2>&1 | awk '$1 ~ /^--/ { n = 0; for (i = 2; i <= NF && $i ~ /^[A-Z][A-Z0-9_]*$/; i++) n++; print $1, n }' | sort >"$BATS_TEST_TMPDIR/help"
  [ -s "$BATS_TEST_TMPDIR/help" ]
  _as_bwrap_options | awk '{ print $1, $2 }' | sort >"$BATS_TEST_TMPDIR/table"
  # every option bwrap has is in the table, with its count
  [ -z "$(comm -23 "$BATS_TEST_TMPDIR/help" "$BATS_TEST_TMPDIR/table")" ]
  ver="$(bwrap --version | awk '{ print $2 }')"
  if [[ "$(printf '%s\n' 0.12.0 "$ver" | sort -V | head -1)" == 0.12.0 ]]; then
    [ -z "$(comm -13 "$BATS_TEST_TMPDIR/help" "$BATS_TEST_TMPDIR/table")" ] # and nothing bwrap lacks
  fi
}

@test "_as_keeper_binds reads by the table: --dir mounts nothing, --bind-fd takes two arguments, --tmp-overlay covers what is under it; an option it does not know writes no record and says so (#389)" {
  source_engine
  local d="$BATS_TEST_TMPDIR/t"
  mkdir -p "$d/p"
  printf 'x\n' >"$d/p/f"
  [ "$(_as_keeper_binds --bind "$d/p" "$d/p" --dir "$d/p" --ro-bind "$d/p/f" "$d/p/f" --dir "$d/p/f" | tr '\0' '|')" = "rw|ro|y|$d/p/f|" ]
  [ "$(_as_keeper_binds --bind "$d/p" "$d/p" --bind-fd 7 /x --ro-bind "$d/p/f" "$d/p/f" | tr '\0' '|')" = "rw|ro|y|$d/p/f|" ]
  [ -z "$(_as_keeper_binds --bind "$d/p" "$d/p" --ro-bind "$d/p/f" "$d/p/f" --tmp-overlay "$d/p" | tr '\0' '|')" ]
  run _as_keeper_binds --bind "$d/p" "$d/p" --no-such-option --ro-bind "$d/p/f" "$d/p/f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bwrap option '--no-such-option' is not in the engine's table (_as_bwrap_options): this launch's single-file mounts are not recorded"* ]]
  [[ "$output" != *"$d/p/f"* ]]
}

@test "a running role with the project read-write: a re-run that would replace its read-only purpose file is refused (2), nothing written, the role, file and command named; after it ends, the run goes ahead (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.agent-sandbox" "$PROJ/.asb/roles/supervisor.md")
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"--init: nothing was written: this run would replace or remove a file bound into a running sandbox, which a host write breaks for it. End each role below, then run --init again:"* ]]
  [[ "$output" == *$'\n'"  role 'supervisor': .asb/roles/supervisor.md would become writable for it -- first: "*" --role supervisor --shutdown claude"* ]]
  [[ "$output" != *".agent-sandbox would"* ]] # the dot-file is never a reason
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  [ ! -e "$PROJ/.asb/impl/2" ]
  stopped
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/supervisor.md from model 'roles'"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/supervisor.md")" = "NEW LINE" ]
}

@test "a re-run that would remove a file bound into a running sandbox is refused (2): an instance above the count, a role set to 0; one line per role, its profile in the command (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  running implementer-2 < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.agent-sandbox" "$PROJ/.asb/roles/implementer-2.md")
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'implementer-2': .asb/roles/implementer-2.md would disappear for it -- first: "*" --role implementer-2 --shutdown claude"* ]]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  # several at once: a role set to 0 under another profile, the Supervisor's purpose file
  running reviewer-1 plain < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.asb/roles/reviewer-1.md")
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/roles/supervisor.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1 reviewer=0
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'reviewer-1': .asb/roles/reviewer-1.md would disappear for it -- first: "*" --role reviewer-1 --shutdown plain"* ]]
  [[ "$output" == *$'\n'"  role 'supervisor': .asb/roles/supervisor.md would become writable for it -- first: "*" --role supervisor --shutdown claude"* ]]
  [ "$(grep -c "^  role '" <<<"$output")" -eq 3 ]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
}

@test "a re-run goes ahead: a role with the project read-only sees its purpose file change; other roles' files change or go from a project it only sees (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/roles/implementer.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  running implementer-1 < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.agent-sandbox" "$PROJ/.asb/roles/implementer-1.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/implementer-1.md from model 'roles'"* ]]
  [[ "$output" == *"updated .asb/roles/supervisor.md from model 'roles'"* ]]
  [[ "$output" == *"removed .asb/roles/implementer-2.md"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-1.md")" = "NEW LINE" ]
}

@test "a re-run goes ahead: the run changes nothing bound (the Supervisor running, only the dot-file changes); a sandbox no longer running; a running role's project copy-on-write (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.agent-sandbox" "$PROJ/.asb/roles/supervisor.md")
  local ino
  ino="$(stat -c %i "$PROJ/.agent-sandbox")"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:implementer-2]"* ]]
  [ "$(stat -c %i "$PROJ/.agent-sandbox")" = "$ino" ]
  stopped
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles # stopped: the keeper's id names a process gone
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/supervisor.md from model 'roles'"* ]]
  printf 'NEWER LINE\n' >>"$H/models/roles/roles/supervisor.md"
  running supervisor </dev/null # a copy-on-write project: no mount on a host file (_as_keeper_binds)
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$PROJ/.asb/roles/supervisor.md")" = "NEWER LINE" ]
  # removed under a copy-on-write project: the bind keeps the old file, nothing disappears
  running implementer-2 </dev/null # a copy-on-write project: no mount on a host file (_as_keeper_binds)
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed .asb/roles/implementer-2.md"* ]]
}

@test "a sandbox an older asb started, with no record of its binds: its declared files taken as bound in a directory that cannot be told -- a change or a removal refused, whatever its project (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/implementer.md"
  RUNNING_OLD=1 running supervisor < <(printf 'connect:%s\tread-only\tbuilt in, #222\n' "$PROJ/.asb/roles/supervisor.md")
  local sup="$RUN_PID"
  RUNNING_OLD=1 running implementer-1 < <(printf 'connect:%s\tread-only\tbuilt in, #222\n' "$PROJ/.asb/roles/implementer-1.md")
  local impl="$RUN_PID"
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'supervisor': .asb/roles/supervisor.md may become writable for it (started by an older asb, which records no binds: its declared files taken as bound) -- first: "*" --role supervisor --shutdown claude"* ]]
  # read-only from its file, but a --connect flag at its launch is in no record
  [[ "$output" == *$'\n'"  role 'implementer-1': .asb/roles/implementer-1.md may become writable for it (started by an older asb"* ]]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  RUN_PID="$sup" stopped
  RUN_PID="$impl" stopped
  RUNNING_OLD=1 running implementer-2 < <(printf 'connect:%s\tread-only\tbuilt in, #222\n' "$PROJ/.asb/roles/implementer-2.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'implementer-2': .asb/roles/implementer-2.md would disappear for it (started by an older asb"* ]]
  stopped # implementer-2's
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-1.md")" = "NEW LINE" ]
}

@test "the refusal comes before the backup of a re-added instance's old clone: nothing moved (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1
  [ "$status" -eq 0 ]
  [ -d "$PROJ/.asb/git/2" ]
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/roles/supervisor.md")
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/roles/supervisor.md would become writable for it"* ]]
  [[ "$output" != *"is added again"* ]]
  [ ! -e "$PROJ/.asb/backup" ]
  [ -d "$PROJ/.asb/git/2" ]
  [ -d "$PROJ/.asb/impl/2" ]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
}

@test "a running instance whose purpose file you changed: a count that removes it keeps that file, so nothing bound goes and the run goes ahead (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  printf 'MINE\n' >>"$PROJ/.asb/roles/implementer-2.md"
  running implementer-2 < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.asb/roles/implementer-2.md")
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept .asb/roles/implementer-2.md: changed since --init wrote it, and implementer-2 is removed"* ]]
  [ "$(tail -1 "$PROJ/.asb/roles/implementer-2.md")" = MINE ]
}

@test "the bookkeeping files bound read-write: a re-run that leaves them as they are goes ahead; one that changes the coord index, .asb/init.sums or a migration copy is refused (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  printf 'MINE\n' >>"$PROJ/.asb/roles/supervisor.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles # the migration copy written
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.asb/migrate/supervisor.md" ]
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/coord/COORDINATION.md" "$PROJ/.asb/init.sums" "$PROJ/.asb/migrate/supervisor.md")
  local ino
  ino="$(stat -c %i "$PROJ/.asb/init.sums")"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles # nothing changes
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$PROJ/.asb/init.sums")" = "$ino" ] # the same text renamed nothing over it
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2 # a row, a record
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/coord/COORDINATION.md would become writable for it, .asb/init.sums would become writable for it -- first:"* ]]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  printf 'NEWER LINE\n' >>"$H/models/roles/roles/supervisor.md" # the migration copy's text
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/migrate/supervisor.md would become writable for it -- first:"* ]]
}

@test "a file in a re-added instance's old clone, bound into a running sandbox: the backup would take it away, so the run is refused (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  printf 'work\n' >"$PROJ/.asb/impl/2/notes.md"
  running reviewer-1 < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.asb/impl/2/notes.md")
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'reviewer-1': .asb/impl/2/notes.md would disappear for it -- first:"* ]]
  [ ! -e "$PROJ/.asb/backup" ]
}

@test "a re-run whose .agent-sandbox is not writable says so, and writes nothing to it (#389)" {
  [ "$(id -u)" -ne 0 ] || skip "root writes a file of mode 444"
  init -- roles
  [ "$status" -eq 0 ]
  cp "$PROJ/.agent-sandbox" "$H/before"
  chmod 444 "$PROJ/.agent-sandbox"
  init -- roles implementer=2
  chmod 644 "$PROJ/.agent-sandbox"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: $PROJ/.agent-sandbox could not be written: it is not writable (mode 444); nothing was written"* ]]
  cmp "$H/before" "$PROJ/.agent-sandbox"
}

@test "re-adding an instance whose old sandbox still runs with its clone declared: refused (2), the clone where it was, no backup, nothing written; after it ends, the run goes ahead (#389)" {
  fixed_date
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1 # removed while nothing runs; its clone left
  [ "$status" -eq 0 ]
  running implementer-2 </dev/null
  printf 'connect:%s\tread-write\t.agent-sandbox [connect:implementer-2]\n' "$PROJ/.asb/impl/2" "$PROJ/.asb/git/2" >"$RUN_SB/keeper/policy"
  snap before
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'implementer-2': .asb/impl/2 would be moved from under it (an instance added again; its old clone goes to .asb/backup/), .asb/git/2 would be moved from under it (an instance added again; its old clone goes to .asb/backup/) -- first: "*" --role implementer-2 --shutdown claude"* ]]
  [[ "$output" != *"is added again"* ]]
  [ ! -e "$PROJ/.asb/backup" ]
  [ -f "$PROJ/.asb/impl/2/.git" ]
  [ -d "$PROJ/.asb/git/2" ]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  stopped
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"implementer-2 is added again"* ]]
  [ -d "$PROJ/.asb/backup/implementer-2-20260101T000000Z" ]
}

@test "re-adding an instance goes ahead with nothing to move, or when no live sandbox has its old clone (the Supervisor has .asb/impl/ around it) (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  running supervisor </dev/null
  printf 'connect:%s\tread-only\t.agent-sandbox [connect:supervisor]\n' "$PROJ/.asb/impl" "$PROJ/.asb/git" >"$RUN_SB/keeper/policy"
  init -- roles implementer=2 # the clone moves inside the Supervisor's mount of .asb/impl/
  [ "$status" -eq 0 ]
  [[ "$output" == *"implementer-2 is added again"* ]]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  rm -rf "$PROJ/.asb/impl/2" "$PROJ/.asb/git/2" # nothing left to move
  running implementer-2 </dev/null
  printf 'connect:%s\tread-write\t.agent-sandbox [connect:implementer-2]\n' "$PROJ/.asb/impl/2" "$PROJ/.asb/git/2" >"$RUN_SB/keeper/policy"
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned for implementer-2"* ]]
}

@test "the hard-link warning's line searches the file's own filesystem from its mount point: on a filesystem that is not /'s it lists the other name (#389)" {
  [[ -d /dev/shm && -w /dev/shm && "$(stat -c %m /dev/shm 2>/dev/null)" == /dev/shm ]] \
    || skip "/dev/shm is not a separate, writable filesystem here: the printed line is run only there, never over /"
  source_engine
  local d cmd
  d="$(mktemp -d /dev/shm/asb-389.XXXXXX)"
  printf '%s\n' "$d" >"$H/shm" # removed in teardown, whatever happens here
  mkdir "$d/a dir"
  printf 'x\n' >"$d/a dir/.agent-sandbox"
  ln "$d/a dir/.agent-sandbox" "$d/other name"
  run _as_dotfile_link_note "$d/a dir/.agent-sandbox" 2
  cmd="${output#*this lists them: }"
  [ "$cmd" = "find /dev/shm -xdev -samefile $(printf '%q' "$d/a dir/.agent-sandbox") 2>/dev/null" ]
  run bash -c "$cmd"
  [[ "$output" == *"$d/other name"* ]]
}

@test "a re-run that writes .agent-sandbox in place warns when it has another name (a hard link), which shows the new text; none with one name (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  [[ "$output" != *"hard link"* ]]
  ln "$PROJ/.agent-sandbox" "$H/other-name"
  init -- roles implementer=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: warning — $PROJ/.agent-sandbox has 1 other name(s) (a hard link): written in place, each shows the new text too, and anyone who can write one of them can change this file. asb cannot tell where they are; this lists them: find $(printf '%q' "$(stat -c %m -- "$PROJ/.agent-sandbox")") -xdev -samefile $(printf '%q' "$PROJ/.agent-sandbox") 2>/dev/null"* ]]
  grep -qF '[connect:implementer-3]' "$H/other-name"
  # the printed line is run only on /dev/shm (the test above): here the mount point may be
  # /, and no test walks the whole root filesystem
}

@test "a replace by what the mount over the file was: a read-write declaration over itself in a read-write project goes ahead; in a read-only one, or a copy of the role's own over the file, refused with what it loses (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/tests"
  running supervisor < <(printf 'rw\trw\ty\t%s\n' "$PROJ/.asb/tests")
  local sup="$RUN_PID"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles # it writes the file before and after
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/tests from model 'roles'"* ]]
  RUN_PID="$sup" stopped
  printf 'NEWER LINE\n' >>"$H/models/roles/tests"
  running implementer-1 < <(printf 'ro\trw\ty\t%s\n' "$PROJ/.asb/tests")
  local impl="$RUN_PID"
  running reviewer-1 < <(printf 'ro\tro\tn\t%s\n' "$PROJ/.asb/tests")
  local rev="$RUN_PID"
  running planner-1 < <(printf 'rw\trw\tn\t%s\n' "$PROJ/.asb/tests")
  snap before
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'implementer-1': its read-write mount of .asb/tests would be replaced by the host's new file, read-only for it -- first: "* ]]
  [[ "$output" == *$'\n'"  role 'reviewer-1': its own copy over .asb/tests would be replaced by the host's new file -- first: "* ]]
  [[ "$output" == *$'\n'"  role 'planner-1': its own copy over .asb/tests would be replaced by the host's new file, writable for it -- first: "* ]]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  RUN_PID="$impl" stopped
  RUN_PID="$rev" stopped
  stopped
  # a read-only declaration over itself in a read-only project: the role sees the new text
  running implementer-1 < <(printf 'ro\tro\ty\t%s\n' "$PROJ/.asb/tests")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
}

@test "the coord index losing a removed instance's row, and a migration copy removed, under a read-write mount: refused (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 0 ]
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/coord/COORDINATION.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=1 # only a row goes from it
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/coord/COORDINATION.md would become writable for it -- first:"* ]]
  stopped
  printf 'MINE\n' >>"$PROJ/.asb/roles/supervisor.md"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2 # the migration copy written
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.asb/migrate/supervisor.md" ]
  rm "$PROJ/.asb/roles/supervisor.md" # step 2 of the offer: the next run takes the model's text and drops the copy
  running supervisor < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/migrate/supervisor.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/migrate/supervisor.md would disappear for it -- first:"* ]]
  [ -f "$PROJ/.asb/migrate/supervisor.md" ]
}

@test "a launch whose bwrap options the table does not know: said, no record but binds.unread, and --init says why it takes the declarations (#389)" {
  init -- roles
  [ "$status" -eq 0 ]
  (cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  # the engine with a table that lacks an option it uses
  cat >"$H/bin/asb-short-table" <<EOF
#!/usr/bin/env bash
source "$ENGINE"
eval "_as_bwrap_options_real() \$(declare -f _as_bwrap_options | tail -n +2)"
_as_bwrap_options() { _as_bwrap_options_real | grep -v '^--unshare-all '; }
agent_sandbox "\$@"
EOF
  chmod +x "$H/bin/asb-short-table"
  local kd="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/supervisor/keeper"
  engine_bg AGENT_SANDBOX_NET=none -- "$H/bin/asb-short-table" --role supervisor claude
  grep -qF "bwrap option '--unshare-all' is not in the engine's table (_as_bwrap_options): this launch's single-file mounts are not recorded" "$H/bg.out"
  [ ! -e "$kd/binds" ]
  [ -e "$kd/binds.unread" ]
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'supervisor': .asb/roles/supervisor.md may become writable for it (its mounts could not be recorded at its launch: its declared files taken as bound) -- first:"* ]]
  release_bg
}

@test "a copy-on-write project with a read-write declaration over a file: a replace is refused, its writes would stop reaching the file (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/tests"
  running gate < <(printf -- '-\trw\ty\t%s\n' "$PROJ/.asb/tests")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'gate': its writes to .asb/tests would stop reaching the project's file (its mount keeps the file the host replaced) -- first: "* ]]
}

@test "re-adding an instance whose old clone is a running sandbox's PROJECT: refused; a sibling's project (.asb/impl/20) goes ahead (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  mkdir -p "$PROJ/.asb/impl/20"
  RUN_PROJ="$PROJ/.asb/impl/20" running default </dev/null
  local sib="$RUN_PID"
  RUN_PROJ="$PROJ/.asb/impl/2" running default </dev/null
  snap before
  init -- roles implementer=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"  role 'default' of the project $PROJ/.asb/impl/2: .asb/impl/2 would be moved from under it (its project; an instance added again, its old clone goes to .asb/backup/) -- first: cd $PROJ/.asb/impl/2 && "*" --role default --shutdown claude"* ]]
  [[ "$output" != *"impl/20"* ]]
  [ ! -e "$PROJ/.asb/backup" ]
  snap after
  cmp "$H/snap.before" "$H/snap.after"
  stopped
  init -- roles implementer=2 # the sibling's sandbox alone: nothing of it moves
  [ "$status" -eq 0 ]
  [[ "$output" == *"implementer-2 is added again"* ]]
  RUN_PID="$sib" stopped
}

@test "another project's path with a newline, a space, a quote and a dollar: named and given to cd quoted, whole (#389)" {
  cp -rL "$(dirname "$ENGINE")/models" "$H/models"
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 0 ]
  printf 'NEW LINE\n' >>"$H/models/roles/roles/supervisor.md"
  local other="$H/odd"$'\n'"name it's \$HOME"
  mkdir -p "$other"
  RUN_PROJ="$other" running default < <(printf 'rw\tro\ty\t%s\n' "$PROJ/.asb/roles/supervisor.md")
  init AGENT_SANDBOX_MODELS_DIR="$H/models" -- roles
  [ "$status" -eq 2 ]
  [[ "$output" == *"  role 'default' of the project $(printf '%q' "$other"): .asb/roles/supervisor.md would become writable for it -- first: cd $(printf '%q' "$other") && "*" --role default --shutdown claude"* ]]
  # the cd, as printed, reaches that directory
  local cmd="${output#*-- first: cd }"
  cmd="${cmd%% && *}"
  run bash -c "cd $cmd && pwd"
  [ "$output" = "$other" ]
}

@test "a copy-on-write project with a read-write declaration over a file: its removal is refused too; a read-only or copied file there is removed (#389)" {
  init -- roles implementer=2
  [ "$status" -eq 0 ]
  running implementer-2 < <(printf -- '-\trw\ty\t%s\n' "$PROJ/.asb/roles/implementer-2.md")
  init -- roles implementer=1
  [ "$status" -eq 2 ]
  [[ "$output" == *$'\n'"  role 'implementer-2': its writes to .asb/roles/implementer-2.md would stop reaching the project's file (its mount keeps the file the host removed) -- first: "* ]]
  [ -f "$PROJ/.asb/roles/implementer-2.md" ]
  stopped
  running implementer-2 </dev/null # read-only or a copy there: nothing recorded
  init -- roles implementer=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed .asb/roles/implementer-2.md"* ]]
}
