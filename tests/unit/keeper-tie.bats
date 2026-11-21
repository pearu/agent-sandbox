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
  # the start time it is told the root has (default: the root's own).
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
[[ -z "${UNTIE:-}" ]] || _as_keeper_untie "$_kt_pid"
[[ -z "${UNTIE:-}" ]] || : >"$out.untied"
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

@test "_as_keeper_untie: the watcher ends, killing nothing" {
  UNTIE=1 start_driver
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -e "$BATS_TEST_TMPDIR/pids.untied" ]] && break
    sleep 0.02
  done
  [ -e "$BATS_TEST_TMPDIR/pids.untied" ]
  gone "$WATCHER"
  [[ -z "$WSLEEP" ]] || gone "$WSLEEP"
  live "$ROOT"
  live "$DRV"
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
