#!/usr/bin/env bats
# The keeper's supervisor keeps a wake (#441): a USR1 that lands while it is not inside a
# `wait` -- between its keeper/id record and its first wait, or in its checks after a
# wake -- is acted on at once, not after its five-second poll or a whole grace.
#
# The supervisor is HELD where no wait is running, by a gate the test controls, so the
# window is hit every time: a stub `flock` stops at the supervisor's unlock after its
# count (`flock -u 8`, the lock released first, so a join can take it), and a stub `mv`
# at its replacing of the session's `keeper` file, the step after its record. Each
# holds once, when armed, until the test releases it; a wake sent meanwhile is pending
# in the supervisor and runs its handler once the gate returns.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  KD="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/default/keeper"
  G="$H/gate"
  mkdir -p "$G"
  local flock mv sleep
  flock="$(command -v flock)" mv="$(command -v mv)" sleep="$(command -v sleep)"
  # flock: the supervisor's `flock -u 8` is logged (each one is a turn's checks), and
  # held once when armed
  cat >"$H/bin/flock" <<S
#!/usr/bin/env bash
if [[ "\$*" == "-u 8" ]]; then
  printf '%s\n' "\$*" >>"$G/flock.log"
  if [[ -e "$G/flock.armed" ]]; then
    rm -f -- "$G/flock.armed"
    "$flock" -u 8
    : >"$G/flock.held"
    while [[ ! -e "$G/flock.release" ]]; do "$sleep" 0.01; done
    exit 0
  fi
fi
exec "$flock" "\$@"
S
  # mv: the supervisor's `mv -f -- SESSION/keeper.new SESSION/keeper`, held once when
  # armed, before it moves
  cat >"$H/bin/mv" <<S
