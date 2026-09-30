#!/usr/bin/env bats
# The dot-file under the real bwrap (#143): read-only inside, a copy of its own when
# declared so, and no gate for an engine running inside a sandbox.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  printf '[allow]\npypi.org\n' >"$IWORK/.agent-sandbox"
  # approved, the way --trust records it
  local rec
  rec="$IHOME/.config/agent-sandbox/trust/$(printf '%s' "$(cd "$IWORK" && pwd -P)" | sha256sum | cut -d' ' -f1)"
  mkdir -p "$(dirname "$rec")"
  sha256sum "$IWORK/.agent-sandbox" | cut -d' ' -f1 >"$rec"
  cp "$IWORK/.agent-sandbox" "$rec.approved"
  ENV=(AGENT_SANDBOX_NET=none)
}

@test "the dot-file cannot be written from inside, though the project around it can" {
  run_sandboxed "${ENV[@]}" -- --profile probe --exec sh -c \
    'echo evil.example >>.agent-sandbox 2>/dev/null && echo dot=written || echo dot=refused; touch other && echo proj=written'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dot=refused"* ]]
  [[ "$output" == *"proj=written"* ]]
  [ "$(cat "$IWORK/.agent-sandbox")" = "$(printf '[allow]\npypi.org')" ]
}

@test "declared copy: writable inside, and the project's file is untouched" {
  run_sandboxed "${ENV[@]}" -- --connect './.agent-sandbox = copy' --profile probe --exec sh -c \
    'echo mine.example >>.agent-sandbox && echo dot=written; cat .agent-sandbox'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dot=written"*"mine.example"* ]]
  [[ "$(cat "$IWORK/.agent-sandbox")" != *mine.example* ]]
}

@test "inside a sandbox the engine knows it, and honours the dot-file with no approval" {
  cp "$ENGINE" "$IWORK/engine-copy"
  # shellcheck disable=SC2016 # expanded by the inner bash
  run_sandboxed "${ENV[@]}" -- --profile probe --exec bash -c \
    'source ./engine-copy; _as_inside_sandbox && echo inside=yes; _as_dotfile_trusted "$PWD" "$PWD/.agent-sandbox" && echo trusted=yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"inside=yes"* ]]
  [[ "$output" == *"trusted=yes"* ]] # no trust store in there, and no gate needed
}
