#!/usr/bin/env bats
# The `copy` mode's three-way sync (components/connect-sync.py).
#
# One test per row of the matrix in that file's header, because the matrix IS
# the mode: get a row wrong and a sandbox either loses the work it did or stops
# receiving what the user changed, and in both cases silently. The study's cells
# assert the same promises from the outside, through a real launch; these assert
# them directly, so a failure says which rule broke rather than which cell did.
#
# The cell each row corresponds to is named, so the two stay findable from each
# other.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  SYNC="$REPO_ROOT/components/connect-sync.py"
  S="$BATS_TEST_TMPDIR/source"
  C="$BATS_TEST_TMPDIR/copy"
  B="$BATS_TEST_TMPDIR/base.json"
  mkdir -p "$S"
}

# sync / reset over the directory-shaped channel
sync() { run python3 "$SYNC" sync --kind dir --source "$S" --copy "$C" --base "$B"; }
reset() { run python3 "$SYNC" reset --kind dir --source "$S" --copy "$C" --base "$B"; }
# and over a file-shaped one
fsync() { run python3 "$SYNC" sync --kind file --source "$1" --copy "$2" --base "$B"; }

plant() { # plant REL CONTENT -- in the source
  mkdir -p "$(dirname "$S/$1")"
  printf '%s\n' "$2" >"$S/$1"
}
inside() { # inside REL CONTENT -- as if the sandbox wrote it
  mkdir -p "$(dirname "$C/$1")"
  printf '%s\n' "$2" >"$C/$1"
}
at_copy() { cat "$C/$1" 2>/dev/null; }

@test "C1 seed: a source file the sandbox has never seen is copied in" {
  plant a.md ONE
  sync
  [ "$status" -eq 0 ]
  [ "$(at_copy a.md)" = ONE ]
  [ -z "$output" ] # no conflict
}

@test "C3 the source standing still leaves the sandbox's edit alone" {
  plant a.md ONE
  sync
  inside a.md MINE
  sync
  [ "$(at_copy a.md)" = MINE ]
  [ -z "$output" ]
}

@test "C4 refresh: the source moves on a file the sandbox never touched" {
  plant a.md ONE
  sync
  plant a.md TWO
  sync
  [ "$(at_copy a.md)" = TWO ]
  [ -z "$output" ]
}

@test "C5 both moved: the sandbox's version stays and the file is NAMED" {
  plant a.md ONE
  sync
  inside a.md MINE
  plant a.md THEIRS
  sync
  [ "$(at_copy a.md)" = MINE ]
  [ "$output" = "conflict a.md" ]
}

@test "C5 the conflict is reported again at the NEXT sync, not just the first" {
  # The base is deliberately not advanced on a conflict. Reporting once would be
  # quieter and would let the single launch that said so scroll past unseen.
  plant a.md ONE
  sync
  inside a.md MINE
  plant a.md THEIRS
  sync
  sync
  [ "$output" = "conflict a.md" ]
  [ "$(at_copy a.md)" = MINE ]
}

@test "C6 the source deletes a file the sandbox never touched: it goes" {
  plant a.md ONE
  sync
  rm "$S/a.md"
  sync
  [ ! -e "$C/a.md" ]
  [ -z "$output" ]
}

@test "the source deletes a file the sandbox HAD changed: the sandbox keeps it" {
  plant a.md ONE
  sync
  inside a.md MINE
  rm "$S/a.md"
  sync
  [ "$(at_copy a.md)" = MINE ]
}

@test "C7 the sandbox deletes a file: it stays deleted and is never resurrected" {
  # The base entry is KEPT for exactly this: without it the next sync cannot tell
  # a deletion from a file it has never seeded, and would copy it straight back.
  plant a.md ONE
  sync
  rm "$C/a.md"
  sync
  [ ! -e "$C/a.md" ]
  sync # and again, in case the memory only survives one round
  [ ! -e "$C/a.md" ]
  [ -f "$S/a.md" ] # the source still has its own
}

@test "both sides create the same path independently: the sandbox's is kept, and named" {
  plant a.md THEIRS
  inside a.md MINE
  sync
  [ "$(at_copy a.md)" = MINE ]
  [ "$output" = "conflict a.md" ]
}

@test "an EMPTY file at an unsynced path is a mount point, not content: the seed wins" {
  # MEASURED, and it cost two study cells. The engine must create a mount point
  # when a channel names a path the source does not have yet, so a launch before
  # the file exists leaves an empty one behind. Without this rule the next sync
  # read that as "the sandbox made this too" and refused the very first seed.
  mkdir -p "$C"
  : >"$C/a.md" # the mount point a previous launch left
  plant a.md ONE
  sync
  [ "$(at_copy a.md)" = ONE ]
  [ -z "$output" ] # and it is NOT a conflict
}

@test "but a file the sandbox deliberately emptied is a real edit and is protected" {
  # The rule above is scoped to paths that were never synced. Once a file has a
  # base, emptying it is something the sandbox did on purpose.
  plant a.md ONE
  sync
  : >"$C/a.md"
  plant a.md THEIRS
  sync
  [ "$(at_copy a.md)" = "" ]
  [ "$output" = "conflict a.md" ]
}

@test "a file only the sandbox has is left entirely alone" {
  inside own.md MINE
  sync
  [ "$(at_copy own.md)" = MINE ]
  [ -z "$output" ]
  [ ! -e "$S/own.md" ] # and is not written back
}

