#!/usr/bin/env bats
# Against the host's real proxy on 127.0.0.1:PORT, the port install.sh recorded for
# this account (8888 unless it chose another; test_proxy_port) (AGENT_SANDBOX_LIVE=1).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/proxy-port"
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests"
  PP="$(test_proxy_port "$HOME")"
  (echo >"/dev/tcp/127.0.0.1/$PP") 2>/dev/null || skip "no proxy on 127.0.0.1:$PP"
  # The proxy MITMs TLS with a CA trusted only inside the sandbox; a host client
  # must be handed that CA (the host system store deliberately does not trust it).
  CA="${AGENT_SANDBOX_PROXY_CA:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"
  [ -r "$CA" ] || skip "proxy CA not readable: $CA"
}

# A live session of the test's own in the base the proxy reads, since the proxy serves
# sessions only (#233): PX carries its token, SESS is removed by teardown.
probe_session() {
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -d "$rt" && -w "$rt" ]] || rt=/tmp
  mkdir -p "$rt/agent-sandbox.$(id -u)"
  SESS="$(mktemp -d "$rt/agent-sandbox.$(id -u)/session.XXXXXX")"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$SESS/owner.id"
  echo liveprobe >"$SESS/proxy.token"
  printf 'api.anthropic.com\n' >"$SESS/allow.txt" # a profile's own host, as a launch opens it
  PX="http://liveprobe:x@127.0.0.1:$PP"
}
teardown() {
  [[ -n "${SESS:-}" ]] && rm -rf "$SESS"
  return 0
}

@test "an allowed host is reached through the proxy; a non-allowed one is refused at CONNECT" {
  probe_session
  run curl -sS --cacert "$CA" --proxy "$PX" --max-time 20 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models
  [[ "$output" == 401 || "$output" == 200 ]] # reached the API through the proxy (401 = no key)
  # A blocked host is refused at CONNECT, before TLS, so no CA is involved.
  run curl -sS --proxy "$PX" --max-time 20 -o /dev/null -w '%{http_code}' https://example.com/
  [ "$status" -ne 0 ]        # a refused CONNECT; curl's exit code varies by version
  [[ "$output" == *"403"* ]] # the proxy's 403 body
}

@test "a client with no session token is refused with 407 (#233)" {
  run curl -s --proxy "http://127.0.0.1:$PP" --max-time 20 -o /dev/null -w '%{http_connect}' https://api.anthropic.com/
  [ "$output" = 407 ]
}

@test "the proxy's leaf certificates carry an Authority Key Identifier (mitmproxy 12+)" {
  probe_session
  # shellcheck disable=SC2016 # $1 is the inner shell's: the proxy's port
  run bash -c 'openssl s_client -proxy "127.0.0.1:$1" -proxy_user liveprobe -proxy_pass pass:x -connect api.github.com:443 -servername api.github.com </dev/null 2>/dev/null | openssl x509 -noout -text | grep -c "Authority Key Identifier"' _ "$PP"
  [ "$output" = 1 ]
}
