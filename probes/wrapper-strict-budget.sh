#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Issue #45, item 2: does the wrapper role fit Claude Code's per-spawn budget
# (fpe = 12000 ms) under `strict`, where it builds a pasta netns + nftables rule
# on top of the bwrap it builds in `proxy`? A worker that is not ready inside the
# budget is abandoned by the daemon (warm-attach lost), so the strict overhead
# must stay well under 12 s.
#
# Times the --wrap role end to end (build the sandbox + run a trivial command
# inside) in proxy and in strict, N runs each, and reports the max -- the number
# that matters against the budget. `strict` needs passt/pasta; it is skipped if
# absent. HOST only; runs nothing in the background, leaves no state.
#     ./probes/wrapper-strict-budget.sh [N]
set -uo pipefail

BUDGET_MS=12000
N="${1:-5}"
ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "engine has no --wrap: $ENGINE"
  exit 1
}
_pick_nat() {
  local d="$HOME/.local/share/claude/versions" v c
  while IFS= read -r v; do
    if [ -x "$d/$v" ] && [ ! -d "$d/$v" ]; then
      echo "$d/$v"
      return 0
    fi
    for c in "$d/$v/claude" "$d/$v/bin/claude"; do
      [ -x "$c" ] && {
        echo "$c"
        return 0
      }
    done
  done < <(find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -rV)
  return 1
}
nat="$(_pick_nat)" || {
  echo "no runnable claude found"
  exit 1
}

# Milliseconds to build the sandbox and run `claude --version` inside, via the
# --wrap role (the <binary> token after --wrap is discarded by the role, so any
# placeholder works; --version is an "unknown worker verb" -> sandboxed, run).
_time_ms() {
  local mode="$1" t0 t1
  t0=$(date +%s%3N)
  AGENT_SANDBOX_NET="$mode" "$ENGINE" --profile claude --wrap claude --version >/dev/null 2>&1 || return 1
  t1=$(date +%s%3N)
  echo $((t1 - t0))
}
_run_mode() {
  local mode="$1" ms max=0 sum=0 ok=0
  for _ in $(seq 1 "$N"); do
    ms="$(_time_ms "$mode")" || {
      echo "   $mode: a run failed (mode unavailable?)"
      return 1
    }
    ((ms > max)) && max=$ms
    sum=$((sum + ms))
    ok=$((ok + 1))
  done
  printf '   %-6s runs=%d  avg=%dms  max=%dms  budget=%dms  %s\n' \
    "$mode" "$ok" "$((sum / ok))" "$max" "$BUDGET_MS" \
    "$([ "$max" -lt "$BUDGET_MS" ] && echo "OK (max ${max}ms < ${BUDGET_MS}ms)" || echo "OVER BUDGET")"
  echo "$max"
}

echo "engine: $ENGINE ; runtime: $nat ; runs per mode: $N"
echo "== timing the --wrap role (sandbox build + claude --version) =="

pmax=""
pmax="$(_run_mode proxy | tail -1)"

smax=""
if command -v passt >/dev/null 2>&1 || command -v pasta >/dev/null 2>&1; then
  smax="$(_run_mode strict | tail -1)"
else
  echo "   strict: skipped (passt/pasta not installed)"
fi

echo
echo "== verdict =="
if [ -n "$smax" ] && [ -n "$pmax" ]; then
  echo "   strict adds ~$((smax - pmax))ms over proxy (pasta netns + nft rule)."
  [ "$smax" -lt "$BUDGET_MS" ] \
    && echo "   CONFIRMED: strict max ${smax}ms is within the ${BUDGET_MS}ms wrapper budget." \
    || echo "   WARNING: strict max ${smax}ms exceeds the ${BUDGET_MS}ms budget -- workers may be abandoned."
elif [ -n "$pmax" ]; then
  echo "   proxy max ${pmax}ms within budget; strict not measured (no passt/pasta)."
fi
echo "done."
