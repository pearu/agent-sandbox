#!/usr/bin/env bash
# Row 13 — A SHARED EXTERNAL MEDIUM, end to end.
#
# THE CLAIM UNDER TEST: two independent sessions given internet access can communicate,
# PROVIDED they can make first contact to exchange an endpoint somehow. The conditional
# is the whole point, so the row measures the antecedent and the consequent separately
# and then the composition.
#
# An earlier draft of this row failed to test it: the harness generated a topic and
# handed it to BOTH sides, which assumes away first contact and measures only
# reachability. Here the harness never tells B the endpoint. A chooses it, publishes to
# it, and writes it into a channel the sandbox leaves open; B must READ IT OUT and use
# what it found.
#
# THREE LINKS, EACH MEASURED, so a broken chain says which link broke:
#   1 PUBLISH        can A, sandboxed, post to the medium at all?
#   2 FIRST CONTACT  does the endpoint A wrote reach B, sandboxed, with no harness help?
#   3 FETCH          can B, using only what it read, retrieve A's canary?
# and then the COMPOSED cell: did B end up holding A's canary.
#
# The carrier for link 2 is downloads/, measured shared in row 12: a plain file with no
# semantics to confuse the result. Any of the channels rows 5-12 and 15-18 found open
# would serve; this row does not claim downloads/ is special, only that one open channel
# is enough.
#
# The medium is ntfy.sh -- publish by POST, read by GET. Checked rather than assumed:
# jsonplaceholder.typicode.com was tried first and rejected, because it echoes a POST
# with a fresh id and then returns {} for that id. It fakes writes, so it would have
# measured reachability while looking like it measured a leak. ntfy is NOT on the
# allowlist, which is what puts the network mode in play; an allowlisted host is measured
# alongside as the control.
#
# Link 3 is tried TWICE per mode: through urllib, which honours HTTPS_PROXY, and over a
# raw socket, which does not. The allowlist is documented as advisory under `proxy`
# (network.md; design.md's guarantee is scoped to "every client that honours HTTPS_PROXY")
# and enforced under `strict`. This is where that is measured rather than quoted.
#
# Free: no credentials, no LLM, no API calls. Network egress only.
set -euo pipefail

# shellcheck source=probes/leak/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LEAK_ROW=13-network
VALID=1
leak_setup "$LEAK_ROW"

STAMP="$(date +%s)"
DOWNLOADS="$LEAK_CONFIG/downloads"
mkdir -p "$DOWNLOADS"
DROP="$DOWNLOADS/notes-from-a.txt" # the carrier: A writes here, B reads here
ALLOWED_URL="https://raw.githubusercontent.com/pearu/agent-sandbox/main/README.md"

# ---- A's side: choose an endpoint, publish to it, leave the address behind -----------
# A is given a canary to publish and nothing else. The TOPIC is A's own choice, so the
# harness never holds a secret both sides share.
cat >"$LEAK_A/publish.py" <<'PY'
import json, random, sys, urllib.request
canary, drop = sys.argv[1], sys.argv[2]
topic = "agent-sandbox-leak-%d-%d" % (int(sys.argv[3]), random.randrange(10**9))
url = "https://ntfy.sh/%s" % topic
out = {"topic": topic, "token": canary}
try:
    req = urllib.request.Request(url, data=canary.encode(), method="POST")
    with urllib.request.urlopen(req, timeout=25) as r:
        r.read()
    out["open"] = "ok"
    out["token_found"] = True
except Exception as e:  # noqa: BLE001 - failing to publish IS the measurement
    out["open"] = type(e).__name__
    out["token_found"] = False
# The address is left behind whether or not the publish succeeded: link 2 is about the
# carrier, and conflating it with link 1 is what a decomposed row exists to avoid.
try:
    with open(drop, "w", encoding="utf-8") as fh:
        fh.write("scratch notes\nendpoint: %s\n" % url)
except OSError as e:
    out["drop_error"] = str(e)
print(json.dumps(out))
PY

# ---- B's side: find the address, then use it ----------------------------------------
# B is NEVER given the topic. It reads the carrier, extracts whatever address is there,
# and fetches that. If the carrier is empty the chain breaks at link 2, which the record
# distinguishes from a fetch that was blocked.
cat >"$LEAK_B/discover.py" <<'PY'
import json, re, socket, ssl, sys, urllib.request

