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

@test "shard: the suites' shards are disjoint and complete, for N = 1..6" {
  cd "$REPO_ROOT" || return
  files=(tests/unit/*.bats tests/unit/profile-*/*.bats)
  [ "${#files[@]}" -gt 20 ]
  for n in 1 2 3 4 5 6; do
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

@test "shard-times: the table is a fit, each job's speed out: three jobs of known factors and three files of known weights are recovered (#462)" {
  # weights argv 10, docs 20, shard 40 (and install 5, in one job only); jobs at 0.5, 1
  # and 2 times the usual speed, each with two of the three, so every job shares a file
  # with another. A mean would say 12.5, 15 and 60, and install 2.5. A fourth job, alone, shares no file: its factor is 1, and it moves
  # no other job's.
  mkdir -p run/1 run/2 run/3 run/4
  printf '5.0\ttests/unit/argv.bats\n10.0\ttests/unit/docs.bats\n2.5\ttests/unit/install.bats\n' >run/1/timing-engine-unit.tsv
  printf '20.0\ttests/unit/docs.bats\n40.0\ttests/unit/shard.bats\n' >run/2/timing-engine-unit.tsv
  printf '20.0\ttests/unit/argv.bats\n80.0\ttests/unit/shard.bats\n' >run/3/timing-engine-unit.tsv
  printf '7.0\ttests/unit/helpers.bats\n' >run/4/timing-engine-unit.tsv
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" run
  [ "$status" -eq 0 ]
  echo "$output"
  [ "$(grep -vc '^#' <<<"$output")" -eq 5 ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 1p)" = $'10.0\ttests/unit/argv.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 2p)" = $'20.0\ttests/unit/docs.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 3p)" = $'7.0\ttests/unit/helpers.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 4p)" = $'5.0\ttests/unit/install.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 5p)" = $'40.0\ttests/unit/shard.bats' ]
  [ "$(grep '^#' <<<"$output" | tail -1)" = '#   run' ]
  [ "${#stderr_lines[@]}" -eq 0 ]
  # --factors: each job's factor, its seconds, and its seconds at the usual speed
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" --factors run
  [ "$status" -eq 0 ]
  echo "$output"
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "0.50"$'\t'"17.5"$'\t'"35.0"$'\t'"$(realpath run/1/timing-engine-unit.tsv)" ]
  [ "${lines[1]}" = "1.00"$'\t'"60.0"$'\t'"60.0"$'\t'"$(realpath run/2/timing-engine-unit.tsv)" ]
  [ "${lines[2]}" = "2.00"$'\t'"100.0"$'\t'"50.0"$'\t'"$(realpath run/3/timing-engine-unit.tsv)" ]
  [ "${lines[3]}" = "1.00"$'\t'"7.0"$'\t'"7.0"$'\t'"$(realpath run/4/timing-engine-unit.tsv)" ]
}

@test "shard-times: runs of one deal tie no shard to another, and say so on stderr; a run of another deal ties them (#462)" {
  # every file weighs 10 at the usual speed; run 1's shard 1 ran at half the speed
  mkdir -p r1/s1 r1/s2 r2/s1 r2/s2 r0/s1 r0/s2
  printf '20.0\ttests/unit/argv.bats\n20.0\ttests/unit/docs.bats\n' >r1/s1/timing-engine-unit.tsv
  printf '10.0\ttests/unit/install.bats\n10.0\ttests/unit/shard.bats\n' >r1/s2/timing-engine-unit.tsv
  printf '10.0\ttests/unit/argv.bats\n10.0\ttests/unit/docs.bats\n' >r2/s1/timing-engine-unit.tsv
  printf '10.0\ttests/unit/install.bats\n10.0\ttests/unit/shard.bats\n' >r2/s2/timing-engine-unit.tsv
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" r1 r2
  [ "$status" -eq 0 ]
  echo "$output"
  echo "$stderr"
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "${stderr_lines[0]}" == "shard-times: the jobs form 2 groups of several that share no file (runs of one deal): "* ]]
  # a run dealt otherwise ties the shards: the four files weigh alike
  printf '10.0\ttests/unit/argv.bats\n10.0\ttests/unit/shard.bats\n' >r0/s1/timing-engine-unit.tsv
  printf '10.0\ttests/unit/docs.bats\n10.0\ttests/unit/install.bats\n' >r0/s2/timing-engine-unit.tsv
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" r0 r1 r2
  [ "$status" -eq 0 ]
  echo "$output"
  [ "${#stderr_lines[@]}" -eq 0 ]
  [ "$(grep -v '^#' <<<"$output" | cut -f1 | sort -u)" = 11.2 ]
}

@test "shard-times: a job that shares no file with another keeps its seconds, a time under 0.05 s as 0.05; sorted by file; a name not of the tree (or a file removed) left out, and the header names the inputs" {
  mkdir -p run/a run/b
  printf '10.0\ttests/unit/shard.bats\n4.5\ttests/unit/argv.bats\n0.0\ttests/unit/install.bats\n' >run/a/timing-engine-unit.tsv
  printf '3.0\tinit.bats\n1.0\ttests/unit/gone.bats\n' >run/b/timing-engine-unit.tsv
  printf '7\ttests/unit/docs.bats\n' >other.tsv
  run --separate-stderr "$REPO_ROOT/scripts/shard-times.sh" run other.tsv
  [ "$status" -eq 0 ]
  echo "$output"
  [ "$(grep -vc '^#' <<<"$output")" -eq 4 ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 1p)" = $'4.5\ttests/unit/argv.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 2p)" = $'7.0\ttests/unit/docs.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 3p)" = $'0.1\ttests/unit/install.bats' ]
  [ "$(grep -v '^#' <<<"$output" | sed -n 4p)" = $'10.0\ttests/unit/shard.bats' ]
  [ "$(grep '^#' <<<"$output" | tail -2 | head -1)" = '#   run' ]
  [ "$(grep '^#' <<<"$output" | tail -1)" = '#   other.tsv' ]
  [ "${stderr_lines[0]}" = "shard-times: init.bats: not a .bats file of this tree; left out" ]
  [ "${stderr_lines[1]}" = "shard-times: tests/unit/gone.bats: not a .bats file of this tree; left out" ]
  [ "${#stderr_lines[@]}" -eq 2 ]
}

@test "shard-times: the table checked in is the one tests/shard.sh reads, every line an existing .bats file of the tree" {
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
    [[ "$f" == tests/*.bats && -f "$f" ]] || echo "not a .bats file of the tree: $f (refresh the table: scripts/shard-times.sh)"
  done < <(grep -v '^#' tests/shard-times.tsv) >"$BATS_TEST_TMPDIR/missing"
  [ ! -s "$BATS_TEST_TMPDIR/missing" ]
}
