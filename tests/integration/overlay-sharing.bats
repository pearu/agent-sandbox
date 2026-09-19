#!/usr/bin/env bats
# THE PLATFORM PREMISE BEHIND `cow` WITH MORE THAN ONE SESSION.
#
# A sandbox is keyed by project and role, so two terminals open on one project are two
# sessions of ONE sandbox. Under `cow` that would be two overlay mounts over one upper
# directory, which overlayfs documents as undefined. The engine's answer (connections.md,
# "two sessions of one sandbox") is to mount ONCE and let every session inherit that
# mount, because inheriting copies mount entries that reference the SAME superblock,
# which is ordinary shared filesystem access and not the undefined case at all.
#
# That answer is a claim about the kernel and about bubblewrap, not about our code. It was
# measured on one host (bubblewrap 0.12.0, Linux 6.8) before the design committed to it.
# This file is what stops that measurement from being true only there: it re-runs it on
# every platform CI covers, and it must run BEFORE the engine relies on it.
#
# WHY THE CONTROL IS NOT OPTIONAL. Everything here compares superblock device numbers, so
# a platform where the two situations happened to report the same number would pass every
# assertion below while proving nothing. The first test therefore BUILDS the undefined
# case on purpose and requires the numbers to differ. Written without it, an early version
# of this measurement ran its two control mounts in sequence, the kernel recycled the
# device minor, and the undefined case looked identical to the safe one.
#
# WHERE IT SKIPS, THE SKIP IS THE RESULT. Real `cow` needs bubblewrap 0.11 or later.
# Ubuntu 24.04 ships 0.9.0, so this skips there and names the version, which is how CI
# tells us which supported platforms need the emulation instead.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11; this host: $(bwrap --version))"
  command -v nsenter >/dev/null || skip "nsenter not installed (util-linux)"

  O="$BATS_TEST_TMPDIR/o"
  L="$O/lower" U="$O/upper" W="$O/work" M="$O/merged"
  mkdir -p "$L/rules" "$U" "$W" "$M"
  printf 'from the source\n' >"$L/CLAUDE.md"
  printf 'topic from the source\n' >"$L/rules/topic.md"
  OV=(--dev-bind / / --overlay-src "$L" --overlay "$U" "$W" "$M")
  HOLDERS=()
  INNER=()
}