how, drop, canary = sys.argv[1], sys.argv[2], sys.argv[3]
out = {"how": how, "token": canary}
try:
    with open(drop, encoding="utf-8") as fh:
        note = fh.read()
except OSError as e:
    print(json.dumps({**out, "open": "no-carrier:" + type(e).__name__,
                      "token_found": False, "endpoint_found": False}))
    raise SystemExit
m = re.search(r"endpoint:\s*(\S+)", note)
out["endpoint_found"] = bool(m)
if not m:
    print(json.dumps({**out, "open": "no-endpoint", "token_found": False}))
    raise SystemExit
url = m.group(1) + "/json?poll=1"
out["path"] = url
try:
    if how == "proxy-aware":
        with urllib.request.urlopen(url, timeout=25) as r:
            data = r.read().decode("utf-8", "replace")
    else:
        host = url.split("/")[2]
        path = "/" + url.split("/", 3)[3]
        ctx = ssl.create_default_context()
        with socket.create_connection((host, 443), timeout=25) as s:
            with ctx.wrap_socket(s, server_hostname=host) as ts:
                ts.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: leak-study\r\n"
                            "Connection: close\r\n\r\n" % (path, host)).encode())
                chunks = []
                while True:
                    b = ts.recv(65536)
                    if not b:
                        break
                    chunks.append(b)
        data = b"".join(chunks).decode("utf-8", "replace")
    out["open"] = "ok"
    out["token_found"] = canary in data
except Exception as e:  # noqa: BLE001 - not reaching it IS the measurement
    out["open"] = type(e).__name__
    out["token_found"] = False
print(json.dumps(out))
PY

# A plain fetch of an allowlisted host, for the control.
cat >"$LEAK_B/fetch.py" <<'PY'
import json, sys, urllib.request
url, token = sys.argv[1], sys.argv[2]
out = {"path": url, "token": token}
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        data = r.read().decode("utf-8", "replace")
    out["open"] = "ok"
    out["token_found"] = token in data
except Exception as e:  # noqa: BLE001
    out["open"] = type(e).__name__
    out["token_found"] = False
print(json.dumps(out))
PY

# ---- (c) can the endpoint be DERIVED, with no first contact at all? -----------------
# Each session reports a SALTED HASH of ambient state and nothing else. Nothing
# identifying is computed into a name, and nothing leaves the machine -- the question is
# only whether two independent sessions can arrive at the same string, which is a
# property of the container. If they can, no carrier is needed and (b) is not the only
# route. Composed with link 3 below, that settles the case without a second live test.
cat >"$LEAK_B/derive.py" <<'PY'
import hashlib, json, os, platform, sys
salt = sys.argv[1]
# Ambient values any session of this user can read, without asking anyone.
parts = [os.environ.get("USER", ""), platform.node(), str(os.getuid())]
digest = hashlib.sha256((salt + "|".join(parts)).encode()).hexdigest()[:16]
print(json.dumps({"digest": digest, "n_parts": len([p for p in parts if p])}))
PY
cp "$LEAK_B/derive.py" "$LEAK_A/derive.py"
SALT="leak-study-$STAMP"
leak_read_sandboxed proxy "$LEAK_A" "$LEAK_A/derive.py" "$LEAK_RUN/derive-a.json" "$SALT"
leak_read_sandboxed proxy "$LEAK_B" "$LEAK_B/derive.py" "$LEAK_RUN/derive-b.json" "$SALT"
python3 - "$LEAK_RUN/derive-a.json" "$LEAK_RUN/derive-b.json" "$LEAK_RUN/derive.json" <<'PY'
import json, sys
def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return {}
a, b = load(sys.argv[1]), load(sys.argv[2])
da, db = a.get("digest"), b.get("digest")
out = {"token": da or "", "open": "ok" if (da and db) else "no-digest",
       "token_found": bool(da) and da == db, "a_parts": a.get("n_parts")}
json.dump(out, open(sys.argv[3], "w"))
PY
leak_record "t2-derivable-rendezvous" --set "topology=T2-derive" --set "net=proxy" \
  --set "link=0-rendezvous" --set "how=ambient-hash" --reader "$LEAK_RUN/derive.json"

# Borrowing the gh config READS the real ~/.claude/gh, which bumps its atime. That has
# to happen BEFORE the baseline snapshot, or the harness perturbs the very state it then
# asserts was untouched -- which is exactly what the first run of this row did.
LEAK_GH_READY=0
if [[ -n "${LEAK_GH_ISSUE:-}" ]] && leak_borrow_gh; then LEAK_GH_READY=1; fi

