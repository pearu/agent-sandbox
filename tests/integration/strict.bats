#!/usr/bin/env bats
# strict net mode end to end with the REAL pasta + bwrap + nftables. A fake proxy
# listens on the host's loopback 8888 (as the unit does) and a host-only listener
# on 8899. A probe inside the sandbox checks that the proxy is reachable at the
# gateway (pasta maps it to the host) and only there, that an arbitrary raw
# socket is blocked by the in-netns firewall, and that the host-only listener is
# not mirrored into the sandbox; meanwhile the test checks from the host that a
# listener the probe starts inside is not published on the host. Skips unless
# pasta can create a namespace here (needs passt + its AppArmor profile, or the
# userns sysctl relaxed) and the three ports are free.

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
  local p
  for p in 8888 8899 8877; do
    (echo >"/dev/tcp/127.0.0.1/$p") 2>/dev/null && skip "port $p already in use"
  done
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
conn() { python3 -c 'import socket,sys
try:
    s=socket.create_connection((sys.argv[1], int(sys.argv[2])), 4); s.close(); print("REACHED")
except Exception as e:
    print("blocked")' "$1" "$2"; }
# pasta's default -T auto (the bug this guards against) rescans the host's
# listening ports every second; give a regression time to show.
sleep 1.5
say proxy_via_gw "$(conn "$GW" 8888)"
say proxy_via_lo "$(conn 127.0.0.1 8888)"
say host_loopback "$(conn 127.0.0.1 8899)"
say raw_external "$(conn 1.1.1.1 443)"
say net_ifaces "$(ip -brief addr show 2>/dev/null | awk '{printf "%s ", $1}')"
# Listen inside, tell the test, and hold the sandbox open while the test looks
# for the port on the host; the test releases us by creating $PWD/done.
python3 -m http.server 8877 --bind 0.0.0.0 >/dev/null 2>&1 &
sleep 0.5
say inside_listener "$(conn 127.0.0.1 8877)"
: >"$PWD/listening"
for _ in $(seq 1 75); do [ -e "$PWD/done" ] && break; sleep 0.2; done
PROBE
  # Host side: a fake proxy on loopback 8888 (accept and close is enough for a
  # TCP connect) and a listener on 8899 that only the host knows about.
  python3 -c 'import socketserver
class H(socketserver.BaseRequestHandler):
    def handle(self): pass
socketserver.ThreadingTCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("127.0.0.1",8888),H).serve_forever()' &
  PROXY_PID=$!
  python3 -c 'import socketserver
class H(socketserver.BaseRequestHandler):
    def handle(self): pass
socketserver.ThreadingTCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("127.0.0.1",8899),H).serve_forever()' &
  HOSTONLY_PID=$!
  sleep 0.5
}

teardown() {
  : >"$IWORK/done" 2>/dev/null
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null
  [ -n "${HOSTONLY_PID:-}" ] && kill "$HOSTONLY_PID" 2>/dev/null
  return 0
}

# conn_host HOST PORT: a TCP connect from the host side -> REACHED | blocked
conn_host() {
  python3 -c 'import socket,sys
try:
    s=socket.create_connection((sys.argv[1], int(sys.argv[2])), 4); s.close(); print("REACHED")
except Exception:
    print("blocked")' "$1" "$2"
}

@test "strict: the proxy is reachable at the gateway only; raw egress, host loopback services and publishing sandbox listeners are blocked" {
  rm -f "$IWORK/report" "$IWORK/listening" "$IWORK/done"
  # Launched in the background rather than with bats' run, so the host side can
  # look for the published port while the sandbox is alive. fd 3 is closed so a
  # stray pasta cannot hold bats open; the engine's output goes to a file that
  # is printed below (bats shows it only when the test fails).
  (
    cd "$IWORK" && exec env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
      AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
      AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PASSENV=GW GW="$GW" \
      "$ENGINE" --profile probe run
  ) >"$I/engine.out" 2>&1 3>&- &
  local pid=$! i
  for i in $(seq 1 100); do
    [ -e "$IWORK/listening" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  # pasta's default -t auto (the other half of the bug) publishes a port bound
  # inside within a second; wait that long so a regression shows.
  sleep 1.5
  local published
  published=$(conn_host 127.0.0.1 8877)
  : >"$IWORK/done"
  local rc=0
  wait "$pid" || rc=$?
  echo "engine output: $(cat "$I/engine.out")"
  [ -e "$IWORK/listening" ] # the probe ran far enough to listen inside
  [ "$rc" -eq 0 ]
  declare -gA REPORT=()
  local k v
  while IFS='=' read -r k v; do [ -n "$k" ] && REPORT["$k"]="$v"; done <"$IWORK/report"
  [ "$(report proxy_via_gw)" = REACHED ]    # gateway:8888 -> host proxy, allowed by nft
  [ "$(report proxy_via_lo)" = blocked ]    # the proxy is reached at the gateway only
  [ "$(report host_loopback)" = blocked ]   # the host-only 127.0.0.1:8899 is not mirrored into the netns
  [ "$(report raw_external)" = blocked ]    # 1.1.1.1:443 dropped by the firewall
  [ "$(report inside_listener)" = REACHED ] # the sandbox's own loopback works
  [ "$published" = blocked ]                # the sandbox's 8877 is not published on the host
  [[ "$(report net_ifaces)" != "lo " ]]     # pasta gave the netns a real interface
}
