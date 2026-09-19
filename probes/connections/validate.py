#!/usr/bin/env python3
"""The VALIDITY GATE for a connections suite: is this run a measurement at all?

Separate from the leak study's gate (probes/leak/record.py validate) because the two
studies control for different things. The leak gate asks whether a reachability
experiment was set up correctly -- a T1 positive control, a `-own` negative control, a
topology on every record. A connections cell has none of those: it asserts that a mode
behaves as promised, over a sequence of launches, and its controls are per cell.

WHAT A GATE IS FOR, AND WHAT IT IS NOT FOR. `fail` is a RESULT: the engine made a
promise and broke it, which is exactly what an acceptance suite exists to report. So a
failed assertion does not invalidate a run. What invalidates a run is the measurement
being untrustworthy: a control that did not hold, a launch whose reader produced
nothing readable, two different Claude Code versions inside one run, or this run having
written to the real ~/.claude. Those make every verdict in the run unsafe to read,
including the passes.

Exits 0 and prints `=> valid`, or exits 1 and prints `=> INVALID RUN`.
"""

import json
import os
import re
import sys

# Statuses a record may carry. An unknown one means the harness and this gate have
# drifted apart, which is itself a reason not to trust the run.
KNOWN = {"pass", "fail", "not-implemented", "blocked", "control-pass", "control-fail"}
RAN = {"pass", "fail"}  # statuses that mean a launch actually happened


def load(rundir):
    recs = []
    d = os.path.join(rundir, "records")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as fh:
                r = json.load(fh)
            r["_file"] = name
            recs.append(r)
        except (OSError, ValueError) as e:
            recs.append({"_file": name, "_error": str(e)})
    return recs


def validate(rundir, known_ambient=None):
    checks = []
    recs = load(rundir)

    broken = [r["_file"] for r in recs if "_error" in r]
    checks.append(("records readable", not broken, ", ".join(broken)))
    recs = [r for r in recs if "_error" not in r]

    checks.append(("records present", bool(recs),
                   "" if recs else "no records in %s" % rundir))
    if not recs:
        return checks

    bad_status = sorted({r.get("status", "") for r in recs} - KNOWN)
    checks.append(("every status is one this gate knows", not bad_status,
                   "unknown: " + ", ".join(bad_status) if bad_status else ""))

    # ONE CLASS PER RUN. A result belongs to a (Claude major.minor x engine x.y.z) pair,
    # so a version changing mid-run -- an auto-update between launches -- would pair
    # assertions from two different subjects under one score. Cheap to check, impossible
    # to spot afterwards.
    for field in ("claude_version", "engine_version"):
        seen = {r.get(field, "") for r in recs}
        ok = len(seen) == 1 and "" not in seen
        checks.append(("one %s across the run" % field.split("_")[0], ok,
                       "" if ok else "saw: " + ", ".join(sorted(repr(s) for s in seen))))

    # A reader that produced nothing parseable is a FAILED EXPERIMENT, not a closed
    # channel -- the distinction the whole harness exists to preserve. Only records from
    # a launch are checked: a recorded expectation never ran a reader.
    invalid = [r["_file"] for r in recs
               if r.get("status") in RAN and r.get("verdict") == "invalid-reader-output"]
    checks.append(("no invalid reader output from a launch", not invalid,
                   ", ".join(invalid)))

    # THE CONTROLS. Without them a suite of closed-channel expectations passes just as
    # well when nothing ran at all.
    ctrl_bad = [r["_file"] for r in recs if r.get("status") == "control-fail"]
    checks.append(("every control held", not ctrl_bad, ", ".join(ctrl_bad)))

    ran_cells = {r.get("cell") for r in recs if r.get("status") in RAN}
    ctrl_cells = {r.get("cell") for r in recs if str(r.get("status", "")).startswith("control-")}
    missing = sorted(ran_cells - ctrl_cells)
    checks.append(("every cell that ran carries its controls", not missing,
                   "no controls for: " + ", ".join(missing) if missing else ""))

    # The one outcome no study may have: changing the thing it measures around.
    att = os.path.join(rundir, "real-attributable")
    unexplained = []
    if os.path.exists(att):
        with open(att, encoding="utf-8", errors="surrogateescape") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and not (known_ambient and re.search(known_ambient, parts[1])):
                    unexplained.append(line.rstrip("\n"))
    checks.append(("the real config carries nothing from this run", not unexplained,
                   "; ".join(unexplained)))
    return checks


def main(argv):
    rundir, known = None, None
    i = 0
    while i < len(argv):
        if argv[i] == "--known-ambient":
            i += 1
            known = argv[i] if i < len(argv) else None
        else:
            rundir = argv[i]
        i += 1
    if not rundir:
        sys.stderr.write("validate.py RUNDIR [--known-ambient REGEX]\n")
        return 2
    checks = validate(rundir, known)
    sys.stdout.write("validity gate:\n")
    for name, ok, detail in checks:
        sys.stdout.write("  %-46s %s%s\n" % (name, "PASS" if ok else "FAIL",
                                             ("  -- " + detail) if detail else ""))
    failed = [c for c in checks if not c[1]]
    with open(os.path.join(rundir, "validity.json"), "w", encoding="utf-8") as fh:
        json.dump({"valid": not failed,
                   "checks": [{"name": n, "pass": o, "detail": d} for n, o, d in checks]},
                  fh, indent=2, sort_keys=True)
        fh.write("\n")
    if failed:
        sys.stdout.write("  => INVALID RUN: do not read this as a result\n")
        return 1
    sys.stdout.write("  => valid\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
