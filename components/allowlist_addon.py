"""
mitmproxy addon for agent-sandbox — host allowlist enforcement.

Reads ~/.config/agent-sandbox/allowlist.txt on every request and lets
through only hosts that match. Lines are exact hostnames; a leading dot
(".github.com") makes the line match the host AND its subdomains.

Per-session additions (`agent-sandbox --allow HOST`) are read from
<session base>/session.*/allow.txt, where <session base> is
$AGENT_SANDBOX_SESSION_BASE, else $XDG_RUNTIME_DIR/agent-sandbox.<uid>,
else /tmp/agent-sandbox.<uid> -- the same rule the engine uses. A session's
allow.txt is honoured only while the process stamped in its owner.id
("<pid> <start-time>") is alive, so a session that dies without cleaning up
cannot leave a host open, and a recycled PID is never mistaken for the
owner. Note the proxy is shared: while a session lives, its --allow hosts
are reachable from every concurrent session.

Blocked requests return HTTP 403 and are logged to
~/.config/agent-sandbox/blocked.log (one line per attempt) so you can
review what the agent tried to reach and decide whether to add it.

Per-session --allow is scoped to its own session, not shared: the engine gives
each session that uses --allow a random token, points that sandbox's proxy URL
at http://<token>@127.0.0.1:8888, and stores the token in the session dir. A
request carries the token in its Proxy-Authorization header (on CONNECT for
HTTPS, on each request for plain HTTP); the addon maps it back to the one live
session and applies the global allowlist plus ONLY that session's --allow. A
request with another session's token, or none, gets the global allowlist only,
so one session's --allow is never reachable from another. The global
allowlist.txt still applies to everyone.

No restart needed when editing the allowlist; the file is re-read on
each request.

HTTPS is refused at the CONNECT stage for hosts not in the allowlist, so a
blocked host never sees a connection from this machine (mitmproxy would
otherwise open a TCP+TLS connection to it, to mirror its certificate, before
the inner request could be checked). The client sees "CONNECT tunnel
failed, response 403"; blocked.log records the host with method CONNECT.
Requests inside an allowed tunnel are still checked per request, so paths
are logged and a Host header naming another host is refused.

Response bodies are streamed to the client as they arrive instead of being
buffered to completion (mitmproxy's default), and the systemd unit runs
mitmdump with http2=false. Together these take downloads and streaming LLM
replies from ~1 MB/s with the first byte at the very end to near-native
speed. Nothing here inspects response bodies, so streaming costs nothing;
every allowlist decision is made before a body flows.
"""

from __future__ import annotations

import base64
import datetime
import logging
import os
from pathlib import Path

from mitmproxy import http


CONFIG_DIR = Path.home() / ".config" / "agent-sandbox"
ALLOWLIST_PATH = CONFIG_DIR / "allowlist.txt"
BLOCKED_LOG_PATH = CONFIG_DIR / "blocked.log"

logger = logging.getLogger(__name__)


def _session_base() -> Path:
    override = os.environ.get("AGENT_SANDBOX_SESSION_BASE")
    if override:
        return Path(override)
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
    # Match the engine's _as_session_base: it falls back to /tmp when the runtime
    # dir is not a writable directory, so require writability here too, or the
    # addon would look in a different base and silently ignore --allow.
    if not (runtime.is_dir() and os.access(runtime, os.W_OK)):
        runtime = Path("/tmp")
    return runtime / f"agent-sandbox.{os.getuid()}"


SESSION_BASE = _session_base()


def _owner_alive(owner_file: Path) -> bool:
    """True iff the process stamped in owner.id ("<pid> <start-time>") still runs.

    The start-time (field 22 of /proc/<pid>/stat) is compared too, so a
    recycled PID is never mistaken for the original owner.
    """
    try:
        pid, start = owner_file.read_text().split()[:2]
        stat = Path(f"/proc/{int(pid)}/stat").read_text()
    except (OSError, ValueError):
        return False
    fields = stat.rsplit(")", 1)[1].split()  # fields after "(comm)"; [0] is field 3
    return len(fields) > 19 and fields[19] == start


# CONNECT establishes an HTTPS tunnel; the token rides its Proxy-Authorization
# header, but the requests inside the tunnel do not resend it. Remember, per
# client connection, the token seen at CONNECT so those inner requests inherit
# it. Bounded by concurrent client connections; entries are dropped on disconnect.
_conn_token: dict[str, str] = {}


