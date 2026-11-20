#!/usr/bin/env bats
# The post-run keeper check (tests/helpers/keeper-leaks.sh), which tests/run.sh runs
# after the suites. Its predecessor, the holder check, exists because 128 orphaned
# overlay holders once accumulated in two days of running this suite without anything
# noticing; a keeper that outlives its joins is the same leak in the new shape.
#
# A fake keeper is a process whose argv[0] is `agent-sandbox-keeper` -- the same
# STRUCTURE the check matches on -- started with `exec -a` over sleep, with the HOME
# the check reads from its environment.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  KL="$REPO_ROOT/tests/helpers/keeper-leaks.sh"
  export AS_KEEPER_SETTLE=2
  export AS_REAL_HOME="$BATS_TEST_TMPDIR/realhome"
  # Only this test's fake keepers: other suites may be running keepers beside it.
  export AS_KEEPER_SCOPE="$BATS_TEST_TMPDIR"
  FAKES=()
}

teardown() {
  local p
  for p in ${FAKES[@]+"${FAKES[@]}"}; do kill -KILL "$p" 2>/dev/null; done
  return 0
}

fake_keeper() { # fake_keeper SECONDS HOME
  (HOME="$2" exec -a agent-sandbox-keeper sleep "$1") </dev/null >/dev/null 2>&1 3>&- &
  FAKES+=("$!")
  disown "$!"
  sleep 0.3
}

@test "a keeper the suite leaves running fails the check, is named, and is killed" {
  local before
  before="$("$KL" snapshot)"
  fake_keeper 60 "$BATS_TEST_TMPDIR/testhome"
  local pid="${FAKES[0]}"
  # shellcheck disable=SC2086 # a list of pids
  run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $pid"* ]]
  [[ "$output" == *"testhome"* ]]
  sleep 0.5
  [ ! -d "/proc/$pid" ]
}

@test "a keeper that ends within the settle window passes: that is the grace working" {
  local before
  before="$("$KL" snapshot)"
  fake_keeper 1 "$BATS_TEST_TMPDIR/testhome"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
}

@test "a keeper that was already running before the suite is not counted" {
  fake_keeper 60 "$BATS_TEST_TMPDIR/testhome"
  local before
  before="$("$KL" snapshot)"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ] # and it was left alone
}

@test "a REAL session's keeper started during the run is never counted or killed" {
  # Its HOME is the user's own, which no test uses.
  local before
  before="$("$KL" snapshot)"
  fake_keeper 60 "$AS_REAL_HOME"
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ -d "/proc/${FAKES[0]}" ]
}

@test "nothing new running means no wait at all" {
  local before t0
  before="$("$KL" snapshot)"
  t0=$SECONDS
  # shellcheck disable=SC2086
  run "$KL" check $before
  [ "$status" -eq 0 ]
  [ $((SECONDS - t0)) -lt 2 ]
}

# What a leak's report says of where it came from (keeper-leaks.sh describe).

start_of() { # start_of PID -- field 22 of its stat
  local st
  read -r st <"/proc/$1/stat"
  st="${st##*) }"
  # shellcheck disable=SC2086 # the fields
  set -- $st
  printf '%s' "${20}"
}

# fake_supervised SECONDS HOME DIR -- a fake keeper under a fake supervisor: a bash
# whose argv[0] is fake-supervisor, in DIR, with HOME and XDG_STATE_HOME=HOME/state,
# that starts the keeper and waits for it; its script has a newline, as pasta's has.
# Sets SUP and KPID.
fake_supervised() {
  local i
  rm -f "$BATS_TEST_TMPDIR/kpid"
  # shellcheck disable=SC2016 # expanded by the fake supervisor
  (cd "$3" && HOME="$2" XDG_STATE_HOME="$2/state" exec -a fake-supervisor \
    bash -c 'exec -a agent-sandbox-keeper sleep "$1" &
echo "$!" >"$2.new" && mv "$2.new" "$2"; wait' _ "$1" "$BATS_TEST_TMPDIR/kpid") \
    </dev/null >/dev/null 2>&1 3>&- &
  SUP=$!
  FAKES+=("$SUP")
  disown "$SUP"
  for ((i = 0; i < 100; i++)); do
    [[ -s "$BATS_TEST_TMPDIR/kpid" ]] && break
    sleep 0.05
  done
  KPID="$(cat "$BATS_TEST_TMPDIR/kpid")"
  FAKES+=("$KPID")
  sleep 0.2
}

@test "a leak's report says when it started, under which processes, and where its record is" {
  local home="$BATS_TEST_TMPDIR/testhome" work="$BATS_TEST_TMPDIR/work" before rec
  mkdir -p "$home" "$work"
  work="$(cd "$work" && pwd -P)"
  before="$("$KL" snapshot)"
  fake_supervised 60 "$home" "$work"
  # Its record, as the engine writes it (SUPERVISOR START PAYLOAD START INIT START),
  # and one that names another process at the same pid, which is not its.
  rec="$home/state/agent-sandbox/probe/-work/default"
  mkdir -p "$rec/keeper" "$home/state/agent-sandbox/probe/-work/other/keeper"
  printf '%s %s %s %s 0 0\n' "$SUP" "$(start_of "$SUP")" "$KPID" "$(start_of "$KPID")" >"$rec/keeper/id"
  printf '%s %s %s %s 0 0\n' "$SUP" 1 "$KPID" 1 >"$home/state/agent-sandbox/probe/-work/other/keeper/id"
  # shellcheck disable=SC2086 # a list of pids
  AS_RUN_START="$(($(date +%s) - 100))" run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $KPID: HOME=$home"$'\n'* ]]
  [[ "$output" =~ started:\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}[^,]*,\ (9[5-9]|10[0-5])\ s\ into\ the\ run ]]
  # one line each, its script's newline included
  [[ "$output" == *$'\n'"      $SUP fake-supervisor -c exec -a agent-sandbox-keeper sleep \"\$1\" & echo "* ]]
  [[ "$output" == *"supervisor: pid $SUP, the first above bwrap and pasta; cwd $work; HOME=$home; XDG_STATE_HOME=$home/state"* ]]
  [[ "$output" == *"keeper record: $rec"$'\n'* ]]
  [[ "$output" != *"/other"* ]]
  [[ "$output" == *"test: none of its mounts is from a bats test's directory"* ]] # no mounts of its own
  sleep 0.5
  [ ! -d "/proc/$KPID" ] # and it is killed as before
}

