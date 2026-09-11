#!/usr/bin/env bash
# What do the extension's settings actually say?
#
# Three of them could decide whether IDE sessions can be sandboxed by
# ENFORCEMENT rather than by trust:
#
#   claudeCode.useTerminal          -- if this runs the CLI in the integrated
#                                      terminal, it resolves `claude` through
#                                      the shell's PATH, which is our launcher.
#                                      Supported, enforcing, no file surgery.
#   claudeCode.claudeProcessWrapper -- the cooperative hook (the binary chooses
#                                      to honour it).
#   claudeCode.environmentVariables -- could carry AGENT_SANDBOX_* into sessions.
#   claudeCode.usePythonEnvironment -- may affect which interpreter/env is used.
#
# Read-only, no display. Run on the HOST:
#     ./probes/vscode-settings.sh
set -uo pipefail

shopt -s nullglob
dirs=("$HOME/.vscode/extensions"/*claude* "$HOME/.vscode-server/extensions"/*claude*)
((${#dirs[@]})) || {
  echo "   extension not installed"
  exit 1
}
ext="${dirs[-1]}"
printf '   extension: %s\n' "$ext"

python3 - "$ext/package.json" <<'PY'
import json, sys, textwrap

p = json.load(open(sys.argv[1]))
cfg = (p.get("contributes") or {}).get("configuration") or {}
props = {}
for block in (cfg if isinstance(cfg, list) else [cfg]):
    props.update(block.get("properties") or {})

want = [
    "claudeCode.useTerminal",
    "claudeCode.claudeProcessWrapper",
    "claudeCode.environmentVariables",
    "claudeCode.usePythonEnvironment",
    "claudeCode.initialPermissionMode",
    "claudeCode.allowDangerouslySkipPermissions",
]
for k in want:
    v = props.get(k)
    print(f"\n== {k}")
    if v is None:
        print("   (absent)")
        continue
    print(f"   type={v.get('type')}  default={v.get('default')!r}")
    desc = v.get("markdownDescription") or v.get("description") or ""
    for line in textwrap.wrap(" ".join(desc.split()), 92):
        print(f"   {line}")
    if v.get("enum"):
        print(f"   enum: {v['enum']}")

print(f"\n   (settings in total: {len(props)})")
PY

cat <<'EOF'

== What to look for
   If useTerminal makes the extension run the CLI in the integrated terminal,
   then IDE sessions resolve `claude` through PATH -- our launcher -- and are
   sandboxed by enforcement, with no trust in the binary and nothing to patch.
   That would make it the answer for IDE users, and shrink the wrapper question
   to a documentation note.
EOF
