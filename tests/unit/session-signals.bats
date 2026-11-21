#!/usr/bin/env bats
# A launch signalled while it is being set up (#422): from _as_session_begin until
# _as_launch hands the session to the keeper's supervisor, INT, TERM and HUP run the
# session's cleanup once and end the launch with 128 + the signal. The launch is held in
# setup at the mount-point list's lock, which _as_placeholder_register waits for (`flock
# -w 10`) after the session directory is made and before bwrap: the stub bwrap is never
# reached, so this needs no real one. It holds an ssh agent of its own (--ssh), a process
# whose name is ssh-agent, so the cleanup has one to stop.

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
  HOLD_PID="" LAUNCH_PID=""
}

teardown() {
  # a launch still held (a test that failed) is ended before the lock lets it go on
  [[ -n "$LAUNCH_PID" && -n "${OWNER:-}" ]] && kill -KILL "$OWNER" 2>/dev/null
  [[ -n "$HOLD_PID" ]] && release_lock
  [[ -n "$LAUNCH_PID" ]] && kill -KILL "$LAUNCH_PID" 2>/dev/null
  [[ -s "$H/agent.pid" ]] && kill "$(cat "$H/agent.pid")" 2>/dev/null
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
  # shell_variables not a function context")
  run ! grep -q "/asb: line [0-9]*:" "$H/out"
  cleaned
  release_lock
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
