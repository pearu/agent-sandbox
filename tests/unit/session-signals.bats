#!/usr/bin/env bats
# A launch signalled while it is being set up (#422): from _as_session_begin until
# _as_launch hands the session to the keeper's supervisor, INT, TERM and HUP run the
# session's cleanup once and end the launch with 128 + the signal. The launch is held in
# setup at the mount-point list's lock, which _as_placeholder_register waits for (`flock
# -w 10`) after the session directory is made and before bwrap: the stub bwrap is never
# reached, so this needs no real one. It holds an ssh agent of its own (--ssh), a process
# whose name is ssh-agent, so the cleanup has one to stop.
#
# And what bash 5.2 does to a handler (#423): a signal that arrives while one command
# substitution runs is handled when bash starts to parse the next substitution of the
# same simple command, and the handler fails there ("trap: line 2: unexpected EOF while
# looking for matching `)'"), abandoning the launch (exit 2; the EXIT trap still cleans
# up). Setup runs one substitution per simple command; the tests here send the TERM
# inside the first of what were two (fire_in), under a bash 5.2 (bash52), and the EXIT
# trap's own cleanup ignores the three signals.
#
# And the hand-over (#422, R1's N3 on it): from the keeper's supervisor's start until the
# start's outcome is known, the session's owner is changing, and a signal is only
# recorded. A stub bwrap holds the start there (handover_stub). A keeper that comes up
# is the supervisor's, which cleans up when it ends, at once; a start that fails leaves
# the session the launch's, which cleans up. Either way once, and 128 + the signal.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  make_ssh_stubs
  STATE="$H/home/.local/state/agent-sandbox"
  mkdir -p "$STATE" "$H/libexec"
  # The agent: a script named ssh-agent, which a process started from it is called
  # (not a copy of sleep: a multi-call coreutils reads its own name and refuses this
  # one), its pid written where the test reads it.
  printf '#!%s\nimport time\ntime.sleep(300)\n' "$(command -v python3)" >"$H/libexec/ssh-agent"
  chmod +x "$H/libexec/ssh-agent"
  cat >"$H/bin/ssh-agent" <<X
#!/usr/bin/env bash
set +x
sock=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == -a ]] && sock="\$2"; shift; done
: >"\$sock" 2>/dev/null
"$H/libexec/ssh-agent" 300 </dev/null >/dev/null 2>&1 &
echo "\$!" >"$H/agent.pid"
echo "SSH_AGENT_PID=\$!; export SSH_AGENT_PID;"
X
  HOLD_PID="" LAUNCH_PID="" OWNER="" SUP=""
}

teardown() {
  # a launch still held (a test that failed) is ended before the lock lets it go on
  [[ -n "$LAUNCH_PID" && -n "${OWNER:-}" ]] && kill -KILL "$OWNER" 2>/dev/null
  [[ -n "$HOLD_PID" ]] && release_lock
  [[ -n "$LAUNCH_PID" ]] && kill -KILL "$LAUNCH_PID" 2>/dev/null
  [[ -s "$H/agent.pid" ]] && kill "$(cat "$H/agent.pid")" 2>/dev/null
  # a keeper a hand-over test left (one that failed): its start let go, then it and its
  # supervisor ended
  : >"$H/bwrap-go"
  local f s t
  for f in "$STATE"/claude/*/*/keeper/id; do
    [[ -s "$f" ]] || continue
    read -r s _ t _ <"$f"
    kill -KILL "$s" "$t" 2>/dev/null
  done
  [[ -n "${SUP:-}" ]] && kill -KILL "$SUP" 2>/dev/null
  # ...and the stub bwrap of a start still held (handover_stub), or the payload it became:
  # it runs in a session of its own, so the supervisor's end does not reach it
  local b=""
  [[ -s "$H/bwrap.pid" ]] && read -r b <"$H/bwrap.pid"
  [[ -n "$b" ]] && grep -qa agent-sandbox-keeper "/proc/$b/cmdline" 2>/dev/null && kill -KILL "$b"
  return 0
}

