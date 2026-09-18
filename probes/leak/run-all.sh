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
# CONCURRENCY. Every cell now builds its own tree (lib.sh leak_cell), so two rows share
# nothing on disk and can run at once. Two things are still shared and bound how far this
# goes: the daemon directory /tmp/cc-daemon-<uid>, which is keyed by the real uid and not
# by HOME, and the OAuth credential every cell copies -- concurrent token refreshes can
# race. Both fail loudly (a session exits non-zero and the gate refuses), so the cost of
# overdoing -j is wasted API spend, not a wrong result.
#
# ROWS THAT RUN A NATIVE CLAUDE SESSION ALWAYS RUN SERIALLY, whatever -j says. A native
# session is not sandboxed, so it can read /tmp -- where, under concurrency, other rows'
# LIVE cell trees sit. Serially only one live tree exists at a time. This is a rule rather
# than a measurement: the contamination it prevents would be silent and would land in the
# one place the study cannot afford it.
#
# Usage:
#   ./probes/leak/run-all.sh                     # every row, in the order below
#   ./probes/leak/run-all.sh --free              # only the rows that cost nothing
#   ./probes/leak/run-all.sh --paid              # only the rows that spend API calls
#   ./probes/leak/run-all.sh -j 3 --paid         # up to 3 sandbox-only rows at a time
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

JOBS=1
while [[ "${1:-}" == -j || "${1:-}" == --jobs ]]; do
  shift
  JOBS="${1:-1}"
  shift
  if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "run-all.sh: -j takes a positive integer" >&2
    exit 2
  fi
done

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

# The two versions name the results CLASS this batch belongs to (see the results
# document's naming scheme: claude-<major.minor>-leak-results-<engine x.y.z>.md). Every
# cell records them too; printing them here makes a batch's class visible in its log.
printf 'batch %s\nclaude: %s\nengine: %s\n%d rows: %s\n\n' "$BATCH" \
  "$(claude --version 2>/dev/null | head -1)" \
  "$(claude --engine-version 2>/dev/null | head -1)" \
  "${#ROWS[@]}" "${ROWS[*]}" | tee "$SUMMARY"
: >"$COMBINED"

started="$(date +%s)"
declare -a NAMES=() STATUS=() GATE=()

# A row runs serially if it starts a NATIVE claude session -- detected from the script
# rather than kept as a list here, so it cannot drift as rows change.
runs_native() { grep -q 'leak_session_native' "$1"; }

run_row() { # run_row SCRIPT NAME LOG -- writes LOG and LOG.rc; safe to background
  local script="$1" log="$3"
  # stdout and stderr together: the rows say most of what matters on stderr, and keeping
  # them interleaved preserves which cell a warning belongs to.
  "$script" >"$log" 2>&1
  printf '%s' "$?" >"$log.rc"
}

collect_row() { # collect_row NAME LOG -- one summary line, once the row has finished
  local name="$1" log="$2" rc gate cells
  rc="$(cat "$log.rc" 2>/dev/null || echo "?")"
  cat "$log" >>"$COMBINED"
  gate="$(grep -oE '=> (valid|INVALID RUN[^$]*)' "$log" | tail -1)"
  [[ -n "$gate" ]] || gate="(no gate line)"
  cells="$(grep -c '^leak: precheck' "$log" 2>/dev/null || echo 0)"
  printf '%-28s exit=%-3s cells=%-3s %s\n' "$name" "$rc" "$cells" "$gate" | tee -a "$SUMMARY"
  NAMES+=("$name")
  STATUS+=("$rc")
  GATE+=("$gate")
}

declare -a SERIAL=() PARALLEL=()
for row in "${ROWS[@]}"; do
  script="$HERE/$row"
  name="${row%.sh}"
  if [[ ! -x "$script" ]]; then
    printf '%-28s MISSING\n' "$name" | tee -a "$SUMMARY"
    NAMES+=("$name")
    STATUS+=(missing)
    GATE+=("-")
    continue
  fi
  printf '\n===== %s =====\n' "$name" >>"$COMBINED"
  if ((JOBS > 1)) && ! runs_native "$script"; then
    PARALLEL+=("$row")
  else
    SERIAL+=("$row")
  fi
done

if ((JOBS > 1)); then
  printf 'concurrency: %d (%d rows in parallel, %d serial because they run a native session)\n' \
    "$JOBS" "${#PARALLEL[@]}" "${#SERIAL[@]}" | tee -a "$SUMMARY"
fi

# the parallel group first, throttled to JOBS at a time
declare -a RUNNING=()
for row in "${PARALLEL[@]+"${PARALLEL[@]}"}"; do
  name="${row%.sh}"
  printf '%-28s running (parallel)...\n' "$name"
  run_row "$HERE/$row" "$name" "$BATCH/$name.log" &
  RUNNING+=("$name")
  while (($(jobs -pr | wc -l) >= JOBS)); do wait -n 2>/dev/null || true; done
done
wait
for name in "${RUNNING[@]+"${RUNNING[@]}"}"; do collect_row "$name" "$BATCH/$name.log"; done

# then the serial group, one at a time, in list order
for row in "${SERIAL[@]+"${SERIAL[@]}"}"; do
  name="${row%.sh}"
  printf '%-28s running...\n' "$name"
  run_row "$HERE/$row" "$name" "$BATCH/$name.log"
  collect_row "$name" "$BATCH/$name.log"
done

# ---- did any run's material reach another run? --------------------------------------
# Rows are isolated by construction -- a tree per cell, under /tmp, thrown away by being
# moved -- and concurrency is the case where that claim is load-bearing rather than
# incidental. It is also checkable rather than arguable: every canary carries its run's
# id, so one run's id appearing anywhere in another run's records or trees is
# contamination, with the run that leaked it named. Run always, not only under -j, since
# a serial batch is the control for the parallel one.
declare -a RUN_DIRS=() RUN_IDS=()
for log in "$BATCH"/*.log; do
  # all.log is every row concatenated, so it would parse the first row's run line a
  # second time and compare that run against itself -- which matches every token it owns.
  [[ "$(basename "$log")" == all.log ]] && continue
  line="$(grep -m1 '^leak: run ' "$log" 2>/dev/null)" || continue
  dir="${line#leak: run }"
  dir="${dir%% (id *}"
  id="${line##*(id }"
  id="${id%)}"
  [[ -d "$dir" && -n "$id" ]] && {
    RUN_DIRS+=("$dir")
    RUN_IDS+=("$id")
  }
done

cross=0
for i in "${!RUN_DIRS[@]}"; do
  for j in "${!RUN_IDS[@]}"; do
    ((i == j)) && continue
    # belt and braces: a run is never contaminated by itself, however the list was built
    [[ "${RUN_IDS[$i]}" == "${RUN_IDS[$j]}" ]] && continue
    if hit="$(grep -rlF -- "${RUN_IDS[$j]}" "${RUN_DIRS[$i]}" 2>/dev/null | head -3)"; then
      [[ -n "$hit" ]] || continue
      cross=$((cross + 1))
      {
        printf 'CONTAMINATION: run %s carries run %s material:\n' \
          "$(basename "${RUN_DIRS[$i]}")" "${RUN_IDS[$j]}"
        printf '  %s\n' "${hit//$'\n'/$'\n'  }"
      } | tee -a "$SUMMARY"
    fi
  done
done
if ((cross == 0)) && ((${#RUN_DIRS[@]} > 1)); then
  printf 'cross-run check: %d runs, none carries another run id\n' \
    "${#RUN_DIRS[@]}" | tee -a "$SUMMARY"
fi

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
