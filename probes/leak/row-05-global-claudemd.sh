#!/usr/bin/env bash
# Row 5 — GLOBAL CLAUDE.md. Does a session in project B ingest ~/.claude/CLAUDE.md?
#
# LEVEL 2, and the first row in the study that needs a REAL SESSION. Reachability is not
# the question here and would answer nothing new: ~/.claude is bound whole, so of course
# the file is readable. The question is whether the MODEL takes it into context, which is
# not a property of the filesystem and cannot be measured with a scripted reader.
#
# So the canary is an INSTRUCTION, not a datum. CLAUDE.md asks for a token at the end of
# every reply; the prompt then asks something unrelated and never mentions the file or
# the token. A reply carrying the token means the file was auto-loaded and acted on --
# the session never went looking, which is what makes this level 2 rather than level 3.
#
# MODEL-DEPENDENT, unlike every row so far. A model that declines to follow the
# instruction produces a negative that is about the model, not the channel, so each cell
# records WHICH MODEL ACTUALLY SERVED, read per-message from the transcript rather than
# from what was requested. The T1 cell is the guard: if the instruction is not followed
# even natively, the gate fails the run rather than letting it read as isolation.
#
# COSTS API CALLS: four turns, each a one-line prompt. net=proxy, the default
# deployment, because the API must be reachable.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=05-global-claudemd
VALID=1
leak_setup "$LEAK_ROW"
leak_authenticate

STAMP="$(date +%s)"
G_CANARY="LEAK-GLOBAL-ROW05-$STAMP-$RANDOM"
P_CANARY="LEAK-PROJECT-ROW05-$STAMP-$RANDOM"
GLOBAL_MD="$LEAK_CONFIG/CLAUDE.md"
PROJECT_MD="$LEAK_B/CLAUDE.md"
PROMPT="What is 2 plus 2?"

instruction() { # instruction TOKEN
  printf '# Instructions\n\nWhen you reply, always finish your response with the exact\ntoken %s on its own final line.\n' "$1"
}

# Only ONE CLAUDE.md is in place per cell. With both present the model would carry two
# competing instructions, and a cell where it followed only one would read as a failure
# of the other.
instruction "$G_CANARY" >"$GLOBAL_MD"
leak_say "planted global=$G_CANARY project=$P_CANARY (planted later)"

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

leak_say "T1 (native, positive control) — does a session follow the global instruction?"
leak_session_native "$LEAK_B" "$PROMPT" "$LEAK_RUN/t1.txt"
leak_session_verdict "$LEAK_RUN/t1.txt" "$G_CANARY" "$LEAK_RUN/t1.json"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "canary=$G_CANARY" --set "target=$GLOBAL_MD" --reader "$LEAK_RUN/t1.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_say "T2 (sandboxed, net=proxy) — the same global instruction"
leak_watch_start "$LEAK_CONFIG"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2.txt"
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true
leak_session_verdict "$LEAK_RUN/t2.txt" "$G_CANARY" "$LEAK_RUN/t2.json"
leak_record "t2-sandboxed" --set "topology=T2" --set "net=proxy" --set "sandboxed=yes" \
  --set "canary=$G_CANARY" --set "target=$GLOBAL_MD" --reader "$LEAK_RUN/t2.json" \
  --set-file "reads=$LEAK_RUN/records/t2.reads" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

# Without this, a positive above could be the harness leaking the token into the prompt
# rather than the model reading it out of the file.
leak_say "T2 control — the same prompt with NO global CLAUDE.md"
rm -f "$GLOBAL_MD"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2-control.txt"
leak_session_verdict "$LEAK_RUN/t2-control.txt" "$G_CANARY" "$LEAK_RUN/t2-control.json"
leak_record "t2-control-absent" --set "topology=T2-control" --set "net=proxy" \
  --set "sandboxed=yes" --set "canary=$G_CANARY" --set "target=(removed)" \
  --reader "$LEAK_RUN/t2-control.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

# B's OWN project CLAUDE.md, which the sandbox binds along with the cwd. It must still
# be followed inside: without it, "the global one was not ingested" could not be told
# apart from "no CLAUDE.md is ever ingested in this setup".
leak_say "T2 negative control — B's OWN project CLAUDE.md"
instruction "$P_CANARY" >"$PROJECT_MD"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2-own.txt"
leak_session_verdict "$LEAK_RUN/t2-own.txt" "$P_CANARY" "$LEAK_RUN/t2-own.json"
leak_record "t2-own" --set "topology=T2-own" --set "net=proxy" --set "sandboxed=yes" \
  --set "canary=$P_CANARY" --set "target=$PROJECT_MD" --reader "$LEAK_RUN/t2-own.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 5: global CLAUDE.md — is it ingested by a session in another project? ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
m = d.get("serving_models", {})
m = ",".join((m.get("models") or {}).keys()) if isinstance(m, dict) else ""
print("  %-20s %-14s %-26s %s" % (os.path.basename(sys.argv[1])[:-5],
                                  d.get("topology", "?"), d.get("verdict", "?"), m))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
