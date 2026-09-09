#!/usr/bin/env bats
# Against the host's real proxy on 127.0.0.1:8888 (AGENT_SANDBOX_LIVE=1).

setup() {
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests"
  (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null || skip "no proxy on 127.0.0.1:8888"
  # The proxy MITMs TLS with a CA trusted only inside the sandbox; a host client
  # must be handed that CA (the host system store deliberately does not trust it).
  CA="${AGENT_SANDBOX_PROXY_CA:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"
  [ -r "$CA" ] || skip "proxy CA not readable: $CA"
}

@test "an allowed host is reached through the proxy; a non-allowed one is refused at CONNECT" {
  run curl -sS --cacert "$CA" --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models
  [[ "$output" == 401 || "$output" == 200 ]] # reached the API through the proxy (401 = no key)
  # A blocked host is refused at CONNECT, before TLS, so no CA is involved.
  run curl -sS --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' https://example.com/
  [ "$status" -ne 0 ]        # a refused CONNECT; curl's exit code varies by version
  [[ "$output" == *"403"* ]] # the proxy's 403 body
}

@test "the proxy's leaf certificates carry an Authority Key Identifier (mitmproxy 12+)" {
  run bash -c 'openssl s_client -proxy 127.0.0.1:8888 -connect api.github.com:443 -servername api.github.com </dev/null 2>/dev/null | openssl x509 -noout -text | grep -c "Authority Key Identifier"'
  [ "$output" = 1 ]
}
