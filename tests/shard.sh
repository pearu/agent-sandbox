#!/usr/bin/env bash
# tests/shard.sh K/N FILE... -- print the bats FILEs that make up shard K of N, one per line.
#
# For a CI matrix: every shard runs this with the same FILEs and gets a disjoint part, and
# together the N parts are all of them. A file is never split: within a shard its tests
# run in parallel anyway (tests/run.sh).
#
# A file weighs its time in tests/shard-times.tsv (`seconds<TAB>file`, its test time
# under kcov in a CI job of the usual speed, fitted by scripts/shard-times.sh). A file
# the table does not list weighs its number of tests (an `@test`, or a
# `bats_test_function` line, which registers one per profile adapter) times the median
# seconds per test of the FILEs it does list, so the two can be dealt together; when it
# lists none of them, every file weighs its number of tests. AGENT_SANDBOX_SHARD_TIMES names another table (a test's).
# Files are dealt out heaviest first (ties by name), each to the shard with the least
# weight so far (ties to the lower shard), so the split is deterministic.
set -euo pipefail
spec="${1:-}"
shift || true
k="${spec%/*}" n="${spec#*/}"
if ! [[ "$spec" == */* && "$k" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] || ((k < 1 || k > n)); then
  echo "usage: tests/shard.sh K/N FILE...  (1 <= K <= N)" >&2
  exit 2
fi
table="${AGENT_SANDBOX_SHARD_TIMES-$(dirname -- "${BASH_SOURCE[0]}")/shard-times.tsv}"
[[ -f "$table" ]] || table=/dev/null
export LC_ALL=C
# weights -- `milliseconds<TAB>file` for each FILE, from `tests<TAB>file` on stdin
weights() {
  awk -F'\t' -v table="$table" '
    BEGIN {
      while ((getline l < table) > 0) {
        split(l, a, "\t")
        if (a[2] != "" && a[1] ~ /^[0-9]+(\.[0-9]*)?$/) t[a[2]] = a[1] + 0
      }
    }
    {
      m++; c[m] = $1 + 0; f[m] = $2
      if (($2 in t) && $1 > 0) r[++nr] = t[$2] / $1
    }
    END {
      # the median seconds per test of the listed files (insertion sort: few files)
      for (i = 2; i <= nr; i++) {
        v = r[i]
        for (j = i - 1; j >= 1 && r[j] > v; j--) r[j + 1] = r[j]
        r[j + 1] = v
      }
      if (nr == 0) med = 1
      else if (nr % 2) med = r[(nr + 1) / 2]
      else med = (r[nr / 2] + r[nr / 2 + 1]) / 2
      for (i = 1; i <= m; i++) {
        s = (f[i] in t) ? t[f[i]] : c[i] * med
        printf "%d\t%s\n", s * 1000 + 0.5, f[i]
      }
    }'
}
declare -a load=()
for ((i = 1; i <= n; i++)); do load[i]=0; done
while IFS=$'\t' read -r w f; do
  best=1
  for ((i = 2; i <= n; i++)); do ((load[i] < load[best])) && best=$i; done
  load[best]=$((load[best] + w))
  ((best == k)) && printf '%s\n' "$f"
done < <(for f in "$@"; do printf '%s\t%s\n' "$(grep -cE '^@test|^[[:space:]]*bats_test_function ' "$f" || true)" "$f"; done \
  | weights | sort -t $'\t' -k1,1nr -k2,2)
exit 0
