#!/usr/bin/env bash
# Row 16 — SESSION ARTIFACTS UNDER projects/. Subagent transcripts, spilled tool
# results, and set-aside transcripts.
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# `/en/claude-directory` names three kinds of per-session artifact the study's catalog
# did not have, all of them under projects/<project>/:
#
#   <session>/subagents/      subagent conversation transcripts
#   <session>/tool-results/   large tool outputs spilled to separate files
#   <session>.orphaned-*.jsonl, <session>.jsonl.superseded-*
#                             a previous transcript Claude Code set aside rather than
#                             overwriting -- it does not appear in the session picker,
#                             so it is easy to forget it is there
#
# EXPECTED ISOLATED, unlike rows 15/17/18: these sit INSIDE the directory row 2 measured
# as unreachable, and the engine rebinds projects/<slug> whole. So this row asks whether
# the scoping covers a project's whole subtree or only the files at its top -- a
# question the study would otherwise be assuming the answer to. The control is therefore
# rows 1-2's: B reads its OWN artifact of the same kind, which must still work inside.
#
# Spilled tool results matter most of the three. A large tool output is FILE CONTENT --
# whatever the tool read -- stored outside the transcript, so it carries exactly the
# material a transcript would.
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=16-session-artifacts
VALID=1
leak_setup "$LEAK_ROW"

# ---- the substrate, rebuilt for every cell -------------------------------
# ONE CELL = ONE TREE (see row 1's header). plant() rebuilds the canaries from nothing for every cell.
plant() {
  # LOCAL, because plant() runs INSIDE the caller's loop: without this its own
  # iteration variable overwrites the caller's, and every cell of the loop
  # measured -- and recorded -- the last entry in this table.
  local k
  A_SLUG="$(leak_slug "$LEAK_A")"
  B_SLUG="$(leak_slug "$LEAK_B")"
  SID=00000000-0000-0000-0000-00000000000a
  STAMP="$(date +%s)"

  # One canary per artefact kind, all belonging to A.
  # -g: a bare `declare` inside a function is LOCAL, and the table has to outlive plant()
  declare -gA A_PATH A_TOK
  A_PATH["subagents"]="$LEAK_CONFIG/projects/$A_SLUG/$SID/subagents/sub-1.jsonl"
  A_PATH["tool-results"]="$LEAK_CONFIG/projects/$A_SLUG/$SID/tool-results/out-1.txt"
  A_PATH["orphaned"]="$LEAK_CONFIG/projects/$A_SLUG/$SID.orphaned-$STAMP-x.jsonl"
  A_PATH["superseded"]="$LEAK_CONFIG/projects/$A_SLUG/$SID.jsonl.superseded-$STAMP"
  for k in "${!A_PATH[@]}"; do
    A_TOK["$k"]="$(leak_token "A${k^^}")"
    mkdir -p "$(dirname "${A_PATH["$k"]}")"
    printf '%s\n' "${A_TOK["$k"]}" >"${A_PATH["$k"]}"
  done

  # B's own artefact of the same kind: the control. Without it, "A's subagent transcript
  # is unreachable" cannot be told apart from "this subtree is not mounted at all".
  B_TOK="$(leak_token BOWN)"
  B_PATH="$LEAK_CONFIG/projects/$B_SLUG/$SID/tool-results/out-1.txt"
  mkdir -p "$(dirname "$B_PATH")"
  printf '%s\n' "$B_TOK" >"$B_PATH"
  leak_say "planted 4 of A's session artefacts and 1 of B's"

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
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY
}

leak_real_config_before

leak_say "T1 (native, positive control: A's spilled tool output)"
leak_cell t1-native
plant
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" \
  "${A_PATH["tool-results"]}" "${A_TOK["tool-results"]}"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "kind=tool-results" --set "canary=${A_TOK["tool-results"]}" \
  --set "target=${A_PATH["tool-results"]}" --reader "$LEAK_RUN/t1.json"

# Four kinds, four EXPERIMENTS: each gets its own tree, so a subtree that is absent is
# absent because of the scoping and not because the previous kind's read moved anything.
for k in subagents tool-results orphaned superseded; do
  leak_say "T2 (sandboxed, net=none) — A's $k"
  leak_cell "t2-$k"
  plant
  leak_watch_start "$LEAK_CONFIG"
  leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-$k.json" \
    "${A_PATH["$k"]}" "${A_TOK["$k"]}"
  leak_watch_stop
  cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2-$k.reads" 2>/dev/null || true
  leak_record "t2-$k" --set "topology=T2" --set "net=none" --set "sandboxed=yes" \
    --set "kind=$k" --set "canary=${A_TOK["$k"]}" --set "target=${A_PATH["$k"]}" \
    --reader "$LEAK_RUN/t2-$k.json" --set-file "reads=$LEAK_RUN/records/t2-$k.reads"
done

leak_say "T2 negative control — B's OWN spilled tool output"
leak_cell t2-own
plant
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$B_PATH" "$B_TOK"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "kind=tool-results" --set "canary=$B_TOK" --set "target=$B_PATH" \
  --reader "$LEAK_RUN/t2-own.json"

leak_cell_finish
leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 16: session artefacts under projects/ ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
print("  %-18s %-10s %-10s %s" % (os.path.basename(sys.argv[1])[:-5], d.get("kind", "?"),
                                  d.get("topology", "?"), d.get("verdict", "?")))
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