# fake_chain HOME DIR [reaper] -- a fake keeper as a real one runs: under bwrap, under
# pasta, under a fake supervisor (argv[0] fake-supervisor, in DIR, with HOME). bwrap and
# pasta are bash run by those names, so those are their comms. With `reaper`, the
# supervisor is started by a subreaper (prctl PR_SET_CHILD_SUBREAPER) whose HOME is the
# real one, as systemd --user is. Sets SUP, KPID and REAPER.
fake_chain() {
  local d="$BATS_TEST_TMPDIR/chain" i
  mkdir -p "$d"
  ln -sf "$(command -v bash)" "$d/bwrap"
  ln -sf "$(command -v bash)" "$d/pasta"
  rm -f "$d/sup" "$d/kpid"
  # shellcheck disable=SC2016 # expanded by the fakes
  {
    printf '%s\n' 'echo "$$" >"$CHAIN/sup"; "$CHAIN/pasta" "$CHAIN/pasta.sh" & wait' >"$d/sup.sh"
    printf '%s\n' '"$CHAIN/bwrap" "$CHAIN/bwrap.sh" & wait' >"$d/pasta.sh"
    printf '%s\n' 'exec -a agent-sandbox-keeper sleep 60 & echo "$!" >"$CHAIN/kpid"; wait' >"$d/bwrap.sh"
  }
  local start="cd \"\$1\" && HOME=\"\$2\" CHAIN=\"\$3\" exec -a fake-supervisor bash \"\$3/sup.sh\""
  REAPER=""
  if [[ "${3:-}" == reaper ]]; then
    (HOME="$AS_REAL_HOME" exec python3 -c '
import ctypes, subprocess, sys, time
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
subprocess.Popen(["bash", "-c"] + sys.argv[1:], stdin=subprocess.DEVNULL)
import os
end = time.time() + 60
while time.time() < end:
    try:
        os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        pass
    time.sleep(0.1)
' "$start" _ "$2" "$1" "$d") </dev/null >/dev/null 2>&1 3>&- &
    REAPER=$!
    FAKES+=("$REAPER")
    disown "$REAPER"
  else
    bash -c "$start" _ "$2" "$1" "$d" </dev/null >/dev/null 2>&1 3>&- &
    disown "$!"
  fi
  for ((i = 0; i < 100; i++)); do
    [[ -s "$d/sup" && -s "$d/kpid" ]] && break
    sleep 0.05
  done
  SUP="$(cat "$d/sup")" KPID="$(cat "$d/kpid")"
  FAKES+=("$SUP" "$KPID")
  sleep 0.2
}

@test "under bwrap and pasta, as a real keeper runs, the supervisor is the first process above them" {
  local home="$BATS_TEST_TMPDIR/testhome" work="$BATS_TEST_TMPDIR/work" before
  mkdir -p "$home" "$work"
  work="$(cd "$work" && pwd -P)"
  before="$("$KL" snapshot)"
  fake_chain "$home" "$work"
  # shellcheck disable=SC2086 # a list of pids
  run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"ancestry, its parent first:"$'\n'"      "*" $BATS_TEST_TMPDIR/chain/bwrap $BATS_TEST_TMPDIR/chain/bwrap.sh"$'\n'"      "*" $BATS_TEST_TMPDIR/chain/pasta $BATS_TEST_TMPDIR/chain/pasta.sh"$'\n'"      $SUP fake-supervisor $BATS_TEST_TMPDIR/chain/sup.sh"$'\n'* ]]
  [[ "$output" == *"supervisor: pid $SUP, the first above bwrap and pasta; cwd $work; HOME=$home"* ]]
  [[ "$output" != *"supervisor is gone"* ]]
}

