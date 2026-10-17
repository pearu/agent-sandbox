#!/usr/bin/env bats
# models/roles/bin/inbox-wait (#274, #288): the watcher a role arms with the Bash tool in
# the background, written to .asb/bin/ by `asb --init roles`. A one-second poll on each
# FILE by path: exit 0 at the first change of any -- a write, or a rename over it as the
# Write tool does -- printing its path, and 1 after -t SECS without a change; -a ALIVE
# touched at every poll.

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
  "$IW" -t 10 "$T/inbox.md" &
  local pid=$!
  sleep 1.5
  printf '## 1\nhello\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  "$IW" -t 10 "$T/inbox.md" &
  pid=$!
  sleep 1.5
  printf '## 1\nhello\n' >"$T/new" # the same size and, within the second, the same mtime
  mv -f "$T/new" "$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
}

@test "inbox-wait: of several files, the first that changes wakes it and its path is printed" {
  : >"$T/a.md"
  : >"$T/b.md"
  "$IW" -t 10 "$T/a.md" "$T/inbox.md" "$T/b.md" >"$T/out" &
  local pid=$!
  sleep 1.5
  printf 'ack 1\n' >>"$T/b.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/b.md" ]
  "$IW" -t 10 "$T/a.md" "$T/inbox.md" "$T/b.md" >"$T/out" &
  pid=$!
  sleep 1.5
  printf 'ack 1\n' >>"$T/a.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/a.md" ]
}

@test "inbox-wait: no change for -t SECS exits 1, printing nothing; a file that appears is a change" {
  local t0=$SECONDS
  run "$IW" -t 2 "$T/inbox.md" "$T/other.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  ((SECONDS - t0 >= 2))
  "$IW" -t 10 "$T/inbox.md" "$T/later.md" >"$T/out" &
  local pid=$!
  sleep 1.5
  : >"$T/later.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/later.md" ]
}

@test "inbox-wait: with no -t (or -t 0) it waits for ever" {
  "$IW" "$T/inbox.md" &
  local pid=$!
  "$IW" -t 0 "$T/inbox.md" &
  local pid0=$!
  sleep 2.5
  kill -0 "$pid" && kill -0 "$pid0"
  printf 'x\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  waited "$pid0"
  [ "$st" -eq 0 ]
}

@test "inbox-wait: -a ALIVE is touched at every poll while it waits, and not after it ends" {
  "$IW" -t 4 -a "$T/alive" "$T/inbox.md" &
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

@test "inbox-wait: the old positional form, no FILE, or a bad option is refused with a usage line (exit 2)" {
  local t0=$SECONDS
  run "$IW" "$T/inbox.md" 0 "$T/alive"
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: inbox-wait [-t SECS] [-a ALIVE] FILE..." ]]
  [ ! -e "$T/alive" ]
  run "$IW" "$T/inbox.md" 2
  [ "$status" -eq 2 ]
  ((SECONDS - t0 < 2))
  run "$IW"
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: "* ]]
  run "$IW" -t soon "$T/inbox.md"
  [ "$status" -eq 2 ]
  run "$IW" -x "$T/inbox.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: inbox-wait"* ]]
}
