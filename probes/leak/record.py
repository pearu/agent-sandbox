#!/usr/bin/env python3
"""Records for the cross-project leak study (docs/cross-project-channels.md).

A row's record must be detailed enough to reconstruct WHAT PATH a leak took, what
triggered or blocked it, and what a user can do in either direction -- sharing is
sometimes the goal. So a record keeps the raw evidence beside the verdict, and the
verdict is derived here rather than decided by whoever writes the row script.

    record.py verdict READER.json      classify one reader result
    record.py models TRANSCRIPT.jsonl  which model(s) actually served, in order
    record.py write --out R.json ...   assemble a record

The reader (a small program run inside or outside the sandbox) reports a JSON object
with `open` (ok, or the errno name) and `token_found`. That is deliberately three
outcomes, not two:

    obtained                  the token was read
    not-obtained-unreachable  the file could not be opened (errno kept)
    not-obtained-absent       the file opened, the token was not in it

The third exists because a mis-planted canary otherwise reads exactly like isolation:
both look like "B did not get it". Keeping them apart is what stops a broken setup
from being recorded as a working sandbox.
"""
import json
import subprocess
import sys

VERDICT_OBTAINED = "obtained"
VERDICT_UNREACHABLE = "not-obtained-unreachable"
VERDICT_ABSENT = "not-obtained-absent"
VERDICT_MALFORMED = "invalid-reader-output"


def classify(reader):
    """Verdict from a reader's report. A reader that did not produce usable output
    is INVALID, never a negative: 'the experiment failed' and 'the sandbox blocked
    it' are different findings and only one of them is a result."""
    if not isinstance(reader, dict):
        return VERDICT_MALFORMED
    opened = reader.get("open")
    if not isinstance(opened, str) or not opened:
        return VERDICT_MALFORMED
    if opened != "ok":
        return VERDICT_UNREACHABLE
    found = reader.get("token_found")
    if not isinstance(found, bool):
        return VERDICT_MALFORMED
    return VERDICT_OBTAINED if found else VERDICT_ABSENT


def models_served(path):
    """Which model served each message of a session, in order of first appearance,
    with counts. The requested model is not necessarily the one that served: a
    session can fall back or switch mid-run, and the transcript is where that is
    visible. An undocumented schema, so a missing field is 'unknown', never assumed.
    """
    counts, order = {}, []
    try:
        fh = open(path, encoding="utf-8", errors="surrogateescape")
    except OSError as e:
        return {"error": "%s: %s" % (type(e).__name__, e.strerror or e)}
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            m = None
            msg = d.get("message")
            if isinstance(msg, dict):
                m = msg.get("model")
            if not m:
                m = d.get("model")
            if not isinstance(m, str) or not m:
                continue
            counts[m] = counts.get(m, 0) + 1
            if not order or order[-1] != m:
                order.append(m)
    if not counts:
        return {"models": {}, "order": [], "note": "no model field found in transcript"}
    out = {"models": counts, "order": order}
    if len(counts) > 1:
        # A run that straddles a switch is not a clean measurement of either model.
        out["note"] = "MORE THAN ONE MODEL SERVED THIS SESSION; attribute per message"
    return out


def _harness_commit():
    try:
        r = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return r.stdout.strip() if r.returncode == 0 else "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def cmd_write(argv):
    out = None
    fields = {}
    reader_path = transcript = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            i += 1
            out = argv[i]
        elif a == "--reader":
            i += 1
            reader_path = argv[i]
        elif a == "--transcript":
            i += 1
            transcript = argv[i]
        elif a == "--set":
            i += 1
            k, _, v = argv[i].partition("=")
            fields[k] = v
        elif a == "--set-file":
            i += 1
            k, _, path = argv[i].partition("=")
            try:
                with open(path, encoding="utf-8", errors="surrogateescape") as fh:
                    fields[k] = fh.read()
            except OSError as e:
                fields[k] = "<unreadable: %s>" % e
        else:
            sys.stderr.write("record.py write: unknown argument %r\n" % a)
            return 2
        i += 1
    if not out:
        sys.stderr.write("record.py write: --out is required\n")
        return 2

    rec = dict(fields)
    rec["harness_commit"] = _harness_commit()
    if reader_path:
        try:
            with open(reader_path, encoding="utf-8") as fh:
                reader = json.load(fh)
        except (OSError, ValueError) as e:
            reader = {"error": str(e)}
        rec["reader"] = reader
        rec["verdict"] = classify(reader)
    if transcript:
        rec["serving_models"] = models_served(transcript)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    sys.stdout.write("%s\n" % rec.get("verdict", "recorded"))
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "verdict":
        try:
            with open(argv[2], encoding="utf-8") as fh:
                reader = json.load(fh)
        except (OSError, ValueError):
            reader = None
        sys.stdout.write("%s\n" % classify(reader))
        return 0
    if len(argv) >= 3 and argv[1] == "models":
        json.dump(models_served(argv[2]), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if len(argv) >= 2 and argv[1] == "write":
        return cmd_write(argv[2:])
    sys.stderr.write(
        "usage: record.py verdict READER.json\n"
        "       record.py models TRANSCRIPT.jsonl\n"
        "       record.py write --out R.json [--set k=v] [--set-file k=PATH]\n"
        "                       [--reader READER.json] [--transcript T.jsonl]\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
