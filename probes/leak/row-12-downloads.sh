#!/usr/bin/env bash
# Row 12 — downloads/. Can a session in project B read files another project downloaded?
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# Expected to leak, and for the simplest reason in the study: ~/.claude/downloads has
# NO disposition at all. It is not in profile_isolate, so it is neither scoped, tmpfs'd,
# copied out nor filtered -- it is simply part of the read-write bind of ~/.claude. It is
# also flat and global, not keyed by project, so one project's downloaded documents sit
# beside another's under one directory. Tracked as #52.
#
# Control: leak_isolation_canary (see lib.sh). On a shared channel "B reads its own
# data" is obtained whether or not the sandbox applied, so it cannot tell a real leak
# from a sandbox that never ran.
#
# One network mode: row 2's invariance control.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=12-downloads
VALID=1
leak_setup "$LEAK_ROW"

# ---- the substrate, rebuilt for every cell -------------------------------
# ONE CELL = ONE TREE (see row 1's header). plant() rebuilds the canaries from nothing for every cell.
plant() {
  DOWNLOADS="$LEAK_CONFIG/downloads"
  mkdir -p "$DOWNLOADS"
  A_CANARY="$(leak_token ADL)"
  B_CANARY="$(leak_token BDL)"
  A_FILE="$DOWNLOADS/quarterly-review.md"
  B_FILE="$DOWNLOADS/b-notes.md"
  printf '# Downloaded by project A\n\n%s\n' "$A_CANARY" >"$A_FILE"
  printf '# Downloaded by project B\n\n%s\n' "$B_CANARY" >"$B_FILE"
  leak_isolation_canary
  leak_say "planted A=$A_CANARY B=$B_CANARY iso=$LEAK_ISO_TOKEN"

  # Reports the directory listing too: for a flat, unscoped directory the question is not
  # only "is A's file readable" but "how much of other projects' material is in view".
  READER="$LEAK_B/reader.py" # inside the cwd: the sandbox binds that, nothing above it
  cat >"$READER" <<'PY'
import errno, json, os, sys
path, token = sys.argv[1], sys.argv[2]
out = {"path": path, "token": token}
try:
    out["dir_entries"] = sorted(os.listdir(os.path.dirname(path)))
except OSError as e:
    out["dir_entries"] = "<%s>" % errno.errorcode.get(e.errno, e.errno)
try:
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        data = fh.read()
    out["open"] = "ok"
    out["token_found"] = token in data
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY
}

leak_real_config_before

leak_say "T1 (native, positive control)"
leak_cell t1-native
plant
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_FILE" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$A_FILE" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=none) — A's downloaded document"
leak_cell t2-shared
plant
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$A_FILE" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-shared" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$A_FILE" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 — B's OWN download (the directory is present and carries B's file)"
leak_cell t2-own
plant
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$B_FILE" "$B_CANARY"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$B_CANARY" --set "target=$B_FILE" --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 ISOLATION CHECK — A's transcript, known scoped, from the SAME sandbox"
leak_cell t2-isolation-check
plant
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-iso.json" \
  "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
leak_record "t2-isolation-check" --set "topology=T2-isolation-check" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-iso.json"

leak_cell_finish
leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 12: downloads/ — reachability of A's downloaded files from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
e = d.get("reader", {}).get("dir_entries")
n = "" if e is None else "downloads/=%s" % (len(e) if isinstance(e, list) else e)
print("  %-20s %-22s %-14s %s" % (os.path.basename(sys.argv[1])[:-5],
                                  d.get("topology", "?"), d.get("verdict", "?"), n))
PY
done
echo
echo "records: $LEAK_RUN/records/"
echo "cells:   $LEAK_RUN/cells/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
