#!/usr/bin/env bats
# Against the host's real proxy on 127.0.0.1:8888 (AGENT_SANDBOX_LIVE=1).

setup() {
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests"
  (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null || skip "no proxy on 127.0.0.1:8888"
}

@test "an allowed host is reached through the proxy; a non-allowed one is refused at CONNECT" {
  run curl -sS --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models
  [[ "$output" == 401 || "$output" == 200 ]]
  run curl -sS --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' https://example.com/
  [[ "$output" == *"CONNECT tunnel failed, response 403"* ]]
}

@test "the proxy's leaf certificates carry an Authority Key Identifier (mitmproxy 12+)" {
  run bash -c 'openssl s_client -proxy 127.0.0.1:8888 -connect api.github.com:443 -servername api.github.com </dev/null 2>/dev/null | openssl x509 -noout -text | grep -c "Authority Key Identifier"'
  [ "$output" = 1 ]
}
