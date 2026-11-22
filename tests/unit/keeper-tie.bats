#!/usr/bin/env bats
# The strict keeper's watcher (#430), _as_keeper_tie: a process that ends the subtrees it
# was given when its caller dies, however it dies. Here the function itself, on a tree of
# sleeps, from a caller that sources the engine; tests/unit/strict.bats pins the
# supervisor's use of it, and tests/integration/keeper.bats the real strict launch.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  D="$BATS_TEST_TMPDIR/driver.sh"
  # The caller: sources the engine, starts a tree (a bash and its two sleeps) and a sleep
  # beside it that nobody names, ties the tree, writes `ROOT OTHER WATCHER` to $1 and
  # waits. $2 is the supervisor the watcher is told of (default: the caller itself), $3
  # the start time it is told the root has (default: the root's own). With UNTIE set, it
  # unties once $1.go is there (the test's word), having waited for the root first when
  # UNTIE=ended, as the supervisor waits for the launch, and then writes $1.untied.
  cat >"$D" <<'S'
#!/usr/bin/env bash
source "$ENGINE"
out=$1
bash -c 'sleep 300 & sleep 300 & wait' &
r=$!
sleep 300 &
other=$!
_as_proc_start "$r"
_as_keeper_tie "${2:-$$}" "$r" "${3:-$_ps_start}"
printf '%s %s %s\n' "$r" "$other" "$_kt_pid" >"$out.new" && mv "$out.new" "$out"
if [[ -n "${UNTIE:-}" ]]; then
  for ((i = 0; i < 500; i++)); do
    [[ -e "$out.go" ]] && break
    sleep 0.02
  done
  [[ "$UNTIE" != ended ]] || wait "$r"
  _as_keeper_untie "$_kt_pid"
  : >"$out.untied"
fi
wait
S
  chmod +x "$D"
  PIDS=()
}

teardown() {
  local p
  [[ -z "${ROOT:-}" ]] || pkill -KILL -P "$ROOT" 2>/dev/null
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  return 0
}

# live PID -- PID runs (a zombie does not)
live() {
  local st
  { read -r st <"/proc/$1/stat"; } 2>/dev/null || return 1
  st="${st##*) }"
  [[ "${st:0:1}" != Z ]]
}

