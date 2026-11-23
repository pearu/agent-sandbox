#!/usr/bin/env bash
# scripts/shard-times.sh DIR|FILE... -- print tests/shard.sh's time table, made from the
# coverage stages' timing files: every timing-*.tsv under each DIR, and each FILE.
#
#   scripts/shard-times.sh coverage-out >tests/shard-times.tsv          a local run
#   gh run download RUN -p 'tests-*' -D runs && scripts/shard-times.sh runs >tests/shard-times.tsv
#
# scripts/coverage.sh writes $OUT/timing-<stage>.tsv, `seconds<TAB>file` (the sum of the
# file's test times under kcov, `bats --timing`), and CI uploads each shard's as its
# tests-<stage>-<k> artifact. A file in several of them (two runs) gets their mean. A
# line whose file is not a .bats file of this tree (a file since removed, or a name from
# an older coverage.sh, which wrote it relative to the first file's directory) is left
# out, and said on stderr. The table is sorted by file, so a refresh's diff shows what
# moved.
#
# Refresh it after a Task that adds many slow tests, or when CI's coverage shards finish
# more than a few minutes apart: tests/shard.sh weighs a file the table does not list by
# its number of tests, so a stale table still deals every file, only less evenly.
set -euo pipefail
(($#)) || {
  echo "usage: scripts/shard-times.sh DIR|FILE...  (timing-*.tsv from scripts/coverage.sh)" >&2
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
mapfile -t files < <(realpath -- "${files[@]}")
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." # the table's paths are the tree's
cat <<'EOF'
# tests/shard.sh's table: seconds<TAB>file, the sum of the file's test times under kcov
# (scripts/coverage.sh's timing-<stage>.tsv). Made by scripts/shard-times.sh, which says
# when to refresh it; a file not listed weighs its tests times the median rate.
EOF
awk -F'\t' '
  NF >= 2 && $1 ~ /^[0-9]+(\.[0-9]*)?$/ { s[$2] += $1; n[$2]++ }
  END { for (f in s) printf "%.1f\t%s\n", s[f] / n[f], f }' "${files[@]}" \
  | LC_ALL=C sort -t $'\t' -k2,2 \
  | while IFS=$'\t' read -r t f; do
    if [[ "$f" == tests/*.bats && -f "$f" ]]; then
      printf '%s\t%s\n' "$t" "$f"
    else
      echo "shard-times: $f: not a .bats file of this tree; left out" >&2
    fi
  done
