#!/usr/bin/env bash
# Row 1 — PROJECT MEMORY. Can a session in project B read project A's memory?
#
# Level 1 only (reachability): the scripted reader contains no LLM, so this measures
# the container alone and the result is model-independent. Level 2 (does a real
# session ingest another project's memory unprompted) is the "real claude" half of
# this row's probe column and is run with the credentialed batch.
#
# Canary placement. Memory is keyed to the REPOSITORY natively and to the DIRECTORY
# inside the sandbox (established in docs/cross-project-channels.md "Units",
# docs/design.md and docs/config.md; not re-measured here). leak_setup makes A and B
# separate repositories AT THEIR OWN ROOTS, so the two keys name the same slug and a
# canary planted by path is correct in both topologies. A row whose projects were
# subdirectories would have to plant twice.
#
# One network mode: row 2 ran all three and found them identical, which is the
# invariance control for the filesystem rows (see "Network mode" in the plan).
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=01-memory
VALID=1
leak_setup "$LEAK_ROW"

# ---- plant the canaries -----------------------------------------------------
A_CANARY="$(leak_token AMEM)"
A_SLUG="$(leak_slug "$LEAK_A")"
A_MEMORY="$LEAK_CONFIG/projects/$A_SLUG/memory/NOTE.md"
mkdir -p "$(dirname "$A_MEMORY")"
printf '%s\n' "$A_CANARY" >"$A_MEMORY"

# B's own memory carries a DIFFERENT token. It is the negative control: inside the
# sandbox B must still reach its own project. Without it, "A's memory is unreachable"
# cannot be told apart from "no config is visible in there at all", and both would
# read as isolation.
B_CANARY="$(leak_token BMEM)"
B_SLUG="$(leak_slug "$LEAK_B")"
B_MEMORY="$LEAK_CONFIG/projects/$B_SLUG/memory/NOTE.md"
mkdir -p "$(dirname "$B_MEMORY")"
printf '%s\n' "$B_CANARY" >"$B_MEMORY"
leak_say "planted A=$A_CANARY B=$B_CANARY"

# ---- the reader -------------------------------------------------------------
# Identifies the canary by CONTENT, not by path, and keeps the three outcomes
# distinguishable (opened-and-found / opened-and-absent / could not open).
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

# An approved [share-memory] entry binds the named project's memory/ READ-ONLY. The
# read verdict says whether B obtains A's notes; it does not say whether B can
# corrupt them, and a user acting on "another project's memory is visible" needs
# both. Reported as a field on the share cell rather than as a verdict, because the
# verdict vocabulary is about reads.
WRITER="$LEAK_B/writer.py"
cat >"$WRITER" <<'PY'
import errno, sys
try:
    with open(sys.argv[1], "a", encoding="utf-8") as fh:
        fh.write("WROTE-FROM-B\n")
    print("wrote")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY

# ---- run the cells ----------------------------------------------------------
leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_MEMORY" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$A_MEMORY" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, scoped default, net=none)"
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$A_MEMORY" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-scoped" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$A_MEMORY" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 negative control (B's own memory, same sandbox, same reader)"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$B_MEMORY" "$B_CANARY"
leak_record "t2-scoped-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$B_CANARY" --set "target=$B_MEMORY" --reader "$LEAK_RUN/t2-own.json"

# ---- the two deliberate-sharing levers ---------------------------------------
# For row 2 the share cell existed only to give the transcript cell meaning. Here it
# IS the channel, and naming-A versus `all` is what tells a user whether memory can
# be shared selectively -- the question the same pair answered negatively for
# transcripts.
leak_say "T2-share ([share-memory] names A)"
printf '[share-memory]\n%s\n' "$LEAK_A" >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-share.json" "$A_MEMORY" "$A_CANARY"
leak_read_sandboxed none "$LEAK_B" "$WRITER" "$LEAK_RUN/t2-share-write.txt" "$A_MEMORY"
SHARE_WRITE="$(cat "$LEAK_RUN/t2-share-write.txt")"
leak_record "t2-share-named" --set "topology=T2-share" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_CANARY" --set "target=$A_MEMORY" \
  --set "write_attempt=$SHARE_WRITE" --reader "$LEAK_RUN/t2-share.json"
leak_say "  write into the shared memory: $SHARE_WRITE"

leak_say "T2-share-all ([share-memory] all)"
printf '[share-memory]\nall\n' >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-all.json" "$A_MEMORY" "$A_CANARY"
leak_record "t2-share-all" --set "topology=T2-share-all" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_CANARY" --set "target=$A_MEMORY" \
  --reader "$LEAK_RUN/t2-all.json"
rm -f "$LEAK_B/.agent-sandbox"
leak_untrust "$LEAK_B"

# A's canary must still read exactly as planted: if the share bind were writable, the
# write above changed the substrate under the later cells.
if [[ "$(cat "$A_MEMORY")" == "$A_CANARY" ]]; then
  leak_say "A's memory is unmodified on the host"
else
  leak_say "WARNING: A's memory CHANGED during the run -- the share bind was writable"
fi

leak_real_config_after
leak_validate || VALID=0

# ---- report -----------------------------------------------------------------
echo
echo "=== row 1: project memory — reachability of A's memory from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
extra = "  write=%s" % d["write_attempt"] if "write_attempt" in d else ""
print("  %-16s %-14s %s%s" % (os.path.basename(sys.argv[1])[:-5],
                              d.get("topology", "?"), d.get("verdict", "?"), extra))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
