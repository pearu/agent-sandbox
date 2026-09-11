#!/usr/bin/env bats
# strict net mode end to end with the REAL pasta + bwrap + nftables. Something
# must answer TCP on the host's loopback 8888: the installed proxy if this host
# has one, else a fake started here; a host-only listener sits on 8899. A probe
# inside the sandbox checks the proxy at the gateway, the same
# two ports at 127.0.0.1, and raw egress; meanwhile the test checks from the host
# whether a listener the probe starts inside (8877) is published. Two scenarios:
# the closed default (nothing but the proxy), and --host-port/--agent-port
# opening exactly the two probe ports. Skips unless pasta can create a namespace
# here (needs passt + its AppArmor profile, or the userns sysctl relaxed) and
# 8899 and 8877 are free.

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
  for p in 8899 8877; do
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
# pasta's default -T auto (the regression guarded against) rescans the host's
# listening ports every second; give it time to show.
sleep 1.5
say https_proxy "${HTTPS_PROXY:-<unset>}"   # must be set, or the agent has no route to the API
say proxy_via_gw "$(conn "$GW" 8888)"
say proxy_via_lo "$(conn 127.0.0.1 8888)"
say host_loopback "$(conn 127.0.0.1 8899)"
say raw_external "$(conn 1.1.1.1 443)"
say net_ifaces "$(ip -brief addr show 2>/dev/null | awk '{printf "%s ", $1}')"
# Listen inside (on PROBE_BIND), tell the test, and hold the sandbox open while
# the test looks for the port on the host; it releases us by creating $PWD/done.
python3 -m http.server 8877 --bind "${PROBE_BIND:-0.0.0.0}" >/dev/null 2>&1 &
sleep 0.5
say inside_listener "$(conn 127.0.0.1 8877)"
: >"$PWD/listening"
for _ in $(seq 1 75); do [ -e "$PWD/done" ] && break; sleep 0.2; done
PROBE
  # Host side. The probe only ever TCP-connects to 8888, so the installed proxy
  # serves when this host has one; otherwise a fake that accepts and closes
  # stands in (CI). Plus a listener on 8899 that only the host knows about.
  PROXY_PID=""
  if ! (echo >"/dev/tcp/127.0.0.1/8888") 2>/dev/null; then
    python3 -c 'import socketserver
class H(socketserver.BaseRequestHandler):
    def handle(self): pass
socketserver.ThreadingTCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer(("127.0.0.1",8888),H).serve_forever()' &
    PROXY_PID=$!
  fi
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

# launch_strict [ENGINE FLAGS...]: run the engine in strict mode with the probe,
# in the background rather than with bats' run so the host side can look for
# the published port while the sandbox is alive. Sets RC (engine exit code),
# PUBLISHED (host 127.0.0.1:8877 -> REACHED | blocked) and REPORT. fd 3 is
# closed so a stray pasta cannot hold bats open; the engine's output is echoed
# (bats shows it only when the test fails). PROBE_BIND (default 0.0.0.0) is the
# address the probe's server binds inside.
launch_strict() {
  rm -f "$IWORK/report" "$IWORK/listening" "$IWORK/done"
  (
    cd "$IWORK" && exec env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
      AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
      AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_NET=strict \
      AGENT_SANDBOX_FORWARD="GW PROBE_BIND" GW="$GW" PROBE_BIND="${PROBE_BIND:-0.0.0.0}" \
      "$ENGINE" --profile probe "$@" run
  ) >"$I/engine.out" 2>&1 3>&- &
  local pid=$!
  for _ in $(seq 1 100); do
    [ -e "$IWORK/listening" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  # pasta's default -t auto (the other half of the regression) publishes a port
  # bound inside within a second; wait that long so it would show.
  sleep 1.5
  PUBLISHED=$(conn_host 127.0.0.1 8877)
  : >"$IWORK/done"
  RC=0
  wait "$pid" || RC=$?
  echo "engine output: $(cat "$I/engine.out")"
  # shellcheck disable=SC2034 # one of launch_strict's documented outputs; not every test reads it
  declare -gA REPORT=()
  local k v
  # shellcheck disable=SC2034 # (same: filled for callers that want it)
  while IFS='=' read -r k v; do [ -n "$k" ] && REPORT["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
  [ -e "$IWORK/listening" ] # the probe ran far enough to listen inside
}

@test "strict: the proxy is reachable at the gateway only; raw egress, host loopback services and publishing sandbox listeners are blocked" {
  launch_strict
  [ "$RC" -eq 0 ]
  [ "$(report proxy_via_gw)" = REACHED ]         # gateway:8888 -> host proxy, allowed by nft
  [[ "$(report https_proxy)" == http://*:8888 ]] # the agent env carries the gateway proxy (survives --clearenv)
  [ "$(report proxy_via_lo)" = blocked ]         # the proxy is reached at the gateway only
  [ "$(report host_loopback)" = blocked ]        # the host-only 127.0.0.1:8899 is not mirrored into the netns
  [ "$(report raw_external)" = blocked ]         # 1.1.1.1:443 dropped by the firewall
  [ "$(report inside_listener)" = REACHED ]      # the sandbox's own loopback works
  [ "$PUBLISHED" = blocked ]                     # the sandbox's 8877 is not published on the host
  [[ "$(report net_ifaces)" != "lo " ]]          # pasta gave the netns a real interface
}

@test "strict: --host-port and --agent-port open exactly those ports; everything else stays blocked" {
  # The server inside binds 127.0.0.1, the common dev-server default.
  PROBE_BIND=127.0.0.1 launch_strict --host-port 8899 --agent-port 8877
  [ "$RC" -eq 0 ]
  [[ "$(cat "$I/engine.out")" == *"host ports the sandbox may reach at 127.0.0.1: 8899"* ]]
  [[ "$(cat "$I/engine.out")" == *"agent ports published at the host's 127.0.0.1: 8877"* ]]
  [ "$(report host_loopback)" = REACHED ] # the opened host port
  [ "$PUBLISHED" = REACHED ]              # the opened agent port, from the host
  [ "$(report proxy_via_gw)" = REACHED ]
  [ "$(report proxy_via_lo)" = blocked ] # 8888 was not opened
  [ "$(report raw_external)" = blocked ]
}
