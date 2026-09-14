#!/usr/bin/env bats
# probes/watch-reads.py reports which files a session READ. Like the snapshot tool
# it is a measurement instrument for the leak study, so it is validated before any
# experiment leans on it: what it reports, what it must not perturb, the directory
# race it narrows, and the overflow that makes a result a lower bound.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  W="$REPO_ROOT/probes/watch-reads.py"
  T="$BATS_TEST_TMPDIR/tree"
  OUT="$BATS_TEST_TMPDIR/out"
  ERR="$BATS_TEST_TMPDIR/err"
  mkdir -p "$T"
}

# Start the watcher over $T and block until it says READY. A read before READY is
# observed by nothing, so every test must wait -- as must any real harness.
start_watch() {
  python3 "$W" "$@" "$T" >"$OUT" 2>"$ERR" &
  WPID=$!
  local i
  for i in $(seq 1 200); do
    grep -q '^READY' "$OUT" && return 0
    sleep 0.05
  done
  echo "watcher never became READY: $(cat "$ERR")" >&2
  return 1
}

# Signal the watcher, wait for it, and leave its exit status in $WSTATUS.
stop_watch() {
  kill -INT "$WPID" 2>/dev/null || true
  WSTATUS=0
  wait "$WPID" || WSTATUS=$?
}

# the paths it reported as read (stdout after the READY line)
reported() { tail -n +2 "$OUT"; }

@test "reports the files that were read and omits those that were not" {
  printf 'a' >"$T/read-me"
  printf 'b' >"$T/leave-me"
  start_watch
  cat "$T/read-me" >/dev/null
  sleep 0.2
  stop_watch
  [ "$WSTATUS" -eq 0 ]
  grep -qxF "$T/read-me" <(reported)
  run ! grep -qxF "$T/leave-me" <(reported)
}

@test "stdout opens with the READY handshake naming the watch count" {
  mkdir -p "$T/a" "$T/b"
  start_watch
  stop_watch
  # the harness contract: READY first, and only then results
  [[ "$(head -1 "$OUT")" == READY\ watches=3\ unwatched=0 ]]
}

@test "distinguishes a file opened but never read from one that was read" {
  printf 'a' >"$T/read-me"
  printf 'b' >"$T/open-only"
  start_watch --out "$BATS_TEST_TMPDIR/events"
  cat "$T/read-me" >/dev/null
  python3 -c "open('$T/open-only')"
  sleep 0.2
  stop_watch
  # only the genuinely-read file is reported as read
  grep -qxF "$T/read-me" <(reported)
  run ! grep -qxF "$T/open-only" <(reported)
  # but the open is still recorded, tagged, in the event log
  grep -q "^IN_OPEN	$T/open-only\$" "$BATS_TEST_TMPDIR/events"
  grep -q "^IN_ACCESS,IN_OPEN	$T/read-me\$" "$BATS_TEST_TMPDIR/events"
}

@test "picks up a directory created after the watch started" {
  start_watch
  mkdir "$T/late-dir"
  sleep 0.3 # let the IN_CREATE land and its watch be added
  printf 'z' >"$T/late-dir/f"
  cat "$T/late-dir/f" >/dev/null
  sleep 0.2
  stop_watch
  grep -qxF "$T/late-dir/f" <(reported)
}

@test "watching perturbs nothing: file atime and mtime are untouched" {
  printf 'payload' >"$T/f"
  local a m
  a=$(stat -c %.9X "$T/f")
  m=$(stat -c %.9Y "$T/f")
  start_watch
  sleep 0.2
  stop_watch
  # unlike snapshot.py --arm, this instrument writes nothing at all
  [ "$(stat -c %.9X "$T/f")" = "$a" ]
  [ "$(stat -c %.9Y "$T/f")" = "$m" ]
}

@test "an unreadable directory is named, not silently dropped" {
  mkdir -p "$T/locked"
  chmod 000 "$T/locked"
  start_watch
  stop_watch
  chmod 755 "$T/locked" # restore so bats can clean up
  [[ "$(head -1 "$OUT")" == *"unwatched=1"* ]]
  grep -q "not watched: $T/locked" "$ERR"
}

@test "IN_Q_OVERFLOW is reported and fails the run: the result is a lower bound" {
  # The queue holds one pending event per distinct (wd, mask, name), so overflow
  # needs more DISTINCT files than fs.inotify.max_queued_events, touched before the
  # reader drains. SIGSTOP holds the reader off rather than adding a test-only knob.
  local cap
  cap=$(cat /proc/sys/fs/inotify/max_queued_events 2>/dev/null || echo 16384)
  python3 -c "
import os, sys
d = sys.argv[1]
for i in range(int(sys.argv[2])):
    open(os.path.join(d, 'f%06d' % i), 'w').write('x')
" "$T" "$((cap + 4000))"
  start_watch
  kill -STOP "$WPID"
  python3 -c "
import os, sys
d = sys.argv[1]
for n in os.listdir(d):
    p = os.path.join(d, n)
    if os.path.isfile(p):
        open(p).read()
" "$T"
  kill -CONT "$WPID"
  sleep 0.5
  stop_watch
  [ "$WSTATUS" -eq 1 ] # a dropped-event run must not look successful
  grep -q 'IN_Q_OVERFLOW' "$ERR"
  grep -q 'lower bound' "$ERR"
}

@test "a symlink leaving the watched tree is a blind spot: the read is not reported" {
  # The arm suite pins that snapshot.py does not follow symlinks; the analogue here
  # is that inotify watches the DIRECTORIES it was given, so an open resolving to an
  # inode outside them raises nothing. That is a false-negative mode, so it is
  # pinned rather than left to be discovered mid-experiment: watch the target's
  # tree too, or accept the gap knowingly.
  mkdir -p "$T/inside" "$BATS_TEST_TMPDIR/outside/deep"
  printf 'target' >"$BATS_TEST_TMPDIR/outside/real.txt"
  printf 'deep' >"$BATS_TEST_TMPDIR/outside/deep/f"
  ln -s "$BATS_TEST_TMPDIR/outside/real.txt" "$T/inside/link-to-file"
  ln -s "$BATS_TEST_TMPDIR/outside/deep" "$T/inside/link-to-dir"
  printf 'local' >"$T/inside/real-local"
  start_watch
  cat "$T/inside/link-to-file" >/dev/null
  cat "$T/inside/link-to-dir/f" >/dev/null
  cat "$T/inside/real-local" >/dev/null
  sleep 0.2
  stop_watch
  # the read that stayed inside the tree is seen
  grep -qxF "$T/inside/real-local" <(reported)
  # the two that left it are not, under either the link path or the target path
  run ! grep -q 'link-to' <(reported)
  run ! grep -q 'outside' <(reported)
}

@test "the watcher's own rescan of a new directory is not reported as a read" {
  # Adding a watch to a directory created mid-run means scanning it. That scan must
  # not show up as the session having read the files inside, or the instrument would
  # manufacture its own findings.
  start_watch
  mkdir -p "$T/fresh/nested"
  printf 'a' >"$T/fresh/unread"
  printf 'b' >"$T/fresh/nested/also-unread"
  sleep 0.4 # long enough for IN_CREATE, the added watch and the rescan
  stop_watch
  [ "$WSTATUS" -eq 0 ]
  # nothing at all, not merely "no file": the scan also touches the new directory,
  # and reporting that would be the instrument reporting itself
  [ -z "$(reported)" ]
}