@test "a supervisor killed under a subreaper with the user's own HOME (systemd --user) is gone, not the reaper" {
  command -v python3 >/dev/null || skip "python3 not installed"
  local home="$BATS_TEST_TMPDIR/testhome" before
  mkdir -p "$home" "$AS_REAL_HOME"
  before="$("$KL" snapshot)"
  fake_chain "$home" "$BATS_TEST_TMPDIR" reaper
  kill -KILL "$SUP"
  sleep 0.5 # pasta is the reaper's now
  # shellcheck disable=SC2086 # a list of pids
  run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $KPID: HOME=$home"* ]]
  [[ "$output" == *$'\n'"      $REAPER python3 -c "* ]] # the ancestry shows it
  [[ "$output" == *"its supervisor is gone: pid $REAPER, with the user's own HOME, is the reaper that took the orphans"* ]]
  [[ "$output" != *"supervisor: pid"* ]]
  [[ "$output" != *"under $AS_REAL_HOME"* ]] # and no record is looked for under its HOME
}

@test "a leak whose HOME has gone says so instead of a record" {
  local home="$BATS_TEST_TMPDIR/gonehome" before
  mkdir -p "$home"
  before="$("$KL" snapshot)"
  fake_supervised 60 "$home" "$BATS_TEST_TMPDIR"
  rmdir "$home"
  # shellcheck disable=SC2086 # a list of pids
  run "$KL" check $before
  [ "$status" -eq 1 ]
  [[ "$output" == *"keeper record: its HOME is gone (bats removes a test's directory when the run ends)"* ]]
  [[ "$output" != *"into the run"* ]] # no run start given: the wall-clock time alone
  [[ "$output" == *"started: "* ]]
}

@test "a keeper whose environ cannot be read is still described, from what can be read" {
  command -v python3 >/dev/null || skip "python3 not installed"
  # Not dumpable: its environ (and cwd) are refused to its own user, as pasta's are.
  # The check cannot count it under a scope (its HOME is unreadable, and so is
  # outside every scope), so it is described directly; HOME=? is the check's line.
  local p
  (HOME="$BATS_TEST_TMPDIR/testhome" exec -a agent-sandbox-keeper python3 -c \
    'import ctypes, time; ctypes.CDLL(None).prctl(4, 0, 0, 0, 0); time.sleep(60)') \
    </dev/null >/dev/null 2>&1 3>&- &
  p=$!
  FAKES+=("$p")
  disown "$p"
  sleep 0.5
  run cat "/proc/$p/environ"
  [ "$status" -ne 0 ] || skip "a process that is not dumpable is readable here"
  AS_KEEPER_SCOPE="" run "$KL" snapshot
  [[ $'\n'"$output"$'\n' == *$'\n'"$p"$'\n'* ]] # it is a keeper to the check
  run "$KL" describe "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid $p:"$'\n'"    started: "* ]]
  # its parent is this test's shell, whose cwd and environ are readable
  [[ "$output" == *"ancestry, its parent first:"$'\n'"      $BASHPID "* ]]
  [[ "$output" == *"supervisor: pid $BASHPID, the first above bwrap and pasta; cwd $(pwd -P); HOME="* ]]
  [[ "$output" != *"denied"* && "$output" != *"No such"* ]] # markers, never errors
}

@test "with no leak the check prints nothing, the grace included" {
  local before
  before="$("$KL" snapshot)"
  fake_supervised 1 "$BATS_TEST_TMPDIR/testhome" "$BATS_TEST_TMPDIR"
  # shellcheck disable=SC2086 # a list of pids
  AS_RUN_START=1 run "$KL" check $before
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a keeper that has exited but is not yet reaped is said to have ended" {
  command -v python3 >/dev/null || skip "python3 not installed"
  run python3 -c '
import os, subprocess, sys, time
pid = os.fork()
if pid == 0:
    os.execvp("sleep", ["agent-sandbox-keeper", "0.1"])
time.sleep(0.5)  # it has exited; nothing reaps it yet
sys.stdout.flush()
subprocess.run([sys.argv[1], "describe", str(pid)])
os.waitpid(pid, 0)
' "$KL"
  [ "$status" -eq 0 ]
  [[ "$output" == "  pid "*":"$'\n'"    it has ended: a zombie, not yet reaped" ]]
}

@test "a keeper that ended before it was described is said to have ended" {
  run "$KL" describe 999999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"pid 999999999:"$'\n'"    it ended before it could be described" ]]
}
