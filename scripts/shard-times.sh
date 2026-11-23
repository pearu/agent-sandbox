#!/usr/bin/env bash
# scripts/shard-times.sh [--factors] DIR|FILE... -- print tests/shard.sh's time table,
# fitted to the coverage stages' timing files: every timing-*.tsv under each DIR, and each
# FILE.
#
#   scripts/shard-times.sh coverage-out >tests/shard-times.tsv          a local run
#   gh run download RUN -p 'tests-engine-unit-*' -D runs/RUN            for each of several
#   scripts/shard-times.sh runs/RUN1 runs/RUN2 ... >tests/shard-times.tsv      CI runs
#
# scripts/coverage.sh writes $OUT/timing-<stage>.tsv, `seconds<TAB>file` (the sum of the
# file's test times under kcov, `bats --timing`), and CI uploads each shard's as its
# tests-<stage>-<k> artifact. Each timing file is one job, and a job's runner has a speed
# of its own: on CI, a job's files ran at its own factor, 0.77 to 1.34 of the usual
# speed, each within about 10% (#462). So the table is a fit, not a mean: log seconds =
# the job's factor + the file's weight, by alternating least squares over every file of
# every job. A file in several jobs (several runs, dealt differently) ties their factors
# together; the factors of the jobs so tied have a geometric mean of 1, and a job that
# shares no file with another (one run alone) has the factor 1, i.e. its seconds as they
# are. A file's line is its weight: its seconds in a job of the usual speed. A time under
# 0.05 s counts as 0.05.
#
# --factors prints, instead, one line per job: its factor, its seconds, its seconds over
# its factor, and its timing file. A shard's balance, free of its runner's speed, is the
# third column (the 1.25 x median rule of #462).
#
# A line whose file is not a .bats file of this tree (a file since removed, or a name
# from an older coverage.sh, which wrote it relative to the first file's directory) is
# left out of the table, and said on stderr; it still counts in the fit. The table is
# sorted by file, so a refresh's diff shows what moved. Its header names the timing
# files' DIRs and FILEs, as given.
#
# The fit ties jobs together only through the files they share, so it needs runs dealt
# differently: the runs of one table and N deal alike, and a deal's shards share no file.
# Given only such runs, each shard's jobs are a group of their own: a group's speed stays
# in its files' weights, and --factors compares the jobs of one group only. Two groups or
# more of several jobs each are said on stderr; add a run of another deal (the table's
# header names the last ones).
#
# Refresh it, over three runs or more, after a Task that adds many slow tests, or when
# the speed-free sums of CI's coverage shards (--factors) drift apart: tests/shard.sh
# weighs a file the table does not list by its number of tests, so a stale table still
# deals every file, only less evenly.
set -euo pipefail
factors=0
[[ "${1:-}" == --factors ]] && factors=1 && shift
(($#)) || {
  echo "usage: scripts/shard-times.sh [--factors] DIR|FILE...  (timing-*.tsv from scripts/coverage.sh)" >&2
  exit 2
}
files=()
for a in "$@"; do
  if [[ -d "$a" ]]; then
    mapfile -t -O "${#files[@]}" files < <(find "$a" -name 'timing-*.tsv' -type f | LC_ALL=C sort)
  elif [[ -f "$a" ]]; then
    files+=("$a")
  else
    echo "shard-times: $a: no such file or directory" >&2
    exit 2
  fi
done
((${#files[@]})) || {
  echo "shard-times: no timing-*.tsv in $*" >&2
  exit 2
}
given=("$@")
mapfile -t files < <(realpath -- "${files[@]}")
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." # the table's paths are the tree's
# fit -- the fit's output on stdout: `J<TAB>factor<TAB>seconds<TAB>timing-file` per job,
# then `W<TAB>weight<TAB>file` per file
fit() {
  awk -F'\t' '
    function root(x) {
      while (up[x] != x) { up[x] = up[up[x]]; x = up[x] }
      return x
    }
    function weights(  i) {
      split("", s); split("", c)
      for (i = 1; i <= n; i++) { s[of[i]] += ol[i] - a[oj[i]]; c[of[i]]++ }
      for (f in s) b[f] = s[f] / c[f]
    }
    FNR == 1 { nj++; job[nj] = FILENAME; up[nj] = nj; a[nj] = 0 }
    NF >= 2 && $1 ~ /^[0-9]+(\.[0-9]*)?$/ {
      t = $1 + 0
      n++; oj[n] = nj; of[n] = $2; ol[n] = log(t < 0.05 ? 0.05 : t); sec[nj] += t
      if ($2 in seen) up[root(nj)] = root(seen[$2]); else seen[$2] = nj
    }
    END {
      for (it = 0; it < 10000; it++) {
        weights()
        split("", s); split("", c)
        for (i = 1; i <= n; i++) { s[oj[i]] += ol[i] - b[of[i]]; c[oj[i]]++ }
        d = 0
        for (j in s) {
          v = s[j] / c[j]
          if ((v - a[j]) ^ 2 > d) d = (v - a[j]) ^ 2
          a[j] = v
        }
        if (d < 1e-20) break
      }
      # a fit fixes a factor only against the jobs it shares files with: each such group
      # of jobs gets a geometric mean of 1, a job alone the factor 1
      split("", s); split("", c)
      for (j = 1; j <= nj; j++) { r = root(j); s[r] += a[j]; c[r]++ }
      for (j = 1; j <= nj; j++) a[j] -= s[root(j)] / c[root(j)]
      # runs of one deal only: no factor of one group compares with those of another
      split("", gs); g = 0
      for (j = 1; j <= nj; j++) gs[root(j)]++
      for (r in gs) if (gs[r] > 1) g++
      if (g > 1) printf "shard-times: the jobs form %d groups of several that share no file (runs of one deal): a factor compares the jobs of its group only, and the speed of each group stays in the weights of its files; add a run dealt otherwise\n", g >"/dev/stderr"
      weights()
      for (j = 1; j <= nj; j++) printf "J\t%.6f\t%.1f\t%s\n", exp(a[j]), sec[j], job[j]
      for (f in b) printf "W\t%.1f\t%s\n", exp(b[f]), f
    }' "${files[@]}"
}
if ((factors)); then
  fit | awk -F'\t' -v OFS='\t' '$1 == "J" { printf "%.2f\t%s\t%.1f\t%s\n", $2, $3, $3 / $2, $4 }'
  exit 0
fi
cat <<'EOF'
# tests/shard.sh's table: seconds<TAB>file, a file's test time under kcov in a CI job of
# the usual speed, fitted to the timing files (scripts/coverage.sh's timing-<stage>.tsv)
# by scripts/shard-times.sh, which says how and when to refresh it; a file not listed
# weighs its tests times the median rate. The timing files, as given to it:
EOF
printf '#   %s\n' "${given[@]}"
fit | awk -F'\t' '$1 == "W" { print $2 "\t" $3 }' \
  | LC_ALL=C sort -t $'\t' -k2,2 \
  | while IFS=$'\t' read -r t f; do
    if [[ "$f" == tests/*.bats && -f "$f" ]]; then
      printf '%s\t%s\n' "$t" "$f"
    else
      echo "shard-times: $f: not a .bats file of this tree; left out" >&2
    fi
  done
