#!/usr/bin/env bash
# Run a set of leak-study rows in one go, keeping every row's output for analysis.
#
# WHY A BATCH RUNNER AT ALL. A method change touches every row, and the only way to know
# the rows still execute is to execute them. Running them by hand loses the output of
# whichever one failed first, and stopping at the first failure hides the rest -- so this
# keeps going, keeps each row's log, and reports at the end which rows the VALIDITY GATE
# refused. A row that exits non-zero is not an error in the batch; it is a result about
# that row.
#
# Usage:
#   ./probes/leak/run-batch.sh                 # the default set (see below)
#   ./probes/leak/run-batch.sh row-01-memory.sh row-02-transcripts.sh
#
# LEAK_GH_ISSUE is passed through if set, which row 13 needs for its public-medium half.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_BASE="$(cd -- "$HERE/../.." && pwd)/probes/results/leak"

# Free first, so a breakage shows up before anything spends an API call; then the one
# paid row that smoke-tests the real-session path; then the two that have never run.
DEFAULT_ROWS=(
  row-01-memory.sh row-02-transcripts.sh row-03-plans.sh row-04-history.sh
  row-10-mcpservers.sh row-11-project-history.sh row-12-downloads.sh
  row-15-agent-memory.sh row-16-session-artifacts.sh row-17-backups.sh
  row-18-uncatalogued.sh row-13-network.sh
  row-19-rules.sh
  row-23-level2-unprompted.sh row-24-level3-directed.sh
)

ROWS=("$@")
((${#ROWS[@]})) || ROWS=("${DEFAULT_ROWS[@]}")

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
  printf '%-28s exit=%-3s %s\n' "$name" "$rc" "$gate" | tee -a "$SUMMARY"
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
} | tee -a "$SUMMARY"