# hold_lock -- take the mount-point list's lock in the background and return once it is
# held (tests/integration/profile-claude/accounts.bats does the same); release_lock lets
# go of it.
hold_lock() {
  local i
  HOLD_RELEASE="$H/lock-release"
  # shellcheck disable=SC2016 # $1/$2 are for the inner bash -c, not this shell
  flock "$STATE/placeholders.lock" bash -c ': >"$1"; while [[ ! -e "$2" ]]; do sleep 0.05; done' \
    _ "$H/lock-held" "$HOLD_RELEASE" 3>&- &
  HOLD_PID=$!
  for ((i = 0; i < 600; i++)); do
    [[ -e "$H/lock-held" ]] && return 0
    sleep 0.05
  done
  echo "hold_lock: not held" >&2
  return 1
}

release_lock() {
  : >"$HOLD_RELEASE"
  wait "$HOLD_PID"
  HOLD_PID=""
}

# descendants PID -- PID's descendants, one per line.
descendants() {
  local f c
  local -a kids
  for f in /proc/"$1"/task/*/children; do
    kids=()
    read -ra kids 2>/dev/null <"$f" || :
    for c in ${kids[@]+"${kids[@]}"}; do
      echo "$c"
      descendants "$c"
    done
  done
}

# launch_held -- start a launch with --ssh in the background, its output in $H/out, with
# INT, TERM and HUP at their defaults (a background job of a non-interactive shell starts
# with SIGINT ignored, which the engine could not trap), and return once it waits at the
# list's lock. Its xtrace goes to $H/trace (fd 6, which the engine does not use), for
# `cleanups`; not under coverage, where kcov traces it its own way. Sets LAUNCH_PID, and
# OWNER, the launch's process that holds the session (its owner.id) and the trap, and
# SESS, its session directory.
launch_held() {
  local i d c
  local -a trace=(SHELLOPTS=xtrace BASH_XTRACEFD=6)
  [[ -z "${AGENT_SANDBOX_KCOV:-}" ]] || trace=()
  : >"$H/home/.ssh/id_ed25519.pub"
  hold_lock
  engine_cmd "$H/bin/asb"
  (
    cd "$H/proj" || exit 1
    exec /usr/bin/env -i --default-signal=INT,TERM,HUP HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" \
      USER=tester TERM=xterm LANG=C.UTF-8 BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" \
      AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_VERBOSE=on ${trace[@]+"${trace[@]}"} "${ENGINE_CMD[@]}" --ssh example.test claude --version
  ) </dev/null >"$H/out" 2>&1 3>&- 6>"$H/trace" &
  LAUNCH_PID=$!
  OWNER="" SESS=""
  for ((i = 0; i < 600; i++)); do
    if [[ -z "$OWNER" ]]; then
      for d in "$H"/base/session.*; do
        [[ -s "$d/owner.id" ]] && read -r OWNER _ <"$d/owner.id" && SESS="$d"
      done
    fi
    if [[ -n "$OWNER" ]]; then
      for c in $(descendants "$OWNER"); do
        [[ "$({ tr '\0' ' ' <"/proc/$c/cmdline"; } 2>/dev/null)" == "flock -w 10 7 " ]] && return 0
      done
    fi
    kill -0 "$LAUNCH_PID" 2>/dev/null || break
    sleep 0.05
  done
  echo "launch_held: the launch did not reach the list's lock:" >&2
  cat "$H/out" >&2
  return 1
}

# launch_free [VAR=value...] -- ARGS... -- a launch of ARGS in the background, not held:
# it runs through setup to its join, or to a refusal. Its output in $H/out; its xtrace
# (not under coverage) in $H/trace, each line naming the process that ran it ('+PID: '),
# for fire_in. Sets LAUNCH_PID.
launch_free() {
  local -a envs=()
  # shellcheck disable=SC2016 # PS4 is the engine's to expand
  local -a trace=(SHELLOPTS=xtrace BASH_XTRACEFD=6 'PS4=+${BASHPID}: ')
  [[ -z "${AGENT_SANDBOX_KCOV:-}" ]] || trace=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  engine_cmd "$H/bin/asb"
  (
    cd "$H/proj" || exit 1
    exec /usr/bin/env -i --default-signal=INT,TERM,HUP HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" \
      USER=tester TERM=xterm LANG=C.UTF-8 BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" \
      AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_VERBOSE=on ${trace[@]+"${trace[@]}"} \
      ${envs[@]+"${envs[@]}"} "${ENGINE_CMD[@]}" "$@"
  ) </dev/null >"$H/out" 2>&1 3>&- 6>"$H/trace" &
  LAUNCH_PID=$!
}

# owner_of -- set OWNER and SESS from the launch's session directory, once there is one.
owner_of() {
  local d
  for d in "$H"/base/session.*; do
    [[ -s "$d/owner.id" ]] && read -r OWNER _ <"$d/owner.id" && SESS="$d"
  done
  [[ -n "$OWNER" ]]
}

# fire_in FUNCTION COMMAND -- COMMAND, ahead of the real one on the harness's PATH, sends
# the launch's owner one TERM and then takes 0.5 s, once: when it runs under a
# substitution whose child called FUNCTION (that child's traced command, launch_free),
# however deep below the owner, so that the TERM arrives while the owner waits on its
# own substitution around it. The first such call after the session is stamped decides,
# so FUNCTION is one whose first call there was a sibling's before #423
# (_as_links_view_file: _as_links_view_write's; now inside its _as_one).
fire_in() {
  local real
  real="$(command -v "$2")"
  cat >"$H/bin/$2" <<X
#!/bin/bash
set +x
if [[ ! -e "$H/fired" ]]; then
  o="" c=\$\$ p="" hit=""
  for d in "$H"/base/session.*; do [[ -s "\$d/owner.id" ]] && read -r o _ <"\$d/owner.id"; done
  while [[ -n "\$o" && "\$c" -gt 1 ]]; do
    grep -q "^+*\$c: $1\\( \\|\$\\)" "$H/trace" && hit=1
    p=""
    while read -r k v; do [[ "\$k" == PPid: ]] && p="\$v"; done </proc/\$c/status
    [[ "\$p" == "\$o" ]] && break
    c="\$p"
  done
  if [[ -n "\$o" && "\$p" == "\$o" && -n "\$hit" ]]; then
    : >"$H/fired"
    kill -TERM "\$o"
    sleep 0.5
  fi
fi
exec "$real" "\$@"
X
  chmod +x "$H/bin/$2"
}

# bash_is_52 -- the engine is run by a bash 5.2 (bash52), linked first on its PATH.
bash_is_52() {
  bash52
  ln -sf "$BASH52" "$H/bin/bash"
}

# launch_end -- wait for the launch; sets LAUNCH_STATUS.
launch_end() {
  LAUNCH_STATUS=0
  wait "$LAUNCH_PID" || LAUNCH_STATUS=$?
  LAUNCH_PID=""
  # shown when a test fails
  echo "the launch's status: $LAUNCH_STATUS; its output:"
  cat "$H/out"
}

# gone PID -- PID has ended (or is a zombie no one has reaped yet), within 5 s.
gone() {
  local i s
  for ((i = 0; i < 100; i++)); do
    s="$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" || return 0
    [[ -z "$s" || "$s" == Z ]] && return 0
    sleep 0.05
  done
  return 1
}

# cleanups -- how many times the launch ran _as_session_cleanup, from its xtrace.
cleanups() { grep -c '^+* _as_session_cleanup$' "$H/trace"; }

# cleaned -- the session's cleanup is done, once: its directory is gone, its ssh agent
# has ended, and the launch went no further (no bwrap, no join).
cleaned() {
  [ ! -e "$SESS" ]
  [ -s "$H/agent.pid" ]
  gone "$(cat "$H/agent.pid")"
  [ ! -s "$H/argv" ]
  [ ! -s "$H/join" ]
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || [ "$(cleanups)" -eq 1 ]
}

# complaints FILE -- bash's own complaints in a launch's output FILE: its lines
# `…/asb: line N: …`, all but one. A TERM of a burst that arrives after the launch's
# trap has started _as_session_signal and before its first line, `trap '' INT TERM HUP`,
# has run stays pending; bash's run_pending_traps then finds that trap ignored, and
# warns "bad value in trap_list[15]: 0x1" (0x1, SIG_IGN) instead of running it. bash's
# trap.c checks for this very case, a race ("This is possible due to a race
# condition"), so as not to run a handler that is no longer there: the TERM is ignored,
# as the handler means it to be, and the cleanup has run once. That line, exactly, is
# no complaint. Every other is, its neighbours included: the trap found at its default
# (the "resending" line, a TERM bash sends itself again), any other value, the same
# warning for another signal (the burst is TERM only), and any other warning.
complaints() {
  grep '/asb: line [0-9]*:' "$1" \
    | grep -vx '.*/asb: line [0-9]*: warning: run_pending_traps: bad value in trap_list\[15\]: 0x1' || :
}