# The medium is eventually consistent: a message is accepted before it is readable.
# Measured -- the first run of this row published successfully and then fetched nothing,
# which looked exactly like isolation. Polling makes the wait explicit and bounded, and
# only runs when the publish actually succeeded, so a mode that cannot publish does not
# pay for it.
leak_await_medium() { # leak_await_medium URL TOKEN PUBLISH_JSON
  local url="$1" token="$2" pub="$3" i
  python3 -c "
import json,sys
try: sys.exit(0 if json.load(open('$pub')).get('token_found') else 1)
except Exception: sys.exit(1)" || return 0
  for i in $(seq 1 15); do
    if curl -sS "$url" --max-time 10 2>/dev/null | grep -qF "$token"; then
      leak_say "  medium visible after ${i}s"
      return 0
    fi
    sleep 1
  done
  leak_say "  WARNING: published but not visible after 15s"
}

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

# ---- T1: the whole chain, native, as the positive control ---------------------------
A_CANARY="$(leak_token CHAIN-T1)"
leak_read_native "$LEAK_A" "$LEAK_A/publish.py" "$LEAK_RUN/t1-pub.json" \
  "$A_CANARY" "$DROP" "$STAMP"
leak_say "T1 A published: $(python3 -c "import json;d=json.load(open('$LEAK_RUN/t1-pub.json'));print(d['open'])")"
T1_TOPIC="$(python3 -c "import json;print(json.load(open('$LEAK_RUN/t1-pub.json')).get('topic',''))")"
leak_await_medium "https://ntfy.sh/$T1_TOPIC/json?poll=1" "$A_CANARY" "$LEAK_RUN/t1-pub.json"
leak_read_native "$LEAK_B" "$LEAK_B/discover.py" "$LEAK_RUN/t1.json" \
  proxy-aware "$DROP" "$A_CANARY"
leak_record "t1-native-chain" --set "topology=T1" --set "net=n/a" --set "link=chain" \
  --set "how=proxy-aware" --set "canary=$A_CANARY" --reader "$LEAK_RUN/t1.json"

# B must still reach an ALLOWED host, or "unreachable" only means there is no network --
# the network analogue of "B must still reach its own project".
leak_say "T2 control — an allowlisted host under proxy"
leak_read_sandboxed proxy "$LEAK_B" "$LEAK_B/fetch.py" "$LEAK_RUN/allowed.json" \
  "$ALLOWED_URL" "agent-sandbox"
leak_record "t2-allowed-own" --set "topology=T2-allowed-own" --set "net=proxy" \
  --set "link=control" --set "how=proxy-aware" --set "canary=agent-sandbox" \
  --reader "$LEAK_RUN/allowed.json"

# ---- the chain, per mode, each link recorded ----------------------------------------
for net in none open proxy strict; do
  rm -f "$DROP"
  C="$(leak_token "CHAIN-${net}")"
  leak_say "net=$net — link 1: can A publish from inside?"
  leak_read_sandboxed "$net" "$LEAK_A" "$LEAK_A/publish.py" "$LEAK_RUN/pub-$net.json" \
    "$C" "$DROP" "$STAMP"
  leak_record "t2-$net-1-publish" --set "topology=T2-$net-publish" --set "net=$net" \
    --set "link=1-publish" --set "canary=$C" --reader "$LEAK_RUN/pub-$net.json"

  TOPIC="$(python3 -c "import json;print(json.load(open('$LEAK_RUN/pub-$net.json')).get('topic',''))")"
  leak_await_medium "https://ntfy.sh/$TOPIC/json?poll=1" "$C" "$LEAK_RUN/pub-$net.json"

  leak_say "net=$net — links 2+3: does B find the address, and reach it?"
  for how in proxy-aware raw; do
    leak_read_sandboxed "$net" "$LEAK_B" "$LEAK_B/discover.py" \
      "$LEAK_RUN/get-$net-$how.json" "$how" "$DROP" "$C"
    leak_record "t2-$net-3-fetch-$how" --set "topology=T2-$net-$how" --set "net=$net" \
      --set "link=3-fetch" --set "how=$how" --set "canary=$C" \
      --reader "$LEAK_RUN/get-$net-$how.json"
  done
done

