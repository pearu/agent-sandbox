#!/usr/bin/env bats
# The wrapper role (--wrap), invoked by Claude Code as CLAUDE_CODE_PROCESS_WRAPPER
# to sandbox a process the agent spawns. Stub bwrap, so these assert on the argv
# and on whether the sandbox was entered at all -- never a real sandbox.
#
# The engine's discovered native binary ($profile_bin) is the harness's stub
# claude, which echoes "stub-agent argv: $*"; a host passthrough (exec) shows
# that echo with bwrap never called, a sandboxed worker shows it inside bwrap's
# recorded argv.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  NATIVE="$H/home/.local/share/claude/versions/2.1.300/claude"
  SOCKDIR="/tmp/cc-daemon-1000/b1952d0c/spare"
  LAUNCHER="$H/bin/claude" # our launcher; the wrapper must discard it for the native
  # the daemon owns these dirs in production; the launch requires rw-bind
  # sources to exist, so create them here.
  mkdir -p "$SOCKDIR" /tmp/cc-daemon-1000/b1952d0c/ctl
}

@test "a --bg-spare worker is sandboxed: native runs it inside bwrap, its socket dir bound" {
  run_engine -- claude --wrap "$LAUNCHER" --bg-spare "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  argv_has --bind "$SOCKDIR" "$SOCKDIR"                 # the rendezvous dir is bound rw
  argv_has "$NATIVE" --bg-spare "$SOCKDIR/a.claim.sock" # the native binary runs the worker args
}

@test "the wrapper discards the launcher Claude passes and runs the discovered native binary" {
  # Claude resolves `claude` to our launcher; the wrapper must not re-enter it.
  run_engine -- claude --wrap "$LAUNCHER" --bg-spare "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  argv_index "$NATIVE" >/dev/null                               # native is in the command
  run ! argv_has "$LAUNCHER" --bg-spare "$SOCKDIR/a.claim.sock" # the launcher is not
}

@test "every .sock dir named in the worker argv is bound, deduplicated, and nothing else" {
  local other="/tmp/cc-daemon-1000/b1952d0c/ctl"
  run_engine -- claude --wrap "$LAUNCHER" --bg-pty-host-not-a-verb \
    "$SOCKDIR/a.pty.sock" 200 50 "$other/c.sock" "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  argv_has --bind "$SOCKDIR" "$SOCKDIR"
  argv_has --bind "$other" "$other"
  # the spare dir is named by two sockets but bound once
  local n
  n=$(printf '%s\n' "${ARGV[@]}" | grep -cx -- "$SOCKDIR" || true)
  [ "$n" -eq 2 ] # one --bind SRC DEST pair == the token appears exactly twice
}

@test "daemon run is a host passthrough: the native binary runs it, bwrap is never entered" {
  run_engine -- claude --wrap "$LAUNCHER" daemon run --origin transient
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ] # bwrap never called
  [[ "$output" == *"stub-agent argv: daemon run --origin transient"* ]]
}

@test "--bg-pty-host is a host passthrough (it spawns and wraps the spare itself)" {
  run_engine -- claude --wrap "$LAUNCHER" --bg-pty-host "$SOCKDIR/a.pty.sock" 200 50 \
    -- /path/wrap "$NATIVE" --bg-spare "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ] # not sandboxed here
  [[ "$output" == *"stub-agent argv: --bg-pty-host"* ]]
}

@test "an unknown worker verb is sandboxed (fail safe), not passed through" {
  run_engine -- claude --wrap "$LAUNCHER" --bg-some-future-worker "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # bwrap WAS entered
  argv_has "$NATIVE" --bg-some-future-worker "$SOCKDIR/a.claim.sock"
}

@test "a wrapped worker gets no briefing (--settings would corrupt its argv)" {
  run_engine -- claude --wrap "$LAUNCHER" --bg-spare "$SOCKDIR/a.claim.sock"
  [ "$status" -eq 0 ]
  run ! grep -q 'settings.json' "$H/argv" # no briefing --settings anywhere in the argv
}

@test "--wrap with no command is rejected" {
  run_engine -- claude --wrap
  [ "$status" -eq 2 ]
  [[ "$output" == *"--wrap needs the wrapped command"* ]]
}
