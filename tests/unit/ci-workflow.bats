#!/usr/bin/env bats
# .github/workflows/ci.yml's gate job, `ci-ok`. The ruleset on main requires that one
# check by name, so a job that must pass reaches the ruleset only through the gate's
# `needs`: a job added to the workflow but not to `needs` would run and fail without
# blocking a merge. Coverage is informational, and a job with `continue-on-error` is
# allowed to fail (e2e-real-systemd, an experiment): both stay out.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
}

# gate FIELD -- print a field of the workflow as python3 + PyYAML (environment.yml) read it
gate() {
  python3 - "$WORKFLOW" "$1" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
gate = jobs.get("ci-ok") or {}
field = sys.argv[2]
if field == "name":
    print(gate.get("name", ""))
elif field == "if":
    print(gate.get("if", ""))
elif field == "needs":
    needs = gate.get("needs", [])
    print(" ".join(sorted([needs] if isinstance(needs, str) else needs)))
elif field == "expected":
    allowed = {k for k, v in jobs.items() if v.get("continue-on-error") is True}
    print(" ".join(sorted(set(jobs) - {"ci-ok", "coverage", "coverage-merge"} - allowed)))
PY
}

@test "ci-ok exists, named ci-ok, and runs always()" {
  [ "$(gate name)" = "ci-ok" ]
  [ "$(gate if)" = "always()" ]
}

@test "ci-ok needs every job but itself, coverage and those allowed to fail" {
  expected="$(gate expected)"
  needs="$(gate needs)"
  [ -n "$expected" ]
  echo "expected: $expected"
  echo "needs:    $needs"
  [ "$needs" = "$expected" ]
}

# cov FIELD -- a field of the coverage job, as python3 + PyYAML read it
cov() {
  python3 - "$WORKFLOW" "$1" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
steps = jobs["coverage"]["steps"]
field = sys.argv[2]
ids = [i for i, s in enumerate(steps) if s.get("id") == "tests"]
t = ids[0] if len(ids) == 1 else 10**6
after = steps[t + 1:]
if field == "tests-run":
    print(steps[t]["run"] if t < len(steps) else "")
elif field == "tests-shell":
    print(steps[t].get("shell", "") if t < len(steps) else "")
elif field == "after-ifs":
    # every step after the tests runs when they failed, and not when they were skipped
    print("\n".join(str(s.get("if", "")) for s in after))
elif field == "summary":
    print("\n".join(s["run"] for s in after if "GITHUB_STEP_SUMMARY" in s.get("run", "")))
elif field == "tests-artifact":
    for s in after:
        w = s.get("with", {})
        if str(s.get("uses", "")).startswith("actions/upload-artifact@") and str(w.get("name", "")).startswith("tests-"):
            print(" ".join(sorted(w["path"].split())))
elif field == "matrix":
    # stage k/n, one line per entry of the coverage matrix
    for e in jobs["coverage"]["strategy"]["matrix"]["include"]:
        print(f"{e['stage']} {e['k']}/{e['n']}")
elif field == "merge-if":
    print(jobs["coverage-merge"].get("if", ""))
    print(jobs["coverage-merge"].get("needs", ""))
PY
}

@test "coverage (#462): a test that fails fails its step; the steps after it still run, the failed tests go in the summary" {
  run cov tests-run
  [[ "$output" == *"scripts/coverage.sh \${{ matrix.stage }}"* ]]
  [[ "$output" != *"|| true"* ]]
  # it pipes into tee: only `shell: bash` (bash -eo pipefail) fails the step when the
  # tests fail; with no shell, GitHub runs `bash -e {0}`, and the step takes tee's status
  run cov tests-shell
  [ "$output" = bash ]
  run cov after-ifs
  echo "$output"
  [ "${#lines[@]}" -ge 4 ]
  [ "$(grep -cvxF "\${{ !cancelled() && steps.tests.outcome != 'skipped' }}" <<<"$output")" -eq 0 ]
  run cov summary
  # shellcheck disable=SC2016 # the workflow's text
  [ "$output" = 'micromamba run -n agent-sandbox scripts/coverage.sh failures >>"$GITHUB_STEP_SUMMARY"' ]
}

@test "coverage (#462): each shard uploads its TAP and timing files, and coverage-merge runs whatever the shards' results" {
  run cov tests-artifact
  [ "$output" = "coverage-out/*.tap coverage-out/engine-runs/*/kcov.log coverage-out/timing-*.tsv" ]
  run cov merge-if
  # shellcheck disable=SC2016 # the workflow's text
  [ "${lines[0]}" = '${{ !cancelled() }}' ]
  [ "${lines[1]}" = coverage ]
}

@test "coverage (#462): engine-unit runs as six shards, k = 1..6 of n = 6, and engine-integration as two" {
  run cov matrix
  echo "$output"
  [ "${#lines[@]}" -eq 8 ]
  [ "${lines[0]}" = "engine-unit 1/6" ]
  [ "${lines[1]}" = "engine-unit 2/6" ]
  [ "${lines[2]}" = "engine-unit 3/6" ]
  [ "${lines[3]}" = "engine-unit 4/6" ]
  [ "${lines[4]}" = "engine-unit 5/6" ]
  [ "${lines[5]}" = "engine-unit 6/6" ]
  [ "${lines[6]}" = "engine-integration 1/2" ]
  [ "${lines[7]}" = "engine-integration 2/2" ]
}
