#!/usr/bin/env bats
# models/roles/bin/inbox-wait (#274): the watcher a role arms with Claude Code's Monitor
# tool, written to .asb/bin/ by `asb --init roles`. A one-second poll on the file by path:
# exit 0 when it changes -- a write, or a rename over it as the Write tool does -- and 1
# after SECS without a change; ALIVE touched at every poll.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  IW="$REPO_ROOT/models/roles/bin/inbox-wait"
  T="$(mktemp -d "$BATS_TEST_TMPDIR/iw.XXXXXX")"
  : >"$T/inbox.md"
}

# waited PID -- its exit status in $st (`run wait` would run in a subshell, which has no
# such child).
waited() {
  st=0
  wait "$1" || st=$?
}

@test "inbox-wait: a write wakes it (exit 0), and so does a rename over the file" {
  "$IW" "$T/inbox.md" 10 &
  local pid=$!
  sleep 1.5
  printf '## 1\nhello\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  "$IW" "$T/inbox.md" 10 &
  pid=$!
  sleep 1.5
  printf '## 1\nhello\n' >"$T/new" # the same size and, within the second, the same mtime
  mv -f "$T/new" "$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
}

@test "inbox-wait: no change for SECS exits 1; a file that appears is a change" {
  local t0=$SECONDS
  run "$IW" "$T/inbox.md" 2
  [ "$status" -eq 1 ]
  ((SECONDS - t0 >= 2))
  "$IW" "$T/later.md" 10 &
  local pid=$!
  sleep 1.5
  : >"$T/later.md"
  waited "$pid"
  [ "$st" -eq 0 ]
}

@test "inbox-wait: ALIVE is touched at every poll while it waits, and not after it ends" {
  "$IW" "$T/inbox.md" 4 "$T/alive" &
  local pid=$! a b
  sleep 0.5
  [ -f "$T/alive" ]
  a="$(stat -c %Y "$T/alive")"
  sleep 2.2
  b="$(stat -c %Y "$T/alive")"
  ((b > a))
  waited "$pid"
  [ "$st" -eq 1 ]
  a="$(stat -c %Y "$T/alive")"
  sleep 1.2
  [ "$(stat -c %Y "$T/alive")" = "$a" ]
}
