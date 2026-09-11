#!/usr/bin/env bash
# F1: does the egress allowlist gate the destination the proxy actually dials?
#
# Two ways the allowlist could be bypassed, both checked here against the REAL
# installed proxy on 127.0.0.1:8888:
#   (a) a spoofed Host header: `GET http://<dest>/` with `Host: <allowlisted>`
#       -- the proxy must judge <dest>, not the header.
#   (b) an allowlisted name/IP that resolves to a non-public address -- the
#       proxy runs on the host, so loopback/private/metadata must be refused
#       whatever the allowlist says about the name.
#
# RUN ON THE HOST, not inside the sandbox (inside there is no route to the host
# proxy on 127.0.0.1:8888). Everything stays on loopback; nothing leaves the
# machine. A throwaway HTTP service on 127.0.0.1 stands in for a host service.
#     ./probes/f1-egress.sh
set -uo pipefail
say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

PROXY=http://127.0.0.1:8888
CFG="$HOME/.config/agent-sandbox"
ALLOW="$CFG/allowlist.txt"
BLOG="$CFG/blocked.log"

command -v curl >/dev/null || {
  note "curl required"
  exit 1
}
systemctl --user is-active agent-sandbox-mitmproxy.service >/dev/null 2>&1 \
  || {
    note "proxy service not active — start it, then re-run"
    exit 1
  }

spoof="$(sed 's/#.*//; s/[[:space:]]//g' "$ALLOW" 2>/dev/null | grep -vE '^\.?$' | grep -v '^\.' | head -1)"
[ -n "$spoof" ] || {
  note "no exact host in $ALLOW to spoof"
  exit 1
}

port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
hits="$(mktemp)"
python3 - "$port" >/dev/null 2>"$hits" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        sys.stderr.write(f"HIT {self.path} Host={self.headers.get('Host')}\n"); sys.stderr.flush()
        self.send_response(200); self.end_headers(); self.wfile.write(b"REACHED-HOST-SERVICE\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
listener=$!
trap 'kill "$listener" 2>/dev/null' EXIT
for _ in $(seq 1 25); do
  (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break
  sleep 0.2
done
before="$(wc -l <"$BLOG" 2>/dev/null || echo 0)"

say "(a) spoofed Host: $spoof  ->  real destination 127.0.0.1:$port (not allowlisted)"
code=$(curl -sS --proxy "$PROXY" --max-time 15 -o /dev/null -w '%{http_code}' \
  -H "Host: $spoof" "http://127.0.0.1:$port/SPOOF" 2>/dev/null || true)
note "status=$code   (a fixed proxy refuses this: not 200)"

say "(b) honest loopback destination 127.0.0.1:$port"
code2=$(curl -sS --proxy "$PROXY" --max-time 15 -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$port/DIRECT" 2>/dev/null || true)
note "status=$code2   (a fixed proxy refuses this: not 200)"

sleep 0.3
say "Did the loopback service get reached through the proxy?"
if grep -q HIT "$hits"; then
  note "LEAK — the proxy reached the host-local service:"
  sed 's/^/     /' "$hits"
else
  note "no — nothing reached it (the fix holds)"
fi
say "blocked.log lines added by this run"
after="$(wc -l <"$BLOG" 2>/dev/null || echo 0)"
if [ "$after" -gt "$before" ]; then tail -n "$((after - before))" "$BLOG" | sed 's/^/   /'; else note "(none)"; fi
rm -f "$hits"

say "Verdict"
if [ "$code" != 200 ] && [ "$code2" != 200 ] && ! grep -q HIT "$hits" 2>/dev/null; then
  note "PASS: neither the Host-header spoof nor the loopback dial reached the service."
else
  note "FAIL: F1 reproduces on this proxy (see above)."
fi
