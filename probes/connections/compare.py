#!/usr/bin/env python3
"""Diff two runs of one suite: which assertions reached different verdicts?

W8 asks whether `copy-on-write` behaves the same when it is implemented with an overlay and when it
falls back to `copy`. That used to require a second, older machine, and would have
compared one implementation against a memory of the other. `[overlay] mode = off` makes
both runnable on one host, so the comparison is direct.

Prints the number of assertions that differ, and writes each difference to stderr. A
difference is not automatically a defect -- `copy-on-write` and `copy` are allowed to diverge WITHIN
a running session, which is Part 7's subject -- but Part 1 only ever observes across
launches, where they are claimed to be identical, so anything printed here contradicts a
claim the model makes.
"""

import json
import os
import sys


def load(d):
    """{(cell, assertion): status} for one run, controls excluded.

    Controls say the measurement was sound, not what the mode did, so comparing them
    would report noise from the throwaway tree rather than from the implementations.
    """
    out = {}
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(d, name), encoding="utf-8") as fh:
            r = json.load(fh)
        if str(r.get("status", "")).startswith("control-"):
            continue
        out[(r.get("cell"), r.get("assertion"))] = r.get("status")
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("compare.py RECORDS_A RECORDS_B\n")
        return 2
    a, b = load(argv[0]), load(argv[1])
    differ = [k for k in sorted(set(a) & set(b)) if a[k] != b[k]]
    # An assertion present in only one run is also a divergence: the suites are the same
    # file, so a missing one means a cell stopped part-way in one arrangement.
    missing = sorted(set(a) ^ set(b))
    for cell, assertion in differ:
        sys.stderr.write("  %s  overlay=%s  off=%s  -- %s\n"
                         % (cell, a[(cell, assertion)], b[(cell, assertion)], assertion))
    for cell, assertion in missing:
        sys.stderr.write("  %s  reached in only one arrangement -- %s\n" % (cell, assertion))
    print(len(differ) + len(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
