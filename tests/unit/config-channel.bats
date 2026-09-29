#!/usr/bin/env bats
# The `config` channel (#119): Claude Code's config file follows a mode as ONE file, like
# any channel. Its source is the native ~/.claude.json, its path inside is
# ~/.claude/.claude.json (CLAUDE_CONFIG_DIR points Claude Code there). The seeding modes
# seed a FILTERED view -- every top-level key and only this project's entry -- and the
# engine never reads or writes `mcpServers` after that: what is inside is Claude Code's.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  SBOX="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
  INSIDE="$H/home/.claude/.claude.json"
  NATIVE_CFG="$H/home/.claude.json"
  OLD_COPY="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/claude.json"
  printf '{"a":1,"mcpServers":{"host":{}},"projects":{"%s":{"t":true},"/elsewhere":{"lastSessionFirstPrompt":"SECRET"}}}' "$PROJ" >"$NATIVE_CFG"
  cp "$NATIVE_CFG" "$H/native-before.json"
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
store() { printf '%s/config/%s/%s' "$SBOX" "$1" "$(slugify "$INSIDE")"; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

@test "config is a channel the profile declares, and a spec for it parses" {
  run_engine -- claude --connect 'config=seed-only native' --version
  [ "$status" -eq 0 ]
  run_engine -- claude --connect 'nosuch=own native' --version
  [[ "$output" == *"It carries:"*"config"* ]]
}

@test "under inherit, config is seed-only: this project's filtered seed, bound inside, CLAUDE_CONFIG_DIR set, the native file untouched" {
  TEST_PRESET=inherit run_engine -- claude --version
  [ "$status" -eq 0 ]
  local s
  s="$(store seed-only)"
  argv_has --bind "$s" "$INSIDE"
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/.claude" ]
  [ "$(json_get "$s" 'd["a"]')" = 1 ]
  [ "$(json_get "$s" 'sorted(d["mcpServers"])')" = "['host']" ]
  [ "$(json_get "$s" 'len(d["projects"])')" = 1 ]
  [ "$(json_get "$s" 'list(d["projects"].values())[0]["t"]')" = True ]
  run ! grep -q SECRET "$s"
  [ "$(stat -c %a "$s")" = 600 ]
  cmp "$NATIVE_CFG" "$H/native-before.json"
  run ! argv_has --bind "$NATIVE_CFG" "$INSIDE"
}

@test "seed-only config is never touched again: a server added inside stays, a native change never arrives (#119)" {
  run_engine -- claude --connect 'config=seed-only native' --version
  local s
  s="$(store seed-only)"
  python3 - "$s" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["mcpServers"] = {"inside": {}}
json.dump(d, open(sys.argv[1], "w"))
PY
  cp "$s" "$H/store-before.json"
  printf '{"a":2,"mcpServers":{"native2":{}},"projects":{"/third":{}}}' >"$NATIVE_CFG"
  run_engine -- claude --quiet --connect 'config=seed-only native' --version
  [ "$status" -eq 0 ]
  cmp "$s" "$H/store-before.json" # byte-identical: the engine did not rewrite it
  [[ "$output" != *"mcpServers"* ]]
}

@test "copy config is seeded from the same filtered view, and other projects never arrive" {
  run_engine -- claude --connect 'config=copy native' --version
  [ "$status" -eq 0 ]
  local s
  s="$(store copy)"
  argv_has --bind "$s" "$INSIDE"
  [ "$(json_get "$s" 'len(d["projects"])')" = 1 ]
  run ! grep -q SECRET "$s"
  # the store is untouched, the source moves: the next launch takes the new view
  printf '{"a":3,"projects":{"%s":{"t":false},"/elsewhere":{"lastSessionFirstPrompt":"SECRET2"}}}' "$PROJ" >"$NATIVE_CFG"
  run_engine -- claude --connect 'config=copy native' --version
  [ "$(json_get "$s" 'd["a"]')" = 3 ]
  run ! grep -q SECRET2 "$s"
}

@test "own config is the role's own, starting from {} with nothing of yours" {
  run_engine -- claude --connect 'config=own native' --version
  [ "$status" -eq 0 ]
  local s
  s="$(store own)"
  argv_has --bind "$s" "$INSIDE"
  [ "$(cat "$s")" = '{}' ]
  TEST_PRESET=isolated run_engine -- claude --version
  argv_has --bind "$s" "$INSIDE"
}

@test "read-only and read-write bind the native file itself, whole, only when asked for" {
  run_engine -- claude --connect 'config=read-only native' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$NATIVE_CFG" "$INSIDE"
  run_engine -- claude --connect 'config=read-write native' --version
  argv_has --bind "$NATIVE_CFG" "$INSIDE"
}

@test "under shared, config is seed-only: shared is the engine before 0.3, and 0.2.1 already had the per-project copy (#90 stays closed)" {
  TEST_PRESET=shared run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$(store seed-only)" "$INSIDE"
  run ! argv_has --bind "$NATIVE_CFG" "$INSIDE"
  run ! grep -q SECRET "$(store seed-only)"
}

@test "under native the config file is neither copied nor relocated" {
  run_engine -- claude --preset native --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$INSIDE" "$H/argv"
  run ! grep -q CLAUDE_CONFIG_DIR "$H/argv"
  [ ! -e "$SBOX/config" ]
}

@test "the per-project copy of 0.3 becomes the default role's seed-only store, moved once" {
  mkdir -p "$(dirname "$OLD_COPY")"
  printf '{"kept":"from 0.3"}' >"$OLD_COPY"
  TEST_PRESET=inherit run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$(store seed-only)")" = '{"kept":"from 0.3"}' ]
  [ ! -e "$OLD_COPY" ]
  argv_has --bind "$(store seed-only)" "$INSIDE"
}

