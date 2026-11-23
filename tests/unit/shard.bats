#!/usr/bin/env bats
# tests/shard.sh, which deals a suite's files out to CI's shards: by their time in a table
# (tests/shard-times.tsv), a file the table does not list by its number of tests times
# the table's median seconds per test, heaviest first, each to the lightest shard (#462).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  SHARD="$REPO_ROOT/tests/shard.sh"
  cd "$BATS_TEST_TMPDIR" || return
}

# mk NAME TESTS -- a bats file NAME with TESTS tests
mk() {
  local i
  for ((i = 1; i <= $2; i++)); do printf '@test "t%s" {\n  :\n}\n' "$i"; done >"$1"
}

# shards N TABLE FILE... -- shard 1..N of the FILEs under TABLE, one line each:
# `K: FILE FILE...`
shards() {
  local n="$1" table="$2" k
  shift 2
  for ((k = 1; k <= n; k++)); do
    echo "$k: $(AGENT_SANDBOX_SHARD_TIMES="$table" "$SHARD" "$k/$n" "$@" | tr '\n' ' ')"
  done
}

@test "shard: a time table moves a heavy file away from files with more tests" {
  mk big.bats 2
  mk f1.bats 10
  mk f2.bats 10
  mk f3.bats 10
  printf '100.5\tbig.bats\n10.0\tf1.bats\n10\tf2.bats\n10\tf3.bats\n' >times.tsv
  run shards 2 times.tsv big.bats f1.bats f2.bats f3.bats
  echo "$output"
  [ "${lines[0]}" = "1: big.bats " ]
  [ "${lines[1]}" = "2: f1.bats f2.bats f3.bats " ]
  # by their number of tests, big.bats shares a shard
  run shards 2 none.tsv big.bats f1.bats f2.bats f3.bats
  echo "$output"
  [ "${lines[0]}" = "1: f1.bats f3.bats " ]
  [ "${lines[1]}" = "2: f2.bats big.bats " ]
}

@test "shard: a file the table does not list weighs its tests times the median seconds per test" {
  mk p.bats 10
  mk q.bats 10
  mk r.bats 10
  mk x.bats 10
  mk y.bats 2
  # 20, 1 and 3 s per test, given in that order: the median is 3 (the mean about 7.7)
  printf '# a comment\n200\tr.bats\n10\tp.bats\n30\tq.bats\n' >times.tsv
  cp times.tsv median.tsv
  printf '30\tx.bats\n6\ty.bats\n' >>median.tsv
  cp times.tsv mean.tsv
  printf '77\tx.bats\n15\ty.bats\n' >>mean.tsv
  for n in 1 2 3 4; do
    run shards "$n" times.tsv r.bats p.bats q.bats x.bats y.bats
    unlisted="$output"
    run shards "$n" median.tsv r.bats p.bats q.bats x.bats y.bats
    echo "N=$n unlisted: $unlisted"
    echo "N=$n median:   $output"
    [ "$unlisted" = "$output" ]
  done
  # and the comparison can tell: at the mean, N=3 deals them otherwise
  run shards 3 times.tsv r.bats p.bats q.bats x.bats y.bats
  unlisted="$output"
  run shards 3 mean.tsv r.bats p.bats q.bats x.bats y.bats
  [ "$unlisted" != "$output" ]
}

@test "shard: with an even number of listed files, the median is the mean of the middle two" {
  mk p.bats 10
  mk q.bats 10
  mk x.bats 20
  : >w.bats
  # 3 and 1 s per test (w.bats has no tests, so no rate): the median is 2, x.bats 40 s
  printf '30\tq.bats\n45\tw.bats\n10\tp.bats\n' >times.tsv
  cp times.tsv median.tsv
  printf '40\tx.bats\n' >>median.tsv
  cp times.tsv upper.tsv
  printf '60\tx.bats\n' >>upper.tsv
  for n in 1 2 3; do
    run shards "$n" times.tsv p.bats q.bats w.bats x.bats
    unlisted="$output"
    run shards "$n" median.tsv p.bats q.bats w.bats x.bats
    echo "N=$n unlisted: $unlisted"
    echo "N=$n median:   $output"
    [ "$unlisted" = "$output" ]
  done
  run shards 2 times.tsv p.bats q.bats w.bats x.bats
  unlisted="$output"
  run shards 2 upper.tsv p.bats q.bats w.bats x.bats
  [ "$unlisted" != "$output" ]
}

@test "shard: a table that lists none of the files deals them by their number of tests" {
  mk a.bats 3
  mk b.bats 5
  mk c.bats 1
  mk d.bats 4
  printf '500\tother.bats\n' >times.tsv
  run shards 2 times.tsv a.bats b.bats c.bats d.bats
  echo "$output"
  [ "${lines[0]}" = "1: b.bats c.bats " ]
  [ "${lines[1]}" = "2: d.bats a.bats " ]
}

