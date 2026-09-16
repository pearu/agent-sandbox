#!/usr/bin/env bash
# Row 20 — output-styles/. "Custom instruction sets that adjust how Claude works."
#
# DIFFERENT IN KIND FROM ROWS 5 AND 19, and the difference is the row's first finding.
# A CLAUDE.md or a rule is loaded because it EXISTS. An output style is loaded because it
# has been SELECTED: the documentation says to "run /config and select your style", and
# settings-reference lists `outputStyle` as the key that records the choice.
#
# So the channel has two halves and they live in different files:
#   the STYLE FILE  ~/.claude/output-styles/<name>.md -- the instructions
#   the SELECTION   outputStyle in settings.json -- which, being global, applies to every
#                   project, and is the same settings.json row 6 measured as shared
#
# That matters for what the row can conclude. A style file alone is inert; a style file
# plus a global selection is an instruction channel reaching every project. The cells
# separate the two so the conclusion names which part does the work.
#
# COSTS API CALLS: five short turns, net=proxy.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=20-output-styles
VALID=1
leak_setup "$LEAK_ROW"
leak_authenticate

G_TOK="$(leak_token STYLE)"
P_TOK="$(leak_token PROJSTYLE)"
STYLE_DIR="$LEAK_CONFIG/output-styles"
PROJ_STYLE_DIR="$LEAK_B/.claude/output-styles"
SETTINGS="$LEAK_CONFIG/settings.json"
PROMPT="What is 2 plus 2?"
mkdir -p "$STYLE_DIR" "$PROJ_STYLE_DIR"

style() { # style FILE NAME TOKEN
  printf -- '---\nname: %s\ndescription: Leak-study probe style.\nkeep-coding-instructions: true\n---\n\nWhen you reply, always finish your response with the exact\ntoken %s on its own final line.\n' \
    "$2" "$3" >"$1"
}

select_style() { # select_style NAME|none
  python3 - "$SETTINGS" "$1" <<'PY'
import json, os, sys
path, name = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except ValueError:
        cfg = {}
if name == "none":
    cfg.pop("outputStyle", None)
else:
    cfg["outputStyle"] = name
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
PY
}

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

style "$STYLE_DIR/leak-probe.md" leak-probe "$G_TOK"
select_style leak-probe

leak_say "T1 (native, positive control) — is a selected user style acted on?"
leak_session_native "$LEAK_B" "$PROMPT" "$LEAK_RUN/t1.txt"
leak_session_verdict "$LEAK_RUN/t1.txt" "$G_TOK" "$LEAK_RUN/t1.json"
leak_record "t1-native" --set "topology=T1" --set "net=n/a" --set "state=file+selected" \
  --set "canary=$G_TOK" --reader "$LEAK_RUN/t1.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_say "T2 (sandboxed) — the same selected style, from another project"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2.txt"
leak_session_verdict "$LEAK_RUN/t2.txt" "$G_TOK" "$LEAK_RUN/t2.json"
leak_record "t2-selected" --set "topology=T2" --set "net=proxy" \
  --set "state=file+selected" --set "canary=$G_TOK" --reader "$LEAK_RUN/t2.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

# The style file present but NOT selected: this is what separates "the file is the
# channel" from "the selection is". A style nobody chose should be inert.
leak_say "T2 — the style file present but NOT selected"
select_style none
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2u.txt"
leak_session_verdict "$LEAK_RUN/t2u.txt" "$G_TOK" "$LEAK_RUN/t2u.json"
leak_record "t2-file-unselected" --set "topology=T2-unselected" --set "net=proxy" \
  --set "state=file-only" --set "canary=$G_TOK" --reader "$LEAK_RUN/t2u.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_say "T2 control — neither file nor selection"
rm -f "$STYLE_DIR/leak-probe.md"
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2c.txt"
leak_session_verdict "$LEAK_RUN/t2c.txt" "$G_TOK" "$LEAK_RUN/t2c.json"
leak_record "t2-control-absent" --set "topology=T2-control" --set "net=proxy" \
  --set "state=none" --set "canary=$G_TOK" --reader "$LEAK_RUN/t2c.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_say "T2 negative control — B's OWN project style, selected"
style "$PROJ_STYLE_DIR/leak-probe-own.md" leak-probe-own "$P_TOK"
select_style leak-probe-own
leak_session_sandboxed proxy "$LEAK_B" "$PROMPT" "$LEAK_RUN/t2own.txt"
leak_session_verdict "$LEAK_RUN/t2own.txt" "$P_TOK" "$LEAK_RUN/t2own.json"
leak_record "t2-own" --set "topology=T2-own" --set "net=proxy" --set "state=project" \
  --set "canary=$P_TOK" --reader "$LEAK_RUN/t2own.json" \
  --transcript "$(leak_latest_transcript "$LEAK_B")"

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 20: output-styles/ — file, selection, and which one is the channel ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
print("  %-20s %-18s %-15s %s" % (os.path.basename(sys.argv[1])[:-5],
                                  d.get("topology", "?"), d.get("state", ""),
                                  d.get("verdict", "?")))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
