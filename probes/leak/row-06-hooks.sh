#!/usr/bin/env bash
# Row 6 — settings.json HOOKS. Does a session in project B run hooks another project
# wrote into the global ~/.claude/settings.json?
#
# The most serious injection channel in the catalog, and the one that differs in kind
# from row 5. A CLAUDE.md is text a model may or may not act on. A hook is CODE THAT
# RUNS: the session executes it because an event fired, not because a model decided to.
#
# Two consequences for the method:
#
#   THE OBSERVABLE IS MODEL-INDEPENDENT. The canary hook writes a token to a file, and
#   the verdict is whether that file carries it. So these cells carry NO transcript: the
#   gate's "a real model served" check exists for cells that assert what a model did, and
#   applying it here would invalidate a perfectly good measurement whenever the API turn
#   failed for unrelated reasons. The hook firing is the finding, served or not.
#
#   THE ISOLATION CHECK IS REQUIRED. A hook firing "inside the sandbox" looks identical
#   to a hook firing because the launch never got sandboxed -- same command, same file,
#   same host path. So a known-isolated canary is read from the same sandbox to show it
#   really applied. Without that, this row's positive would be uninterpretable.
#
#   AND THE HOOK REPORTS WHERE IT RAN, POSITIVELY. The isolation check above shows the
#   SESSION was sandboxed; it does not show the HOOK was, because the marker file goes
#   to the bound working directory, which the host can write just as well. So the hook
#   echoes $AGENT_SANDBOX -- set by the engine only inside -- and separately tries to
#   read another project's transcript, leaving no file when it cannot. Measuring both
#   avoids chaining "it runs inside" (unverified) onto "inside, that path is ENOENT"
#   (measured for a DIFFERENT launch path: `--exec` replaces the agent, while a hook is
#   spawned by the agent at runtime).
#
# Each cell writes to its OWN file: a file left by an earlier cell would otherwise make
# the control cell, which must find nothing, read as a positive.
#
# Expected shared in both topologies: settings.json is in ~/.claude, bound whole, with no
# disposition -- the sandbox does not filter the user's own configuration.
#
# COSTS API CALLS: four short turns, net=proxy.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=06-hooks
VALID=1
leak_setup "$LEAK_ROW"
leak_authenticate

STAMP="$(date +%s)"
G_CANARY="LEAK-HOOK-ROW06-$STAMP-$RANDOM"
P_CANARY="LEAK-PROJHOOK-ROW06-$STAMP-$RANDOM"
SETTINGS="$LEAK_CONFIG/settings.json"
PROJECT_SETTINGS="$LEAK_B/.claude/settings.json"
PROMPT="What is 2 plus 2?"
mkdir -p "$(dirname "$PROJECT_SETTINGS")"

# write_hooks FILE TOKEN OUTFILE -- SessionStart and Stop both fire without any tool
# use, and both write the same marker file: which of them fires is detail, that one of
# them does is the result. The per-event prefix keeps that detail in the record.
write_hooks() {
  python3 - "$1" "$2" "$3" "$PROBE" "$LEAK_ISO_PATH" <<'PY'
import json, os, sys
path, token, outfile, probe, target = sys.argv[1:6]
hooks = {}
for event in ("SessionStart", "Stop"):
    cmd = "sh %s %s %s %s %s" % (probe, event, outfile, token, target)
    hooks[event] = [{"hooks": [{"type": "command", "command": cmd}]}]
cfg = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except ValueError:
        cfg = {}
cfg["hooks"] = hooks
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
PY
}

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
    out["events"] = sorted({ln.split(":")[0] for ln in data.splitlines() if ":" in ln})
    out["agent_sandbox"] = sorted({ln.split("AGENT_SANDBOX=")[1].strip()
                                   for ln in data.splitlines() if "AGENT_SANDBOX=" in ln})
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY

leak_isolation_canary
PROBE="$LEAK_B/exec-probe.sh"
leak_write_exec_probe "$PROBE"
leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control) — does a global hook fire at all?"
T1_OUT="$LEAK_B/fired-t1.txt"
write_hooks "$SETTINGS" "$G_CANARY" "$T1_OUT"
leak_session_native "$LEAK_B" "$PROMPT" "$LEAK_RUN/t1.txt"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$T1_OUT" "$G_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$G_CANARY" --set "target=$SETTINGS" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=proxy) — the same global hook"
T2_OUT="$LEAK_B/fired-t2.txt"
write_hooks "$SETTINGS" "$G_CANARY" "$T2_OUT"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2.txt"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$T2_OUT" "$G_CANARY"
leak_record "t2-sandboxed" --set "topology=T2" --set "net=proxy" --set "sandboxed=yes" \
  --set "canary=$G_CANARY" --set "target=$SETTINGS" --reader "$LEAK_RUN/t2.json"

leak_say "  ...and what could the hook reach? (A's transcript, copied beside the marker)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2-reach.json" "$T2_OUT.read" "$LEAK_ISO_TOKEN"
leak_record "t2-hook-reach" --set "topology=T2-hook-reach" --set "net=proxy" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-reach.json"

leak_say "T2 control — the same prompt with NO hooks configured"
T2C_OUT="$LEAK_B/fired-t2-control.txt"
python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p)); d.pop('hooks', None)
json.dump(d, open(p,'w'), indent=2)" "$SETTINGS"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2-control.txt"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2-control.json" "$T2C_OUT" "$G_CANARY"
leak_record "t2-control-nohooks" --set "topology=T2-control" --set "net=proxy" \
  --set "sandboxed=yes" --set "canary=$G_CANARY" --set "target=(removed)" \
  --reader "$LEAK_RUN/t2-control.json"

leak_say "  ...and the same reach question NATIVELY, as the comparison"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1-reach.json" "$T1_OUT.read" "$LEAK_ISO_TOKEN"
leak_record "t1-hook-reach" --set "topology=T1-hook-reach" --set "net=n/a" \
  --set "sandboxed=no" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t1-reach.json"

leak_say "T2 negative control — B's OWN project hook (.claude/settings.json)"
OWN_OUT="$LEAK_B/fired-own.txt"
write_hooks "$PROJECT_SETTINGS" "$P_CANARY" "$OWN_OUT"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2-own.txt"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$OWN_OUT" "$P_CANARY"
leak_record "t2-own" --set "topology=T2-own" --set "net=proxy" --set "sandboxed=yes" \
  --set "canary=$P_CANARY" --set "target=$PROJECT_SETTINGS" --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 ISOLATION CHECK — A's transcript, known scoped, from the SAME sandbox"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-iso.json" \
  "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
leak_record "t2-isolation-check" --set "topology=T2-isolation-check" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-iso.json"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 6: settings.json hooks — does another project's hook run in B? ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
r = d.get("reader", {})
e = r.get("events") or []
a = r.get("agent_sandbox") or []
print("  %-20s %-22s %-26s %-18s %s" % (os.path.basename(sys.argv[1])[:-5],
                                        d.get("topology", "?"), d.get("verdict", "?"),
                                        ",".join(e), "AGENT_SANDBOX=" + ",".join(a) if a else ""))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
