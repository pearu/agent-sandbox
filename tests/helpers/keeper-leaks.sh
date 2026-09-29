#!/usr/bin/env bash
# keeper-leaks.sh -- find role keepers a test run left running.
#   keeper-leaks.sh snapshot           print the pids of the keepers alive now
#   keeper-leaks.sh check PID...       fail if a keeper not in PID... is still alive
#                                      after the settle window; name it, and kill it
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
    home="$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)"
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

case "${1:-}" in
  snapshot) keepers | cut -f1 ;;
  check)
    shift
    [[ -n "$(new_keepers "$@")" ]] || exit 0
    sleep "${AS_KEEPER_SETTLE:-7}"
    left="$(new_keepers "$@")"
    [[ -n "$left" ]] || exit 0
    echo "tests/run.sh: the run left role keepers running (nothing is joined into them; they should have ended):" >&2
    while IFS=$'\t' read -r p what; do
      echo "  pid $p: HOME=$what" >&2
      kill -KILL "$p" 2>/dev/null || true
    done <<<"$left"
    echo "  killed. A keeper ends when its last join does; see _as_keeper_supervise." >&2
    exit 1
    ;;
  *)
    echo "usage: keeper-leaks.sh snapshot | check PID..." >&2
    exit 2
    ;;
esac