# signal_once SIG STATUS -- one SIG to a launch in setup ends it with STATUS, cleaned up
# once.
signal_once() {
  launch_held
  [ -d "$SESS" ]
  [ "$(cat "/proc/$(cat "$H/agent.pid")/comm")" = ssh-agent ] # the agent is up
  kill -s "$1" "$OWNER"
  launch_end
  [ "$LAUNCH_STATUS" -eq "$2" ]
  cleaned
  release_lock
}

@test "a launch in setup sent a burst of TERM ends 143, cleaned up once, without a crash or a parse error" {
  local i
  launch_held
  for ((i = 0; i < 20; i++)); do
    kill -TERM "$OWNER" 2>/dev/null || true
  done
  launch_end
  [ "$LAUNCH_STATUS" -eq 143 ]
  run ! grep -q "Segmentation fault" "$H/out"
  run ! grep -q "unexpected EOF" "$H/out"
  # bash's own complaints about its state (5.2.37 on main: "pop_var_context: head of
  # shell_variables not a function context"), but its warning for a TERM it ignored
  run complaints "$H/out"
  [ -z "$output" ]
  cleaned
  release_lock
}

@test "complaints: every line of bash's '/asb: line N:' is one, but run_pending_traps' warning for an ignored TERM" {
  local a="/tmp/bats-run-x/test/1/h/bin/asb"
  printf '%s\n' \
    "agent-sandbox: connect: preset shared" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x1" \
    "$a: line 1: pop_var_context: head of shell_variables not a function context" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: (nil)" \
    "$a: line 1236: warning: run_pending_traps: signal handler is SIG_DFL, resending 15 (SIGTERM) to myself" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x1 (and more)" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[1]: 0x1" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x55d0c2a4b0e0" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[14]: 0x1" \
    "$a: line 1237: warning: something else" \
    "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x1" >"$H/out"
  run complaints "$H/out"
  [ "${#lines[@]}" -eq 8 ]
  [ "${lines[0]}" = "$a: line 1: pop_var_context: head of shell_variables not a function context" ]
  [ "${lines[1]}" = "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: (nil)" ]
  [ "${lines[2]}" = "$a: line 1236: warning: run_pending_traps: signal handler is SIG_DFL, resending 15 (SIGTERM) to myself" ]
  [ "${lines[3]}" = "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x1 (and more)" ]
  [ "${lines[4]}" = "$a: line 1236: warning: run_pending_traps: bad value in trap_list[1]: 0x1" ]
  [ "${lines[5]}" = "$a: line 1236: warning: run_pending_traps: bad value in trap_list[15]: 0x55d0c2a4b0e0" ]
  [ "${lines[6]}" = "$a: line 1236: warning: run_pending_traps: bad value in trap_list[14]: 0x1" ]
  [ "${lines[7]}" = "$a: line 1237: warning: something else" ]
}

