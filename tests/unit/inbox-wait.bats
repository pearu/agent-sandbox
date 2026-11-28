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

# mv_fails -- put an mv first in $T/bin that fails while $T/mvfail exists, as on a full
# disk; prefix a command with PATH="$T/bin:$PATH" to use it. A run then saves its
# baseline at start, and fails at the next save once the flag is made.
mv_fails() {
  local real
  real="$(command -v mv)"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\n[ ! -e "%s" ] || exit 1\nexec "%s" "$@"\n' "$T/mvfail" "$real" >"$T/bin/mv"
  chmod +x "$T/bin/mv"
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

@test "inbox-wait -s: -t running out leaves STATE at the baseline the run started from" {
  changed_in_a_run -s "$T/st"
  local before
  before="$(grep -F "	$T/inbox.md" "$T/st")"
  run "$IW" -t 2 -s "$T/st" "$T/inbox.md" "$T/other.md"
  [ "$status" -eq 1 ]
  [ "$(grep -F "	$T/inbox.md" "$T/st")" = "$before" ] # its entry as it was
  grep -qxF "	$T/other.md" "$T/st"                    # a new FILE's: its state at start (none)
  [ "$(wc -l <"$T/st")" -eq 2 ]
}

@test "inbox-wait -s: a missing or empty STATE starts from now, and is written at start; an entry for a FILE no longer watched is kept" {
  printf 'x\n' >>"$T/inbox.md"
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]                                              # from now: x is no change
  [ "$(cut -f1 "$T/st")" = "$(stat -c '%y %i %s' "$T/inbox.md")" ] # the baseline, written at start
  : >"$T/st"
  printf 'x\n' >>"$T/inbox.md"
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
  [ "$(cut -f1 "$T/st")" = "$(stat -c '%y %i %s' "$T/inbox.md")" ]
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

@test "inbox-wait -s: a run killed while it waits leaves STATE at its baseline, so the next run reports a change made meanwhile" {
  changed_in_a_run -s "$T/st"
  local before t0
  before="$(cat "$T/st")"
  "$IW" -s "$T/st" "$T/inbox.md" &
  local pid=$!
  sleep 1.5
  kill "$pid"
  waited "$pid"
  [ "$st" -ne 0 ]
  [ "$(cat "$T/st")" = "$before" ] # written again at start, the same
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
  mv_fails
  PATH="$T/bin:$PATH" "$IW" -t 10 -s "$T/st" "$T/inbox.md" >"$T/out" 2>"$T/err" &
  local pid=$!
  sleep 1.5 # its baseline saved at start, before the flag
  : >"$T/mvfail"
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$pid"
  [ "$st" -eq 0 ]
  [ "$(cat "$T/out")" = "$T/inbox.md" ]
  [ "$(cat "$T/err")" = "inbox-wait: could not write $T/st; the next run reports this change again" ]
  [ -z "$(find "$T" -maxdepth 1 -name 'st.*')" ]
}

@test "inbox-wait -s: a STATE that cannot be written refuses the run at its start (exit 2), naming no FILE; once cleared, the change is reported once" {
  mv_fails
  run "$IW" -t 2 -s "$T/st" "$T/inbox.md" # a baseline
  [ "$status" -eq 1 ]
  : >"$T/mvfail"
  printf 'done 1\n' >>"$T/inbox.md"
  local t0
  t0="$(usec)"
  PATH="$T/bin:$PATH" run "$IW" -t 10 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 2 ]
  (($(usec) - t0 < 1000000))
  [ "$output" = "inbox-wait: -s $T/st: could not write it, so nothing it reports could be saved" ]
  [ -z "$(find "$T" -maxdepth 1 -name 'st.*')" ]
  rm "$T/mvfail"
  PATH="$T/bin:$PATH" run "$IW" -t 3 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/inbox.md" ]
  run "$IW" -t 1 -s "$T/st" "$T/inbox.md"
  [ "$status" -eq 1 ]
}

# ---- the stream (-f): the Supervisor's watch under a tool that takes each line as an
# event. Each test runs it in the background with a short -t and asserts on its lines.

