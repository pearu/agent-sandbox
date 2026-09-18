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
# ONE CELL = ONE TREE (see row 1's header). plant() rebuilds the substrate from
# nothing for every cell, so no cell can be answered from another's leftovers.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=02-transcripts
VALID=1
leak_setup "$LEAK_ROW"

# ---- the substrate, rebuilt for every cell ----------------------------------
# A transcript is keyed to the WORKING DIRECTORY (memory is keyed to the repository;
# that difference is row 1's problem, not this one).
#
# B gets a transcript of its own carrying a DIFFERENT token: the negative control.
# Without it, "A's transcript is unreachable" cannot be told apart from "no config is
# visible in there at all", and it would read as isolation either way. A also gets a
# memory note, because the share cells need something that IS shared to contrast with
# the transcript that is not.
plant() {
  CANARY="$(leak_token CANARY)"
  A_SLUG="$(leak_slug "$LEAK_A")"
  A_TRANSCRIPT="$LEAK_CONFIG/projects/$A_SLUG/00000000-0000-0000-0000-00000000000a.jsonl"
  mkdir -p "$(dirname "$A_TRANSCRIPT")"
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$CANARY" >"$A_TRANSCRIPT"

  A_MEM_CANARY="$(leak_token AMEM)"
  A_MEMORY="$LEAK_CONFIG/projects/$A_SLUG/memory/NOTE.md"
  mkdir -p "$(dirname "$A_MEMORY")"
  printf '%s\n' "$A_MEM_CANARY" >"$A_MEMORY"

  B_SLUG="$(leak_slug "$LEAK_B")"
  B_CANARY="$(leak_token OWN)"
  B_TRANSCRIPT="$LEAK_CONFIG/projects/$B_SLUG/00000000-0000-0000-0000-00000000000b.jsonl"
  mkdir -p "$(dirname "$B_TRANSCRIPT")"
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$B_CANARY" >"$B_TRANSCRIPT"

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
}

leak_real_config_before

# ---- the cells --------------------------------------------------------------
leak_say "T1 (native, positive control)"
leak_cell t1-native
plant
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_TRANSCRIPT" "$CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" --reader "$LEAK_RUN/t1.json"

for net in none proxy strict; do
  leak_say "T2 (sandboxed, net=$net)"
  leak_cell "t2-$net"
  plant
  leak_watch_start "$LEAK_CONFIG"
  leak_read_sandboxed "$net" "$LEAK_B" "$READER" "$LEAK_RUN/t2-$net.json" "$A_TRANSCRIPT" "$CANARY"
  leak_watch_stop
  cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2-$net.reads" 2>/dev/null || true
  leak_record "t2-$net" --set "topology=T2" --set "net=$net" --set "sandboxed=yes" \
    --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" \
    --reader "$LEAK_RUN/t2-$net.json" --set-file "reads=$LEAK_RUN/records/t2-$net.reads"

  # negative control, same sandbox, same reader, B's OWN project -- and its own tree
  leak_say "T2 negative control (net=$net)"
  leak_cell "t2-$net-own"
  plant
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
# advice a user acts on. Two cells, two trees: the share is set up from nothing in
# each, so neither read can be explained by the other's setup.
leak_say "T2-share, A's MEMORY ([share-memory] names A, net=none)"
leak_cell t2-share-memory
plant
printf '[share-memory]\n%s\n' "$LEAK_A" >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-share-mem.json" \
  "$A_MEMORY" "$A_MEM_CANARY"
leak_record "t2-share-memory" --set "topology=T2-share" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_MEM_CANARY" --set "target=$A_MEMORY" \
  --reader "$LEAK_RUN/t2-share-mem.json"

leak_say "T2-share, A's TRANSCRIPT (the same entry, net=none)"
leak_cell t2-share-transcript
plant
printf '[share-memory]\n%s\n' "$LEAK_A" >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-share-tx.json" \
  "$A_TRANSCRIPT" "$CANARY"
leak_record "t2-share-transcript" --set "topology=T2-share" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$CANARY" --set "target=$A_TRANSCRIPT" \
  --reader "$LEAK_RUN/t2-share-tx.json"

leak_cell_finish
leak_real_config_after
leak_validate || VALID=0

# ---- report -----------------------------------------------------------------
echo
echo "=== row 2: transcripts — reachability of A's transcript from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1]))
print("  %-22s net=%-6s %s" % (os.path.basename(sys.argv[1])[:-5], d.get("net", "?"), d.get("verdict", "?")))
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