@test "a launch in setup sent one TERM ends 143, cleaned up once" {
  signal_once TERM 143
}

@test "a launch in setup sent one INT ends 130, cleaned up once" {
  signal_once INT 130
}

@test "a launch in setup sent one HUP ends 129, cleaned up once" {
  signal_once HUP 129
}

@test "a launch in setup sent one TERM ends 143 when a cleanup step fails, and the rest of the cleanup runs" {
  [[ $EUID -ne 0 ]] || skip "root removes what is in a read-only directory"
  launch_held
  # a session directory rm -rf cannot remove: a read-only subdirectory with a file in it
  mkdir -p "$SESS/ro"
  : >"$SESS/ro/f"
  chmod 555 "$SESS/ro"
  kill -TERM "$OWNER"
  launch_end
  chmod 755 "$SESS/ro"
  [ "$LAUNCH_STATUS" -eq 143 ]
  gone "$(cat "$H/agent.pid")"
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || grep -q '^+* _as_placeholder_release$' "$H/trace"
  release_lock
}

# fired_clean FUNCTION -- under a bash 5.2, a TERM during the owner's substitution that
# calls FUNCTION, which ran beside another substitution in one command before #423, ends
# the launch 143, cleaned up, with no parse error.
fired_clean() {
  [[ -z "${AGENT_SANDBOX_KCOV:-}" ]] || skip "fire_in reads the launch's xtrace, which coverage takes"
  bash_is_52
  : >"$H/home/.ssh/id_ed25519.pub"
  fire_in "$1" sha256sum
  launch_free -- --ssh example.test claude --version
  launch_end
  [ -e "$H/fired" ]
  [ "$LAUNCH_STATUS" -eq 143 ]
  run ! grep -q "unexpected EOF" "$H/out"
  [ -z "$(find "$H/base" -maxdepth 1 -name 'session.*' -print -quit)" ]
}

