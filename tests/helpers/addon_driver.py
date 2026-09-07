"""Load components/allowlist_addon.py with its config redirected, run one
scenario named on the command line, print results as key=value lines.

usage: addon_driver.py ADDON CONFIG_DIR SCENARIO [args...]
The mitmproxy stub must be importable as `mitmproxy.http` (PYTHONPATH)."""
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


class Req:
    def __init__(self, host, method="GET", path="/"):
        self.pretty_host = host
        self.host = host
        self.method = method
        self.path = path


class Flow:
    def __init__(self, host, method="GET", path="/"):
        self.request = Req(host, method, path)
        self.response = None


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
elif scenario == "session_lines":
    show(lines="|".join(m._session_lines()))
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