def _token_from(flow: http.HTTPFlow) -> str | None:
    """The session token in a request's Proxy-Authorization (Basic <b64 token:>),
    or None. The username field is the token; the password is unused."""
    try:
        auth = flow.request.headers.get("Proxy-Authorization")
    except Exception:
        return None
    if not auth or not auth.lower().startswith("basic "):
        return None
    try:
        user = base64.b64decode(auth.split(" ", 1)[1]).decode().split(":", 1)[0]
    except Exception:
        return None
    return user or None


def _strip_proxy_auth(flow: http.HTTPFlow) -> None:
    """Never forward the session token upstream."""
    try:
        if "Proxy-Authorization" in flow.request.headers:
            del flow.request.headers["Proxy-Authorization"]
    except Exception:
        pass


def _session_allow(token: str | None) -> list[str]:
    """--allow lines of the single live session whose proxy.token matches `token`.
    No token, or no live match, means no per-session grants (global list only), so
    one session's --allow is never visible to another."""
    if not token or not SESSION_BASE.is_dir():
        return []
    for session in sorted(SESSION_BASE.glob("session.*")):
        tok, allow, owner = session / "proxy.token", session / "allow.txt", session / "owner.id"
        try:
            if (
                tok.is_file()
                and allow.is_file()
                and owner.is_file()
                and tok.read_text().strip() == token
                and _owner_alive(owner)
            ):
                return allow.read_text().splitlines()
        except OSError:
            continue
    return []


def _parse(lines: list[str], exact: set[str], suffix: list[str]) -> None:
    """Add allowlist lines to (exact_hosts, suffix_patterns).

    A line "github.com" matches only "github.com".
    A line ".github.com" matches "github.com" and "*.github.com".
    """
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("."):
            exact.add(line[1:])
            suffix.append(line)
        else:
            exact.add(line)


def _load_allowlist(token: str | None = None) -> tuple[set[str], list[str]]:
    exact: set[str] = set()
    suffix: list[str] = []
    if ALLOWLIST_PATH.exists():
        _parse(ALLOWLIST_PATH.read_text().splitlines(), exact, suffix)
    _parse(_session_allow(token), exact, suffix)
    return exact, suffix


def _is_allowed(host: str, exact: set[str], suffix: list[str]) -> bool:
    if host in exact:
        return True
    return any(host.endswith(s) for s in suffix)


def _log_blocked(host: str, method: str, path: str) -> None:
    BLOCKED_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now().isoformat(timespec="seconds")
    with BLOCKED_LOG_PATH.open("a") as fh:
        fh.write(f"{ts}\t{host}\t{method}\t{path}\n")


def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    token = _token_from(flow)
    if token is None:  # inner request of an HTTPS tunnel: inherit the CONNECT's token
        cid = getattr(getattr(flow, "client_conn", None), "id", None)
        token = _conn_token.get(cid) if cid is not None else None
    _strip_proxy_auth(flow)
    exact, suffix = _load_allowlist(token)
    if _is_allowed(host, exact, suffix):
        return
    _log_blocked(host, flow.request.method, flow.request.path)
    flow.response = http.Response.make(
        403,
        (
            f"agent-sandbox: host {host!r} is not in the allowlist.\n"
            f"To allow it, add a line to {ALLOWLIST_PATH}:\n"
            f"    {host}        (exact)\n"
            f"    .{host}       (and all subdomains)\n"
            f"or relaunch with:  --allow {host}   (this session only)\n"
        ).encode(),
        {"Content-Type": "text/plain; charset=utf-8"},
    )


def client_disconnected(client) -> None:
    _conn_token.pop(getattr(client, "id", None), None)


def http_connect(flow: http.HTTPFlow) -> None:
    """Refuse CONNECT to a non-allowed host before any upstream connection."""
    host = flow.request.host
    token = _token_from(flow)
    cid = getattr(getattr(flow, "client_conn", None), "id", None)
    if cid is not None and token:
        _conn_token[cid] = token  # inner tunnel requests inherit this
    _strip_proxy_auth(flow)
    exact, suffix = _load_allowlist(token)
    if _is_allowed(host, exact, suffix):
        return
    _log_blocked(host, "CONNECT", "-")
    flow.response = http.Response.make(
        403,
        f"agent-sandbox: host {host!r} is not in the allowlist.\n".encode(),
        {"Content-Type": "text/plain; charset=utf-8"},
    )


def responseheaders(flow: http.HTTPFlow) -> None:
    flow.response.stream = True