@test "bash 5.2: a TERM while the launch's links view is named ends it 143, not with a parse error (#423)" {
  fired_clean _as_links_view_file
}

@test "a signal while a launch's exit runs its cleanup is ignored: the launch keeps its own status, cleaned up once (#423)" {
  local real="$BATS_TEST_TMPDIR/real" rm i st
  mkdir -p "$real" "$H/proj/w"
  touch "$real/f.md"
  ln -s "$real" "$H/proj/w/l"
  # Refused before bwrap (an unapproved link, briefing.bats): the launch ends through its
  # EXIT trap. Its status without a signal:
  launch_free AGENT_SANDBOX_NET=none -- --connect './w/l/f.md = read-only' claude --version
  launch_end
  st="$LAUNCH_STATUS"
  [ "$st" -ne 0 ]
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || [ "$(grep -c '^+*[0-9]*: _as_session_cleanup$' "$H/trace")" -eq 1 ]
  # Again, the cleanup held at its removal of the session directory, and sent TERMs there.
  rm="$(command -v rm)"
  cat >"$H/bin/rm" <<X
#!/bin/bash
set +x
if [[ "\$1 \$2" == "-rf --" && "\$3" == "$H/base/session."* ]]; then
  : >"$H/in-rm"
  while [[ ! -e "$H/rm-go" ]]; do sleep 0.05; done
fi
exec "$rm" "\$@"
X
  chmod +x "$H/bin/rm"
  OWNER=""
  launch_free AGENT_SANDBOX_NET=none -- --connect './w/l/f.md = read-only' claude --version
  for ((i = 0; i < 600; i++)); do
    [[ -e "$H/in-rm" ]] && break
    sleep 0.05
  done
  [ -e "$H/in-rm" ]
  owner_of
  for ((i = 0; i < 5; i++)); do
    kill -TERM "$OWNER"
    sleep 0.05
  done
  : >"$H/rm-go"
  launch_end
  [ "$LAUNCH_STATUS" -eq "$st" ]
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || [ "$(grep -c '^+*[0-9]*: _as_session_cleanup$' "$H/trace")" -eq 1 ]
  [ -z "$(find "$H/base" -maxdepth 1 -name 'session.*' -print -quit)" ]
}

# handover_stub -- a bwrap that holds a keeper's start: it records its argv, says it is
# there ($H/in-bwrap), and waits for $H/bwrap-go; then it runs the payload, or, with
# $H/bwrap-fail, exits 1, a start that failed. The supervisor has taken the session
# (owner.id) by then: the launch waits for the keeper, in the hand-over.
handover_stub() {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
if [[ "${!#}" == agent-sandbox-keeper ]]; then
  echo "$$" >"${BWRAP_DUMP%/*}/bwrap.pid"
  : >"${BWRAP_DUMP%/*}/in-bwrap"
  while [[ ! -e "${BWRAP_DUMP%/*}/bwrap-go" ]]; do sleep 0.02; done
  [[ ! -e "${BWRAP_DUMP%/*}/bwrap-fail" ]] || exit 1
fi
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
}