# stream ARGS... -- start inbox-wait -f -s "$T/st" ARGS in the background, its output in
# $T/out and its errors in $T/err; its pid in $spid. Returns once it has taken its
# baseline: it writes STATE anew (a rename, so a new inode) right after, or says on
# stderr that it could not -- not after a fixed sleep, which a loaded host outlasts --
# or once it has ended. A -1 run that ends at its first poll writes STATE twice before
# this looks, and ext4 gives the second rename the inode the first one freed: STATE's
# inode is then the one it had before (seen on CI's kcov shard), so the end counts too.
stream() {
  local before _
  before="$(stat -c %i "$T/st" 2>/dev/null)" || true
  "$IW" -f -s "$T/st" "$@" >"$T/out" 2>"$T/err" &
  spid=$!
  for _ in $(seq 100); do
    [ "$(stat -c %i "$T/st" 2>/dev/null)" = "$before" ] || break
    [ ! -s "$T/err" ] || break
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.1
  done
}

# line N -- line N of the stream's output.
line() { sed -n "${1}p" "$T/out"; }

# lines -- how many lines the stream has printed.
lines() { wc -l <"$T/out"; }

teardown() {
  [ -z "${spid:-}" ] || kill "$spid" 2>/dev/null || true
}

@test "inbox-wait -f: an 'ack N' append prints nothing and its baseline advances, so a later 'done N' is one line" {
  stream -i '^ack [0-9]+$' -t 6 "$T/inbox.md"
  printf 'ack 1\n' >>"$T/inbox.md"
  sleep 1.5
  [ "$(lines)" -eq 0 ]
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: a 'done' and an 'ack' in one append print one line, the 'done'; several -i are alternatives" {
  stream -i '^ack [0-9]+$' -i '^- note' -t 4 "$T/inbox.md"
  printf 'done 1\nack 2\n- note on 2\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: without -i every append is an event, its last line shown" {
  stream -t 4 "$T/inbox.md"
  printf 'ack 1\nwork\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: work" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: a rename over a FILE, a FILE appearing, vanishing and shrinking each print 'PATH changed'" {
  printf 'one\ntwo\n' >"$T/shrink.md"
  : >"$T/gone.md"
  stream -i '^ack [0-9]+$' -t 7 "$T/inbox.md" "$T/new.md" "$T/gone.md" "$T/shrink.md"
  printf 'ack 1\n' >"$T/x"
  mv -f "$T/x" "$T/inbox.md"
  sleep 1.2
  : >"$T/new.md"
  sleep 1.2
  rm "$T/gone.md"
  sleep 1.2
  printf 'one\n' >"$T/shrink.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md changed" ]
  [ "$(line 2)" = "$T/new.md changed" ]
  [ "$(line 3)" = "$T/gone.md changed" ]
  [ "$(line 4)" = "$T/shrink.md changed" ]
  [ "$(lines)" -eq 4 ]
}

@test "inbox-wait -f: two FILEs changed in one poll print two lines" {
  : >"$T/b.md"
  stream -t 4 "$T/inbox.md" "$T/b.md"
  printf 'done 1\n' >>"$T/b.md"
  printf 'done 2\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 2" ]
  [ "$(line 2)" = "$T/b.md: done 1" ]
  [ "$(lines)" -eq 2 ]
}

@test "inbox-wait -f: control characters in an append are shown escaped, and make no second line" {
  stream -t 4 "$T/inbox.md"
  printf 'done 1\033]0;x\007 \033[2J\rforged: done 9\177\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1^[]0;x^G ^[[2J^Mforged: done 9^?" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: a NUL byte or a byte that is not UTF-8 in an append is no 'binary file' line: the text is shown" {
  LC_ALL=C.UTF-8 stream -i '^ack [0-9]+$' -t 5 "$T/inbox.md" # -i: through the filter
  printf 'done 1\000 x\n' >>"$T/inbox.md"
  sleep 1.2
  printf 'done 2 \377 y\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1 x" ]
  [ "$(line 2)" = "$T/inbox.md: done 2 "$'\377'" y" ]
  [ "$(lines)" -eq 2 ]
}