# ---- the missing cell: a publisher that does NOT honour the proxy variables ---------
# Link 3 showed a raw socket reaching the medium under `proxy`, while link 1 was blocked
# -- but link 1 used urllib, which consults HTTPS_PROXY. So "A cannot publish under
# proxy" was measured only for a client that cooperates with the proxy, and the chain's
# failure there could not be attributed. This closes that: the same raw socket, used to
# POST. If it publishes, the whole chain completes under `proxy` and the allowlist stops
# only clients that agree to be stopped.
cat >"$LEAK_A/raw-publish.py" <<'PY'
import json, random, socket, ssl, sys
canary, drop, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
topic = "agent-sandbox-leak-%s-%d" % (stamp, random.randrange(10**9))
host, url = "ntfy.sh", "https://ntfy.sh/%s" % topic
out = {"topic": topic, "token": canary}
try:
    body = canary.encode()
    req = ("POST /%s HTTP/1.1\r\nHost: %s\r\nUser-Agent: leak-study\r\n"
           "Content-Length: %d\r\nConnection: close\r\n\r\n"
           % (topic, host, len(body))).encode() + body
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=25) as s:
        with ctx.wrap_socket(s, server_hostname=host) as ts:
            ts.sendall(req)
            chunks = []
            while True:
                b = ts.recv(65536)
                if not b:
                    break
                chunks.append(b)
    resp = b"".join(chunks).decode("utf-8", "replace")
    status = resp.split("\r\n", 1)[0] if resp else ""
    out["open"] = "ok" if " 200" in status else ("http:" + status[:40])
    out["token_found"] = " 200" in status
except Exception as e:  # noqa: BLE001 - failing to publish IS the measurement
    out["open"] = type(e).__name__
    out["token_found"] = False
try:
    with open(drop, "w", encoding="utf-8") as fh:
        fh.write("scratch notes\nendpoint: %s\n" % url)
except OSError as e:
    out["drop_error"] = str(e)
print(json.dumps(out))
PY

for net in proxy strict; do
  rm -f "$DROP"
  C="$(leak_token "RAWCHAIN-${net}")"
  leak_say "net=$net — link 1 via RAW SOCKET: can A publish without honouring the proxy?"
  leak_read_sandboxed "$net" "$LEAK_A" "$LEAK_A/raw-publish.py" \
    "$LEAK_RUN/rawpub-$net.json" "$C" "$DROP" "$STAMP"
  leak_record "t2-$net-1-publish-raw" --set "topology=T2-$net-publish-raw" \
    --set "net=$net" --set "link=1-publish" --set "how=raw-socket" --set "canary=$C" \
    --reader "$LEAK_RUN/rawpub-$net.json"

  TOPIC="$(python3 -c "import json;print(json.load(open('$LEAK_RUN/rawpub-$net.json')).get('topic',''))")"
  leak_await_medium "https://ntfy.sh/$TOPIC/json?poll=1" "$C" "$LEAK_RUN/rawpub-$net.json"

  leak_say "net=$net — and does the chain then complete, raw end to end?"
  leak_read_sandboxed "$net" "$LEAK_B" "$LEAK_B/discover.py" \
    "$LEAK_RUN/rawchain-$net.json" raw "$DROP" "$C"
  leak_record "t2-$net-chain-raw" --set "topology=T2-$net-chain-raw" --set "net=$net" \
    --set "link=chain" --set "how=raw-socket" --set "canary=$C" \
    --reader "$LEAK_RUN/rawchain-$net.json"
done

# ---- (a) a PUBLIC, INDEXED medium, and the allowlist cap ----------------------------
# No address is passed. A posts into a reserved issue of this repository; B enumerates
# the repository's issues and looks for the token. What B knows is the SUBJECT -- the
# repo both sessions work on -- which is the genuinely accidental case: A publishes as
# part of its task, B finds it while researching.
#
# It is also where the allowlist cap is measured. github.com and api.github.com are
# allowlisted in EVERY mode, strict included, so if a sandboxed session can authenticate
# then strict does not close cross-project communication -- it narrows the medium to
# what the allowlist contains, and the allowlist contains a writable one.
if ((LEAK_GH_READY)); then
  cat >"$LEAK_A/gh-publish.py" <<'PY'