@test "--reset-connection config discards the store, and the next launch seeds a fresh filtered view" {
  run_engine -- claude --connect 'config=seed-only native' --version
  local s
  s="$(store seed-only)"
  printf '{"a":9,"projects":{}}' >"$NATIVE_CFG"
  run_engine -- claude --reset-connection config
  [ "$status" -eq 0 ]
  [ ! -e "$s" ]
  run_engine -- claude --connect 'config=seed-only native' --version
  [ "$(json_get "$s" 'd["a"]')" = 9 ]
}

@test "without python3 nothing is seeded: the launch is refused first, since every app is joined by python3" {
  mkdir -p "$H/nopy"
  local t
  for t in /usr/bin/*; do
    [[ "$(basename "$t")" == python3* ]] || ln -s "$t" "$H/nopy/$(basename "$t")" 2>/dev/null || true
  done
  run_engine PATH="$H/bin:$H/nopy" -- claude --connect 'config=seed-only native' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs python3"* ]]
  [ ! -e "$(store seed-only)" ]
  [ ! -s "$H/argv" ]
}

@test "a python3 that fails the filter degrades to the whole native file, said out loud" {
  # It fails the filter (a script on stdin) only: the join into the keeper is python3 too.
  # shellcheck disable=SC2016 # the stub's own $1 and $@
  printf '#!/usr/bin/env bash\n[ "$1" = - ] && exit 3\nexec /usr/bin/python3 "$@"\n' >"$H/bin/python3"
  chmod +x "$H/bin/python3"
  run_engine -- claude --connect 'config=seed-only native' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 failed (exit 3): this project's config file is seeded from the whole"* ]]
  cmp "$(store seed-only)" "$H/native-before.json"
  argv_has --bind "$(store seed-only)" "$INSIDE"
}

@test "user-mcp is refused in every form, naming config = own (#132)" {
  run_engine AGENT_SANDBOX_CLAUDE_USER_MCP=none -- claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"user-mcp"*"removed"*"config = own"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- claude --user-mcp none --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"config = own"* ]]
}

@test "the empty mount-point file bwrap leaves for the config file is removed after the launch" {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then printf '    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST\n'; exit 0; fi
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
[ -e "$HOME/.claude/.claude.json" ] || : >"$HOME/.claude/.claude.json"
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- claude --connect 'config=seed-only native' --version
  [ "$status" -eq 0 ]
  [ ! -e "$INSIDE" ]
}

@test "under read-only, claude mcp add --scope user typed at the shell runs natively" {
  run_engine -- claude --connect 'config=read-only native' mcp add --scope user foo -- true
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-agent argv: mcp add --scope user foo -- true"* ]]
  [ ! -s "$H/argv" ] # no sandbox was built
  # local scope is the project's own entry: it stays inside
  run_engine -- claude --connect 'config=read-only native' mcp add --scope local foo -- true
  [ -s "$H/argv" ]
}
