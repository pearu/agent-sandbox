#!/usr/bin/env bash
# orphans.sh -- find, and with --kill end, what a sandbox left running after its
# parent was killed (#127). RUN ON THE HOST.
#
#   probes/orphans.sh          list them
#   probes/orphans.sh --kill   list them, then kill each (SIGKILL)
#
# Four shapes, each recognised by STRUCTURE, never by a command-line pattern:
#   - a keeper payload (argv[0] exactly `agent-sandbox-keeper`) whose parent is gone.
#     Under the real bwrap its parent is bwrap's pid 1, and killing that ends it; one
#     found reparented is a leak -- measured on a development host 2026-09-30, from a
#     unit-suite run whose stub bwrap plays the keeper on the host.
#   - a strict keeper whose supervisor is gone (#430): a keeper payload with its parent,
#     below a pasta whose parent is gone. Under `strict` the payload's parent is bwrap,
#     bwrap's is pasta, and pasta's the supervisor; a SIGKILL of the supervisor ends none
#     of them on a host where AppArmor confines pasta (measured), so its watcher does
#     (_as_keeper_tie). A watcher killed with it leaves this. --kill ends the pasta and
#     everything between it and the payload.
#   - a strict keeper's watcher whose parent is gone (`bash -c BODY agent-sandbox-tie
#     ...`): it ends at once when its supervisor dies, so one still there is stuck.
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

# pasta_above PID -- the chain from PID's parent up to the first pasta above it, when
# that pasta is orphaned: pids in $chain, the pasta last. Fails at pid 1 or a pasta
# with its parent.
pasta_above() {
  local q="$1" pp c
  chain=()
  while :; do
    pp="$(awk '/^PPid:/ {print $2}' "/proc/$q/status" 2>/dev/null)" || return 1
    [[ -n "$pp" && "$pp" != 0 && "$pp" != 1 ]] || return 1
    chain+=("$pp")
    c="$(cat "/proc/$pp/comm" 2>/dev/null)"
    if [[ "$c" == pasta || "$c" == pasta.avx2 ]]; then
      orphaned "$pp"
      return
    fi
    q="$pp"
  done
}

found=0
for c in /proc/[0-9]*/cmdline; do
  p="${c#/proc/}" p="${p%/cmdline}"
  [[ "$p" == "$$" ]] && continue
  argv=()
  { mapfile -d '' -t argv <"$c"; } 2>/dev/null || continue # it may exit while we look
  ((${#argv[@]})) || continue
  what=""
  chain=()
  if [[ "${argv[0]}" == agent-sandbox-keeper ]]; then
    if orphaned "$p"; then
      what="keeper payload"
    elif pasta_above "$p"; then
      what="strict keeper payload, its supervisor gone (pasta ${chain[-1]} orphaned)"
    else
      continue
    fi
  elif [[ "${argv[0]##*/}" == bash && "${argv[1]:-}" == -c && "${argv[3]:-}" == agent-sandbox-tie ]]; then
    orphaned "$p" || continue
    what="strict keeper's watcher, its supervisor gone"
  elif [[ "${argv[0]}" == sleep && "${argv[1]:-}" == infinity && ${#argv[@]} -eq 2 ]] \
    && [[ "$(readlink "/proc/$p/ns/mnt" 2>/dev/null)" != "$host_mnt" ]]; then
    orphaned "$p" || continue
    what="holder sleeper (before #116)"
  else
    continue
  fi
  found=$((found + 1))
  printf 'pid %s: %s, started %s, HOME=%s\n' "$p" "$what" \
    "$(ps -o lstart= -p "$p" 2>/dev/null | sed 's/  */ /g')" \
    "$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)"
  # the pasta first (the last of the chain), which ends what is below it with the rest
  if ((kill_them)); then
    for ((i = ${#chain[@]} - 1; i >= 0; i--)); do kill -KILL "${chain[i]}" 2>/dev/null || true; done
    kill -KILL "$p" 2>/dev/null || true
  fi
done
if ((found == 0)); then
  echo "no orphans"
elif ((kill_them)); then
  echo "killed $found"
else
  echo "$found found; run with --kill to end them"
fi