@test "inbox-wait -f: a long line is cut at 160 bytes, back to a whole UTF-8 character, and marked" {
  local long
  long="$(printf '%0159d' 0)"
  stream -t 4 "$T/inbox.md"
  printf '%s—and more\n' "$long" >>"$T/inbox.md" # the dash's 3 bytes straddle byte 160
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: $long ..." ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: a change made while no stream ran is printed by the first poll (STATE)" {
  stream -t 2 "$T/inbox.md"
  waited "$spid"
  [ "$(lines)" -eq 0 ]
  printf 'done 1\n' >>"$T/inbox.md"
  stream -t 2 "$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: STATE not written after a print (killed between, or mv failing): the next run prints that change again, once" {
  mv_fails
  "$IW" -f -s "$T/st" -t 4 "$T/inbox.md" >/dev/null 2>&1 # STATE has a baseline
  PATH="$T/bin:$PATH" stream -t 4 "$T/inbox.md"
  : >"$T/mvfail" # after its save at start
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ] # its own baseline advanced: printed once in this run
  grep -qxF "inbox-wait: could not write $T/st; the next run reports these changes again" "$T/err"
  rm "$T/mvfail"
  stream -t 3 "$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
  stream -t 2 "$T/inbox.md"
  waited "$spid"
  [ "$(lines)" -eq 0 ]
}

@test "inbox-wait -f: a STATE that cannot be written refuses the stream at its start (exit 2), printing no line; once cleared, the change is printed once" {
  mv_fails
  "$IW" -f -s "$T/st" -t 2 "$T/inbox.md" >/dev/null 2>&1 # STATE has a baseline
  : >"$T/mvfail"
  printf 'done 1\n' >>"$T/inbox.md"
  local t0
  t0="$(usec)"
  PATH="$T/bin:$PATH" run "$IW" -f -s "$T/st" -t 10 "$T/inbox.md"
  [ "$status" -eq 2 ]
  (($(usec) - t0 < 1000000))
  [ "$output" = "inbox-wait: -s $T/st: could not write it, so nothing it reports could be saved" ]
  rm "$T/mvfail"
  stream -t 3 "$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: the line is printed before STATE is written" {
  local real
  real="$(command -v mktemp)"
  mkdir "$T/bin"
  # a mktemp first on PATH runs as STATE is written: it records what was printed by then,
  # in brackets, one pair per write
  printf '#!/bin/sh\n{ printf "["; cat "%s"; printf "]"; } >>"%s"\nexec "%s" "$@"\n' "$T/out" "$T/seen" "$real" >"$T/bin/mktemp"
  chmod +x "$T/bin/mktemp"
  "$IW" -f -s "$T/st" -t 4 "$T/inbox.md" >/dev/null # STATE has a baseline
  PATH="$T/bin:$PATH" stream -t 4 "$T/inbox.md"
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  # the write at start, before any line; then the one after the poll's line, and no other
  [ "$(cat "$T/seen")" = "[][$T/inbox.md: done 1"$'\n'"]" ]
}

@test "inbox-wait -f: a second stream on the same STATE prints that one runs, with its pid, and exits 0, printing no event" {
  stream -t 8 "$T/inbox.md"
  local first=$spid
  run "$IW" -f -s "$T/st" -t 8 "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "inbox-wait: a watcher already runs on $T/st (pid $first)" ]
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$first"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: a stream that died holds nothing: the next one starts at once and reports" {
  stream -t 30 "$T/inbox.md"
  kill -9 "$spid"
  waited "$spid"
  printf 'done 1\n' >>"$T/inbox.md"
  local t0
  t0="$(usec)"
  run "$IW" -f -s "$T/st" -t 2 "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/inbox.md: done 1" ]
  (($(usec) - t0 < 2500000)) # no wait on a lock: the first poll, then -t
}

@test "inbox-wait -f: -t ends it with status 0 and STATE saved; -a is touched while it runs" {
  stream -t 4 -a "$T/alive" "$T/inbox.md"
  printf 'done 1\n' >>"$T/inbox.md"
  sleep 1.2
  local a1
  a1="$(stat -c %Y.%y "$T/alive")"
  sleep 1.2
  [ "$(stat -c %Y.%y "$T/alive")" != "$a1" ]
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(cut -f2 "$T/st")" = "$T/inbox.md" ]
  [ "$(cut -d' ' -f5 "$T/st" | cut -f1)" = "$(stat -c %s "$T/inbox.md")" ]
}

@test "inbox-wait -f: refused (exit 2): -f without -s, -i without -f, an -i that is no ERE" {
  run "$IW" -f -t 2 "$T/inbox.md"
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: "* ]]
  run "$IW" -i '^ack' -t 2 "$T/inbox.md"
  [ "$status" -eq 2 ]
  [[ "$output" == "usage: "* ]]
  run "$IW" -f -s "$T/st" -i '(' -t 2 "$T/inbox.md"
  [ "$status" -eq 2 ]
  [ "$output" = "inbox-wait: -i (: not an extended regular expression" ]
  [ ! -e "$T/st.lock" ]
}

@test "inbox-wait -f: a blank line is never the event's line: a blank and an 'ack' print nothing, and a report that ends blank shows its last line" {
  stream -i '^ack [0-9]+$' -t 5 "$T/inbox.md"
  printf '\nack 1\n' >>"$T/inbox.md"
  sleep 1.5
  [ "$(lines)" -eq 0 ]
  printf '## To S\ndone 1\n\n \n' >>"$T/inbox.md"
  waited "$spid"
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f: -t is seconds by the clock, not a count of polls" {
  mkdir "$T/bin"
  # each poll's sleep takes 2 s: 4 polls would be 8 s
  printf '#!/bin/sh\nexec %s 2\n' "$(command -v sleep)" >"$T/bin/sleep"
  chmod +x "$T/bin/sleep"
  local t0
  t0="$(usec)"
  PATH="$T/bin:$PATH" run "$IW" -f -s "$T/st" -t 4 "$T/inbox.md"
  [ "$status" -eq 0 ]
  (($(usec) - t0 < 7000000))
}

# ---- one event (-f -1): the Supervisor's watch as a background command, whose end is
# the wake. The stream, ending after the first poll that printed a line.

@test "inbox-wait -f -1: the first event line ends it (exit 0), printed, with STATE saved" {
  stream -1 -i '^ack [0-9]+$' -t 30 "$T/inbox.md"
  local t0
  t0="$(usec)"
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  (($(usec) - t0 < 10000000)) # at the event, not at -t
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
  [ "$(cut -d' ' -f5 "$T/st" | cut -f1)" = "$(stat -c %s "$T/inbox.md")" ]
}

@test "inbox-wait -f -1: two FILEs changed in one poll print both lines, then it ends" {
  : >"$T/b.md"
  stream -1 -t 30 "$T/inbox.md" "$T/b.md"
  printf 'done 1\n' >>"$T/b.md"
  printf 'done 2\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 2" ]
  [ "$(line 2)" = "$T/b.md: done 1" ]
  [ "$(lines)" -eq 2 ]
  # both entries advanced: the next run has nothing to report
  stream -1 -t 2 "$T/inbox.md" "$T/b.md"
  waited "$spid"
  [ "$(lines)" -eq 0 ]
}

@test "inbox-wait -f -1: an 'ack N' append does not end it and its baseline advances; a later 'done N' ends it with one line" {
  stream -1 -i '^ack [0-9]+$' -t 30 "$T/inbox.md"
  printf '\nack 1\n' >>"$T/inbox.md"
  local size _
  size="$(stat -c %s "$T/inbox.md")"
  for _ in $(seq 50); do
    [ "$(cut -d' ' -f5 "$T/st" | cut -f1)" != "$size" ] || break
    sleep 0.1
  done
  [ "$(cut -d' ' -f5 "$T/st" | cut -f1)" = "$size" ] # the filtered poll saved its baseline
  sleep 1.2
  kill -0 "$spid" # still waiting
  [ "$(lines)" -eq 0 ]
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f -1: a FILE renamed over ends it with 'PATH changed', and so does one that appears" {
  stream -1 -i '^ack [0-9]+$' -t 30 "$T/inbox.md" "$T/asking"
  printf 'ack 1\n' >"$T/x"
  mv -f "$T/x" "$T/inbox.md" # as the Write tool does: the content would be dropped
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md changed" ]
  [ "$(lines)" -eq 1 ]
  stream -1 -t 30 "$T/inbox.md" "$T/asking"
  printf 'since=2026-11-27T10:00:00Z\n' >"$T/asking"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/asking changed" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f -1: -t ends it with no line (exit 0); a change made before the next run is printed by its first poll" {
  stream -1 -t 2 "$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(lines)" -eq 0 ]
  printf 'done 1\n' >>"$T/inbox.md"
  local t0
  t0="$(usec)"
  stream -1 -t 30 "$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  (($(usec) - t0 < 10000000))
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f -1: a save that fails ends the run after its lines; the next run refuses at its start while it fails, and reports the lines once it is cleared" {
  local real t0
  real="$(command -v mv)"
  mkdir "$T/bin"
  # an mv that fails while $T/mvfail exists, as on a full disk
  printf '#!/bin/sh\n[ ! -e "%s" ] || exit 1\nexec "%s" "$@"\n' "$T/mvfail" "$real" >"$T/bin/mv"
  chmod +x "$T/bin/mv"
  PATH="$T/bin:$PATH" stream -1 -t 30 "$T/inbox.md"
  : >"$T/mvfail"
  t0="$(usec)"
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  (($(usec) - t0 < 5000000)) # it ends at the event, not at -t
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
  grep -qxF "inbox-wait: could not write $T/st; the next run reports these changes again" "$T/err"
  # the failure persists: the next run refuses at its start, reporting nothing
  t0="$(usec)"
  PATH="$T/bin:$PATH" run "$IW" -f -1 -s "$T/st" -t 30 "$T/inbox.md"
  [ "$status" -eq 2 ]
  (($(usec) - t0 < 1000000))
  [ "$output" = "inbox-wait: -s $T/st: could not write it, so nothing it reports could be saved" ]
  # cleared: the next run reports the lines, once
  rm "$T/mvfail"
  PATH="$T/bin:$PATH" stream -1 -t 30 "$T/inbox.md"
  waited "$spid"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
  stream -1 -t 2 "$T/inbox.md"
  waited "$spid"
  [ "$(lines)" -eq 0 ]
}

@test "inbox-wait -f -1: a second run on the same STATE prints that one runs, with its pid, and ends at once (exit 0); the first reports the event" {
  stream -1 -t 30 "$T/inbox.md"
  local first=$spid t0
  t0="$(usec)"
  run "$IW" -f -1 -s "$T/st" -t 30 "$T/inbox.md"
  [ "$status" -eq 0 ]
  [ "$output" = "inbox-wait: a watcher already runs on $T/st (pid $first)" ]
  (($(usec) - t0 < 5000000)) # the lock's 2 s wait, not -t
  printf 'done 1\n' >>"$T/inbox.md"
  waited "$first"
  [ "$st" -eq 0 ]
  [ "$(line 1)" = "$T/inbox.md: done 1" ]
  [ "$(lines)" -eq 1 ]
}

@test "inbox-wait -f -1: refused (exit 2) without -f, with a usage line that names it" {
  run "$IW" -1 -s "$T/st" -t 2 "$T/inbox.md"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "usage: inbox-wait [-t SECS] [-a ALIVE] [-s STATE] FILE..." ]
  [ "${lines[1]}" = "       inbox-wait -f [-1] -s STATE [-i PATTERN]... [-t SECS] [-a ALIVE] FILE..." ]
  [ ! -e "$T/st" ]
}
