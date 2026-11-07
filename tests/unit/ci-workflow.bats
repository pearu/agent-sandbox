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