#!/usr/bin/env bash
if [[ \$# == 4 && "\${3##*/}" == keeper.new && "\${4##*/}" == keeper && -e "$G/mv.armed" ]]; then
  rm -f -- "$G/mv.armed"
  : >"$G/mv.held"
  while [[ ! -e "$G/mv.release" ]]; do "$sleep" 0.01; done
fi
exec "$mv" "\$@"
S
  chmod +x "$H/bin/flock" "$H/bin/mv"
}

teardown() {
  : >"$G/flock.release"
  : >"$G/mv.release"
  rm -f "$H/hold"
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  # a keeper a failed test left, found by its record (a test can fail before it read
  # SUP): told to stop, woken until it is gone, then killed; and its payload, by the
  # record's pid and start time, when the supervisor died (or was killed here) without
  # ending it. A record the launch removed (a supervisor that died during the start)
  # leaves the payload to own_keepers.
  local i p s="" ss="" t="" ts="" init="" is=""
  if { read -r s ss t ts init is <"$KD/id"; } 2>/dev/null; then
    : >"$KD/stop" 2>/dev/null || :
    : >"$KD/force" 2>/dev/null || :
    for ((i = 0; i < 300; i++)); do
      started "$s" "$ss" || break
      kill -USR1 "$s" 2>/dev/null || break
      sleep 0.02
    done
    ((i < 300)) || kill -KILL "$s" 2>/dev/null
    if started "$t" "$ts"; then kill -KILL "$t" 2>/dev/null; fi
    if started "$init" "$is"; then kill -KILL "$init" 2>/dev/null; fi
  fi
  for p in $(own_keepers); do kill -KILL "$p" 2>/dev/null; done
  return 0
}

# own_keepers -- this test's fake keepers still running (the stub bwrap's payload,
# argv[0] agent-sandbox-keeper, with this harness's HOME), one pid per line. For a
# supervisor that died during the start: the launch then removes the keeper directory,
# record and all, and leaves the payload running.
own_keepers() {
  local p
  local -a a
  for p in /proc/[0-9]*; do
    a=()
    { mapfile -d '' -t a <"$p/cmdline"; } 2>/dev/null || continue
    [[ "${a[0]:-}" == agent-sandbox-keeper ]] || continue
    { grep -qzxF "HOME=$H/home" "$p/environ"; } 2>/dev/null || continue
    printf '%s\n' "${p#/proc/}"
  done
}

# started PID START -- PID is still the process that started at START (field 22 of
# /proc/PID/stat), as the engine's _as_proc_is judges it
started() {
  local st
  local -a f
  [[ -n "$1" && -n "$2" ]] || return 1
  { read -r st <"/proc/$1/stat"; } 2>/dev/null || return 1
  st="${st##*) }"
  read -r -a f <<<"$st"
  [[ "${f[19]:-}" == "$2" ]]
}

# sup -- SUP, the supervisor's pid, from its record
sup() {
  local i
  for ((i = 0; i < 250; i++)); do
    { read -r SUP _ <"$KD/id"; } 2>/dev/null && [[ -n "$SUP" ]] && return 0
    sleep 0.02
  done
  echo "no keeper record" >&2
  return 1
}

# held NAME -- the NAME gate (flock, mv) holds the supervisor, within 5 s
held() {
  local i
  for ((i = 0; i < 250; i++)); do
    [[ -e "$G/$1.held" ]] && return 0
    sleep 0.02
  done
  echo "the $1 gate was not reached" >&2
  return 1
}

# waiting PID SECS -- PID is blocked in a wait (State S in /proc/PID/stat) with a child
# `sleep SECS` (its poll: 5; its grace), within 5 s. Between the fork of that sleep and
# its `wait` it runs builtins only, so a blocked state there is the wait.
waiting() {
  local i st c a
  for ((i = 0; i < 250; i++)); do
    st=""
    { read -r st <"/proc/$1/stat"; } 2>/dev/null || :
    st="${st##*) }"
    if [[ "${st:0:1}" == S ]]; then
      for c in $(kids "$1"); do
        a=""
        { a="$(tr '\0' ' ' <"/proc/$c/cmdline")"; } 2>/dev/null || :
        [[ "$a" == *"sleep $2 " ]] && return 0
      done
    fi
    sleep 0.02
  done
  echo "supervisor $1 is not waiting on a sleep $2" >&2
  return 1
}

# kids PID -- PID's children, one per line
kids() {
  local f
  local -a k
  for f in /proc/"$1"/task/*/children; do
    k=()
    { read -r -a k <"$f"; } 2>/dev/null || :
    ((${#k[@]} == 0)) || printf '%s\n' "${k[@]}"
  done
  return 0
}

# sleeps PID SECS -- how many live `sleep SECS` children PID has (a killed one, a zombie,
# has no command line)
sleeps() {
  local c a n=0
  for c in $(kids "$1"); do
    a=""
    { a="$(tr '\0' ' ' <"/proc/$c/cmdline")"; } 2>/dev/null || :
    [[ "$a" == *"sleep $2 " ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# ends_within -- the keeper decides to end (its record removed, which it does just
# before its cleanup) within 2 s; well under the 5 s poll a lost wake would cost
ends_within() {
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e "$KD/id" ]] || return 0
    sleep 0.02
  done
  echo "the keeper did not end within 2 s" >&2
  return 1
}

# checks -- how many times the supervisor has run its checks (its logged unlocks)
checks() {
  local n=0
  [[ -e "$G/flock.log" ]] && n="$(wc -l <"$G/flock.log")"
  printf '%s\n' "$n"
}

@test "a wake in the supervisor's checks is kept: a join that ends there, with a stop, ends the keeper at once (#441)" {
  # a grace, so the join's exit sends ONE USR1 (with none it wakes in a loop)
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=37 -- asb claude --version
  sup
  waiting "$SUP" 5
  # into its checks, which count the join and are held after the count
  : >"$G/flock.armed"
  kill -USR1 "$SUP"
  held flock
  # the join ends meanwhile: its record removed, one USR1; and a reset's stop
  release_bg
  [ "$BG_STATUS" -eq 0 ]
  : >"$KD/stop"
  : >"$G/flock.release"
  ends_within
}

@test "a wake between the supervisor's record and its first wait is kept (#441)" {
  : >"$G/mv.armed"
  # the supervisor held after its keeper/id record; the launch joins all the same
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=37 -- asb claude --version
  held mv
  sup
  release_bg
  [ "$BG_STATUS" -eq 0 ]
  : >"$KD/stop"
  : >"$G/mv.release"
  ends_within
}

@test "a wake in the checks before the grace's wait starts the grace over, and a stop then ends it (#441)" {
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=37 -- asb claude --version
  sup
  release_bg
  [ "$BG_STATUS" -eq 0 ]
  # idle, in its grace
  waiting "$SUP" 37
  # a join that came and went interrupts the grace; the checks run again, and are held
  : >"$G/flock.armed"
  kill -USR1 "$SUP"
  held flock
  local n i
  n="$(checks)"
  # another that came and went, while it is in those checks
  kill -USR1 "$SUP"
  : >"$G/flock.release"
  # the grace is interrupted at once and the checks run again (lost, it would run its
  # whole 37 s first)
  for ((i = 0; i < 100; i++)); do
    (($(checks) > n)) && break
    sleep 0.02
  done
  (($(checks) > n))
  waiting "$SUP" 37
  # and it stays there: no turn runs meanwhile (one that kept the flag would spin), and
  # the sleep of the wait it skipped is gone, so the one it waits on is its only one
  n="$(checks)"
  sleep 0.5
  (($(checks) == n))
  [ "$(sleeps "$SUP" 37)" -eq 1 ]
  : >"$KD/stop"
  kill -USR1 "$SUP"
  ends_within
}