@test "shard: the suites' shards are disjoint and complete, for N = 1..4" {
  cd "$REPO_ROOT" || return
  files=(tests/unit/*.bats tests/unit/profile-*/*.bats)
  [ "${#files[@]}" -gt 20 ]
  for n in 1 2 3 4; do
    for ((k = 1; k <= n; k++)); do tests/shard.sh "$k/$n" "${files[@]}"; done >"$BATS_TEST_TMPDIR/all"
    echo "N=$n: $(wc -l <"$BATS_TEST_TMPDIR/all") of ${#files[@]}"
    [ "$(sort "$BATS_TEST_TMPDIR/all" | uniq -d)" = "" ]
    [ "$(sort "$BATS_TEST_TMPDIR/all")" = "$(printf '%s\n' "${files[@]}" | sort)" ]
  done
}

@test "shard: deterministic on ties, whatever the order of the files" {
  mk a.bats 2
  mk b.bats 2
  mk c.bats 2
  mk d.bats 2
  printf '5\ta.bats\n5\tb.bats\n5\tc.bats\n5\td.bats\n' >times.tsv
  run shards 3 times.tsv a.bats b.bats c.bats d.bats
  echo "$output"
  [ "${lines[0]}" = "1: a.bats d.bats " ]
  [ "${lines[1]}" = "2: b.bats " ]
  [ "${lines[2]}" = "3: c.bats " ]
  forward="$output"
  run shards 3 times.tsv d.bats c.bats b.bats a.bats
  [ "$output" = "$forward" ]
}

@test "shard: a fraction of a second in the table still orders the files" {
  mk a.bats 1
  mk b.bats 1
  printf '1.2\ta.bats\n1.4\tb.bats\n' >times.tsv
  run shards 2 times.tsv a.bats b.bats
  echo "$output"
  [ "${lines[0]}" = "1: b.bats " ]
  [ "${lines[1]}" = "2: a.bats " ]
}

@test "shard-times: the table from the stages' timing files: a mean where a file is twice, sorted by file, a name not of the tree (or a file removed) left out" {
  mkdir -p run/a run/b
  printf '10.0\ttests/unit/shard.bats\n4.5\ttests/unit/argv.bats\n' >run/a/timing-engine-unit.tsv
  printf '20.0\ttests/unit/shard.bats\n3.0\tinit.bats\n1.0\ttests/unit/gone.bats\n' >run/b/timing-engine-unit.tsv
  printf '7\ttests/unit/docs.bats\n' >other.tsv
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" run other.tsv
  [ "$status" -eq 0 ]
  echo "$output"
  [ "$(grep -vc '^#' <<<"$output")" -eq 3 ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 1p)" = $'4.5\ttests/unit/argv.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 2p)" = $'7.0\ttests/unit/docs.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 3p)" = $'15.0\ttests/unit/shard.bats' ]
  [ "${stderr_lines[0]}" = "shard-times: init.bats: not a .bats file of this tree; left out" ]
  [ "${stderr_lines[1]}" = "shard-times: tests/unit/gone.bats: not a .bats file of this tree; left out" ]
  [ "${#stderr_lines[@]}" -eq 2 ]
}

@test "shard-times: the table checked in is the one tests/shard.sh reads, every line a file of the tree" {
  [ -f "$REPO_ROOT/tests/shard-times.tsv" ]
  cd "$REPO_ROOT" || return
  run awk -F'\t' '!/^#/ && !(NF == 2 && $1 ~ /^[0-9]+(\.[0-9]*)?$/) {print "bad line: " $0}' tests/shard-times.tsv
  [ -z "$output" ]
  [ "$(grep -vc '^#' tests/shard-times.tsv)" -gt 20 ]
  files=(tests/unit/*.bats tests/unit/profile-*/*.bats)
  run env -u AGENT_SANDBOX_SHARD_TIMES tests/shard.sh 1/4 "${files[@]}"
  default="$output"
  run env AGENT_SANDBOX_SHARD_TIMES=tests/shard-times.tsv tests/shard.sh 1/4 "${files[@]}"
  [ "$output" = "$default" ]
  run env AGENT_SANDBOX_SHARD_TIMES=none.tsv tests/shard.sh 1/4 "${files[@]}"
  [ "$output" != "$default" ]
  while IFS=$'\t' read -r _ f; do
    [ -f "$f" ] || echo "not a file: $f (remove its line, or refresh the table: scripts/shard-times.sh)"
  done < <(grep -v '^#' tests/shard-times.tsv) >"$BATS_TEST_TMPDIR/missing"
  [ ! -s "$BATS_TEST_TMPDIR/missing" ]
}
