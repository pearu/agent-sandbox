#!/usr/bin/env bats
# Routing (#123): every session runs in its role's sandbox, `--bg` included; the scope
# that once chose between foreground and background is refused in every form; running
# without a sandbox is `--preset none`, typed per launch. The management verbs join the
# role's launch and never start one. A sandboxed launch runs the stub bwrap ($H/argv
# non-empty) and joins the command ($H/join); a native one execs the stub agent
# directly, which echoes its argv.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  SBOX="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}"
  CFG="$H/home/.config/agent-sandbox"
  BIN="$H/home/.local/share/claude/versions/2.1.300/claude"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

sandboxed() { [ -s "$H/argv" ] && [ -s "$H/join" ]; }
native() { [ ! -s "$H/argv" ] && [ ! -s "$H/join" ]; }
trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "a foreground session is sandboxed" {
  run_engine -- asb claude -p hello
  [ "$status" -eq 0 ]
  sandboxed
  join_has "$BIN" -p hello
}

@test "--bg is sandboxed too: joined into the role's launch, with no wrapper anywhere" {
  run_engine -- asb claude --bg 'do a thing'
  [ "$status" -eq 0 ]
  sandboxed
  join_has "$BIN" --bg 'do a thing'
  run ! grep -q CLAUDE_CODE_PROCESS_WRAPPER "$H/argv"
  run ! grep -q CLAUDE_CODE_PROCESS_WRAPPER "$H/join"
  [ ! -e "$H/base/wrap-claude.sh" ]
}

@test "--preset none runs the agent with no sandbox, and says so" {
  run_engine -- asb --preset none claude -p hello
  [ "$status" -eq 0 ]
  native
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
  [[ "$output" == *"preset none"*"no sandbox"* ]]
  run_engine -- asb --preset none claude --bg 'do a thing'
  native
  [[ "$output" == *"stub-agent argv: --bg do a thing"* ]]
}

@test "--preset none with --exec runs the command with no sandbox" {
  run_engine -- asb --preset none --profile claude --exec /bin/echo plain
  [ "$status" -eq 0 ]
  native
  [[ "$output" == *"plain"* ]]
}

@test "none is the flag only: from the environment or a project file it is refused" {
  run_engine AGENT_SANDBOX_PRESET=none -- asb claude -p hello
  [ "$status" -ne 0 ]
  [[ "$output" == *"'none' runs the agent with no sandbox at all"* ]]
  native
  printf '[sandbox]\npreset = none\n' >"$PROJ/.agent-sandbox"
  trust
  TEST_PRESET="" run_engine -- asb claude -p hello
  [ "$status" -ne 0 ]
  [[ "$output" == *"only accepted as the --preset flag"* ]]
  native
}

@test "--preset none is not stopped by an unapproved dot-file: there is no policy to apply" {
  printf '[net]\nmode = none\n' >"$PROJ/.agent-sandbox"
  trust
  printf '[net]\nmode = open\n' >"$PROJ/.agent-sandbox" # changed since approved
  run_engine -- asb --preset none claude -p hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-agent argv: -p hello"* ]]
}

@test "AGENT_SANDBOX=1 on the host is not \"inside a sandbox\": the launch is sandboxed (#197)" {
  # The passthrough runs the agent unsandboxed, so it needs the marker AND pid 1 being
  # bubblewrap (_as_inside_sandbox); the marker alone is a variable any shell can set.
  # The real inside case is in tests/integration/exec.bats.
  run_engine AGENT_SANDBOX=1 -- asb claude -p hello
  sandboxed
}

@test "a management verb with no running role starts none: a question gets the empty answer" {
  local v
  for v in agents logs; do
    run_engine -- asb claude "$v" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"role 'default' is not running"* ]]
    native
  done
}

@test "a management verb that acts on a session is refused when the role is not running" {
  local v
  for v in attach stop rm daemon; do
    run_engine -- asb claude "$v" x
    [ "$status" -ne 0 ]
    [[ "$output" == *"role 'default' is not running"* ]]
    native
  done
}

@test "a management verb joins the running role, with no briefing on its argv" {
  engine_bg -- asb claude --bg 'a task'
  run_engine -- asb claude agents --json
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ] # nothing built
  [ "${JOINV[*]}" = "$BIN agents --json" ]
  release_bg
}

@test "under an unapproved edit, a verb finds the one running role; with none it answers, with two it asks" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- asb --role r claude --version
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox" # not approved
  run_engine -- asb claude agents
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$BIN agents" ]
  release_bg
  run_engine -- asb claude agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"no role of this project is running"* ]]
  run_engine -- asb claude stop x
  [ "$status" -ne 0 ]
}

@test "under an unapproved edit, with two roles running, a verb asks for --role" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- asb --role r claude --version
  local first=$BG_PID
  engine_bg -- asb --role s claude --version
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox"
  run_engine -- asb claude agents
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 are running"*"--role"* ]]
  release_bg
  wait "$first" 2>/dev/null
}

@test "--shutdown ends the role's launch; with none running it says so" {
  run_engine -- asb --shutdown claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"role 'default' is not running"* ]]
  engine_bg -- asb claude --version
  [ -e "$SBOX/default/keeper/id" ]
  run_engine -- asb --shutdown claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended, with everything that ran in it"* ]]
  [ ! -e "$SBOX/default/keeper" ]
  release_bg
}

@test "--shutdown names the role it ends, and ends no other" {
  engine_bg -- asb --role one claude --version
  run_engine -- asb --role two --shutdown claude
  [[ "$output" == *"role 'two' is not running"* ]]
  [ -e "$SBOX/one/keeper/id" ]
  release_bg
}

@test "a --bg records workspace trust in the role's own config file when it is not there, once" {
  TEST_PRESET=isolated run_engine -- asb claude --bg 'a task'
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded workspace trust for $PROJ in role 'default'"* ]]
  local store
  store="$(find "$SBOX/default/config" -name '*claude.json' | head -1)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["projects"][sys.argv[2]]["hasTrustDialogAccepted"]' "$store" "$PROJ"
  TEST_PRESET=isolated run_engine -- asb claude --bg 'another'
  [[ "$output" != *"recorded workspace trust"* ]]
  # a foreground session records nothing: it can ask
  rm -rf "$SBOX"
  TEST_PRESET=isolated run_engine -- asb claude -p hi
  [[ "$output" != *"recorded workspace trust"* ]]
}

@test "a --bg in a project whose path is past 200 characters finds the role's config store too" {
  # The profile once rebuilt the store's path with Claude Code's project slug; the
  # engine names the directory with its own, and past 200 characters the two differ,
  # so the store was never found and the trust never recorded.
  local long
  long="$H/$(printf 'd%.0s' {1..220})"
  mkdir -p "$long"
  long="$(cd "$long" && pwd -P)"
  RUN_CWD="$long" TEST_PRESET=isolated run_engine -- asb claude --bg 'a task'
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded workspace trust for $long in role 'default'"* ]]
  local store
  store="$(find "$H/home/.local/state/agent-sandbox/claude" -path '*/default/config/*' -name '*claude.json' | head -1)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["projects"][sys.argv[2]]["hasTrustDialogAccepted"]' "$store" "$long"
}

@test "an unknown [claude] key is warned of at the review (typo guard), known ones are not; a launch ignores it quietly" {
  printf '[claude]\nhide = ide\nbogus = x\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- asb claude -p hello
  [[ "$output" != *"is not one this profile reads"* ]]
  run_review
  [[ "$output" == *"[claude] key 'bogus' is not one this profile reads"* ]]
  [[ "$output" != *"key 'hide' is not one"* ]]
}
