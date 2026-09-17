#!/usr/bin/env bash
# Row 3 — PLANS. Can a session in project B read project A's plan documents?
#
# Level 1 only (reachability): the scripted reader contains no LLM, so this measures
# the container alone and the result is model-independent.
#
# A DIFFERENT MECHANISM from rows 1-2, which is why the cells differ. `plans/` is not
# scoped like `projects/` -- it is COPYOUT (profiles/claude.sh, profile_isolate): the
# engine binds an EMPTY staging directory over it, and at exit merges back the entries
# the session created (`cp -an`, never overwriting). Two consequences the cells have to
# respect:
#
#   1. B has no plan of its own inside to serve as the negative control, because the
#      directory starts empty for EVERY session. The control therefore WRITES a plan
#      inside and reads it back: without it, "A's plan is unreachable" cannot be told
#      apart from "plans/ is not mounted in there at all".
#   2. Isolation here governs READS, not write-back. A sandboxed session's own new
#      plan is copied out to the host, where a native reader in any project can see
#      it. That is measured as its own cell rather than left as an inference, because
#      it is the half that makes "isolated" only half true.
#
# One network mode: row 2 ran all three and found them identical (the invariance
# control for the filesystem rows).
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=03-plans
VALID=1
leak_setup "$LEAK_ROW"

# ---- the substrate, rebuilt for every cell ----------------------------------
# plans/ is a FLAT, GLOBAL directory -- not keyed by project at all, so natively
# every project's plans sit side by side and the slug question of rows 1-2 does not
# arise here.
#
# ONE CELL = ONE TREE (see row 1's header): every cell gets a new HOME, a new config
# and new repositories, so a copyout directory that is empty inside is empty because
# of the disposition and not because an earlier cell happened to leave it so.
plant() {
  PLANS="$LEAK_CONFIG/plans"
  mkdir -p "$PLANS"
  A_CANARY="$(leak_token APLAN)"
  A_PLAN="$PLANS/20260915-aaaaaaaaaa-plan1.md"
  printf '# Plan\n\n%s\n' "$A_CANARY" >"$A_PLAN"
  B_CANARY="$(leak_token BPLAN)"
  B_PLAN="$PLANS/20260915-bbbbbbbbbb-plan1.md"

  # Identifies the canary by CONTENT. It also lists the target's PARENT directory:
  # for a copyout path the claim under test is "empty at start", which one ENOENT does
  # not show and a listing does.
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
    out["bytes"] = len(data)
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY

  # The negative control: write a plan inside the sandbox and read it back, proving
  # plans/ is present and writable in there. Emits the same contract, so it gets a
  # verdict like any other cell.
  OWN="$LEAK_B/own.py"
  cat >"$OWN" <<'PY'
import errno, json, os, sys
path, token = sys.argv[1], sys.argv[2]
out = {"path": path, "token": token}
try:
    out["dir_entries_before"] = sorted(os.listdir(os.path.dirname(path)))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# Plan\n\n%s\n" % token)
    with open(path, encoding="utf-8") as fh:
        data = fh.read()
    out["open"] = "ok"
    out["token_found"] = token in data
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY
}

# ---- the cells --------------------------------------------------------------
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_cell t1-native
plant
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$A_PLAN" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$A_PLAN" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=none)"
leak_cell t2-copyout
plant
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$A_PLAN" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-copyout" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$A_PLAN" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

# ONE CELL, TWO OBSERVATIONS. The write inside and the host read afterwards are a
# single experiment -- the second measures what the first left behind -- so they share
# a tree by necessity, not by optimisation. Splitting them would delete the thing the
# second one reads.
leak_say "T2 negative control: B writes its own plan inside and reads it back"
leak_cell t2-writeback
plant
leak_read_sandboxed none "$LEAK_B" "$OWN" "$LEAK_RUN/t2-own.json" "$B_PLAN" "$B_CANARY"
leak_record "t2-copyout-own" --set "topology=T2-own" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$B_CANARY" --set "target=$B_PLAN" \
  --reader "$LEAK_RUN/t2-own.json"

# The other direction: the plan B wrote INSIDE the sandbox, read from the host after
# that session exited. copyout merges a session's new entries back, so this is where
# "isolated" stops being the whole story.
leak_say "T2-writeback: did B's sandboxed plan reach the host?"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2-writeback.json" "$B_PLAN" "$B_CANARY"
leak_record "t2-writeback" --set "topology=T2-writeback" --set "net=none" \
  --set "sandboxed=no" --set "canary=$B_CANARY" --set "target=$B_PLAN" \
  --reader "$LEAK_RUN/t2-writeback.json"

# Does the blunt sharing lever reach plans? [share-memory] adds read-only binds under
# projects/<slug>/memory and `all` switches the memory mode -- neither touches the
# copyout of plans/. Measured rather than reasoned, because "there is no way to share
# plans" is advice a user acts on.
leak_say "T2-share-all ([share-memory] all — does any lever reach plans?)"
leak_cell t2-share-all
plant
printf '[share-memory]\nall\n' >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-all.json" "$A_PLAN" "$A_CANARY"
leak_record "t2-share-all" --set "topology=T2-share-all" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_CANARY" --set "target=$A_PLAN" \
  --reader "$LEAK_RUN/t2-all.json"

leak_cell_finish
leak_real_config_after
leak_validate || VALID=0

# ---- report -----------------------------------------------------------------
echo
echo "=== row 3: plans — reachability of A's plan from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
e = d.get("reader", {}).get("dir_entries")
n = "" if e is None else ("  plans/=%s" % (len(e) if isinstance(e, list) else e))
print("  %-16s %-14s %s%s" % (os.path.basename(sys.argv[1])[:-5],
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
