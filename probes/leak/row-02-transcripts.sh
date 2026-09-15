#!/usr/bin/env bash
# Row 2 — TRANSCRIPTS. Can a session in project B read project A's transcript?
#
# Level 1 only (reachability): the scripted reader contains no LLM, so this measures
# the container alone and its result is model-independent. Whether a real session
# would ever *look* is level 2, and what one obtains when told to try is level 3;
# both need real sessions and are run separately (see the Method section).
#
# Cells:
#   T1  reader runs NATIVE           — the positive control. If A's canary is not
#                                      reachable with nothing isolating it, the
#                                      experiment is broken, not the sandbox working.
#   T2  reader runs under --exec     — the test, repeated in every network mode as
#                                      the invariance control: rows 1-12 should not
#                                      depend on the mode, and this is where that is
#                                      checked rather than assumed.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=02-transcripts
VALID=1
leak_setup "$LEAK_ROW"

# ---- plant A's canary -------------------------------------------------------
# A transcript is keyed to the WORKING DIRECTORY (memory is keyed to the
# repository; that difference is row 1's problem, not this one).
CANARY="LEAK-CANARY-ROW02-$(date +%s)-$RANDOM"
A_SLUG="$(leak_slug "$LEAK_A")"
A_TRANSCRIPT="$LEAK_CONFIG/projects/$A_SLUG/00000000-0000-0000-0000-00000000000a.jsonl"
mkdir -p "$(dirname "$A_TRANSCRIPT")"
printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$CANARY" >"$A_TRANSCRIPT"
leak_say "planted $CANARY in A's transcript ($A_SLUG)"

# B gets a transcript of its own, carrying a DIFFERENT token. It is the negative
# control: inside the sandbox B must still reach its own project. Without it,
# "A's transcript is unreachable" cannot be told apart from "no config is visible in
# there at all" -- the same shape of mistake as a mis-planted canary, and it would
# read as isolation either way.
# A also gets a memory note. The share-memory cell below needs something that IS
# shared to contrast with the transcript that is not: "nothing came through" would
# otherwise be explained equally well by the share not taking effect at all.
A_MEM_CANARY="LEAK-AMEM-ROW02-$(date +%s)-$RANDOM"
A_MEMORY="$LEAK_CONFIG/projects/$A_SLUG/memory/NOTE.md"
mkdir -p "$(dirname "$A_MEMORY")"
printf '%s\n' "$A_MEM_CANARY" >"$A_MEMORY"

B_SLUG="$(leak_slug "$LEAK_B")"
B_CANARY="LEAK-OWN-ROW02-$(date +%s)-$RANDOM"
B_TRANSCRIPT="$LEAK_CONFIG/projects/$B_SLUG/00000000-0000-0000-0000-00000000000b.jsonl"
mkdir -p "$(dirname "$B_TRANSCRIPT")"
printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$B_CANARY" >"$B_TRANSCRIPT"

# ---- the reader -------------------------------------------------------------
# Identifies the canary by CONTENT, not by path: a positive survives Claude Code
# moving the file, and the three outcomes stay distinguishable (see record.py).
READER="$LEAK_B/reader.py" # inside the cwd: the sandbox binds that, and nothing above it
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

# ---- run the cells ----------------------------------------------------------
leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_TRANSCRIPT" "$CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" --reader "$LEAK_RUN/t1.json"

for net in none proxy strict; do
  leak_say "T2 (sandboxed, net=$net)"
  leak_watch_start "$LEAK_CONFIG"
  leak_read_sandboxed "$net" "$LEAK_B" "$READER" "$LEAK_RUN/t2-$net.json" "$A_TRANSCRIPT" "$CANARY"
  leak_watch_stop
  cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2-$net.reads" 2>/dev/null || true
  leak_record "t2-$net" --set "topology=T2" --set "net=$net" --set "sandboxed=yes" \
    --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" \
    --reader "$LEAK_RUN/t2-$net.json" --set-file "reads=$LEAK_RUN/records/t2-$net.reads"

  # negative control, same sandbox, same reader, B's OWN project
  leak_read_sandboxed "$net" "$LEAK_B" "$READER" "$LEAK_RUN/t2-$net-own.json" \
    "$B_TRANSCRIPT" "$B_CANARY"
  leak_record "t2-$net-own" --set "topology=T2-own" --set "net=$net" --set "sandboxed=yes" \
    --set "canary=$B_CANARY" --set "target=$B_TRANSCRIPT" \
    --reader "$LEAK_RUN/t2-$net-own.json"
done

# ---- can a share expose transcripts too? -------------------------------------
# [share-memory] naming A binds projects/<A>/memory read-only. Transcripts are
# SIBLINGS of memory/, not inside it, so the expectation is that A's memory comes
# through and A's transcript does not -- i.e. transcripts cannot be shared
# selectively at all. Measured rather than read off the code, because it is the
# advice a user acts on.
leak_say "T2-share (sandboxed, [share-memory] names A, net=none)"
printf '[share-memory]\n%s\n' "$LEAK_A" >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-share-mem.json" \
  "$A_MEMORY" "$A_MEM_CANARY"
leak_record "t2-share-memory" --set "topology=T2-share" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_MEM_CANARY" --set "target=$A_MEMORY" \
  --reader "$LEAK_RUN/t2-share-mem.json"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-share-tx.json" \
  "$A_TRANSCRIPT" "$CANARY"
leak_record "t2-share-transcript" --set "topology=T2-share" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" \
  --reader "$LEAK_RUN/t2-share-tx.json"
rm -f "$LEAK_B/.agent-sandbox"

leak_real_config_after
leak_validate || VALID=0

# ---- report -----------------------------------------------------------------
echo
echo "=== row 2: transcripts — reachability of A's transcript from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1]))
print("  %-12s net=%-6s %s" % (os.path.basename(sys.argv[1])[:-5], d.get("net", "?"), d.get("verdict", "?")))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