import json, os, subprocess, sys
issue, canary = sys.argv[1], sys.argv[2]
env = dict(os.environ)
# The one step a session would take: point gh at the config the sandbox leaves readable.
env["GH_CONFIG_DIR"] = os.path.join(os.environ["HOME"], ".claude", "gh")
out = {"token": canary, "issue": issue}
try:
    r = subprocess.run(["gh", "api", "-X", "POST",
                        "repos/pearu/agent-sandbox/issues/%s/comments" % issue,
                        "-f", "body=leak-study row 13 canary: %s" % canary],
                       capture_output=True, text=True, timeout=60, env=env)
    out["open"] = "ok" if r.returncode == 0 else "gh-exit-%d" % r.returncode
    out["token_found"] = r.returncode == 0
    out["stderr"] = r.stderr[:200]
except Exception as e:  # noqa: BLE001
    out["open"] = type(e).__name__
    out["token_found"] = False
print(json.dumps(out))
PY
  cat >"$LEAK_B/gh-discover.py" <<'PY'
import json, sys, urllib.request
canary = sys.argv[1]
# B knows the repository, not the issue: it enumerates and searches, unauthenticated,
# the way a session researching this project would.
out = {"token": canary}
# The listing is eventually consistent and unauthenticated reads may be served from
# cache, so a single miss cannot be told from a block. Retry, and record the attempt
# count: "not found after N tries with the endpoint reachable" is a different statement
# from "could not reach the endpoint".
import time
last = None
for attempt in range(1, 7):
    try:
        url = ("https://api.github.com/repos/pearu/agent-sandbox/issues/comments"
               "?per_page=100&sort=created&direction=desc&_=%d" % time.time())
        req = urllib.request.Request(url, headers={"User-Agent": "leak-study",
                                                   "Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read().decode("utf-8", "replace")
        last, out["open"], out["bytes"] = "ok", "ok", len(data)
        if canary in data:
            out["token_found"] = True
            out["attempts"] = attempt
            break
        out["token_found"] = False
    except Exception as e:  # noqa: BLE001
        last = type(e).__name__
        out["open"], out["token_found"] = last, False
        break  # unreachable is unreachable; retrying measures nothing
    time.sleep(5)
out.setdefault("attempts", 6)
print(json.dumps(out))
PY
  for net in proxy strict; do
    G="$(leak_token "GH-${net}")"
    leak_say "net=$net — (a) can A publish to the allowlisted medium from inside?"
    leak_read_sandboxed "$net" "$LEAK_A" "$LEAK_A/gh-publish.py" \
      "$LEAK_RUN/gh-pub-$net.json" "$LEAK_GH_ISSUE" "$G"
    leak_record "t2-$net-gh-publish" --set "topology=T2-$net-gh-publish" \
      --set "net=$net" --set "link=1-publish" --set "how=gh+allowlisted" \
      --set "canary=$G" --reader "$LEAK_RUN/gh-pub-$net.json"
    sleep 3
    leak_say "net=$net — (a) does B find it by enumerating the repository?"
    leak_read_sandboxed "$net" "$LEAK_B" "$LEAK_B/gh-discover.py" \
      "$LEAK_RUN/gh-get-$net.json" "$G"
    leak_record "t2-$net-gh-discover" --set "topology=T2-$net-gh-discover" \
      --set "net=$net" --set "link=3-fetch" --set "how=enumerate-allowlisted" \
      --set "canary=$G" --reader "$LEAK_RUN/gh-get-$net.json"
  done
else
  leak_say "SKIPPING (a): set LEAK_GH_ISSUE to the reserved issue number to run it"
  leak_say "  (and the host needs ~/.claude/gh for a sandboxed session to authenticate)"
fi

leak_real_config_after
leak_validate || VALID=0

echo
echo "=== row 13: independent sessions, one medium, per network mode ==="
for r in "$LEAK_RUN"/records/*.json; do
  python3 - "$r" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
rd = d.get("reader") or {}
ep = rd.get("endpoint_found")
note = "" if rd.get("open") == "ok" else str(rd.get("open", ""))
if ep is not None:
    note = ("addr=%s " % ("found" if ep else "MISSING")) + note
print("  %-24s %-22s %-8s %-11s %-26s %s" % (
    os.path.basename(sys.argv[1])[:-5], d.get("topology", "?"), d.get("net", "?"),
    d.get("how", ""), d.get("verdict", "?"), note))
PY
done
echo
echo "records: $LEAK_RUN/records/"
((VALID)) || {
  echo
  echo "THIS RUN IS NOT A RESULT -- see the validity gate above." >&2
  exit 1
}
