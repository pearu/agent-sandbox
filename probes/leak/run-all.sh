#!/usr/bin/env bash
# Run EVERY experiment in the leak study, in one go, keeping every row's output.
#
# WHY A SINGLE RUNNER. A method change touches every row, and the only way to know the
# rows still execute is to execute them. Running them by hand loses the output of
# whichever one failed first, and stopping at the first failure hides the rest -- so this
# keeps going, keeps each row's log, and reports at the end which rows the VALIDITY GATE
# refused. A row that exits non-zero is not an error in the batch; it is a result about
# that row.
#
# ORDER. Free rows first, so a breakage shows up before anything spends an API call; then
# the rows that run real sessions, cheapest first; then the two that need the network and
# a GitHub token. Every row builds its own tree per cell (see lib.sh leak_cell), so the
# order changes nothing about the results -- it only changes how early a mistake is seen.
#
# Usage:
#   ./probes/leak/run-all.sh                     # every row, in the order below
#   ./probes/leak/run-all.sh --free              # only the rows that cost nothing
#   ./probes/leak/run-all.sh --paid              # only the rows that spend API calls
#   ./probes/leak/run-all.sh row-01-memory.sh …  # exactly these
#
# LEAK_GH_ISSUE is passed through if set, which row 13 needs for its public-medium half.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_BASE="$(cd -- "$HERE/../.." && pwd)/probes/results/leak"

# Scripted readers: no credentials, no model, no API calls.
FREE_ROWS=(
  row-01-memory.sh row-02-transcripts.sh row-03-plans.sh row-04-history.sh
  row-10-mcpservers.sh row-11-project-history.sh row-12-downloads.sh
  row-15-agent-memory.sh row-16-session-artifacts.sh row-17-backups.sh
  row-18-uncatalogued.sh
)

# Real sessions. These cost API calls and take minutes per cell.
PAID_ROWS=(
  row-05-global-claudemd.sh row-05b-ancestor-claudemd.sh
  row-19-rules.sh row-20-output-styles.sh row-21-agents.sh
  row-06-hooks.sh row-08-commands.sh row-09-plugins.sh row-07-skills.sh
  row-22-workflows.sh
  row-23-level2-unprompted.sh row-24-level3-directed.sh
  row-25-arithmetic-canary.sh row-26-per-path-search.sh
  row-13-network.sh row-14a-mcp-capability.sh
)

case "${1:-}" in
  --free)
    ROWS=("${FREE_ROWS[@]}")
    shift
    ;;
  --paid)
    ROWS=("${PAID_ROWS[@]}")
    shift
    ;;
  "") ROWS=("${FREE_ROWS[@]}" "${PAID_ROWS[@]}") ;;
  *) ROWS=("$@") ;;
esac

BATCH="$OUT_BASE/batch-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$BATCH"
SUMMARY="$BATCH/summary.txt"
COMBINED="$BATCH/all.log"

printf 'batch %s\n%d rows: %s\n\n' "$BATCH" "${#ROWS[@]}" "${ROWS[*]}" | tee "$SUMMARY"
: >"$COMBINED"

started="$(date +%s)"
declare -a NAMES=() STATUS=() GATE=()

for row in "${ROWS[@]}"; do
  script="$HERE/$row"
  name="${row%.sh}"
  log="$BATCH/$name.log"
  if [[ ! -x "$script" ]]; then
    printf '%-28s MISSING\n' "$name" | tee -a "$SUMMARY"
    NAMES+=("$name")
    STATUS+=(missing)
    GATE+=("-")
    continue
  fi
  printf '\n===== %s =====\n' "$name" >>"$COMBINED"
  printf '%-28s running...\n' "$name"
  # stdout and stderr together: the rows say most of what matters on stderr, and keeping
  # them interleaved preserves which cell a warning belongs to.
  "$script" >"$log" 2>&1
  rc=$?
  cat "$log" >>"$COMBINED"
  gate="$(grep -oE '=> (valid|INVALID RUN[^$]*)' "$log" | tail -1)"
  [[ -n "$gate" ]] || gate="(no gate line)"
  cells="$(grep -c '^leak: precheck' "$log" 2>/dev/null || echo 0)"
  printf '%-28s exit=%-3s cells=%-3s %s\n' "$name" "$rc" "$cells" "$gate" | tee -a "$SUMMARY"
  NAMES+=("$name")
  STATUS+=("$rc")
  GATE+=("$gate")
done

elapsed=$(($(date +%s) - started))
{
  printf '\n----- summary (%dm%02ds) -----\n' $((elapsed / 60)) $((elapsed % 60))
  ok=0
  bad=0
  for i in "${!NAMES[@]}"; do
    if [[ "${STATUS[$i]}" == 0 ]]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
    printf '%-28s %-8s %s\n' "${NAMES[$i]}" "exit=${STATUS[$i]}" "${GATE[$i]}"
  done
  printf '\n%d valid, %d refused or failed\n' "$ok" "$bad"
  printf 'logs:     %s/<row>.log\n' "$BATCH"
  printf 'combined: %s\n' "$COMBINED"
  printf '\nEvery cell of every row kept its own tree under <run>/cells/<cell>-<hexid>/.\n'
} | tee -a "$SUMMARY"
