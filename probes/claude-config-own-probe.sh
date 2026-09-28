#!/usr/bin/env bash
# claude-config-own-probe.sh -- does Claude Code run with a config file that carries
# nothing of yours? Evidence for the `config` channel under `isolated` (#119, #129 step 6):
# `own` means an empty config file beside the real credentials. If a turn works, the
# account block in ~/.claude.json is app state and `own` is fine; if it does not, that
# block belongs to the identity channel and has to be seeded even at `own`.
#
# Three throwaway config directories, each with your real credentials file copied in and
# a different config file: {} (own), the account block only, and no file at all. One
# short Haiku turn in each, then what Claude Code wrote into the config afterwards.
# Nothing in your real ~/.claude is touched; the copies are removed at the end.
#
#   bash probes/claude-config-own-probe.sh
set -uo pipefail
native="$(printf '%s\n' "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[[ -x "$native" ]] || {
  echo "no native Claude Code under ~/.local/share/claude/versions" >&2
  exit 2
}
[[ -r "$HOME/.claude/.credentials.json" ]] || {
  echo "no ~/.claude/.credentials.json to copy" >&2
  exit 2
}
echo "native: $native ($("$native" --version 2>/dev/null))"
account="$(python3 -c 'import json;d=json.load(open("'"$HOME"'/.claude.json"));print(json.dumps({k:v for k,v in d.items() if k=="oauthAccount"}))' 2>/dev/null || echo '{}')"
echo "your ~/.claude.json has an oauthAccount block: $([[ "$account" != '{}' ]] && echo yes || echo no)"
P="$(mktemp -d /tmp/ccown-proj-XXXXXX)"
cd "$P" || exit 2

run_case() { # run_case LABEL CONFIG-JSON|absent
  local label="$1" cfg="$2" d out rc
  d="$(mktemp -d /tmp/ccown-cfg-XXXXXX)"
  chmod 700 "$d"
  cp -- "$HOME/.claude/.credentials.json" "$d/.credentials.json"
  [[ "$cfg" == absent ]] || printf '%s' "$cfg" >"$d/.claude.json"
  echo
  echo "=== $label"
  out="$(CLAUDE_CONFIG_DIR="$d" timeout 120 "$native" --model haiku -p 'Reply with exactly: OK' 2>&1)"
  rc=$?
  echo "exit=$rc reply: $(printf '%s' "$out" | head -c 200 | tr '\n' ' ')"
  if [[ -e "$d/.claude.json" ]]; then
    echo "config afterwards: $(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print("unparsable", e); sys.exit()
print("keys:", ", ".join(sorted(d)))
print("  oauthAccount present:", "oauthAccount" in d, "| hasCompletedOnboarding:", d.get("hasCompletedOnboarding"), "| projects:", list((d.get("projects") or {}).keys()))' "$d/.claude.json")"
  else
    echo "config afterwards: still absent"
  fi
  rm -rf -- "$d"
}
run_case "own: {} beside the real credentials" '{}'
run_case "account block only" "$account"
run_case "no config file at all" absent
echo
echo "=== cleanup"
rm -rf -- "$P"
echo "removed $P (your ~/.claude and ~/.claude.json were not touched)"
