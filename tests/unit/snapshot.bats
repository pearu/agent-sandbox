#!/usr/bin/env bats
# probes/snapshot.py is the study's measurement instrument, so it is validated
# before any experiment uses it: every change class, determinism (which doubles as
# a self-non-perturbation check), and the awkward edge cases.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  SNAP="$REPO_ROOT/probes/snapshot.py"
  T="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$T"
}

manifest() { python3 "$SNAP" manifest "$T"; }
manifest_to() { python3 "$SNAP" manifest "$T" >"$1"; }
# type recorded for a path, read from $output of a `run` of manifest
type_of() { printf '%s\n' "$output" | awk -F'\t' -v p="$1" '$6==p{print $1}'; }
# assert (exit 0/1) a STATUS row for PATH is present in $output of a `run` of diff
has_change() { printf '%s\n' "$output" | awk -F'\t' -v s="$1" -v p="$2" '$1==s && $2==p{f=1} END{exit !f}'; }

@test "manifest is deterministic and self-non-perturbing (identical back-to-back, atime included)" {
  mkdir -p "$T/d"
  printf 'hello' >"$T/d/a.txt"
  printf 'world' >"$T/b.txt"
  manifest_to "$BATS_TEST_TMPDIR/m1"
  # hashing during m1 must not bump any atime, or m2 would record a newer one:
  manifest_to "$BATS_TEST_TMPDIR/m2"
  diff "$BATS_TEST_TMPDIR/m1" "$BATS_TEST_TMPDIR/m2"
}

@test "diff classifies created / deleted / content / touched / atime; unchanged never appears" {
  printf 'x' >"$T/stable.txt"   # fully untouched -> must NOT appear
  printf 'orig' >"$T/edit.txt"  # content change
  printf 'gone' >"$T/del.txt"   # deleted
  printf 'same' >"$T/touch.txt" # mtime bumped, content identical
  printf 'read' >"$T/atime.txt" # atime bumped only
  manifest_to "$BATS_TEST_TMPDIR/before"

  printf 'CHANGED-and-longer' >"$T/edit.txt"
  rm "$T/del.txt"
  printf 'new' >"$T/new.txt"
  touch -m -d '2030-01-01T00:00:00' "$T/touch.txt" # mtime only (content same)
  touch -a -d '2030-01-01T00:00:00' "$T/atime.txt" # atime only
  manifest_to "$BATS_TEST_TMPDIR/after"

  run python3 "$SNAP" diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$status" -eq 0 ]
  has_change content "$T/edit.txt"
  has_change deleted "$T/del.txt"
  has_change created "$T/new.txt"
  has_change touched "$T/touch.txt"
  has_change atime "$T/atime.txt"
  # a genuinely unchanged file appears under no status
  run ! grep -qF -- "$T/stable.txt" <<<"$output"
}

@test "edge cases: symlink recorded not followed; fifo, broken/loop links, unreadable never crash" {
  printf 'target' >"$T/real.txt"
  ln -s real.txt "$T/link"       # symlink to a real file
  ln -s /nonexistent "$T/broken" # dangling symlink
  ln -s loop "$T/loop"           # self-referential symlink
  mkfifo "$T/pipe"               # a fifo must not be opened/hashed (would block)
  printf 'secret' >"$T/noread.txt"
  chmod 000 "$T/noread.txt"

  run manifest # must terminate and exit 0
  [ "$status" -eq 0 ]
  [ "$(type_of "$T/link")" = link ]
  [ "$(type_of "$T/broken")" = link ]
  [ "$(type_of "$T/loop")" = link ]
  [ "$(type_of "$T/pipe")" = fifo ]
  [ "$(type_of "$T/real.txt")" = file ] # the symlink was not followed to duplicate it
  [ "$(type_of "$T/noread.txt")" = unreadable ]

  chmod 644 "$T/noread.txt" # restore so bats can clean up
}
