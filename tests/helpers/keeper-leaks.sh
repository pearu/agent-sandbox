#!/usr/bin/env bash
# keeper-leaks.sh -- find role keepers a test run left running.
#   keeper-leaks.sh snapshot           print the pids of the keepers alive now
#   keeper-leaks.sh check PID...       fail if a keeper not in PID... is still alive
#                                      after the settle window; name it, say where it
#                                      came from (describe), and kill it
#   keeper-leaks.sh describe PID...    where each keeper payload PID came from
# tests/run.sh takes a snapshot before the suites and checks after them. The suites
# run with no idle grace, so a keeper ends with its last join; one still running
# after the settle window is a leak. It is killed as well as reported, so a leak
# costs one failed run rather than a slowly filling process table -- 128 overlay
# holders, the keeper's predecessor, once accumulated in two days with nothing
# noticing.
#
# A keeper is recognised by STRUCTURE, never by a pattern: its payload's argv[0] is
# exactly `agent-sandbox-keeper`, under the real bwrap and under the unit suite's
# stub alike. A `pgrep -f` pattern matches the command line of whatever runs it.
# Killing the payload ends the keeper: bwrap's pid 1 goes with it, and the
# supervisor then cleans up after the launch.
#
# A keeper whose HOME is the user's own belongs to a real session started during the
# run, not to a test (the tests all use a throwaway HOME), and is never counted or
# killed.
#
# WHERE A LEAK CAME FROM (describe), read only once there is one, from the host's
# /proc: under bats the check runs after bats has removed the tests' directories, so
# the payload and its ancestors are what is left to read (measured on a real bwrap
# keeper, T9):
# - its start, as wall-clock time and, given AS_RUN_START, seconds into the run;
# - the test: a bats test's directory is $BATS_RUN_TMPDIR/test/N, N being the number
#   of its `ok N` / `not ok N` line, serially and under --jobs alike; the roots of
#   the payload's mounts (mountinfo field 4) still name it once it is deleted;
# - its ancestry, one process a line, payload's parent first: bwrap twice, pasta under
#   strict, then the supervisor -- the engine's fork, its command line the launch's.
#   The supervisor is taken to be the first process above bwrap and pasta, unless that
#   is a reaper: pid 1, or a subreaper (systemd --user) -- told by its HOME, the user's
#   own, which no test's launch has. Then the supervisor is gone (under strict the
#   payload outlives it: bwrap dies with its parent, which is pasta);
# - the supervisor's cwd and its HOME, XDG_STATE_HOME and AGENT_SANDBOX_SESSION_BASE,
#   which are the test's (pasta's environ is unreadable, the others' are not);
# - the keeper's record, if its directories are still there;
# - and when the payload ended while the check looked: already reaped, a zombie, or
#   gone when the kill came -- a keeper that ended late rather than a leak.
# Each detail it cannot read is marked so, and nothing in it fails the check.
#   AS_RUN_START      the run's start, in seconds since the epoch (tests/run.sh)
#   AS_KEEPER_SETTLE  seconds to wait before the recount (default 7)
#   AS_REAL_HOME      the real home directory (default: $HOME)
#   AS_KEEPER_SCOPE   count only keepers whose HOME is under this directory (default:
#                     all). The check's own tests set it: suites may run side by side
#                     (scripts/coverage.sh runs files in parallel), and a check that
#                     kills every new keeper on the machine kills other tests' keepers.
set -euo pipefail

real_home="${AS_REAL_HOME:-$HOME}"

