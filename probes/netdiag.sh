#!/usr/bin/env bash
# agent-sandbox strict-mode network diagnostic. RUN ON THE HOST (not in a sandbox).
#
#   bash probes/netdiag.sh
#
# It launches the INSTALLED engine in a throwaway "netdiag" profile that runs a
# shell probe INSIDE the sandbox, across net modes, and prints what each sees.
# Goal: find why the agent gets ENOTFOUND in strict mode. It only reads and
# probes; it starts no long-lived process and writes nothing outside a tempdir.
# The proxy token is redacted in the output. Paste the whole output back.
set -uo pipefail

launcher="${PROBE_LAUNCHER:-$(command -v claude || true)}"
[[ -n "$launcher" ]] || {
  echo "netdiag: no 'claude' launcher on PATH; set PROBE_LAUNCHER=/path/to/launcher" >&2
  exit 2
}
ev="$("$launcher" --engine-version 2>/dev/null || true)"
case "$ev" in
  agent-sandbox*) : ;;
  *)
    echo "netdiag: '$launcher' is not the agent-sandbox launcher (--engine-version: ${ev:-nothing})" >&2
    exit 2
    ;;
esac
if [[ -r /proc/1/cmdline ]] && [[ "$(tr '\0' ' ' </proc/1/cmdline)" == bwrap* ]]; then
  echo "netdiag: this is inside a sandbox; run it on the host" >&2
  exit 2
fi
echo "netdiag: launcher $launcher ($ev)"
echo "netdiag: host resolves api.anthropic.com -> $(getent hosts api.anthropic.com 2>/dev/null | awk '{print $1}' | head -1 || echo '?')"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/netdiag.sh" <<'PROF'
profile_command=netdiag
profile_bin_discover() {
  profile_bin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/netdiag-probe.sh"
  [[ -x "$profile_bin" ]] || { _as_msg "netdiag: probe missing"; return 1; }
}
PROF

cat >"$tmp/netdiag-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# Runs INSIDE the sandbox as the profile binary. No secrets printed.
set +e
R() { printf '  %-30s %s\n' "$1" "$2"; }
R "HTTPS_PROXY" "$(printf '%s' "${HTTPS_PROXY:-<unset>}" | sed -E 's#://[^@/]+@#://<TOKEN>@#')"
phostport="$(printf '%s' "${HTTPS_PROXY:-}" | sed -E 's#^[a-z]+://([^@]*@)?##; s#/.*##')"
R "proxy endpoint" "${phostport:-<none>}"
R "interfaces" "$(ip -brief addr show 2>/dev/null | awk '{printf "%s ",$1}')"
R "default gw" "$(ip -4 route show default 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1)"
R "DNS resolve api.anthropic.com" "$(python3 -c 'import socket
try: print(socket.gethostbyname("api.anthropic.com"))
except Exception as e: print("FAIL", type(e).__name__)' 2>&1)"
R "TCP -> proxy endpoint" "$(python3 -c 'import socket,sys
hp=sys.argv[1]
if not hp: print("no proxy"); raise SystemExit
h,p=hp.rsplit(":",1)
try: socket.create_connection((h,int(p)),4).close(); print("REACHED")
except Exception as e: print("blocked", type(e).__name__)' "$phostport" 2>&1)"
R "curl via proxy (hostname)" "$(curl -sS -o /dev/null -w '%{http_code} err=%{errormsg}' --max-time 15 https://api.anthropic.com/ 2>&1 | tail -c 90)"
R "curl direct (no proxy)" "$(curl -sS -o /dev/null -w '%{http_code} err=%{errormsg}' --max-time 10 --noproxy '*' https://api.anthropic.com/ 2>&1 | tail -c 90)"
node="$(command -v node || true)"
if [[ -n "$node" ]]; then
  R "node version" "$("$node" -v 2>&1)"
  R "node bare fetch (no proxy)" "$("$node" -e 'fetch("https://api.anthropic.com/",{signal:AbortSignal.timeout(10000)}).then(r=>console.log("status",r.status)).catch(e=>console.log("ERR",(e.cause&&e.cause.code)||e.code||e.name))' 2>&1 | tail -1)"
  R "node fetch via ProxyAgent" "$("$node" -e '
let U; try { U = require("undici"); } catch(e){ console.log("undici-unavailable:", e.code||e.name); process.exit(0); }
U.fetch("https://api.anthropic.com/", {dispatcher:new U.ProxyAgent(process.env.HTTPS_PROXY), signal:AbortSignal.timeout(10000)})
  .then(r=>console.log("status", r.status)).catch(e=>console.log("ERR",(e.cause&&e.cause.code)||e.code||e.name));' 2>&1 | tail -1)"
else
  R "node" "not on PATH inside"
fi
PROBE
chmod +x "$tmp/netdiag-probe.sh"

run() {
  local label="$1" mode="$2"
  shift 2
  echo
  echo "===================== $label ====================="
  AGENT_SANDBOX_PROFILE_DIR="$tmp" AGENT_SANDBOX_NET="$mode" \
    "$launcher" --profile netdiag "$@" run 2>&1
  echo "===================== end: $label ================"
}

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
run "strict + token (--allow example.com)" strict --allow example.com
run "strict + NO token" strict
run "proxy + token (control; should reach)" proxy --allow example.com
echo
echo "netdiag: done."
