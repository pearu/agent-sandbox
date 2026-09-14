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
# fields recorded for PATH in manifest FILE, space-separated: type size mtime atime sha
rec() { awk -F'\t' -v p="$1" '$6==p{print $1, $2, $3, $4, $5}' "$2"; }

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

@test "record fields: a content save changes sha+mtime(+size) not atime; same-length still 'content'; a read changes only atime" {
  printf 'aaaa' >"$T/f.txt"
  manifest_to "$BATS_TEST_TMPDIR/m0"

  # (1) content save, different length -> sha, size, mtime change; atime UNCHANGED (a write is not a read)
  sleep 0.05
  printf 'aaaaaa' >"$T/f.txt"
  manifest_to "$BATS_TEST_TMPDIR/m1"
  read -r -a r0 < <(rec "$T/f.txt" "$BATS_TEST_TMPDIR/m0")
  read -r -a r1 < <(rec "$T/f.txt" "$BATS_TEST_TMPDIR/m1")
  [ "${r1[4]}" != "${r0[4]}" ] # sha changed
  [ "${r1[1]}" != "${r0[1]}" ] # size changed
  [ "${r1[2]}" != "${r0[2]}" ] # mtime changed
  [ "${r1[3]}" = "${r0[3]}" ]  # atime unchanged

  # (2) same-length content change -> size same, sha differs; still classified 'content'
  sleep 0.05
  printf 'bbbbbb' >"$T/f.txt"
  manifest_to "$BATS_TEST_TMPDIR/m2"
  read -r -a r2 < <(rec "$T/f.txt" "$BATS_TEST_TMPDIR/m2")
  [ "${r2[1]}" = "${r1[1]}" ]  # size unchanged
  [ "${r2[4]}" != "${r1[4]}" ] # sha changed -> detectable without a size change
  run python3 "$SNAP" diff "$BATS_TEST_TMPDIR/m1" "$BATS_TEST_TMPDIR/m2"
  has_change content "$T/f.txt"

  # (3) a read (atime bumped only) -> only atime changes; classified 'atime'
  touch -a -d '2031-01-01T00:00:00' "$T/f.txt"
  manifest_to "$BATS_TEST_TMPDIR/m3"
  read -r -a r3 < <(rec "$T/f.txt" "$BATS_TEST_TMPDIR/m3")
  [ "${r3[3]}" != "${r2[3]}" ] # atime changed
  [ "${r3[2]}" = "${r2[2]}" ]  # mtime unchanged
  [ "${r3[1]}" = "${r2[1]}" ]  # size unchanged
  [ "${r3[4]}" = "${r2[4]}" ]  # sha unchanged
  run python3 "$SNAP" diff "$BATS_TEST_TMPDIR/m2" "$BATS_TEST_TMPDIR/m3"
  has_change atime "$T/f.txt"
}

# Which atime policy is this filesystem on? --arm exists because of relatime, and
# asserting relatime behaviour blindly would turn a strictatime or noatime mount into
# a baffling failure rather than an honest skip.
atime_policy() {
  local f="$BATS_TEST_TMPDIR/atime-probe" a1 a2 m
  printf x >"$f"
  sleep 1.1
  cat "$f" >/dev/null # a first read a full second after the write is always recorded
  a1=$(stat -c %.9X "$f")
  cat "$f" >/dev/null # a second one is not, under relatime
  a2=$(stat -c %.9X "$f")
  if [ "$a1" != "$a2" ]; then
    printf strictatime
    return 0
  fi
  m=$(stat -c %Y "$f")
  touch -a -d "@$m" "$f" # arm by hand
  a1=$(stat -c %.9X "$f")
  cat "$f" >/dev/null
  a2=$(stat -c %.9X "$f")
  if [ "$a1" = "$a2" ]; then printf noatime; else printf relatime; fi
}

require_relatime() {
  local p
  p="$(atime_policy)"
  [ "$p" = relatime ] || skip "filesystem atime policy is $p, not relatime"
}

# has PATH's atime moved across a read? Compared at NANOSECOND precision: an
# update that lands in the same second as the previous atime is still an update,
# and comparing `stat -c %X` would miss it intermittently.
read_is_recorded() {
  local x y
  x=$(stat -c %.9X "$1")
  cat "$1" >/dev/null
  y=$(stat -c %.9X "$1")
  [ "$x" != "$y" ]
}

@test "--arm makes an otherwise invisible read observable" {
  require_relatime
  printf 'canary' >"$T/f.txt"
  sleep 1.1
  cat "$T/f.txt" >/dev/null # atime now leads mtime: further reads leave no trace
  run ! read_is_recorded "$T/f.txt"

  run python3 "$SNAP" manifest --arm "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed 1 file"* ]]
  read_is_recorded "$T/f.txt"
}

