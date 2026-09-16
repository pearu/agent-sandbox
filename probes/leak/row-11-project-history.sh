#!/usr/bin/env bash
# Row 11 — PER-PROJECT STATE IN ~/.claude.json. Can B read A's project entry?
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# The sharp row, and the plan says why: this is per-project DATA that the project
# scoping misses, because it is not under projects/. ~/.claude.json is bound WHOLE and
# read-write, so `memory = scoped` -- which made rows 1-2 unreachable -- does not reach
# it. Expected to leak, so the control is leak_isolation_canary (see lib.sh), not
# "B reads its own data", which is obtained on a shared channel whether or not the
# sandbox applied.
#
# WHAT IS ACTUALLY IN THERE, measured on a working host: a project entry carries
# `lastSessionFirstPrompt` -- the literal text of that project's last session's opening
# prompt -- alongside mcpServers, allowedTools, exampleFiles, lastSessionId and
# per-project cost and token metrics. So the canary is planted in the field that
# actually carries another project's words, not in a synthetic key: the row should
# measure the exposure that exists rather than one invented for it.
#
# One network mode: row 2's invariance control.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=11-project-history
VALID=1
leak_setup "$LEAK_ROW"

CONFIG_JSON="$LEAK_HOME/.claude.json"
A_CANARY="$(leak_token APROJ)"
B_CANARY="$(leak_token BPROJ)"

python3 - "$CONFIG_JSON" "$LEAK_A" "$LEAK_B" "$A_CANARY" "$B_CANARY" <<'PY'
import json, sys
path, a, b, a_tok, b_tok = sys.argv[1:6]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg.setdefault("projects", {})
# The shape a real entry has, with the canary where a real prompt would be.
for d, tok in ((a, a_tok), (b, b_tok)):
    cfg["projects"][d] = {
        "hasTrustDialogAccepted": True,
        "lastSessionFirstPrompt": "please review the auth rewrite " + tok,
        "lastSessionId": "00000000-0000-0000-0000-000000000000",
        "allowedTools": [],
    }
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh)
PY
leak_isolation_canary
leak_say "planted A=$A_CANARY B=$B_CANARY iso=$LEAK_ISO_TOKEN"

READER="$LEAK_B/reader.py" # inside the cwd: the sandbox binds that, nothing above it
cat >"$READER" <<'PY'
import errno, json, sys
path, token = sys.argv[1], sys.argv[2]
out = {"path": path, "token": token}
try:
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        data = fh.read()
    out["open"] = "ok"
    out["token_found"] = token in data
    out["bytes"] = len(data)
    # How many project entries are visible: a count, never the paths themselves.
    try:
        out["projects_visible"] = len(json.loads(data).get("projects", {}))
    except ValueError:
        out["projects_visible"] = None
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$CONFIG_JSON" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$CONFIG_JSON" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=none) — A's last-session prompt"
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$CONFIG_JSON" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-shared" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$CONFIG_JSON" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 — B's OWN entry (the file is present and carries B's data)"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$CONFIG_JSON" "$B_CANARY"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$B_CANARY" --set "target=$CONFIG_JSON" --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 ISOLATION CHECK — A's transcript, known scoped, from the SAME sandbox"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-iso.json" \
  "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
leak_record "t2-isolation-check" --set "topology=T2-isolation-check" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-iso.json"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 11: per-project state in ~/.claude.json ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
n = d.get("reader", {}).get("projects_visible")
print("  %-20s %-22s %-14s %s" % (os.path.basename(sys.argv[1])[:-5],
                                  d.get("topology", "?"), d.get("verdict", "?"),
                                  "" if n is None else "projects_visible=%d" % n))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
