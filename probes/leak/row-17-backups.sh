#!/usr/bin/env bash
# Row 17 — backups/. Old ~/.claude.json snapshots, and what they do to deletion.
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# `/en/claude-directory`: Claude Code writes a `.claude.json.backup.<timestamp>` before
# each write and keeps the five most recent under `~/.claude/backups/`. Each snapshot is
# a whole `~/.claude.json`, so each carries EVERY project's entry -- the material row 11
# measured, including another project's `lastSessionFirstPrompt`.
#
# Its own row rather than a cell of row 18 because it is a different KIND of channel:
# a historical copy of another channel. Two consequences no other row has.
#
#   1. It survives removal. The purge documentation says so itself -- "backups/ may
#      still contain this project entry in old .claude.json snapshots". So the one
#      user-facing remedy row 11 could offer is incomplete by design.
#   2. It is not isolated. backups/ appears nowhere in profiles/claude.sh, so even a
#      future scoping of .claude.json would leave the snapshots beside it readable.
#
# Expected to leak, so the control is leak_isolation_canary (see lib.sh).
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=17-backups
VALID=1
leak_setup "$LEAK_ROW"

# ---- the substrate, rebuilt for every cell -------------------------------
# ONE CELL = ONE TREE (see row 1's header). plant() rebuilds the canaries from nothing for every cell.
plant() {
  BACKUPS="$LEAK_CONFIG/backups"
  mkdir -p "$BACKUPS"
  STAMP="$(date +%s)"
  A_CANARY="$(leak_token ABACKUP)"
  B_CANARY="$(leak_token BBACKUP)"
  SNAPSHOT="$BACKUPS/.claude.json.backup.$STAMP"
  CONFIG_JSON="$LEAK_HOME/.claude.json"

  # The snapshot carries A's project entry. The LIVE config does not: A's entry is
  # "deleted" there, exactly as `claude project purge` would leave it. So a positive in
  # this row is not a restatement of row 11 -- it is the leak that survives the remedy.
  python3 - "$CONFIG_JSON" "$SNAPSHOT" "$LEAK_A" "$LEAK_B" "$A_CANARY" "$B_CANARY" <<'PY'
import json, sys
cfg_path, snap_path, a, b, a_tok, b_tok = sys.argv[1:7]
with open(cfg_path, encoding="utf-8") as fh:
    cfg = json.load(fh)
snapshot = dict(cfg)
snapshot["projects"] = {
    a: {"lastSessionFirstPrompt": "please review the auth rewrite " + a_tok},
    b: {"lastSessionFirstPrompt": "start the migration " + b_tok},
}
with open(snap_path, "w", encoding="utf-8") as fh:
    json.dump(snapshot, fh)
# the live config AFTER a purge of A: only B remains
cfg["projects"] = {b: {"lastSessionFirstPrompt": "start the migration " + b_tok}}
with open(cfg_path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh)
PY
  leak_isolation_canary
  leak_say "planted A=$A_CANARY (snapshot only, purged from the live config) B=$B_CANARY"

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
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$SNAPSHOT" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$SNAPSHOT" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed) — A's purged entry, from the backup snapshot"
leak_cell t2-shared
plant
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$SNAPSHOT" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-shared" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$SNAPSHOT" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 — the LIVE config no longer has A's entry (the purge itself worked)"
leak_cell t2-live-config
plant
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-live.json" "$CONFIG_JSON" "$A_CANARY"
leak_record "t2-live-config" --set "topology=T2-purged" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_CANARY" --set "target=$CONFIG_JSON" \
  --reader "$LEAK_RUN/t2-live.json"

leak_say "T2 — B's own entry in the snapshot (the file is present and readable)"
leak_cell t2-own
plant
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$SNAPSHOT" "$B_CANARY"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$B_CANARY" --set "target=$SNAPSHOT" --reader "$LEAK_RUN/t2-own.json"

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
echo "=== row 17: backups/ — does a purged project entry survive in the snapshots? ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
print("  %-20s %-22s %s" % (os.path.basename(sys.argv[1])[:-5],
                            d.get("topology", "?"), d.get("verdict", "?")))
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
