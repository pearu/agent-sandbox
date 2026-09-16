#!/usr/bin/env bash
# Row 15 — agent-memory/ (SUBAGENT MEMORY). Can B read the memory A's subagents kept?
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# Found by reading the documentation rather than the code. `/en/claude-directory` lists
# `agent-memory/` under "Keep these state files", described as *subagent memory*. It is
# TOP-LEVEL -- a sibling of projects/, not inside it -- and it appears NOWHERE in this
# repository: no disposition, no mention. So `memory = scoped`, which closed row 1, does
# not reach it.
#
# That is why this row exists separately from the other uncatalogued paths: it is
# MEMORY, the same kind of content row 1 measured as closed, reachable through a path
# beside the one that was closed.
#
# The directory does not exist on the host that ran this, so nothing has written it yet
# and its internal shape is UNVERIFIED -- the canary is planted at a plausible path.
# What the row measures is the container's treatment of the path, which does not depend
# on the shape: an unisolated path is part of the read-write bind of ~/.claude whatever
# it contains.
#
# Expected to leak, so the control is leak_isolation_canary (see lib.sh) rather than
# "B reads its own data", which is obtained on a shared channel whether or not the
# sandbox applied.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=15-agent-memory
VALID=1
leak_setup "$LEAK_ROW"

AGENT_MEM="$LEAK_CONFIG/agent-memory"
A_CANARY="$(leak_token AAGENT)"
B_CANARY="$(leak_token BAGENT)"
A_FILE="$AGENT_MEM/reviewer/NOTE.md"
B_FILE="$AGENT_MEM/explorer/NOTE.md"
mkdir -p "$(dirname "$A_FILE")" "$(dirname "$B_FILE")"
printf '# subagent note\n\n%s\n' "$A_CANARY" >"$A_FILE"
printf '# subagent note\n\n%s\n' "$B_CANARY" >"$B_FILE"
leak_isolation_canary
leak_say "planted A=$A_CANARY B=$B_CANARY iso=$LEAK_ISO_TOKEN"

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

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_FILE" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$A_FILE" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=none) — another agent's memory note"
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$A_FILE" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-shared" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$A_FILE" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 — B's own agent note (the directory is present and carries B's file)"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$B_FILE" "$B_CANARY"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$B_CANARY" --set "target=$B_FILE" --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 ISOLATION CHECK — A's transcript, known scoped, from the SAME sandbox"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-iso.json" \
  "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
leak_record "t2-isolation-check" --set "topology=T2-isolation-check" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-iso.json"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 15: agent-memory/ — reachability of another agent's memory from B ==="
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
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
