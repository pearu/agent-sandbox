#!/usr/bin/env bash
# How does the VS Code extension start Claude Code?
#
# This decides whether agent-sandbox applies to IDE use at all: an extension
# that resolves `claude` from PATH reaches our launcher and is sandboxed; one
# that calls a bundled or absolute path to the agent's own binary is not, and
# nothing tells the user. README's Scope section says this is unverified, and
# this script is how that gets settled.
#
# Read-only and display-free: it inspects the installed extension, never runs
# VS Code. Pass --install to install the extension first (also display-free).
#
# Run on the HOST, not inside the sandbox:
#     ./probes/vscode-probe.sh [--install]
set -uo pipefail

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

install=0
[[ "${1:-}" == --install ]] && install=1

say "VS Code present?"
if command -v code >/dev/null 2>&1; then
  note "code: $(command -v code)"
  note "version: $(code --version 2>/dev/null | head -1)"
else
  note "no \`code\` on PATH."
  note "Install VS Code first (snap: sudo snap install code --classic), then re-run."
  exit 1
fi

if ((install)); then
  say "Installing the extension (no display needed)"
  code --install-extension anthropic.claude-code --force 2>&1 | sed 's/^/   /'
fi

say "Extension installed?"
shopt -s nullglob
dirs=("$HOME/.vscode/extensions"/*claude* "$HOME/.vscode-server/extensions"/*claude*)
if ((${#dirs[@]} == 0)); then
  note "not installed. Re-run with --install, or:"
  note "    code --install-extension anthropic.claude-code"
  exit 1
fi
for d in "${dirs[@]}"; do note "$d"; done
ext="${dirs[-1]}"

say "Does it declare a path setting? (a way to point it at our launcher)"
if [[ -r "$ext/package.json" ]]; then
  python3 - "$ext/package.json" <<'PY' 2>/dev/null || note "(could not parse package.json)"
import json, sys
p = json.load(open(sys.argv[1]))
cfg = (p.get("contributes") or {}).get("configuration") or {}
props = {}
for block in (cfg if isinstance(cfg, list) else [cfg]):
    props.update(block.get("properties") or {})
hits = {k: v for k, v in props.items()
        if any(w in k.lower() for w in ("path", "exec", "command", "binary", "cli"))}
print("   settings that look like a path/command:" if hits else "   no path-like settings")
for k, v in hits.items():
    print(f"     {k}: default={v.get('default')!r} -- {str(v.get('description',''))[:90]}")
print(f"   (total settings: {len(props)})")
PY
else
  note "no package.json at $ext"
fi

say "Does it ship its own agent binary?"
found=$(find "$ext" -maxdepth 3 -type f \( -name 'claude' -o -name 'claude-code' -o -name '*.node' \) 2>/dev/null | head -5)
[[ -n "$found" ]] && printf '   %s\n' $found || note "nothing binary-looking in the top levels"

say "How does its code start the CLI?"
# The bundle is minified, so context lines matter more than the match itself.
mapfile -t js < <(find "$ext" -name '*.js' -size +1k 2>/dev/null | head -20)
note "scanning ${#js[@]} bundle file(s)"
for pat in 'spawn' 'execFile' 'which' 'PATH' '"claude"' "'claude'" 'executablePath' 'cliPath'; do
  n=$(grep -oF "$pat" "${js[@]}" 2>/dev/null | wc -l)
  printf '   %-16s %s hit(s)\n' "$pat" "$n"
done

say "The lines that name the command (trimmed)"
grep -ohE '.{0,70}(spawn|execFile)[^;]{0,90}' "${js[@]}" 2>/dev/null \
  | grep -iE 'claude|cli|bin' | sort -u | head -8 | cut -c1-160 | sed 's/^/   /'

say "Any absolute path to the agent's own install?"
grep -ohE '[^"'"'"']*\.local/share/claude[^"'"'"']*' "${js[@]}" 2>/dev/null | sort -u | head -5 | sed 's/^/   /' \
  || note "none found"

say "What would win today"
note "type -a claude:"
type -a claude 2>&1 | sed 's/^/     /'

say "Done"
note "Paste the output back. What matters: whether it resolves \`claude\` through"
note "PATH (sandboxed, because the launcher is ours) or by an absolute path to"
note "the agent's own binary (NOT sandboxed), and whether a setting lets you"
note "point it at the launcher explicitly."