# launch_in_handover [VAR=value...] -- a launch with --ssh, held in the hand-over (handover_stub); sets
# SUP, the supervisor (owner.id's process now), OWNER, the launch's process that held the
# session before it (the supervisor's parent, which has the handlers), and SESS.
launch_in_handover() {
  local i
  handover_stub
  : >"$H/home/.ssh/id_ed25519.pub"
  launch_free "$@" -- --ssh example.test claude --version
  for ((i = 0; i < 600; i++)); do
    [[ -e "$H/in-bwrap" ]] && break
    kill -0 "$LAUNCH_PID" 2>/dev/null || break
    sleep 0.05
  done
  [ -e "$H/in-bwrap" ]
  OWNER=""
  owner_of
  SUP="$OWNER"
  # the launch's process that holds the session and its handlers: the supervisor's parent
  OWNER="$(awk '$1 == "PPid:" {print $2}' "/proc/$SUP/status")"
  [ "$OWNER" != "$SUP" ]
  [ "$(cat "/proc/$(cat "$H/agent.pid")/comm")" = ssh-agent ]
}

# _us EPOCHREALTIME -- that time in microseconds.
_us() { echo "$((10#${1/./}))"; }

# launch_cleanups -- how many times the launch itself (not its supervisor) ran
# _as_session_cleanup, from its xtrace.
launch_cleanups() { grep -c "^+*$OWNER: _as_session_cleanup\$" "$H/trace" || :; }

# handover_live SIG STATUS -- SIG to a launch in the hand-over, whose keeper then comes
# up: the session is the supervisor's. Until the start is over the launch waits and
# the session is whole (on main the launch's cleanup removed it from under the starting
# keeper); then the launch ends with STATUS without joining, never cleaning up itself,
# and the keeper, joined by no one, ends at once, its cleanup with it (slowed here), before
# the launch does: woken (not after the supervisor's five-second wait) and told to stop
# (keeper/stop; not after the grace, which is long here).
handover_live() {
  local rm
  # the supervisor's removal of the session directory takes 0.5 s, so that a launch that
  # ended before its keeper had would be seen
  rm="$(command -v rm)"
  cat >"$H/bin/rm" <<X
#!/bin/bash
set +x
[[ "\$1 \$2" == "-rf --" && "\$3" == "$H/base/session."* ]] && sleep 0.5
exec "$rm" "\$@"
X
  chmod +x "$H/bin/rm"
  launch_in_handover AGENT_SANDBOX_KEEPER_GRACE=60
  kill -s "$1" "$OWNER"
  sleep 0.5
  [ -d "$SESS" ]
  kill -0 "$OWNER" # still waiting for the start
  [ "$(cat "/proc/$(cat "$H/agent.pid")/comm")" = ssh-agent ]
  local t0=$EPOCHREALTIME
  : >"$H/bwrap-go"
  launch_end
  [ "$LAUNCH_STATUS" -eq "$2" ]
  [ ! -s "$H/join" ]
  [ ! -d "/proc/$SUP" ] # ended before the launch did
  # ...within 3 s: well before the supervisor's own five-second wait would end it
  (($(_us "$EPOCHREALTIME") - $(_us "$t0") < 3000000))
  [ ! -e "$SESS" ]
  gone "$(cat "$H/agent.pid")"
  [ -z "$(find "$STATE" -path '*/keeper/id' -print -quit)" ]
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || [ "$(launch_cleanups)" -eq 0 ]
}

@test "a launch sent TERM while its keeper starts leaves the session to the keeper, which ends at once with its cleanup; the launch ends 143 (#422)" {
  handover_live TERM 143
}

@test "a launch sent INT while its keeper starts leaves the session to the keeper, which ends at once with its cleanup; the launch ends 130 (#422)" {
  handover_live INT 130
}

@test "a launch sent TERM while its keeper starts, which then fails, keeps the session and cleans it up once; it ends 143 (#422)" {
  launch_in_handover
  : >"$H/bwrap-fail"
  kill -TERM "$OWNER"
  sleep 0.5
  [ -d "$SESS" ]
  kill -0 "$OWNER" # still waiting for the start
  : >"$H/bwrap-go"
  launch_end
  [ "$LAUNCH_STATUS" -eq 143 ]
  grep -q "the sandbox did not start" "$H/out"
  [ ! -s "$H/join" ]
  [ ! -d "/proc/$SUP" ]
  [ ! -e "$SESS" ]
  gone "$(cat "$H/agent.pid")"
  [[ -n "${AGENT_SANDBOX_KCOV:-}" ]] || [ "$(launch_cleanups)" -eq 1 ]
}
