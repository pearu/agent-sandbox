#!/usr/bin/env bats
# probes/watch-reads.py is a HOST-side inotify watch, but the sessions the leak
# study measures run inside bwrap, in their own mount namespace, reading files
# through bind mounts. The tool's documentation claims the watch still sees those
# reads because inotify follows the inode rather than the mount. That is a claim
# about the kernel, so it is pinned here against real bwrap rather than asserted.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  W="$REPO_ROOT/probes/watch-reads.py"
  T="$BATS_TEST_TMPDIR/tree"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$T"
}

start_watch() {
  python3 "$W" "$T" >"$OUT" 2>"$BATS_TEST_TMPDIR/err" &
  WPID=$!
  local i
  for i in $(seq 1 200); do
    grep -q '^READY' "$OUT" && return 0
    sleep 0.05
  done
  return 1
}

stop_watch() {
  kill -INT "$WPID" 2>/dev/null || true
  wait "$WPID" || true
}

reported() { tail -n +2 "$OUT"; }

@test "a read inside the sandbox is seen by the host watch, through a read-write bind" {
  printf 'canary' >"$T/rw-file"
  printf 'other' >"$T/untouched"
  start_watch
  bwrap --ro-bind / / --bind "$T" "$T" --dev /dev --proc /proc --unshare-all \
    --chdir "$T" /bin/cat rw-file >/dev/null
  sleep 0.3
  stop_watch
  grep -qxF "$T/rw-file" <(reported)
  run ! grep -qxF "$T/untouched" <(reported)
}

@test "a read inside the sandbox is seen through a read-only bind too" {
  # the engine exposes most paths read-only, so this is the common case
  printf 'canary' >"$T/ro-file"
  start_watch
  bwrap --ro-bind / / --ro-bind "$T" "$T" --dev /dev --proc /proc --unshare-all \
    --chdir "$T" /bin/cat ro-file >/dev/null
  sleep 0.3
  stop_watch
  grep -qxF "$T/ro-file" <(reported)
}
