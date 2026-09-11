#!/usr/bin/env bash
# How long does the engine take to reach the agent, per network mode?
#
# This decides whether agent-sandbox can act as a CLAUDE_CODE_PROCESS_WRAPPER.
# That contract gives a launcher about three seconds to reach `exec`, and in
# strict mode the engine sets up a pasta namespace and nftables rules first. If
# strict exceeds the budget, wrapper support is viable only in the looser modes
# and the docs have to say so.
#
# `claude --version` is the measurement: the agent prints and exits at once, so
# nearly all the wall time is the engine's own setup plus exec.
#
# Run on the HOST, as yourself (not inside the sandbox, which cannot nest):
#     ./probes/startup-timing.sh [runs]
set -uo pipefail

runs="${1:-5}"
say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

command -v claude >/dev/null || {
  note "no \`claude\` on PATH"
  exit 1
}
note "launcher: $(command -v claude) -> $(readlink -f "$(command -v claude)")"
note "runs per mode: $runs"

# A directory with no .agent-sandbox, so the dot-file cannot change the mode
# under test. Its own project state is irrelevant to timing.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

timed() { # timed MODE -- prints the wall seconds of one launch, or "fail"
  local mode=$1 t0 t1
  t0=$(date +%s.%N)
  if ! (cd "$work" && AGENT_SANDBOX_NET="$mode" timeout 60 claude --version >/dev/null 2>&1); then
    printf 'fail'
    return
  fi
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}'
}

for mode in none proxy strict; do
  say "AGENT_SANDBOX_NET=$mode"
  times=()
  for ((i = 0; i < runs; i++)); do
    t="$(timed "$mode")"
    times+=("$t")
    printf '   run %d: %s\n' "$((i + 1))" "$t"
  done
  printf '%s\n' "${times[@]}" | grep -v fail | sort -n | awk '
    {v[NR]=$1}
    END{
      if(NR==0){print "   all runs failed"; exit}
      printf "   min %.2fs  median %.2fs  max %.2fs", v[1], v[int((NR+1)/2)], v[NR]
      print (v[NR] > 3 ? "   <-- OVER the 3s wrapper budget" : "   (within the 3s wrapper budget)")
    }'
done

say "Cold vs warm"
note "The proxy service and any conda environment are already running by now, so"
note "these are WARM numbers. A first launch after boot pays more; re-run this"
note "right after a reboot to see the worst case."

say "Done"
note "What matters for the wrapper: whether strict's max stays under ~3 seconds."
