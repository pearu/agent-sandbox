#!/usr/bin/env bats
# models/roles/bin/inbox-wait (#274, #288): the watcher a role arms with the Bash tool in
# the background, written to .asb/bin/ by `asb --init roles`. A one-second poll on each
# FILE by path: exit 0 at the first change of any -- a write, or a rename over it as the
# Write tool does -- printing its path, and 1 after -t SECS without a change; -a ALIVE
# touched at every poll; -s STATE carries the baseline from one run to the next (#339).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  IW="$REPO_ROOT/models/roles/bin/inbox-wait"
  T="$(mktemp -d "$BATS_TEST_TMPDIR/iw.XXXXXX")"
  : >"$T/inbox.md"
}

# usec -- microseconds since the epoch.
usec() { echo "${EPOCHREALTIME/./}"; }

# changed_in_a_run OPTS... -- a run of inbox-wait with OPTS on "$T/inbox.md" that a write
# during it ends (exit 0).
changed_in_a_run() {
  "$IW" -t 10 "$@" "$T/inbox.md" >/dev/null &
  local pid=$!
  sleep 1.5
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
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

@test "inbox-wait: a file removed is a change -- the Supervisor waits so for a reset marker to be taken" {
  : >"$T/r.reset"
  "$IW" -t 10 "$T/r.reset" >"$T/out" &
  local pid=$!
  sleep 1.5
  rm -f "$T/r.reset"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/r.reset" ]
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
  [[ "$output" == "usage: inbox-wait [-t SECS] [-a ALIVE] [-s STATE] FILE..." ]]
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

@test "inbox-wait -s: a change made between two runs is reported by the second at once; without -s it is missed (#339)" {
  changed_in_a_run -s "$T/st"
  printf 'done 2\n' >>"$T/inbox.md" # no watcher runs now
  local t0
  t0="$(usec)"
  run "$IW" -t 3 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/inbox.md" ]
  (($(usec) - t0 < 1000000))
  # and that change is now the baseline: the next run waits
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
  # today's behaviour, kept without -s
  changed_in_a_run
  printf 'done 3\n' >>"$T/inbox.md"
  run "$IW" -t 2 "$T/inbox.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "inbox-wait -s: of two FILEs changed in one poll, one run reports each, the second at once; paths with a space and a tab" {
  local a="$T/a b.md" b="$T/c"$'\t'"d.md" t0
  : >"$a"
  : >"$b"
  "$IW" -t 10 -s "$T/st" "$a" "$b" >"$T/out" &
  local pid=$!
  sleep 1.5
  printf 'ack 1\n' >>"$a"
  printf 'ack 1\n' >>"$b"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$a" ]
  t0="$(usec)"
  run "$IW" -t 3 -s "$T/st" "$a" "$b"
  [ "$status" -eq 0 ]
  [ "$output" = "$b" ]
  (($(usec) - t0 < 1000000))
  run "$IW" -t 1 -s "$T/st" "$a" "$b"
  [ "$status" -eq 1 ]
  # one line per FILE, its state, a tab and its path; no temporary file left beside it
  [ "$(wc -l <"$T/st")" -eq 2 ]
  [ "$(cut -f2- "$T/st")" = "$(printf '%s\n' "$a" "$b")" ]
  [ "$(cut -f1 "$T/st" | sed -n 2p)" = "$(stat -c '%y %i %s' "$b")" ]
  [ "$(find "$T" -name 'st*' | wc -l)" -eq 1 ]
}

@test "inbox-wait -s: -t running out leaves STATE as it was" {
  changed_in_a_run -s "$T/st"
  local before
  before="$(stat -c '%y %i' "$T/st") $(cksum <"$T/st")"
  run "$IW" -t 2 -s "$T/st" "$T/inbox.md" "$T/other.md"
  [ "$status" -eq 1 ]
  [ "$(stat -c '%y %i' "$T/st") $(cksum <"$T/st")" = "$before" ]
}

@test "inbox-wait -s: a missing or empty STATE is today's behaviour; an entry for a FILE no longer watched is kept" {
  printf 'x\n' >>"$T/inbox.md"
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
  [ ! -e "$T/st" ]
  : >"$T/st"
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
  [ ! -s "$T/st" ]
  : >"$T/b.md"
  "$IW" -t 10 -s "$T/st" "$T/inbox.md" "$T/b.md" >/dev/null &
  local pid=$! line
  sleep 1.5
  printf 'y\n' >>"$T/b.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  line="$(grep -F "	$T/inbox.md" "$T/st")"
  # a run over b.md alone advances b.md and keeps inbox.md's entry as it is
  "$IW" -t 10 -s "$T/st" "$T/b.md" >/dev/null &
  pid=$!
  sleep 1.5
  printf 'z\n' >>"$T/b.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(grep -F "	$T/inbox.md" "$T/st")" = "$line" ]
  [ "$(grep -F "	$T/b.md" "$T/st" | cut -f1)" = "$(stat -c '%y %i %s' "$T/b.md")" ]
  [ "$(wc -l <"$T/st")" -eq 2 ]
  # an entry is a FILE's by its whole path as given: inbox.md's is not $T/inbox.md's
  { printf 'not a state\tinbox.md\n' && cat "$T/st"; } >"$T/st.new" # first, so a lookup meets it first
  mv -f "$T/st.new" "$T/st"
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
  grep -qxF "not a state	inbox.md" "$T/st"
}

@test "inbox-wait -s: a run killed while it waits leaves STATE as it was, so the next run reports a change made meanwhile" {
  changed_in_a_run -s "$T/st"
  local before t0
  before="$(stat -c %i "$T/st") $(cat "$T/st")"
  "$IW" -s "$T/st" "$T/inbox.md" &
  local pid=$!
  sleep 1.5
  kill "$pid"
  waited "$pid"
  [ "$st" -ne 0 ]
  [ "$(stat -c %i "$T/st") $(cat "$T/st")" = "$before" ] # not even rewritten
  printf 'done 2\n' >>"$T/inbox.md"
  t0="$(usec)"
  run "$IW" -t 3 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/inbox.md" ]
  (($(usec) - t0 < 1000000))
}

@test "inbox-wait -s: refused at once (exit 2): STATE's directory missing or not writable, a FILE path with a newline, STATE among the FILEs, an empty STATE, STATE a directory or unreadable" {
  local t0=$SECONDS
  run "$IW" -t 5 -s "$T/no/st" "$T/inbox.md"
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -s $T/no/st: its directory is missing or not writable" ]
  mkdir "$T/ro"
  chmod 555 "$T/ro"
  run "$IW" -t 5 -s "$T/ro/st" "$T/inbox.md"
  chmod 755 "$T/ro"
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -s $T/ro/st: its directory is missing or not writable" ]
  [ ! -e "$T/ro/st" ]
  run "$IW" -t 5 -s "$T/st" "$T/inbox.md" "$T/a"$'\n'"b"
  [ "$status" -eq 2 ]
  [[ "$output" == *"a FILE path holds a newline"* ]]
  run "$IW" -t 5 -s "$T/st" "$T/inbox.md" "$T/st"
  [ "$status" -eq 2 ]
  [[ "$output" == *"STATE is also a FILE"* ]]
  run "$IW" -t 5 -s '' "$T/inbox.md"
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: "* ]]
  mkdir "$T/sd"
  run "$IW" -t 5 -s "$T/sd" "$T/inbox.md"
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -s $T/sd: a directory" ]
  : >"$T/su"
  chmod 000 "$T/su"
  run "$IW" -t 5 -s "$T/su" "$T/inbox.md"
  chmod 644 "$T/su"
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -s $T/su: not readable" ]
  ((SECONDS - t0 < 2))
  [ ! -e "$T/st" ]
}

@test "inbox-wait -s: STATE among the FILEs by another spelling is refused (exit 2) once STATE exists -- the first run makes it, the next is refused" {
  changed_in_a_run -s "$T/st"
  [ -f "$T/st" ]
  cd "$T"
  run "$IW" -t 5 -s st inbox.md ./st
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -s st: STATE is also a FILE, so writing it would wake the next run" ]
  ln "$T/st" "$T/hard"
  run "$IW" -t 5 -s "$T/st" "$T/inbox.md" "$T/hard"
  [ "$status" -eq 2 ]
}

# The two stub tests below put a mktemp or an mv first on PATH. Under busybox sh they
# fail, because its applets run ahead of PATH: a property of the test, not the script,
# which ships as #!/bin/sh -- dash on the hosts and in CI.
@test "inbox-wait -s: at exit 0 the path is printed before STATE is written, from a temporary beside it, and the reported FILE's entry is the state its poll saw" {
  # a mktemp first on PATH runs as STATE is written: it records what the run has printed
  # by then and its own arguments, and writes to the inbox after the poll that saw the change
  local real pid
  real="$(command -v mktemp)"
  mkdir "$T/bin"
  printf '#!/bin/sh\ncat "%s" >"%s"\nprintf "%%s\\n" "$*" >"%s"\nprintf "late\\n" >>"%s"\nexec "%s" "$@"\n' \
    "$T/out" "$T/seen" "$T/args" "$T/inbox.md" "$real" >"$T/bin/mktemp"
  chmod +x "$T/bin/mktemp"
  PATH="$T/bin:$PATH" "$IW" -t 10 -s "$T/st" "$T/inbox.md" >"$T/out" &
  pid=$!
  sleep 1.5
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  # printed first, so a kill while STATE is written leaves it behind, never ahead
  [ "$(cat "$T/seen")" = "$T/inbox.md" ]
  # the temporary is made in STATE's directory, so the rename over it is atomic
  [ "$(dirname "$(cat "$T/args")")" = "$T" ]
  # the late write is not in STATE: the next run reports it at once
  run "$IW" -t 3 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/inbox.md" ]
}

@test "inbox-wait -s: STATE that cannot be written at exit 0: the path printed, exit 0, a line on stderr, no temporary left" {
  mkdir "$T/bin"
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/mv"
  chmod +x "$T/bin/mv"
  PATH="$T/bin:$PATH" "$IW" -t 10 -s "$T/st" "$T/inbox.md" >"$T/out" 2>"$T/err" &
  local pid=$!
  sleep 1.5
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/inbox.md" ]
  [ "$(cat "$T/err")" = "inbox-wait: could not write $T/st; the next run reports this change again" ]
  [ -z "$(find "$T" -maxdepth 1 -name 'st*')" ]
}