# EVERY BACKGROUND PROCESS HERE IS DETACHED FROM THE TEST'S STDOUT, and teardown never
# waits. bats reads a test's output through a pipe and finishes when that pipe closes, so
# a surviving background child holding the descriptor HANGS the run instead of failing it.
# The first version of this file did exactly that, and the process left holding the pipe
# was the joined session of the last test. Killing the bwrap wrapper is also not enough on
# its own: the process it started inside is what holds the mount, so both pids are
# recorded and both are killed.
# It also POLLS for the processes to be gone instead of returning straight after the
# kill. bats removes the temporary directory next, and an overlay whose mount has not yet
# been torn down leaves a workdir the cleanup cannot unlink -- which fails the run with a
# bare `rm: Permission denied` long after the assertions passed. Polling /proc is the way
# to wait here, since `wait` on a job holding the output pipe is what hung this file
# before.
teardown() {
  local p i
  for p in ${INNER[@]+"${INNER[@]}"} ${HOLDERS[@]+"${HOLDERS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
  for p in ${INNER[@]+"${INNER[@]}"} ${HOLDERS[@]+"${HOLDERS[@]}"}; do
    for ((i = 0; i < 200; i++)); do
      [[ -d "/proc/$p" ]] || break
      sleep 0.05
    done
  done
  # Then remove the tree HERE, and chmod it first. MEASURED while writing this: once
  # anything has been written through an overlay, its workdir keeps a mode-000 directory
  # that `rm -rf` cannot enter even as its owner, so the tree outlives the test and the
  # run fails with a bare `rm: Permission denied` after every assertion has passed. It is
  # not a permissions bug to route around here: the engine will meet the same thing when
  # it resets a `cow` layer or deletes a sandbox, and its teardown needs the same chmod.
  chmod -R u+rwX "$O" 2>/dev/null || true
  rm -rf "$O" 2>/dev/null || true
}

# start_holder N -- a bwrap process holding one overlay mount, alive until killed.
# Records its pid in HOLDER_PID and waits for the mount rather than sleeping, because a
# fixed sleep is the classic CI flake.
start_holder() {
  local pidfile="$O/pid$1" i
  rm -f "$pidfile"
  bwrap "${OV[@]}" -- bash -c "echo \$\$ >'$pidfile'; exec sleep 120" >/dev/null 2>&1 &
  HOLDERS+=("$!")
  for ((i = 0; i < 200; i++)); do
    if [[ -s "$pidfile" ]]; then
      HOLDER_PID="$(cat "$pidfile")"
      if [[ -n "$(dev_of "$HOLDER_PID")" ]]; then
        INNER+=("$HOLDER_PID")
        return 0
      fi
    fi
    sleep 0.05
  done
  return 1
}

# An awk program, not shell: $5 is mountinfo's mount point and $3 its device.
# shellcheck disable=SC2016
AWK_DEV='$5 == m {print $3}'

# dev_of PID -- the overlay's superblock device, as that pid's namespace sees it.
dev_of() { awk -v m="$M" "$AWK_DEV" "/proc/$1/mountinfo" 2>/dev/null; }

# in_ns PID CMD... -- run a command inside that pid's user and mount namespaces.
in_ns() { nsenter -t "$1" -m -U --preserve-credentials -- "${@:2}"; }

@test "CONTROL: two independent mounts over one upper are two superblocks, and we can see that" {
  # The undefined case, built deliberately. Both must be alive at once: a sequential pair
  # lets the kernel reuse the device minor and the comparison silently means nothing.
  start_holder a
  local a="$HOLDER_PID"
  start_holder b
  local b="$HOLDER_PID"
  local da db
  da="$(dev_of "$a")"
  db="$(dev_of "$b")"
  [ -n "$da" ]
  [ -n "$db" ]
  [ "$da" != "$db" ]
}

@test "a session joined to the holder sees the holder's superblock, not a new one" {
  start_holder a
  local want
  want="$(dev_of "$HOLDER_PID")"
  [ -n "$want" ]
  run in_ns "$HOLDER_PID" awk -v m="$M" "$AWK_DEV" /proc/self/mountinfo
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "a full sandbox built INSIDE the join still references that one superblock" {
  # The engine's real shape: join, then run bwrap. bwrap makes its own mount namespace,
  # and the question is whether that clone is another reference or another mount.
  start_holder a
  local want
  want="$(dev_of "$HOLDER_PID")"
  run in_ns "$HOLDER_PID" bwrap --dev-bind / / -- awk -v m="$M" "$AWK_DEV" /proc/self/mountinfo
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "two concurrent sandboxes on that one mount are coherent, and the source is untouched" {
  start_holder a
  local h="$HOLDER_PID"
  in_ns "$h" bwrap --dev-bind / / -- bash -c "printf 'by A\n' >'$M/from-A.md'"
  run in_ns "$h" bwrap --dev-bind / / -- test -f "$M/from-A.md"
  [ "$status" -eq 0 ] # B sees A's write

  in_ns "$h" bwrap --dev-bind / / -- rm -f "$M/rules/topic.md"
  run in_ns "$h" bwrap --dev-bind / / -- test -e "$M/rules/topic.md"
  [ "$status" -ne 0 ] # B sees the hide too

  # The one outcome that must never happen: a delete inside reaching the source.
  [ -f "$L/rules/topic.md" ]
}

@test "the holder may exit once a session has joined: the mount is held by membership" {
  # This is why no long-lived daemon is required. If it were false, the engine would need
  # one process per sandbox alive for as long as any session, and a crash would pull the
  # filesystem out from under a running agent.
  start_holder a
  local h="$HOLDER_PID" want
  want="$(dev_of "$h")"
  # The session reports its own pid rather than being hunted with pgrep, which matches on
  # a pattern and would happily pick up another test's, or this runner's, sleep.
  local sp="$O/sesspid" i spid=""
  rm -f "$sp"
  in_ns "$h" bash -c "echo \$\$ >'$sp'; while :; do sleep 0.2; done" >/dev/null 2>&1 &
  HOLDERS+=("$!")
  for ((i = 0; i < 200; i++)); do
    [[ -s "$sp" ]] && spid="$(cat "$sp")" && break
    sleep 0.05
  done
  [ -n "$spid" ]
  INNER+=("$spid")

  kill "$h" 2>/dev/null || true
  for ((i = 0; i < 200; i++)); do
    [[ -d "/proc/$h" ]] || break
    sleep 0.05
  done
  [ ! -d "/proc/$h" ]

  run in_ns "$spid" cat "$M/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ "$output" = "from the source" ]
  run in_ns "$spid" awk -v m="$M" "$AWK_DEV" /proc/self/mountinfo
  [ "$output" = "$want" ]
  run in_ns "$spid" bash -c "printf x >'$M/after-holder-died.md'"
  [ "$status" -eq 0 ]
}
