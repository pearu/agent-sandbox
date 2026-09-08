#!/usr/bin/env bats
# strict net mode end to end with the REAL pasta + bwrap + nftables. A fake proxy
# listens on the host's 8888; a probe inside the sandbox checks that the proxy is
# reachable at the gateway (pasta maps it to the host) while an arbitrary raw
# socket is blocked by the in-netns firewall. Skips unless pasta can create a
# namespace here (needs passt + its AppArmor profile, or the userns sysctl
# relaxed) and 8888 is free.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v pasta >/dev/null || skip "pasta (passt) not installed"
  command -v nft >/dev/null || skip "nft (nftables) not installed"
  GW=$(ip route show default 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$GW" ] || skip "no default-route gateway"
  # Confirm pasta can create a namespace here. When blocked it can leave a stray
  # forwarder; closing fd 3 (bats's pipe) for the probe keeps such a stray from
  # holding the suite open, and the timeout bounds a hang.
  if ! timeout -k 1 8 pasta --config-net --quiet -- true >/dev/null 2>&1 3>&-; then
    skip "pasta cannot create a namespace here (needs passt + its AppArmor profile, or the userns sysctl relaxed)"
  fi
  (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null && skip "port 8888 already in use"
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
conn() { python3 -c 'import socket,sys
try:
    s=socket.create_connection((sys.argv[1], int(sys.argv[2])), 4); s.close(); print("REACHED")
except Exception as e:
    print("blocked")' "$1" "$2"; }
say proxy_via_gw "$(conn "$GW" 8888)"
say raw_external "$(conn 1.1.1.1 443)"
say net_ifaces "$(ip -brief addr show 2>/dev/null | awk '{printf "%s ", $1}')"
PROBE
  # fake proxy: accept and immediately close, just enough for a TCP connect
  python3 -c 'import socketserver
class H(socketserver.BaseRequestHandler):
    def handle(self): pass
socketserver.ThreadingTCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("0.0.0.0",8888),H).serve_forever()' &
  PROXY_PID=$!
  sleep 0.5
}

teardown() {
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null
  return 0
}

@test "strict: the proxy on the gateway is reachable; arbitrary raw egress is blocked" {
  run_sandboxed AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PASSENV=GW GW="$GW" -- run
  [ "$status" -eq 0 ]
  [ "$(report proxy_via_gw)" = REACHED ] # gateway:8888 -> host proxy, allowed by nft
  [ "$(report raw_external)" = blocked ] # 1.1.1.1:443 dropped by the firewall
  [[ "$(report net_ifaces)" != "lo " ]]  # pasta gave the netns a real interface
}