# keepers -- one line per keeper payload: PID, a tab, its HOME.
keepers() {
  local c p a0 home
  for c in /proc/[0-9]*/cmdline; do
    p="${c#/proc/}" p="${p%/cmdline}"
    a0=""
    { IFS= read -r -d '' a0 <"$c"; } 2>/dev/null || true # it may exit while we look
    [[ "$a0" == agent-sandbox-keeper ]] || continue
    # Braced: the redirection fails when the process exits while we look, and bash
    # reports a failed redirection before the command's own 2> is in place.
    home="$({ tr '\0' '\n' <"/proc/$p/environ"; } 2>/dev/null | sed -n 's/^HOME=//p' | head -1)" || true
    [[ -n "$home" && "$home" == "$real_home" ]] && continue
    [[ -z "${AS_KEEPER_SCOPE:-}" || "$home" == "$AS_KEEPER_SCOPE"/* ]] || continue
    printf '%s\t%s\n' "$p" "${home:-?}"
  done
}

# new_keepers PID... -- the keepers not among PID...
new_keepers() {
  local line p q
  keepers | while IFS= read -r line; do
    p="${line%%$'\t'*}"
    for q in "$@"; do [[ "$p" == "$q" ]] && continue 2; done
    printf '%s\n' "$line"
  done
}

# The description's readers: each prints nothing and returns 1 when it cannot read.
stat_of() { # stat_of PID -- its state and its start in clock ticks after boot (fields 3 and 22)
  local st
  { read -r st <"/proc/$1/stat"; } 2>/dev/null || return 1
  st="${st##*) }" # the comm field can hold spaces and parentheses
  local -a f
  read -r -a f <<<"$st"
  [[ -n "${f[19]:-}" ]] && printf '%s %s' "${f[0]}" "${f[19]}"
}
ppid_of() {
  local k v
  while read -r k v; do
    [[ "$k" == PPid: ]] && printf '%s' "$v" && return 0
  done 2>/dev/null <"/proc/$1/status" || return 1
  return 1
}
comm_of() {
  local c
  { read -r c <"/proc/$1/comm"; } 2>/dev/null && printf '%s' "$c"
}
cmdline_of() { # cmdline_of PID -- its arguments on one line, cut to 160 characters
  local c
  c="$({ tr '\0\n\t' '   ' <"/proc/$1/cmdline"; } 2>/dev/null)" && [[ -n "$c" ]] || return 1
  c="${c% }"
  ((${#c} <= 160)) || c="${c:0:160}..."
  printf '%s' "$c"
}
env_of() { # env_of PID NAME -- its value; returns 2 when the environ cannot be read
  { : <"/proc/$1/environ"; } 2>/dev/null || return 2
  local l
  while IFS= read -r -d '' l; do
    [[ "$l" == "$2="* ]] && printf '%s' "${l#*=}" && return 0
  done 2>/dev/null <"/proc/$1/environ"
  return 1
}

# describe PID -- the indented lines under a leak's name that say where it came from.
describe() {
  local p="$1" t hz btime s when q n c line sup="" gone="" last="" home="" v rc
  if ! t="$(stat_of "$p")"; then
    echo "    it ended before it could be described"
    return 0
  fi
  case "${t%% *}" in
    Z | X)
      echo "    it has ended: a zombie, not yet reaped"
      return 0
      ;;
  esac
  t="${t#* }"
  hz="$(getconf CLK_TCK 2>/dev/null)" || hz=""
  btime="$(awk '$1 == "btime" {print $2; exit}' /proc/stat 2>/dev/null)" || btime=""
  if [[ "$hz" =~ ^[0-9]+$ && "$btime" =~ ^[0-9]+$ ]] && ((hz > 0)); then
    s=$((btime + t / hz))
    printf -v when '%(%F %T %Z)T' "$s"
    [[ "${AS_RUN_START:-}" =~ ^[0-9]+$ ]] && when+=", $((s - AS_RUN_START)) s into the run"
    echo "    started: $when"
  else
    echo "    started: (unreadable: no clock tick or boot time)"
  fi
  # The test, from the roots of its mounts.
  if line="$({ awk '{print $4}' "/proc/$p/mountinfo"; } 2>/dev/null)"; then
    line="$(grep -oE 'bats-run-[^/]+/test/[0-9]+' <<<"$line" | sort -u)" || true
    if [[ -n "$line" ]]; then
      while IFS= read -r v; do
        echo "    test: ${v##*/} (its mounts are from $v): the log's \`ok ${v##*/}\` or \`not ok ${v##*/}\` line"
      done <<<"$line"
    else
      echo "    test: none of its mounts is from a bats test's directory"
    fi
  else
    echo "    test: (its mounts are unreadable)"
  fi
  # Its ancestry, to pid 1 or as far as this pid namespace goes.
  echo "    ancestry, its parent first:"
  q="$p"
  for ((n = 0; n < 64; n++)); do
    q="$(ppid_of "$q")" || {
      echo "      (the next parent is unreadable)"
      break
    }
    [[ "$q" =~ ^[1-9][0-9]*$ ]] || break # 0: no parent in this pid namespace
    c="$(cmdline_of "$q")" || c="[$(comm_of "$q" || echo unreadable)]"
    echo "      $q $c"
    last="$q"
    if [[ -z "$sup$gone" ]]; then
      case "$(comm_of "$q" || true)" in
        bwrap | pasta*) ;;
        *)
          # Not a supervisor: pid 1, or a reaper with the user's own HOME (a subreaper,
          # systemd --user), which a test's launch never has.
          if [[ "$q" == 1 ]]; then
            gone="no process but bwrap and pasta below pid 1"
          elif [[ "$(env_of "$q" HOME || true)" == "$real_home" ]]; then
            gone="pid $q, with the user's own HOME, is the reaper that took the orphans"
          else
            sup="$q"
          fi
          ;;
      esac
    fi
    [[ "$q" == 1 ]] && break
  done
  if [[ -n "$gone" ]]; then
    echo "    its supervisor is gone: $gone"
  elif [[ -z "$sup" ]]; then
    echo "    its supervisor is gone or out of sight: no process above bwrap and pasta${last:+ up to pid $last}"
  else
    line="    supervisor: pid $sup, the first above bwrap and pasta; cwd $(readlink "/proc/$sup/cwd" 2>/dev/null || echo '(unreadable)')"
    for v in HOME XDG_STATE_HOME AGENT_SANDBOX_SESSION_BASE XDG_RUNTIME_DIR; do
      rc=0
      c="$(env_of "$sup" "$v")" || rc=$?
      case "$rc" in
        0) line+="; $v=$c" ;;
        2)
          line+="; its environ is unreadable"
          break
          ;;
      esac
    done
    echo "$line"
  fi
  # Its record, under the HOME found above (the payload's, else the supervisor's).
  home="$(env_of "$p" HOME)" || home=""
  [[ -n "$home" || -z "$sup" ]] || home="$(env_of "$sup" HOME)" || home=""
  if [[ -z "$home" ]]; then
    echo "    keeper record: (no HOME to look under)"
  elif [[ ! -d "$home" ]]; then
    echo "    keeper record: its HOME is gone (bats removes a test's directory when the run ends)"
  else
    local st="" base="" uid f x y found=0
    if [[ -n "$sup" ]]; then
      st="$(env_of "$sup" XDG_STATE_HOME)" || st=""
      base="$(env_of "$sup" AGENT_SANDBOX_SESSION_BASE)" || base=""
      if [[ -z "$base" ]]; then # as _as_session_base
        uid="$(id -u)"
        base="$(env_of "$sup" XDG_RUNTIME_DIR)" || base="/run/user/$uid"
        [[ -d "$base" && -w "$base" ]] || base=/tmp
        base+="/agent-sandbox.$uid"
      fi
    fi
    for f in "${st:-$home/.local/state}"/agent-sandbox/*/-*/*/keeper/id; do
      { read -r _ _ x y _ <"$f"; } 2>/dev/null || continue
      [[ "$x" == "$p" && "$y" == "$t" ]] || continue
      echo "    keeper record: ${f%/keeper/id}"
      found=1
    done
    if [[ -n "$base" ]]; then
      for f in "$base"/session.*/keeper; do
        { read -r x y <"$f"; } 2>/dev/null || continue
        [[ "$x" == "$p" && "$y" == "$t" ]] || continue
        echo "    session: ${f%/keeper}"
        found=1
      done
    fi
    ((found)) || echo "    keeper record: none naming it under ${st:-$home/.local/state}${base:+ or $base}"
  fi
  return 0
}

case "${1:-}" in
  snapshot) keepers | cut -f1 ;;
  describe)
    shift
    for p in "$@"; do
      echo "  pid $p:"
      describe "$p" || true
    done
    ;;
  check)
    shift
    [[ -n "$(new_keepers "$@")" ]] || exit 0
    sleep "${AS_KEEPER_SETTLE:-7}"
    left="$(new_keepers "$@")"
    [[ -n "$left" ]] || exit 0
    echo "tests/run.sh: the run left role keepers running (nothing is joined into them; they should have ended):" >&2
    while IFS=$'\t' read -r p what; do
      echo "  pid $p: HOME=$what" >&2
      describe "$p" >&2 || true
      if ! kill -KILL "$p" 2>/dev/null; then
        if [[ -d "/proc/$p" ]]; then
          echo "    the kill failed" >&2
        else
          echo "    it had ended by itself before the kill" >&2
        fi
      fi
    done <<<"$left"
    echo "  killed. A keeper ends when its last join does; see _as_keeper_supervise." >&2
    exit 1
    ;;
  *)
    echo "usage: keeper-leaks.sh snapshot | check PID... | describe PID..." >&2
    exit 2
    ;;
esac
