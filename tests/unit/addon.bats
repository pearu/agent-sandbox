#!/usr/bin/env bats
# components/allowlist_addon.py: parsing, allow semantics, session liveness,
# the CONNECT-stage and request-stage refusals, response streaming. Runs with
# a stub `mitmproxy` module, so no mitmproxy install is needed.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  ADDON="${AGENT_SANDBOX_TEST_ADDON:-$REPO_ROOT/components/allowlist_addon.py}"
  CFG="$BATS_TEST_TMPDIR/cfg"
  BASE="$BATS_TEST_TMPDIR/base"
  mkdir -p "$CFG" "$BASE" "$BATS_TEST_TMPDIR/stub/mitmproxy"
  cp "$BATS_TEST_DIRNAME/../helpers/mitmproxy_stub.py" "$BATS_TEST_TMPDIR/stub/mitmproxy/http.py"
  : >"$BATS_TEST_TMPDIR/stub/mitmproxy/__init__.py"
  export PYTHONPATH="$BATS_TEST_TMPDIR/stub" AGENT_SANDBOX_SESSION_BASE="$BASE"
  printf '# comment\napi.github.com   # trailing\n\n.example.org\n' >"$CFG/allowlist.txt"
}

# AGENT_SANDBOX_TEST_PYTHON may wrap the interpreter, e.g. "python3 -m trace --count ..." for coverage.
# shellcheck disable=SC2086
drive() { ${AGENT_SANDBOX_TEST_PYTHON:-python3} "$BATS_TEST_DIRNAME/../helpers/addon_driver.py" "$ADDON" "$CFG" "$@"; }

@test "the allowlist parses comments and whitespace; a leading dot means the domain and its subdomains" {
  run drive parse
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact=api.github.com,example.org"* ]]
  [[ "$output" == *"suffix=.example.org"* ]]
  run drive allowed api.github.com example.org www.example.org notexample.org github.com
  [[ "$output" == *"api.github.com=True"* ]]
  [[ "$output" == *"example.org=True"* ]]
  [[ "$output" == *"www.example.org=True"* ]]
  [[ "$output" == *"notexample.org=False"* ]]
  [[ "$output" == *"github.com=False"* ]]
}

@test "session --allow files count only while their owner is alive; a recycled pid never counts" {
  sleep 300 &
  local live=$!
  mkdir -p "$BASE/session.a" "$BASE/session.dead" "$BASE/session.recycled" "$BASE/session.noowner"
  printf '%s %s\n' "$live" "$(awk '{print $22}' "/proc/$live/stat")" >"$BASE/session.a/owner.id"
  printf '# header\npypi.org\n' >"$BASE/session.a/allow.txt"
  echo "999999 1" >"$BASE/session.dead/owner.id"
  echo "dead.example" >"$BASE/session.dead/allow.txt"
  printf '%s %s\n' "$live" "1" >"$BASE/session.recycled/owner.id"
  echo "recycled.example" >"$BASE/session.recycled/allow.txt"
  echo "noowner.example" >"$BASE/session.noowner/allow.txt"
  run drive owner_alive "$BASE/session.a/owner.id"
  [[ "$output" == "alive=True" ]]
  run drive owner_alive "$BASE/session.dead/owner.id"
  [[ "$output" == "alive=False" ]]
  run drive owner_alive "$BASE/session.recycled/owner.id"
  [[ "$output" == "alive=False" ]]
  run drive allowed pypi.org dead.example recycled.example noowner.example
  [[ "$output" == *"pypi.org=True"* ]]
  [[ "$output" == *"dead.example=False"* ]]
  [[ "$output" == *"recycled.example=False"* ]]
  [[ "$output" == *"noowner.example=False"* ]]
  kill "$live"
  wait "$live" 2>/dev/null || true
  run drive allowed pypi.org
  [[ "$output" == *"pypi.org=False"* ]]
}

@test "a non-allowed request gets a 403 with the allowlist message and is logged; an allowed one passes" {
  run drive request blocked.invalid POST /v1/x
  [[ "$output" == *"blocked=True"* ]]
  [[ "$output" == *"status=403"* ]]
  [[ "$output" == *"body=agent-sandbox: host 'blocked.invalid' is not in the allowlist."* ]]
  grep -q $'\tblocked.invalid\tPOST\t/v1/x$' "$CFG/blocked.log"
  run drive request api.github.com
  [[ "$output" == *"blocked=False"* ]]
  [ "$(wc -l <"$CFG/blocked.log")" -eq 1 ]
}

@test "a non-allowed CONNECT is refused with 403 and logged as CONNECT; an allowed one passes" {
  run drive connect example.com
  [[ "$output" == *"blocked=True"* ]]
  [[ "$output" == *"status=403"* ]]
  grep -q $'\texample.com\tCONNECT\t-$' "$CFG/blocked.log"
  run drive connect sub.example.org
  [[ "$output" == *"blocked=False"* ]]
}

@test "responses are streamed" {
  run drive responseheaders text/event-stream
  [[ "$output" == "stream=True" ]]
  run drive responseheaders application/octet-stream
  [[ "$output" == "stream=True" ]]
}
