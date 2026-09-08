"""Load components/allowlist_addon.py with its config redirected, run one
scenario named on the command line, print results as key=value lines.

usage: addon_driver.py ADDON CONFIG_DIR SCENARIO [args...]
The mitmproxy stub must be importable as `mitmproxy.http` (PYTHONPATH)."""
import base64
import importlib.util
import os
import sys
from pathlib import Path

addon_path, config_dir, scenario, *args = sys.argv[1:]
spec = importlib.util.spec_from_file_location("addon", addon_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.CONFIG_DIR = Path(config_dir)
m.ALLOWLIST_PATH = m.CONFIG_DIR / "allowlist.txt"
m.BLOCKED_LOG_PATH = m.CONFIG_DIR / "blocked.log"


class Conn:
    def __init__(self, cid):
        self.id = cid


class Req:
    def __init__(self, host, method="GET", path="/", headers=None):
        self.pretty_host = host
        self.host = host
        self.method = method
        self.path = path
        self.headers = headers if headers is not None else {}


class Flow:
    def __init__(self, host, method="GET", path="/", headers=None, cid="c1"):
        self.request = Req(host, method, path, headers)
        self.response = None
        self.client_conn = Conn(cid)


def _auth(token):
    if not token or token == "none":
        return {}
    return {"Proxy-Authorization": "Basic " + base64.b64encode(f"{token}:".encode()).decode()}


def show(**kv):
    for k, v in kv.items():
        print(f"{k}={v}")


if scenario == "parse":
    exact, suffix = m._load_allowlist()
    show(exact=",".join(sorted(exact)), suffix=",".join(suffix))
elif scenario == "allowed":
    exact, suffix = m._load_allowlist()
    for h in args:
        show(**{h: m._is_allowed(h, exact, suffix)})
elif scenario == "owner_alive":
    show(alive=m._owner_alive(Path(args[0])))
elif scenario == "session_allow":
    show(lines="|".join(m._session_allow(args[0] if args else None)))
elif scenario == "allowed_tok":
    exact, suffix = m._load_allowlist(args[0])
    for h in args[1:]:
        show(**{h: m._is_allowed(h, exact, suffix)})
elif scenario == "connect_tok":
    f = Flow(args[1], "CONNECT", "-", _auth(args[0]))
    m.http_connect(f)
    show(blocked=f.response is not None, status=getattr(f.response, "status_code", None))
elif scenario == "tunnel_tok":
    # CONNECT carries the token; the inner request does not, and must inherit it.
    c = Flow(args[1], "CONNECT", "-", _auth(args[0]), cid="tc")
    m.http_connect(c)
    r = Flow(args[2], "GET", "/", {}, cid="tc")
    m.request(r)
    show(connect_blocked=c.response is not None, request_blocked=r.response is not None)
elif scenario == "disconnect_tok":
    # CONNECT stashes the token for the tunnel; after the client disconnects the
    # stash is dropped, so a later request on that conn id is untagged (blocked).
    c = Flow(args[1], "CONNECT", "-", _auth(args[0]), cid="dc")
    m.http_connect(c)
    m.client_disconnected(Conn("dc"))
    r = Flow(args[1], "GET", "/", {}, cid="dc")
    m.request(r)
    show(after_disconnect_blocked=r.response is not None)
elif scenario == "connect_badauth":
    # A malformed Proxy-Authorization is ignored (treated as no token).
    f = Flow(args[0], "CONNECT", "-", {"Proxy-Authorization": "garbage not-base64"})
    m.http_connect(f)
    show(blocked=f.response is not None)
elif scenario == "request":
    f = Flow(args[0], args[1] if len(args) > 1 else "GET", args[2] if len(args) > 2 else "/")
    m.request(f)
    show(blocked=f.response is not None,
         status=getattr(f.response, "status_code", None),
         body=(f.response.content.decode() if f.response else "").splitlines()[0] if f.response else "")
elif scenario == "connect":
    f = Flow(args[0], "CONNECT", "-")
    m.http_connect(f)
    show(blocked=f.response is not None, status=getattr(f.response, "status_code", None))
elif scenario == "responseheaders":
    f = Flow("x")
    f.response = m.http.Response.make(200, b"", {"content-type": args[0] if args else "text/plain"})
    m.responseheaders(f)
    show(stream=f.response.stream)
else:
    sys.exit(f"unknown scenario {scenario}")
