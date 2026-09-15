#!/usr/bin/env bash
# Row 4 — PROMPT HISTORY. Can a session in project B read project A's prompts?
#
# Level 1 only (reachability): the scripted reader contains no LLM, so this measures
# the container alone and the result is model-independent.
#
# A THIRD MECHANISM, and the first one that is a FILTER rather than an absence.
# history.jsonl is `append` with _claude_history_filter (profiles/claude.sh): at
# launch the engine writes B's OWN lines into a staging file and binds that over the
# host path, and at exit appends back whatever B added. So unlike rows 1-3 the file is
# present and readable inside -- a negative here is `not-obtained-absent`, not
# `not-obtained-unreachable`, and that distinction is the result.
#
# It also means the negative control is free: B's own lines are supposed to be there,
# so the same cell that proves the file is mounted proves the filter kept B's history.
#
# The filter is `grep -F "\"project\":\"$cwd\""` over a line-oriented, UNDOCUMENTED
# record format, so two collision cells probe what it actually discriminates on:
#
#   PREFIX   a sibling project whose path extends B's (`<B>-notes`). The engine's own
#            comment claims the closing quote rules this out. An explicit claim about
#            external behaviour is worth measuring rather than trusting.
#   POSITION a line belonging to A that CONTAINS the literal `"project":"<B>"`
#            somewhere else on it -- here nested inside pastedContents, which the real
#            format carries as an object. grep -F matches a substring anywhere on the
#            line, so this asks whether the filter discriminates by field or by text.
#            Note what already defends the ordinary case: a PASTED string cannot
#            collide, because its quotes are escaped as \" when serialised.
#
# One network mode: row 2 ran all three and found them identical.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=04-history
VALID=1
leak_setup "$LEAK_ROW"

HISTORY="$LEAK_CONFIG/history.jsonl"
A_CANARY="LEAK-APROMPT-ROW04-$(date +%s)-$RANDOM"
B_CANARY="LEAK-BPROMPT-ROW04-$(date +%s)-$RANDOM"
PFX_CANARY="LEAK-PFXPROMPT-ROW04-$(date +%s)-$RANDOM"
NEST_CANARY="LEAK-NESTPROMPT-ROW04-$(date +%s)-$RANDOM"
WB_CANARY="LEAK-WBPROMPT-ROW04-$(date +%s)-$RANDOM"

# Records are COMPACT json, one per line -- separators matter, because the filter
# greps the literal `"project":"<dir>"` with no space after the colon.
python3 - "$HISTORY" "$LEAK_A" "$LEAK_B" \
  "$A_CANARY" "$B_CANARY" "$PFX_CANARY" "$NEST_CANARY" <<'PY'
import json, sys
path, a, b, a_tok, b_tok, pfx_tok, nest_tok = sys.argv[1:8]
def rec(display, project, pasted=None):
    return json.dumps({"display": display, "pastedContents": pasted or {},
                       "timestamp": 1789480000, "project": project,
                       "sessionId": "00000000-0000-0000-0000-000000000000"},
                      separators=(",", ":"))
lines = [
    rec(a_tok, a),                       # A's own prompt: the canary B must not get
    rec(b_tok, b),                       # B's own prompt: the filter must keep it
    rec(pfx_tok, b + "-notes"),          # a sibling whose path EXTENDS B's
    # A's line, but carrying the literal `"project":"<B>"` nested in pastedContents.
    rec(nest_tok, a, {"1": {"project": b, "content": "pasted"}}),
]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
leak_say "planted 4 history lines (A, B, ${LEAK_B##*/}-notes, A-with-nested-B)"

# ---- the readers ------------------------------------------------------------
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
    out["lines"] = data.count("\n")
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY

# Append a record inside the sandbox and read it back. `append` merges a session's new
# lines into the host file at exit, so this is the outward direction -- the same shape
# of question row 3 answered for copyout.
WRITER="$LEAK_B/writer.py"
cat >"$WRITER" <<'PY'
import errno, json, sys
path, token = sys.argv[1], sys.argv[2]
out = {"path": path, "token": token}
try:
    line = json.dumps({"display": token, "pastedContents": {}, "timestamp": 1789480001,
                       "project": sys.argv[3],
                       "sessionId": "00000000-0000-0000-0000-00000000000b"},
                      separators=(",", ":"))
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    with open(path, encoding="utf-8") as fh:
        data = fh.read()
    out["open"] = "ok"
    out["token_found"] = token in data
    out["lines"] = data.count("\n")
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY

# ---- run the cells ----------------------------------------------------------
leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" "$HISTORY" "$A_CANARY"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$A_CANARY" --set "target=$HISTORY" --reader "$LEAK_RUN/t1.json"

leak_say "T2 (sandboxed, net=none) — A's prompt"
leak_watch_start "$LEAK_CONFIG"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2.json" "$HISTORY" "$A_CANARY"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_record "t2-append" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
  --set "canary=$A_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2.json" --set-file "reads=$LEAK_RUN/records/t2.reads"

leak_say "T2 negative control — B's OWN prompt (the filter must keep it)"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$HISTORY" "$B_CANARY"
leak_record "t2-append-own" --set "topology=T2-own" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$B_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 collision A — a sibling project whose path EXTENDS B's"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-prefix.json" "$HISTORY" "$PFX_CANARY"
leak_record "t2-prefix-collision" --set "topology=T2-prefix" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$PFX_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-prefix.json"

leak_say "T2 collision B — A's line carrying the literal project key of B, nested"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-nested.json" "$HISTORY" "$NEST_CANARY"
leak_record "t2-nested-collision" --set "topology=T2-nested" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$NEST_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-nested.json"

leak_say "T2-share-all ([share-memory] all — does any lever reach the history?)"
printf '[share-memory]\nall\n' >"$LEAK_B/.agent-sandbox"
leak_trust "$LEAK_B"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-all.json" "$HISTORY" "$A_CANARY"
leak_record "t2-share-all" --set "topology=T2-share-all" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$A_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-all.json"
rm -f "$LEAK_B/.agent-sandbox"
leak_untrust "$LEAK_B"

leak_say "T2-writeback: B appends a prompt inside..."
leak_read_sandboxed none "$LEAK_B" "$WRITER" "$LEAK_RUN/t2-wb-in.json" \
  "$HISTORY" "$WB_CANARY" "$LEAK_B"
leak_record "t2-writeback-inside" --set "topology=T2-writeback-inside" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$WB_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-wb-in.json"
leak_say "...and does it reach the host history?"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t2-wb-host.json" "$HISTORY" "$WB_CANARY"
leak_record "t2-writeback" --set "topology=T2-writeback" --set "net=none" \
  --set "sandboxed=no" --set "canary=$WB_CANARY" --set "target=$HISTORY" \
  --reader "$LEAK_RUN/t2-wb-host.json"

leak_real_config_after
leak_validate || VALID=0

# ---- report -----------------------------------------------------------------
echo
echo "=== row 4: prompt history — reachability of A's prompts from B ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
n = d.get("reader", {}).get("lines")
print("  %-22s %-22s %-26s %s" % (os.path.basename(sys.argv[1])[:-5],
                                  d.get("topology", "?"), d.get("verdict", "?"),
                                  "" if n is None else "lines=%d" % n))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
