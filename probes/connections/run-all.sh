#!/usr/bin/env bash
# Run every Part 1 suite and report the ACCEPTANCE SCORE for the connections model.
#
# This is not only a study runner. Part 1 asserts what docs/connections.md promises, one
# cell per promise, against the container alone -- so the number below is how much of the
# model the installed engine expresses. It is meant to read 0 fail and a shrinking
# not-implemented count as the implementation lands, and "all pass, nothing blocked" is
# the definition of done for the engine work.
#
# FOUR OUTCOMES, KEPT APART. `pass` and `fail` are the engine keeping or breaking a
# promise. `not-implemented` is a promise it does not make yet. `blocked` is a promise
# nobody can measure here -- a host this one is not, or a decision not yet taken -- and
# folding it into not-implemented would let it vanish as the implementation lands.
#
# A SUITE THAT DID NOT FINISH IS A FAILURE OF THE BATCH. It contributes nothing to any
# counter, so counting only assertions would report a tidy "0 fail" for a run where a
# whole mode crashed or its validity gate refused it.
#
# Free: no credentials, no network, no API calls. Host-only, like every probe here.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUITES=(part1-live.sh part1-none.sh part1-copy.sh part1-cow.sh part1-ro.sh)
[[ $# -gt 0 ]] && SUITES=("$@")

OUT="$(cd -- "$HERE/../.." && pwd)/probes/results/connections/batch-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$OUT"
printf 'batch %s\nclaude: %s\nengine: %s\n\n' "$OUT" \
  "$(claude --version 2>/dev/null | head -1)" \
  "$(claude --engine-version 2>/dev/null | head -1)" | tee "$OUT/summary.txt"

# field N LINE -- the count labelled N on a summary line, or 0 if it is not there.
field() { sed -n "s/.*[:,] \([0-9]*\) $1.*/\1/p" <<<"$2"; }

total_pass=0 total_fail=0 total_todo=0 total_blocked=0 total_ctrl_bad=0 broken=0
for s in "${SUITES[@]}"; do
  name="${s%.sh}"
  log="$OUT/$name.log"
  printf '%-18s running...\n' "$name"
  rc=0
  "$HERE/$s" >"$log" 2>&1 || rc=$?
  line="$(grep -E "^$name: [0-9]+ pass" "$log" | tail -1)"
  if [[ -z "$line" ]]; then
    # No score line at all: the suite died before conn_summary, so there is nothing to
    # add up and the batch cannot be called clean.
    broken=$((broken + 1))
    printf '%-18s DID NOT FINISH (exit %s) -- see %s\n' "$name" "$rc" "$log" \
      | tee -a "$OUT/summary.txt"
    continue
  fi
  if grep -q '=> INVALID RUN' "$log"; then
    # ITS COUNTS ARE NOT ADDED. The gate refused the run, so its passes are exactly as
    # untrustworthy as the rest of it; folding them into the headline printed "6 pass"
    # beside "1 suite did not produce a usable result", which is a number no reader
    # should be given.
    broken=$((broken + 1))
    total_ctrl_bad=$((total_ctrl_bad + $(field 'bad)' "$line")))
    printf '%s  [GATE REFUSED THIS RUN -- its counts are not added]\n' "$line" \
      | tee -a "$OUT/summary.txt"
    continue
  fi
  printf '%s\n' "$line" | tee -a "$OUT/summary.txt"
  total_pass=$((total_pass + $(field pass "$line")))
  total_fail=$((total_fail + $(field fail "$line")))
  total_todo=$((total_todo + $(field not-implemented "$line")))
  total_blocked=$((total_blocked + $(field blocked "$line")))
  total_ctrl_bad=$((total_ctrl_bad + $(field 'bad)' "$line")))
done

# ----- W8's other half: the two `cow` implementations, compared on one host ----------
# Where bubblewrap cannot mount an overlay, `cow` is `copy`, and the claim that the two
# agree at launch granularity used to need a second, older machine. It does not any more:
# `[overlay] mode = off` forces the fallback here, so the suite runs twice and the
# verdicts are diffed. That compares the two implementations AGAINST EACH OTHER, which the
# original plan could not do -- it would have compared one of them against a memory of the
# other, taken on different hardware at a different time.
divergent=0
cowlog="$OUT/part1-cow.log"
if [[ -f "$cowlog" ]]; then
  printf '%-18s running again, overlay forced off...\n' part1-cow
  nolog="$OUT/part1-cow-nooverlay.log"
  CONN_OVERLAY=off "$HERE/part1-cow.sh" >"$nolog" 2>&1 || true
  reca="$(sed -n 's/^records: //p' "$cowlog" | tail -1)"
  recb="$(sed -n 's/^records: //p' "$nolog" | tail -1)"
  if [[ -d "$reca" && -d "$recb" ]]; then
    divergent="$(python3 "$HERE/compare.py" "$reca" "$recb")"
    printf 'cow with and without the overlay: %s assertion(s) differ\n' "$divergent" \
      | tee -a "$OUT/summary.txt"
  else
    printf 'cow with and without the overlay: NOT COMPARED (a run produced no records)\n' \
      | tee -a "$OUT/summary.txt"
    divergent=1
  fi
fi

{
  printf '\n----- acceptance -----\n'
  printf '%d pass, %d fail, %d not-implemented, %d blocked\n' \
    "$total_pass" "$total_fail" "$total_todo" "$total_blocked"
  ((broken)) && printf '%d suite(s) did not produce a usable result\n' "$broken"
  ((total_ctrl_bad)) && printf '%d control(s) did not hold\n' "$total_ctrl_bad"
  ((divergent)) && printf '%d cow assertion(s) differ between the two implementations\n' "$divergent"
  printf 'logs: %s\n' "$OUT"
} | tee -a "$OUT/summary.txt"

((total_fail == 0 && broken == 0 && total_ctrl_bad == 0 && divergent == 0))
