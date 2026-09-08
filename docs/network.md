# Network modes and the egress allowlist

Every sandbox starts with the network unshared; the mode selected by
`AGENT_SANDBOX_NET` decides what is re-introduced.

| Mode | What the sandbox gets | Use |
|---|---|---|
| `proxy` (default) | The host network namespace (`--share-net`) plus `HTTPS_PROXY`/`HTTP_PROXY` pointing at the host proxy on `127.0.0.1:8888`, and the proxy CA trusted inside. Every client that honours the proxy variables is filtered by the allowlist. | everyday work |
| `strict` | Its own network namespace, owned by `pasta` and forwarded to the host in userspace; an nftables rule inside allows only the proxy on the default gateway. Closes the raw-socket loophole (a tool ignoring the proxy variables has no route out) and blocks localhost/LAN: pasta's port forwarding is off in both directions, so no host loopback service is mirrored into the sandbox and no sandbox listener is published on the host. Needs the `passt` package and its AppArmor profile (`install.sh` adds it) and nftables; `--ssh` does not work in this mode. | the network closed to everything but the proxy |
| `open` | The host network, no proxy. | debugging only |
| `none` | No network. | offline work |

In `proxy` mode a tool that bypasses the proxy variables (raw sockets, its own
resolver) is **not** filtered and can reach localhost and the LAN; `strict` mode
closes that (at the cost of `--ssh` and a `passt` dependency). See the residual
risks in [design.md](design.md) and issue #1.

## The proxy

`install.sh` puts mitmproxy 12 or newer into a private environment under
`~/.local/share/agent-sandbox` (a Python venv when `python3 >= 3.12` with
`venv` is available, else a conda/mamba env) and runs it as the systemd user
service `agent-sandbox-mitmproxy.service`:

```
mitmdump --listen-host 127.0.0.1 --listen-port 8888 --set block_global=false \
         --set termlog_verbosity=info --set flow_detail=0 --set http2=false \
         -s ~/.config/agent-sandbox/allowlist_addon.py
```

Distro packages are too old: Ubuntu 24.04 and 26.04 ship mitmproxy 8.1.1,
whose leaf certificates lack an Authority Key Identifier, and Python 3.13+
rejects those under its default strict verification.

`http2=false` and the addon's response streaming are performance settings.
mitmproxy buffers response bodies by default and its HTTP/2 path is pure
Python; together they made every download crawl at about 1 MB/s with the first
byte arriving only at the end, which also tripped streaming API clients' first
byte timeouts. With both changed the proxy runs at near-native speed (measured
50 to 74 MB/s on a 27 MB file, against 63 MB/s direct). Do **not** use
mitmproxy's `stream_large_bodies` instead: it streams request bodies too, and
then the allowlist hook runs after the upstream connection is made.

## The allowlist

`~/.config/agent-sandbox/allowlist.txt`, one host per line; `#` starts a
comment; a leading dot (`.github.com`) matches the domain and its subdomains.
It is re-read on every request; edits take effect immediately.

`install.sh` writes a generic starter list once (never overwriting your edits)
and then appends each installed profile's seed hosts (`profiles/<name>.allowlist`)
that are missing. The claude profile seeds `api.anthropic.com`,
`.anthropic.com`, `statsigapi.net`, `.statsig.com`.

Enforcement happens twice:

1. **At CONNECT**, for HTTPS. A non-allowed host is refused before any upstream
   connection, so a blocked host never sees a handshake from your machine. The
   client sees `CONNECT tunnel failed, response 403`.
2. **Per request**, inside an allowed tunnel and for plain HTTP. This keeps
   per-path logging and refuses a `Host` header naming another host.

Refusals are appended to `~/.config/agent-sandbox/blocked.log` as
`timestamp  host  method  path`; `tail -f` it to see what the agent is reaching
for and add hosts as needed.

## Per-session hosts: `--allow`

```
claude --allow pypi.org --allow .example.org
```

opens those hosts for this session only, on top of the global allowlist. The
engine writes them to the session directory; the addon honours the file only
while the process stamped in `owner.id` (PID and start time) is alive, so a
session that dies without cleaning up cannot leave a host open, and a recycled
PID is never mistaken for the owner. The flag is ignored, with a note, in the
`open` and `none` modes. Because the proxy is shared, a host allowed by one
session is reachable from every concurrent session while that session lives.

## The proxy CA

mitmproxy writes its CA to `~/.mitmproxy/` on first start (`install.sh` does
this). It is **not** installed into the host's trust store. In the `proxy` and
`strict` modes the engine builds `(system bundle + proxy CA)` under the session
base and bind-mounts it over `/etc/ssl/certs/ca-certificates.crt` inside the
sandbox, so everything in there trusts the proxy and nothing on the host does.
It also points the CA variables of tools that ship their own store at that
path: `SSL_CERT_FILE`, `SSL_CERT_DIR`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`,
`CONDA_SSL_VERIFY`, `PIP_CERT`, `GIT_SSL_CAINFO`, `NODE_EXTRA_CA_CERTS`,
`NPM_CONFIG_CAFILE`, `CARGO_HTTP_CAINFO`, unless you set them yourself. A tool
with yet another knob needs it forwarded via `AGENT_SANDBOX_PASSENV`.
`AGENT_SANDBOX_PROXY_CA` overrides the CA's location; a missing CA is a warning
at launch. Do not change the host's CA state while a session runs; relaunch.

## One-time host setup

`install.sh` does all of it: the proxy environment, the CA, the addon, the
allowlist, the unit, and starting the service. Afterwards:

```
systemctl --user status agent-sandbox-mitmproxy
tail -f ~/.config/agent-sandbox/blocked.log
```

Inside a sandboxed session, in `proxy` mode:

```
curl -sI https://api.anthropic.com    # allowed
curl -sI https://example.com          # CONNECT tunnel failed, response 403
```

## Per-project allow hosts

Instead of passing `--allow` each time, a project can list hosts in an
`[allow]` section of its `.agent-sandbox` file, one per line, which applies to
every session run from that project once you approve the file with
`claude --trust`. Same
rules as `--allow`, same per-session lifetime. See [config.md](config.md).
