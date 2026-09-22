#!/usr/bin/env bash
# holder-leaks.sh -- find overlay holders a test run left running.
#   holder-leaks.sh snapshot           print the pids of the holders alive now
#   holder-leaks.sh check PID...       fail if a holder not in PID... is still alive
#                                      after the settle window; name it, and kill it
# tests/run.sh takes a snapshot before the suites and checks after them. A holder
# leaves on its own within five seconds of its sandbox being deleted, so one still
# running after that is a leak -- and 128 of them once accumulated in two days of
# running this suite with nothing noticing. It is killed as well as reported, so a
# leak costs one failed run rather than a slowly filling process table.
#
# A holder is recognised by STRUCTURE, never by a pattern: argv[0] is bwrap and an
# argument is exactly --overlay-src. A `pgrep -f` pattern matches the command line
# of whatever runs it, and excluding `bash -c` to avoid that excludes every holder
# too (its inner command is a bash -c). Both have happened.
#
# A holder whose upper layer is under the user's real state directory belongs to a
# real session started during the run, not to a test (the tests all use a
# throwaway HOME), and is never counted or killed.
#   AS_HOLDER_SETTLE  seconds to wait before the recount (default 7: one poll and change)
#   AS_REAL_STATE     the real state directory (default: the engine's)
set -euo pipefail

real_state="${AS_REAL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-sandbox}"

# holders -- one line per holder: PID, a tab, its first --overlay-src and --overlay.
holders() {
  local c p a argv src upper
  for c in /proc/[0-9]*/cmdline; do
    p="${c#/proc/}" p="${p%/cmdline}"
    argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done <"$c" 2>/dev/null || continue
    ((${#argv[@]})) && [[ "${argv[0]##*/}" == bwrap ]] || continue
    src="" upper=""
    for ((a = 1; a < ${#argv[@]} - 1; a++)); do
      [[ -z "$src" && "${argv[a]}" == --overlay-src ]] && src="${argv[a + 1]}"
      [[ -z "$upper" && "${argv[a]}" == --overlay ]] && upper="${argv[a + 1]}"
    done
    [[ -n "$src" ]] || continue
    [[ -n "$upper" && "$upper/" == "$real_state/"* ]] && continue
    printf '%s\t%s -> %s\n' "$p" "$src" "$upper"
  done
}

# new_holders PID... -- the holders not among PID...
new_holders() {
  local line p q
  holders | while IFS= read -r line; do
    p="${line%%$'\t'*}"
    for q in "$@"; do [[ "$p" == "$q" ]] && continue 2; done
    printf '%s\n' "$line"
  done
}

case "${1:-}" in
  snapshot) holders | cut -f1 ;;
  check)
    shift
    [[ -n "$(new_holders "$@")" ]] || exit 0
    sleep "${AS_HOLDER_SETTLE:-7}"
    left="$(new_holders "$@")"
    [[ -n "$left" ]] || exit 0
    echo "tests/run.sh: the run left overlay holders running (their sandboxes are gone; they should have exited):" >&2
    while IFS=$'\t' read -r p what; do
      echo "  pid $p: $what" >&2
      # The holder's shell is a child of its bwrap (no pid namespace), and killing
      # the bwrap alone would orphan it.
      pkill -KILL -P "$p" 2>/dev/null || true
      kill -KILL "$p" 2>/dev/null || true
    done <<<"$left"
    echo "  killed. A holder is found and stopped only through holder.id; see _as_holder_ensure." >&2
    exit 1
    ;;
  *)
    echo "usage: holder-leaks.sh snapshot | check PID..." >&2
    exit 2
    ;;
esac