@test "--arm skips a file whose next read is already recorded, and that skip is safe" {
  require_relatime
  # (1) atime equal to mtime
  printf 'one' >"$T/a.txt"
  touch -a -d "@$(stat -c %Y "$T/a.txt")" "$T/a.txt"
  # (2) atime past mtime but not past ctime
  printf 'two' >"$T/b.txt"
  touch -m -d '2020-01-01T00:00:00' "$T/b.txt"
  local ca cb
  ca=$(stat -c %.9Z "$T/a.txt")
  cb=$(stat -c %.9Z "$T/b.txt")

  run python3 "$SNAP" manifest --arm "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped 2 already-observable"* ]]
  # untouched: any utime would have moved ctime to now
  [ "$(stat -c %.9Z "$T/a.txt")" = "$ca" ]
  [ "$(stat -c %.9Z "$T/b.txt")" = "$cb" ]
  # and the skip was justified -- reads of both ARE recorded, unarmed
  read_is_recorded "$T/a.txt"
  read_is_recorded "$T/b.txt"
}

@test "--arm changes atime only: content, size and mtime survive exactly" {
  require_relatime
  printf 'payload' >"$T/f.txt"
  sleep 1.1
  cat "$T/f.txt" >/dev/null
  local m s h
  m=$(stat -c %y "$T/f.txt") # nanosecond precision
  s=$(stat -c %s "$T/f.txt")
  h=$(sha256sum "$T/f.txt" | cut -d' ' -f1)
  sleep 1.1 # the sha256sum above re-read it; make it need arming again

  run python3 "$SNAP" manifest --arm "$T"
  [[ "$output" == *"armed 1 file"* ]]
  # mtime must not move: if it did, every later diff would report every file 'touched'
  [ "$(stat -c %y "$T/f.txt")" = "$m" ]
  [ "$(stat -c %s "$T/f.txt")" = "$s" ]
  [ "$(stat -c %.9X "$T/f.txt")" = "$(stat -c %.9Y "$T/f.txt")" ] # atime := mtime
  [ "$(sha256sum "$T/f.txt" | cut -d' ' -f1)" = "$h" ]            # reads it, so assert last
}

@test "--arm does not follow a symlink to re-time its target" {
  require_relatime
  mkdir -p "$T/inside" "$T/outside"
  printf 'target' >"$T/outside/real.txt"
  ln -s ../outside/real.txt "$T/inside/link"
  sleep 1.1
  cat "$T/outside/real.txt" >/dev/null
  local a c
  a=$(stat -c %.9X "$T/outside/real.txt")
  c=$(stat -c %.9Z "$T/outside/real.txt")
  run python3 "$SNAP" manifest --arm "$T/inside"
  [ "$status" -eq 0 ]
  [ "$(stat -c %.9X "$T/outside/real.txt")" = "$a" ]
  [ "$(stat -c %.9Z "$T/outside/real.txt")" = "$c" ]
}

@test "after --arm, a diff names exactly the files that were read" {
  require_relatime
  printf 'a' >"$T/read-me.txt"
  printf 'b' >"$T/leave-me.txt"
  sleep 1.1
  cat "$T/read-me.txt" >/dev/null # both start invisible to further reads
  cat "$T/leave-me.txt" >/dev/null

  python3 "$SNAP" manifest --arm "$T" >"$BATS_TEST_TMPDIR/before" 2>/dev/null
  cat "$T/read-me.txt" >/dev/null # the "session"
  manifest_to "$BATS_TEST_TMPDIR/after"

  run python3 "$SNAP" diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$status" -eq 0 ]
  has_change atime "$T/read-me.txt"
  run ! grep -qF -- "leave-me.txt" <<<"$output"
}

@test "--arm does not mistake same-second-but-later-nanoseconds for observable" {
  require_relatime
  # atime in the SAME second as mtime but later in nanoseconds, with ctime safely
  # below both so only the mtime comparison decides. Comparing whole seconds would
  # call this observable and skip it -- while the kernel, which compares
  # nanoseconds, records nothing on the next read.
  printf 'x' >"$T/ns.txt"
  python3 - "$T/ns.txt" <<'PY'
import os, sys, time
base = int(time.time()) + 10          # ahead of ctime, which utime sets to now
os.utime(sys.argv[1], ns=(base * 10**9 + 900000000, base * 10**9 + 100000000))
PY
  run ! read_is_recorded "$T/ns.txt" # the kernel really does hide this read

  run python3 "$SNAP" manifest --arm "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"armed 1 file"* ]] # armed, NOT skipped as already observable
  read_is_recorded "$T/ns.txt"
}
