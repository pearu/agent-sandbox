#!/usr/bin/env bash
# Row 18 — THE REST OF THE UNCATALOGUED PATHS under ~/.claude.
#
# Level 1 only (reachability): the scripted reader contains no LLM.
#
# `/en/claude-directory` inventories paths the study's catalog did not have. Row 15
# took agent-memory/ and row 17 took backups/, because each is its own kind of channel.
# What remains is measured here in one row, because they share one mechanism: NONE of
# them appears in profiles/claude.sh, so none has a disposition, and each is simply part
# of the read-write bind of ~/.claude.
#
# Reachability is therefore the easy half and the expected answer is `obtained` for all
# of them. The half worth the row is the SPLIT the plan calls a study output:
#
#   content-bearing -- another session's work is in it, so sharing it lets one
#                      project's model learn from another's
#   auxiliary       -- machine-local bookkeeping from which nothing about another
#                      session's work can be inferred, hence SAFE fully shared
#
# The documented description of each path is recorded beside its verdict so the split
# rests on what the path is stated to hold, not on its name. Several of these do not
# exist on the host that ran this, so nothing has written them yet; the canary is
# planted at the documented path, and the container's treatment of a path does not
# depend on whether the product has populated it.
#
# Expected to leak, so the control is leak_isolation_canary (see lib.sh).
#
# Free: no credentials, no network, no API calls.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=18-uncatalogued
VALID=1
leak_setup "$LEAK_ROW"

SID=00000000-0000-0000-0000-00000000000a
STAMP="$(date +%s)"

# path (relative to the config dir) -> the DOCUMENTED description of its contents
PATHS=(
  "uploads/$SID/attachment.md|files attached from the web or mobile app to a Remote Control session"
  "image-cache/$SID/image.txt|attached images"
  "usage-data/report.json|past /insights reports and the cached analysis data behind them"
  "feedback-bundles/bundle.json|feedback and bug-report archives not yet sent"
  "tasks/task-list.json|task lists that a resumed session would pick up"
  "stats-cache.json|aggregated token and cost counts shown by /usage"
  "remote-settings.json|cached server-managed settings for the organization"
  "cache/changelog.md|cached copy of the Claude Code changelog"
  "policy-limits.json|cached feature policy settings for the organization"
)

declare -A TOK
for entry in "${PATHS[@]}"; do
  rel="${entry%%|*}"
  key="${rel%%/*}"
  key="${key%.json}"
  key="${key%.md}"
  TOK[$rel]="LEAK-${key^^}-ROW18-$STAMP-$RANDOM"
  mkdir -p "$(dirname "$LEAK_CONFIG/$rel")"
  printf '%s\n' "${TOK[$rel]}" >"$LEAK_CONFIG/$rel"
done

# B's own file in one of them: the gate's negative control, and evidence the tree is
# mounted rather than the whole config being absent.
B_TOK="LEAK-BOWN-ROW18-$STAMP-$RANDOM"
B_FILE="$LEAK_CONFIG/tasks/b-task-list.json"
printf '%s\n' "$B_TOK" >"$B_FILE"
leak_isolation_canary
leak_say "planted ${#PATHS[@]} canaries + B's own, iso=$LEAK_ISO_TOKEN"

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

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

FIRST="${PATHS[0]%%|*}"
leak_say "T1 (native, positive control)"
leak_read_native "$LEAK_B" "$READER" "$LEAK_RUN/t1.json" \
  "$LEAK_CONFIG/$FIRST" "${TOK[$FIRST]}"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "sandboxed=no" \
  --set "path=$FIRST" --set "canary=${TOK[$FIRST]}" --reader "$LEAK_RUN/t1.json"

leak_watch_start "$LEAK_CONFIG"
n=0
for entry in "${PATHS[@]}"; do
  rel="${entry%%|*}"
  docs="${entry#*|}"
  n=$((n + 1))
  leak_say "T2 ($n/${#PATHS[@]}) $rel"
  leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-$n.json" \
    "$LEAK_CONFIG/$rel" "${TOK[$rel]}"
  leak_record "t2-$(printf '%02d' "$n")-${rel%%/*}" --set "topology=T2" --set "net=none" \
    --set "sandboxed=yes" --set "path=$rel" --set "docs=$docs" \
    --set "canary=${TOK[$rel]}" --reader "$LEAK_RUN/t2-$n.json"
done
leak_watch_stop
cp "$LEAK_WATCH_OUT" "$LEAK_RUN/records/t2.reads" 2>/dev/null || true

leak_say "T2 — B's own file under tasks/"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-own.json" "$B_FILE" "$B_TOK"
leak_record "t2-own" --set "topology=T2-own" --set "net=none" --set "sandboxed=yes" \
  --set "path=tasks/b-task-list.json" --set "canary=$B_TOK" --reader "$LEAK_RUN/t2-own.json"

leak_say "T2 ISOLATION CHECK — A's transcript, known scoped, from the SAME sandbox"
leak_read_sandboxed none "$LEAK_B" "$READER" "$LEAK_RUN/t2-iso.json" \
  "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
leak_record "t2-isolation-check" --set "topology=T2-isolation-check" --set "net=none" \
  --set "sandboxed=yes" --set "canary=$LEAK_ISO_TOKEN" --set "target=$LEAK_ISO_PATH" \
  --reader "$LEAK_RUN/t2-iso.json"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 18: uncatalogued paths — reachability from B's sandbox ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
print("  %-34s %-22s %s" % (d.get("path", os.path.basename(sys.argv[1])[:-5])[:34],
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
