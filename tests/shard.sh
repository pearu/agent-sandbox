#!/usr/bin/env bash
# tests/shard.sh K/N FILE... -- print the bats FILEs that make up shard K of N, one per line.
#
# For a CI matrix: every shard runs this with the same FILEs and gets a disjoint part, and
# together the N parts are all of them. Files are weighed by their number of tests and
# dealt out heaviest first, each to the shard with the fewest tests so far (ties to the
# lower shard), so the split is deterministic and roughly even. A file is never split:
# within a shard its tests run in parallel anyway (tests/run.sh).
set -euo pipefail
spec="${1:-}"
shift || true
k="${spec%/*}" n="${spec#*/}"
if ! [[ "$spec" == */* && "$k" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] || ((k < 1 || k > n)); then
  echo "usage: tests/shard.sh K/N FILE...  (1 <= K <= N)" >&2
  exit 2
fi
declare -a load=()
for ((i = 1; i <= n; i++)); do load[i]=0; done
while read -r w f; do
  best=1
  for ((i = 2; i <= n; i++)); do ((load[i] < load[best])) && best=$i; done
  load[best]=$((load[best] + w))
  ((best == k)) && printf '%s\n' "$f"
done < <(for f in "$@"; do printf '%s %s\n' "$(grep -c '^@test' "$f" || true)" "$f"; done | sort -k1,1nr -k2,2)
exit 0