@test "C8 reset throws the sandbox's copy away, re-seeds, and clears the conflict" {
  plant a.md ONE
  sync
  inside a.md MINE
  plant a.md THEIRS
  sync
  [ "$output" = "conflict a.md" ]
  reset
  [ "$status" -eq 0 ]
  [ "$(at_copy a.md)" = THEIRS ]
  [ -z "$output" ]
  sync # and the conflict does not come back
  [ -z "$output" ]
}

@test "C2 nothing is ever written back to the source, whatever the sandbox does" {
  plant a.md ONE
  plant keep/b.md TWO
  sync
  local before
  before="$(find "$S" -type f -exec sha256sum {} + | sort)"
  inside a.md MINE
  inside brand-new.md MINE
  rm "$C/keep/b.md"
  sync
  [ "$(find "$S" -type f -exec sha256sum {} + | sort)" = "$before" ]
}

@test "nested paths in a directory channel are handled at every depth" {
  plant deep/er/still/a.md ONE
  sync
  [ "$(at_copy deep/er/still/a.md)" = ONE ]
  plant deep/er/still/a.md TWO
  sync
  [ "$(at_copy deep/er/still/a.md)" = TWO ]
  rm "$S/deep/er/still/a.md"
  sync
  [ ! -e "$C/deep/er/still/a.md" ]
}

@test "a file-shaped channel behaves the same, and names itself in the conflict" {
  local sf="$BATS_TEST_TMPDIR/CLAUDE.md" cf="$BATS_TEST_TMPDIR/copy-of-it"
  printf 'ONE\n' >"$sf"
  fsync "$sf" "$cf"
  [ "$(cat "$cf")" = ONE ]
  printf 'MINE\n' >"$cf"
  printf 'THEIRS\n' >"$sf"
  fsync "$sf" "$cf"
  [ "$(cat "$cf")" = MINE ]
  # no relative path to report, so the channel's own file name is the name
  [ "$output" = "conflict CLAUDE.md" ]
}

@test "the base is a manifest of hashes, not a second copy of the files" {
  # If it held content it would double the storage of every copied channel, and
  # a restore reads the source anyway.
  plant a.md ONE
  sync
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert list(d) == ["a.md"], d
assert len(d["a.md"]) == 64, d          # a sha256, not a blob
' "$B"
  [ "$status" -eq 0 ]
}

# ----- `cow`: which shadows has the source changed underneath? ---------------

shadows() { run python3 "$SYNC" shadows --source "$S" --upper "$U" --seen "$B"; }
shadow() { # shadow REL CONTENT -- as if the sandbox had written it through the overlay
  mkdir -p "$(dirname "$U/$1")"
  printf '%s\n' "$2" >"$U/$1"
}

@test "W4 a shadowed file whose source changed afterwards is reported, by name" {
  # THE BUG THIS PINS: the baseline must be the source as of the PREVIOUS launch.
  # A shadow is created during a session, so the launch that first sees it is
  # already after any edit the user made in between -- recording the source then
  # records the changed file as the baseline and the warning never fires. It did
  # not, and no study cell caught it, because W4 uses the file-shaped path, which
  # falls back to `copy` and takes a different code path entirely.
  U="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$U"
  plant a.md YOURS
  shadows # launch 1: nothing shadowed yet, the source is snapshotted
  [ -z "$output" ]
  shadow a.md MINE   # the session writes, during launch 1
  plant a.md CHANGED # and the user edits their own copy afterwards
  shadows            # launch 2
  [ "$output" = "conflict a.md" ]
}

@test "W4 it keeps reporting at every later launch, as a copy conflict does" {
  U="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$U"
  plant a.md YOURS
  shadows
  shadow a.md MINE
  plant a.md CHANGED
  shadows
  shadows
  [ "$output" = "conflict a.md" ]
}

@test "a shadow the source has NOT touched is not reported" {
  U="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$U"
  plant a.md YOURS
  shadows
  shadow a.md MINE
  shadows
  [ -z "$output" ]
}

@test "a file the sandbox created that the source never had is not a shadow of anything" {
  U="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$U"
  shadows
  shadow own.md MINE
  shadows
  [ -z "$output" ]
}

@test "a whiteout is not a shadow: deleting is covered by W5, not by this warning" {
  # An overlay records a deletion as a character device in the upper layer. It is
  # not a stale copy of anything, so warning about it would be noise on top of a
  # deliberate act.
  U="$BATS_TEST_TMPDIR/upper"
  mkdir -p "$U"
  plant a.md YOURS
  shadows
  # a character device cannot be made without privilege here, so stand in with
  # the property the scan actually tests for: not a regular file.
  mkdir -p "$U/a.md"
  plant a.md CHANGED
  shadows
  [ -z "$output" ]
}

@test "bad arguments are refused rather than half-applied" {
  run python3 "$SYNC" sync --kind dir --source "$S" --copy "$C"
  [ "$status" -eq 2 ]
  run python3 "$SYNC" sync --kind sideways --source "$S" --copy "$C" --base "$B"
  [ "$status" -eq 2 ]
  run python3 "$SYNC" frobnicate --kind dir --source "$S" --copy "$C" --base "$B"
  [ "$status" -eq 2 ]
}
