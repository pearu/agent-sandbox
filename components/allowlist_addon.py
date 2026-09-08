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


def _session_lines() -> list[str]:
    """Allowlist lines contributed by live sessions' --allow files."""
    lines: list[str] = []
    if not SESSION_BASE.is_dir():
        return lines
    for session in sorted(SESSION_BASE.glob("session.*")):
        allow, owner = session / "allow.txt", session / "owner.id"
        try:
            if allow.is_file() and owner.is_file() and _owner_alive(owner):
                lines.extend(allow.read_text().splitlines())
        except OSError:
            continue
    return lines


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


def _load_allowlist() -> tuple[set[str], list[str]]:
    exact: set[str] = set()
    suffix: list[str] = []
    if ALLOWLIST_PATH.exists():
        _parse(ALLOWLIST_PATH.read_text().splitlines(), exact, suffix)
    _parse(_session_lines(), exact, suffix)
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
    exact, suffix = _load_allowlist()
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


def http_connect(flow: http.HTTPFlow) -> None:
    """Refuse CONNECT to a non-allowed host before any upstream connection."""
    host = flow.request.host
    exact, suffix = _load_allowlist()
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
