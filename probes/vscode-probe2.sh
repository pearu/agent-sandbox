#!/usr/bin/env bash
# Which binary does the VS Code extension actually run: the one it ships, or
# `claude` from PATH (i.e. the agent-sandbox launcher)?
#
# vscode-probe.sh established that the extension bundles
# resources/native-binary/claude and exposes no setting to redirect it. What is
# still open is the PREFERENCE: some extensions use an installed CLI when there
# is one and fall back to the bundle. That difference decides whether IDE use is
# sandboxed, so this pulls out the resolution logic instead of guessing.
#
# Read-only, no display, does not launch VS Code. Run on the HOST:
#     ./probes/vscode-probe2.sh
set -uo pipefail

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

shopt -s nullglob
dirs=("$HOME/.vscode/extensions"/*claude* "$HOME/.vscode-server/extensions"/*claude*)
((${#dirs[@]})) || {
  note "extension not installed; run ./probes/vscode-probe.sh --install first"
  exit 1
}
ext="${dirs[-1]}"
note "extension: $ext"
mapfile -t js < <(find "$ext" -name '*.js' -size +1k 2>/dev/null)
note "bundle files: ${#js[@]}"
# The bundles are minified: single lines can be megabytes long, which makes
# `.{0,120}...` style regexes backtrack for ever. Split on statement
# boundaries once, then search the split copy.
split="$(mktemp)"
trap 'rm -f "$split"' EXIT
tr ';{}' '\n\n\n' <"${js[0]}" >"$split"
for f in "${js[@]:1}"; do tr ';{}' '\n\n\n' <"$f" >>"$split"; done
note "split into $(wc -l <"$split") statement-ish lines"

say "The bundled binary"
bundled="$ext/resources/native-binary/claude"
if [[ -x "$bundled" ]]; then
  note "$bundled"
  note "version: $("$bundled" --version 2>&1 | head -1)"
  note "size: $(du -h "$bundled" | cut -f1)"
else
  note "not found at the expected path"
fi

say "Every mention of the bundled path, with context"
grep -F native-binary "$split" | sort -u | head -12 | cut -c1-300 | sed 's/^/   /'

say "How a command is chosen: candidates and fallbacks"
for pat in 'native-binary' 'existsSync' 'fallback' 'bundled' 'PATH.split' 'delimiter'; do
  n=$(grep -cF "$pat" "$split")
  printf '   %-16s %s hit(s)\n' "$pat" "$n"
done

say "Lines where a claude path or command is assigned"
grep -E 'claudePath|cliPath|commandPath|binaryPath|claudeExecutable|resolveClaude|findClaude|locateClaude|resolveShellPath' \
  "$split" | sort -u | head -14 | cut -c1-240 | sed 's/^/   /'

say "Does it consult PATH for a claude at all?"
grep -E 'which|lookpath|resolveShellPath|PATH' "$split" \
  | grep -iE 'claude|cmd|bin|exec|path' | sort -u | head -14 | cut -c1-240 | sed 's/^/   /'

say "The resolver itself: is the bundle a fallback or the only option?"
note "(M1\$ is the function that returns the bundled path; find its body and callers)"
grep -E 'resolveShellPath|asAbsolutePath|existsSync' "$split" | grep -iE 'native|bin|claude|path' \
  | sort -u | head -14 | cut -c1-260 | sed 's/^/   /'

say "Any environment variable that could point it at another binary"
grep -oE 'CLAUDE[A-Z_]*|process\.env\.[A-Za-z_]+' "$split" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'

say "Settings it does expose (all of them, for the record)"
python3 - "$ext/package.json" <<'PY' 2>/dev/null || note "(could not parse)"
import json, sys
p = json.load(open(sys.argv[1]))
cfg = (p.get("contributes") or {}).get("configuration") or {}
props = {}
for block in (cfg if isinstance(cfg, list) else [cfg]):
    props.update(block.get("properties") or {})
for k in sorted(props):
    print(f"     {k}")
PY

say "Done"
note "The question: is the bundled binary used unconditionally, or only when no"
note "\`claude\` is found on PATH? If unconditional, IDE use is NOT sandboxed and"
note "README's Scope section should say so plainly."