# kids PID -- PID's children, one per line
kids() {
  local f
  local -a k
  for f in /proc/"$1"/task/*/children; do
    k=()
    # no newline at its end: read fails, having read it all
    { read -r -a k <"$f"; } 2>/dev/null || :
    ((${#k[@]} == 0)) || printf '%s\n' "${k[@]}"
  done
  return 0
}

# gone PID... -- every PID ends within 5 s
gone() {
  local i p left
  for ((i = 0; i < 100; i++)); do
    left=""
    for p in "$@"; do live "$p" && left+=" $p"; done
    [[ -z "$left" ]] && return 0
    sleep 0.05
  done
  echo "still running:$left" >&2
  return 1
}

# start_driver [SUP [START]] -- run the caller in the background; sets DRV, ROOT, OTHER,
# WATCHER, TREE (the root and its two sleeps) and WSLEEP (the watcher's sleep), once each
# is there.
start_driver() {
  local out="$BATS_TEST_TMPDIR/pids" i
  rm -f "$out"
  ENGINE="$ENGINE" "$D" "$out" "$@" 3>&- &
  DRV=$!
  PIDS+=("$DRV")
  for ((i = 0; i < 200; i++)); do
    [[ -s "$out" ]] && break
    sleep 0.02
  done
  read -r ROOT OTHER WATCHER <"$out"
  PIDS+=("$ROOT" "$OTHER" "$WATCHER")
  local -a k=()
  for ((i = 0; i < 200; i++)); do
    mapfile -t k < <(kids "$ROOT")
    ((${#k[@]} == 2)) && break
    sleep 0.02
  done
  TREE=("$ROOT" "${k[@]}")
  PIDS+=("${k[@]}")
  WSLEEP=""
  for ((i = 0; i < 200; i++)); do
    WSLEEP="$(kids "$WATCHER" | head -1)"
    [[ -n "$WSLEEP" ]] && break
    live "$WATCHER" || break
    sleep 0.02
  done
  [[ -z "$WSLEEP" ]] || PIDS+=("$WSLEEP")
  return 0
}

@test "the caller killed with -9: the named subtree ends, the watcher and its sleep with it; nothing else" {
  start_driver
  [ "${#TREE[@]}" -eq 3 ]
  [ -n "$WSLEEP" ]
  local -a a
  mapfile -d '' -t a <"/proc/$WATCHER/cmdline"
  [ "${a[3]}" = agent-sandbox-tie ] # the name probes/orphans.sh looks for
  live "$ROOT"
  kill -KILL "$DRV"
  gone "${TREE[@]}" "$WATCHER" "$WSLEEP"
  live "$OTHER" # not named, so not ended
}

@test "the start-time guard: a root that is not the process named is left alone" {
  start_driver "" 1
  [ "${#TREE[@]}" -eq 3 ]
  kill -KILL "$DRV"
  gone "$WATCHER" "$WSLEEP"
  live "$ROOT"
  live "${TREE[1]}"
  live "${TREE[2]}"
}

@test "a watcher whose parent is not the supervisor it was given acts at once" {
  # As when the supervisor died before the watcher could take its death signal.
  start_driver 1
  gone "${TREE[@]}" "$WATCHER"
  live "$DRV"
  live "$OTHER"
}

# untie -- have the caller untie now, and wait until it has
untie() {
  : >"$BATS_TEST_TMPDIR/pids.go"
  untied
}

# untied -- wait until the caller's untie has returned
untied() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -e "$BATS_TEST_TMPDIR/pids.untied" ]] && break
    sleep 0.02
  done
  [ -e "$BATS_TEST_TMPDIR/pids.untied" ]
}

# The untie is a TERM, whose handler ends what is named and still runs. Both tests untie
# only once the watcher's sleep runs, so its trap is set: a TERM before that ends the
# watcher by default, killing nothing, a race no caller relies on (#449).
@test "_as_keeper_untie after the tree has ended (a normal end): the watcher ends, nothing else is touched" {
  UNTIE=ended start_driver
  [ "${#TREE[@]}" -eq 3 ]
  [ -n "$WSLEEP" ]
  kill -KILL "${TREE[@]}"
  gone "${TREE[@]}"
  untie
  gone "$WATCHER" "$WSLEEP"
  live "$OTHER"
  live "$DRV"
}

@test "_as_keeper_untie while the tree runs (a failed start): the tree ends, the sleep beside it stays" {
  UNTIE=running start_driver
  [ "${#TREE[@]}" -eq 3 ]
  [ -n "$WSLEEP" ]
  live "$ROOT"
  untie
  gone "${TREE[@]}" "$WATCHER" "$WSLEEP"
  live "$OTHER"
  live "$DRV"
}

# The wait matters at the failed start, which sends the launch TERM as soon as the untie
# returns: the watcher must have collected and killed by then. A watcher held stopped
# cannot end, so a caller that waits stays in its wait, with the TERM pending on the
# watcher, and has not untied yet.
@test "_as_keeper_untie returns only once the watcher has ended" {
  UNTIE=running start_driver
  [ -n "$WSLEEP" ]
  kill -STOP "$WATCHER"
  local i k v pnd="" st="" stopped="" held=""
  # Stopped before the TERM: one that comes first is taken first (the lower number)
  for ((i = 0; i < 250; i++)); do
    while read -r k v; do
      [[ "$k" == State: ]] && break
    done <"/proc/$WATCHER/status"
    [[ "$v" == T* ]] && stopped=1 && break
    sleep 0.02
  done
  [ -n "$stopped" ]
  : >"$BATS_TEST_TMPDIR/pids.go"
  for ((i = 0; i < 250; i++)); do
    { read -r st <"/proc/$DRV/stat"; } 2>/dev/null || st=""
    st=${st##*) }
    while read -r k v; do
      [[ "$k" == ShdPnd: ]] && pnd=$v && break
    done <"/proc/$WATCHER/status"
    # SIGTERM is pending (bit 15), and the caller sleeps: after its kill it blocks only
    # in a wait (State S, which any kernel shows; /proc/PID/wchan can read 0)
    (((16#${pnd:-0} & 0x4000) != 0)) && [[ "${st:0:1}" == S ]] && held=1 && break
    sleep 0.02
  done
  [ -n "$held" ]
  [ ! -e "$BATS_TEST_TMPDIR/pids.untied" ]
  live "$ROOT" # killed by nothing yet
  kill -CONT "$WATCHER"
  untied
  gone "${TREE[@]}" "$WATCHER" "$WSLEEP"
  live "$OTHER"
}

@test "the watcher killed with -9 leaves no sleep of its own behind" {
  start_driver
  [ -n "$WSLEEP" ]
  kill -KILL "$WATCHER"
  gone "$WATCHER" "$WSLEEP"
  live "$ROOT" # and kills nothing
}

@test "no setpriv: no watcher, and the keeper's log says what that means" {
  # shellcheck disable=SC2016 # expanded by the inner bash
  run env -i ENGINE="$ENGINE" /bin/bash -c 'source "$ENGINE"; PATH=/nonexistent; _as_keeper_tie $$ 1 1; echo "rc=$? pid=[$_kt_pid]"'
  [[ "$output" == *"no setpriv (util-linux), so this keeper is not tied to its supervisor: a SIGKILL of the supervisor leaves it running (#430)"* ]]
  [[ "$output" == *"rc=1 pid=[]"* ]]
}
