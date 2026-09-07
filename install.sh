#!/usr/bin/env bash
# install.sh — per-host setup for agent-sandbox.
#
# Idempotent: safe to run multiple times. Skips steps that are already
# done; only invokes sudo for the few system-level steps (AppArmor
# profile, CA trust) that require it.
#
# Usage:
#   1. Clone the repository (or copy this file, agent-sandbox and
#      profiles/ together) to the new host.
#   2. ./install.sh
#
# Embeds the canonical mitmproxy addon, starter allowlist, and systemd
# user unit so nothing else needs to be carried across hosts. The
# allowlist is only written if it doesn't already exist (so re-runs
# preserve your customizations).

set -euo pipefail

# ----- locations -----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENGINE="$SCRIPT_DIR/agent-sandbox"
CONFIG_DIR="$HOME/.config/agent-sandbox"
SYSTEMD_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"

# ----- pretty output -----
if [[ -t 1 ]] && command -v tput >/dev/null; then
  C_BOLD=$(tput bold) C_DIM=$(tput dim) C_RED=$(tput setaf 1)
  C_GREEN=$(tput setaf 2) C_YELLOW=$(tput setaf 3) C_BLUE=$(tput setaf 4)
  C_RESET=$(tput sgr0)
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_RESET=""
fi
section() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()      { printf '    %s[ok]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '    %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()     { printf '    %s[err]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
info()    { printf '    %s%s%s\n'        "$C_DIM"    "$*"        "$C_RESET"; }

# ----- 1. sanity -----
section "Sanity check"
[[ -f "$ENGINE" ]] || err "agent-sandbox engine not found at $ENGINE (keep it next to this installer)"
[[ -f "$SCRIPT_DIR/profiles/claude.sh" ]] || err "claude profile not found at $SCRIPT_DIR/profiles/claude.sh"
ok "found $ENGINE"

# ----- 2. packages -----
section "Packages"
missing=()
command -v bwrap     >/dev/null || missing+=(bubblewrap)
command -v mitmdump  >/dev/null || missing+=(mitmproxy)
if (( ${#missing[@]} > 0 )); then
  err "Missing required packages: ${missing[*]}. Run: sudo apt install ${missing[*]}"
fi
ok "bwrap installed:    $(bwrap --version 2>/dev/null || echo unknown)"
ok "mitmdump installed: $(mitmdump --version 2>/dev/null | head -1)"
if command -v slirp4netns >/dev/null; then
  ok "slirp4netns installed (enables AGENT_SANDBOX_NET=strict in the future)"
else
  info "slirp4netns not installed; only needed for the (currently non-functional) strict mode"
fi

# ----- 3. claude itself -----
section "Claude Code installation"
versions_dir="$HOME/.local/share/claude/versions"
if [[ ! -d "$versions_dir" ]]; then
  warn "No installation found at $versions_dir"
  info "Install Claude Code first (https://docs.anthropic.com/claude-code), then re-run."
else
  latest=$(
    find "$versions_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d -o -type l \) \
         -printf '%f\n' 2>/dev/null | sort -V | tail -n1
  )
  if [[ -n "${latest:-}" ]]; then
    ok "latest version: $latest"
  else
    warn "$versions_dir exists but is empty"
  fi
fi

# ----- 4. AppArmor profile (Ubuntu 24.04+) -----
section "AppArmor profile for bwrap"
restrict_flag=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
if [[ -e "$restrict_flag" ]] && [[ "$(cat "$restrict_flag")" == "1" ]]; then
  if [[ -f /etc/apparmor.d/bwrap ]]; then
    ok "/etc/apparmor.d/bwrap already present"
  else
    info "Installing AppArmor profile (requires sudo)"
    sudo tee /etc/apparmor.d/bwrap >/dev/null <<'AAEOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
AAEOF
    sudo apparmor_parser -r /etc/apparmor.d/bwrap
    ok "AppArmor profile installed and loaded"
  fi
else
  ok "kernel does not restrict unprivileged userns; no profile needed"
fi

# ----- 5. mitmproxy CA -----
section "mitmproxy CA cert"
ca_in_store=/usr/local/share/ca-certificates/mitmproxy.crt
if [[ -f "$ca_in_store" ]]; then
  ok "CA already in system store"
else
  ca_src=""
  for cand in "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" \
              "$HOME/.mitmproxy/mitmproxy-ca-cert.cer"; do
    [[ -f "$cand" ]] && { ca_src="$cand"; break; }
  done
  if [[ -z "$ca_src" ]]; then
    info "Generating mitmproxy CA (one-time)"
    # Run mitmdump briefly to create ~/.mitmproxy with the CA.
    mitmdump --listen-port 0 >/dev/null 2>&1 &
    _mp_pid=$!
    for _ in 1 2 3 4 5 6 7 8; do
      sleep 0.5
      for cand in "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" \
                  "$HOME/.mitmproxy/mitmproxy-ca-cert.cer"; do
        [[ -f "$cand" ]] && { ca_src="$cand"; break 2; }
      done
    done
    kill "$_mp_pid" 2>/dev/null
    wait "$_mp_pid" 2>/dev/null || true
  fi
  [[ -n "$ca_src" ]] || err "Could not find or generate ~/.mitmproxy/mitmproxy-ca-cert.{pem,cer}"
  info "Installing CA into system store (requires sudo)"
  sudo cp "$ca_src" "$ca_in_store"
  sudo update-ca-certificates
  ok "CA installed and trusted"
fi

# ----- 6. config files -----
section "Config files"
# Migrate the pre-rename config dir if present (keeps your allowlist edits).
if [[ -d "$HOME/.config/claude-sandbox" && ! -e "$CONFIG_DIR" ]]; then
  mv "$HOME/.config/claude-sandbox" "$CONFIG_DIR"
  ok "migrated ~/.config/claude-sandbox -> $CONFIG_DIR"
fi
mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"

# 6a. allowlist_addon.py (static content; safe to overwrite on every run)
cat >"$CONFIG_DIR/allowlist_addon.py" <<'ADDON_EOF'
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
    if not runtime.is_dir():
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
ADDON_EOF
ok "wrote $CONFIG_DIR/allowlist_addon.py"

# 6b. allowlist.txt (customizable; only write if it doesn't already exist)
if [[ -f "$CONFIG_DIR/allowlist.txt" ]]; then
  ok "$CONFIG_DIR/allowlist.txt already exists (kept as-is)"
else
  cat >"$CONFIG_DIR/allowlist.txt" <<'ALLOW_EOF'
# agent-sandbox allowlist
#
# One hostname per line. Lines starting with "#" are comments.
# A leading dot (".github.com") matches the host AND its subdomains.
# Edits take effect immediately — no restart needed.
#
# Blocked requests are logged to ~/.config/agent-sandbox/blocked.log;
# tail it (`tail -f ~/.config/agent-sandbox/blocked.log`) to see what
# the agent is trying to reach and add hosts here as needed.

# ---- Anthropic ----
api.anthropic.com
.anthropic.com
statsigapi.net
.statsig.com

# ---- Git / code hosting ----
github.com
api.github.com
codeload.github.com
objects.githubusercontent.com
raw.githubusercontent.com
.githubusercontent.com

# ---- Python packaging ----
pypi.org
files.pythonhosted.org

# ---- Node packaging ----
registry.npmjs.org

# ---- Conda / mamba ----
conda.anaconda.org
repo.anaconda.com
.conda-forge.org

# ---- Rust ----
crates.io
static.crates.io

# ---- Add more below as you hit 403s ----
ALLOW_EOF
  ok "wrote starter $CONFIG_DIR/allowlist.txt"
fi

# 6c. systemd user unit (static; safe to overwrite)
cat >"$SYSTEMD_DIR/agent-sandbox-mitmproxy.service" <<UNIT_EOF
[Unit]
Description=mitmproxy enforcing allowlist for the agent sandbox
Documentation=file:$ENGINE
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# http2=false: mitmproxy's HTTP/2 path is pure Python and an order of magnitude
# slower than HTTP/1.1; with response streaming in the addon this is near-native.
ExecStart=/usr/bin/mitmdump \\
    --listen-host 127.0.0.1 \\
    --listen-port 8888 \\
    --set block_global=false \\
    --set termlog_verbosity=info \\
    --set flow_detail=0 \\
    --set http2=false \\
    -s %h/.config/agent-sandbox/allowlist_addon.py
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT_EOF
ok "wrote $SYSTEMD_DIR/agent-sandbox-mitmproxy.service"

# ----- 7. systemd: reload, enable, start -----
section "Systemd user service"
# Migrate off the pre-rename unit if present: it also binds 127.0.0.1:8888, so
# leaving it enabled would collide with agent-sandbox-mitmproxy.service.
if systemctl --user is-enabled claude-mitmproxy.service >/dev/null 2>&1 \
   || [[ -f "$SYSTEMD_DIR/claude-mitmproxy.service" ]]; then
  systemctl --user disable --now claude-mitmproxy.service >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/claude-mitmproxy.service"
  ok "migrated off legacy claude-mitmproxy.service"
fi
systemctl --user daemon-reload
systemctl --user enable agent-sandbox-mitmproxy.service >/dev/null 2>&1 || true
systemctl --user restart agent-sandbox-mitmproxy.service
sleep 1
if systemctl --user is-active --quiet agent-sandbox-mitmproxy.service; then
  ok "agent-sandbox-mitmproxy.service is active"
else
  warn "agent-sandbox-mitmproxy.service did not start; inspect: journalctl --user -u agent-sandbox-mitmproxy"
fi

# ----- 8. PATH symlink -----
section "PATH symlink (\$HOME/.local/bin/claude -> agent-sandbox)"
mkdir -p "$BIN_DIR"
link="$BIN_DIR/claude"
if [[ -L "$link" && "$(readlink -f "$link")" == "$ENGINE" ]]; then
  ok "symlink already pointing at $ENGINE"
elif [[ -L "$link" && "$(basename -- "$(readlink -f "$link")")" == claude.sh ]]; then
  ln -sfn "$ENGINE" "$link"
  ok "re-pointed $link from the legacy claude.sh wrapper -> $ENGINE"
elif [[ -e "$link" ]]; then
  warn "$link exists and is not the expected symlink (left untouched)"
  info "If it's the upstream Claude Code binary you no longer want, remove it and re-run."
else
  ln -s "$ENGINE" "$link"
  ok "symlinked $link -> $ENGINE"
fi

# Verify $HOME/.local/bin precedes any other claude on PATH. The engine
# infers the claude profile from the symlink name.
if command -v claude >/dev/null; then
  resolved=$(readlink -f "$(command -v claude)")
  if [[ "$resolved" == "$ENGINE" ]]; then
    ok "\`claude\` on PATH resolves to the agent-sandbox engine"
  else
    warn "\`claude\` on PATH resolves to $resolved (not our wrapper)"
    info "Ensure $BIN_DIR comes before other claude installations in PATH."
  fi
fi

# ----- 9. smoke test -----
section "Smoke tests"
if bwrap --ro-bind / / --unshare-user --unshare-pid -- /bin/true 2>/dev/null; then
  ok "bwrap can create user+pid namespaces"
else
  warn "bwrap user-namespace test failed — see the agent-sandbox header for AppArmor notes"
fi
if curl -fsS --proxy http://127.0.0.1:8888 -o /dev/null https://api.anthropic.com 2>/dev/null; then
  ok "mitmproxy reached api.anthropic.com (allowlist working)"
else
  warn "mitmproxy test request failed (might be transient; check 'systemctl --user status agent-sandbox-mitmproxy')"
fi

# ----- 10. summary -----
section "Done"
cat <<SUMMARY
Next steps:
  - Open a fresh shell (or \`hash -r\`) so the new \`claude\` is on PATH.
  - cd into a project and run \`claude\`.
  - Tail blocked requests:  tail -f $CONFIG_DIR/blocked.log
  - Edit the allowlist:     \$EDITOR $CONFIG_DIR/allowlist.txt
  - Bypass proxy one-shot:  AGENT_SANDBOX_NET=open claude
SUMMARY
