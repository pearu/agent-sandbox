#!/usr/bin/env bash
# Row 10 — mcpServers. Can a session in project B read project A's MCP server config?
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# THE FIRST ROW EXPECTED TO LEAK. mcpServers lives in ~/.claude.json, which the engine
# binds WHOLE and read-write (profile_config_binds) -- no scoping, no disposition. So
# unlike rows 1-4 the expectation is `obtained` in T2, and the control structure has to
# change with it: see leak_isolation_canary in lib.sh for why "B reads its own data"
# proves nothing on a shared channel, and what replaces it.
#
# Documented as a known cap, not an oversight: .claude.json "lists every project path
# and the account email, and it is written live by the agent, so filtering it risks
# breaking Claude Code" (docs/design.md). This row measures what that cap costs.
#
# One network mode: row 2's invariance control.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=10-mcpservers
VALID=1
leak_setup "$LEAK_ROW"

CONFIG_JSON="$LEAK_HOME/.claude.json"
A_CANARY="LEAK-AMCP-ROW10-$(date +%s)-$RANDOM"
B_CANARY="LEAK-BMCP-ROW10-$(date +%s)-$RANDOM"

# A global mcpServers entry (A's), and a per-project one under B's own entry. The
# per-project form is real: a project entry in .claude.json carries its own mcpServers.
python3 - "$CONFIG_JSON" "$LEAK_A" "$LEAK_B" "$A_CANARY" "$B_CANARY" <<'PY'
import json, sys
path, a, b, a_tok, b_tok = sys.argv[1:6]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["mcpServers"] = {a_tok: {"command": "/usr/bin/" + a_tok, "args": ["--from", a]}}
cfg.setdefault("projects", {})
cfg["projects"][b] = {"mcpServers": {b_tok: {"command": "/usr/bin/" + b_tok}}}
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

leak_say "T2 (sandboxed, net=none) — A's MCP server config"
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$CONFIG_JSON" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-shared" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$CONFIG_JSON" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 — B's OWN per-project mcpServers (the file is present and carries B's data)"
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
echo "=== row 10: mcpServers — reachability of A's MCP config from B ==="
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
