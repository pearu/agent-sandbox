#!/usr/bin/env bash
# orphans.sh -- find, and with --kill end, what a sandbox left running after its
# parent was killed (#127). RUN ON THE HOST.
#
#   probes/orphans.sh          list them
#   probes/orphans.sh --kill   list them, then kill each (SIGKILL)
#
# Two shapes, each recognised by STRUCTURE, never by a command-line pattern:
#   - a keeper payload (argv[0] exactly `agent-sandbox-keeper`) whose parent is gone.
#     Under the real bwrap its parent is bwrap's pid 1, and killing that ends it; one
#     found reparented is a leak -- measured on a development host 2026-09-30, from a
#     unit-suite run whose stub bwrap plays the keeper on the host.
#   - a holder sleeper of an engine before #116: `sleep infinity` in a mount namespace
#     that is not the host's, whose parent is gone. 181 of them, up to 179 hours old,
#     were measured on one host (2026-09-27); each kept its namespaces and the mounts
#     they held alive.
# "Parent gone" is reparented: to pid 1, or to a `systemd --user` that took it as a
# subreaper. A live keeper or holder has its bwrap as parent, so it is never listed.
set -euo pipefail

kill_them=0
case "${1:-}" in
  "") ;;
  --kill) kill_them=1 ;;
  *)
    echo "usage: probes/orphans.sh [--kill]" >&2
    exit 2
    ;;
esac

host_mnt="$(readlink /proc/1/ns/mnt 2>/dev/null || readlink /proc/self/ns/mnt)"

# orphaned PID -- its parent is pid 1, or a systemd acting as a subreaper
orphaned() {
  local pp
  pp="$(awk '/^PPid:/ {print $2}' "/proc/$1/status" 2>/dev/null)" || return 1
  [[ "$pp" == 1 ]] && return 0
  [[ "$(cat "/proc/$pp/comm" 2>/dev/null)" == systemd ]]
}

found=0
for c in /proc/[0-9]*/cmdline; do
  p="${c#/proc/}" p="${p%/cmdline}"
  [[ "$p" == "$$" ]] && continue
  argv=()
  mapfile -d '' -t argv <"$c" 2>/dev/null || continue # it may exit while we look
  ((${#argv[@]})) || continue
  what=""
  if [[ "${argv[0]}" == agent-sandbox-keeper ]]; then
    what="keeper payload"
  elif [[ "${argv[0]}" == sleep && "${argv[1]:-}" == infinity && ${#argv[@]} -eq 2 ]] \
    && [[ "$(readlink "/proc/$p/ns/mnt" 2>/dev/null)" != "$host_mnt" ]]; then
    what="holder sleeper (before #116)"
  else
    continue
  fi
  orphaned "$p" || continue
  found=$((found + 1))
  printf 'pid %s: %s, started %s, HOME=%s\n' "$p" "$what" \
    "$(ps -o lstart= -p "$p" 2>/dev/null | sed 's/  */ /g')" \
    "$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)"
  ((kill_them)) && { kill -KILL "$p" 2>/dev/null || true; }
done
if ((found == 0)); then
  echo "no orphans"
elif ((kill_them)); then
  echo "killed $found"
else
  echo "$found found; run with --kill to end them"
fi
