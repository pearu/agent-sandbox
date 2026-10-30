# Network modes and the egress allowlist

Every sandbox starts with the network unshared; the mode selected by
`AGENT_SANDBOX_NET` (or, for a project, a trusted `.agent-sandbox` `[net]`
`mode = ...` line, which the shell's knob overrides) decides what is
re-introduced.

| Mode | What the sandbox gets | Use |
|---|---|---|
| `proxy` (default) | The host network namespace (`--share-net`) plus `HTTPS_PROXY`/`HTTP_PROXY` pointing at the host proxy on `127.0.0.1:8888`, and the proxy CA trusted inside. Every client that honours the proxy variables is filtered by the allowlist. | everyday work |
| `strict` | Its own network namespace, owned by `pasta` and forwarded to the host in userspace; an nftables rule inside allows only the proxy on the default gateway. Closes the raw-socket loophole (a tool ignoring the proxy variables has no route out) and blocks localhost/LAN: pasta's port forwarding is off in both directions, so no host loopback service is mirrored into the sandbox and no sandbox listener is published on the host. Needs the `passt` package and its AppArmor profile (`install.sh` adds it) and nftables. `--ssh HOST` works (a firewall pinhole to the host's resolved IPv4 and an `/etc/hosts` entry; `--ssh-unrestricted` is refused). | the network closed to everything but the proxy |
| `open` | The host network, no proxy. | debugging only |
| `none` | No network. | offline work |

In `proxy` mode a tool that bypasses the proxy variables (raw sockets, its own
resolver) is **not** filtered and can reach localhost and the LAN; `strict` mode
closes that (at the cost of `--ssh` and a `passt` dependency). See the residual
risks in [design.md](design.md) and issue #1.

## Strict mode: opening ports

`strict` switches off both directions of pasta's port forwarding: nothing
listening on the host is reachable from the sandbox, and nothing the agent
listens on appears on the host. Open exactly what a project needs:

| | Effect | Flag | Knob | `.agent-sandbox` |
|---|---|---|---|---|
| host port | the sandbox reaches the host's `127.0.0.1:PORT` (a database, a local model server) | `--host-port PORT` | `AGENT_SANDBOX_HOST_PORTS="PORT PORT"` | `[net]` `host-port = PORT` |
| agent port | a port the agent listens on is published at the host's `127.0.0.1:PORT` (a dev server you open in a browser) | `--agent-port PORT` | `AGENT_SANDBOX_AGENT_PORTS="PORT"` | `[net]` `agent-port = PORT` |

Rules: TCP only (UDP is not forwarded; open an issue if you need it). Ports
1024–65535; the engine refuses a system port rather than let pasta fail to bind
it. The three sources form a union; `none` in any
of them closes that direction for the session, whatever the others list.
Loopback on both sides, never the LAN. The engine prints what it opened at
launch. In `proxy` and `open` modes the sandbox already shares the host's
network, and `none` has no network, so the flags are noted and ignored there.

A host port is not an allowlist entry: it is a raw TCP path to that one host
service, which the proxy never sees. If that service forwards traffic (a SOCKS
proxy, a tunnel), the sandbox's egress control ends there.

## The proxy

`install.sh` puts mitmproxy 12 or newer into a private environment under
`~/.local/share/agent-sandbox` (a dedicated conda env when mamba/conda is
available, else a venv from a regular-build `python3 >= 3.12` with `venv`;
a broken environment is recreated on the next `install.sh`) and runs it as the systemd user
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

`install.sh` writes a generic starter list once (never overwriting your edits).
The hosts an agent itself needs are not in it: they are the `[allow]` of its
profile's dot-file (`profiles/<name>/agent-sandbox`), opened for every launch of
that profile as its session allowlist, beside `--allow`'s. The claude profile's are
`api.anthropic.com`, `.anthropic.com`, `platform.claude.com` (OAuth sign-in),
`statsigapi.net`, `.statsig.com`.

Enforcement happens twice:

1. **At CONNECT**, for HTTPS. A non-allowed host is refused before any upstream
   connection, so a blocked host never sees a handshake from your machine. The
   client sees `CONNECT tunnel failed, response 403`.
2. **Per request**, inside an allowed tunnel and for plain HTTP. This keeps
   per-path logging and refuses a `Host` header naming another host.

The allowlist gates **public** hosts only. Independently, the proxy refuses to
connect to any destination that resolves to a **non-public** address — loopback
(`127.0.0.0/8`, `::1`), private/LAN (`10/8`, `172.16/12`, `192.168/16`),
link-local including cloud metadata (`169.254.169.254`), and unique-local IPv6 —
even when the host *name* is on the allowlist. An allowlisted name that resolves
to such an address (an internal/LAN host, `localhost`, or a public name under
DNS rebinding) is refused with a `502` and a `DEST` line in the log; the proxy
runs on the host, so these are never legitimate egress targets. To reach a
host-local service from a sandbox, use `--host-port` in `strict` mode (above),
not the allowlist.

Refusals are appended to `~/.config/agent-sandbox/blocked.log` as
`timestamp  host  method  path`; `tail -f` it to see what the agent is reaching
for and add hosts as needed. The addon only appends, never rotates, so on a busy
allowlist the file grows without bound; if that matters, point `logrotate` at it
or truncate it between sessions (`: > ~/.config/agent-sandbox/blocked.log`). It
holds only refused destinations, no payloads.

## Refusals reach the session

A 403 in the middle of a command reads to an agent like an outage to route around:
another mirror, another channel, another tool. So the session is told, as it
happens. With the briefing on, the engine creates an empty `refused.log` in the
session directory and binds that one file read-only at
`/run/agent-sandbox/refused.log`; the addon appends each refusal attributed to the
session (by its proxy token) to it, as `timestamp  host  method  why`, where `why`
is `allowlist`, `[deny]`, `retrieve-only`, `git refuse`, `git push` or `non-public`
(the last for HTTPS only, through the tunnel's token). The claude profile's hook runs
after every Bash call, on `PostToolUse` and `PostToolUseFailure` (a broken command
usually exits nonzero), and takes the lines that are new since the previous call. It
reports them only after a command that failed (#304): a refusal during a command that
exited 0 did not affect the task, so on `PostToolUse` the hook counts those lines as
seen, never to be reported later, and says nothing. The rule is the same for every
reason. Every refusal is still in `refused.log` and `blocked.log`; only what the agent
is told mid-command changes. After a failed command it reports each new line once,
next to the command's result, as statements rather than instructions: the host was
refused, going on with a mirror, another channel or another tool for the same thing
is going on without it and is the user's decision, the user adds the host with
`asb --apply '[allow]' HOST` (`[allow:ROLE]` where the dot-file has role sections),
and the session continues without it only once the user has said so. A policy
refusal (`[deny]`, `retrieve-only`, git, `non-public`) says instead that `--apply`
does not lift it. Only the host, checked as a hostname, and a known reason reach
that text. A refusal of a host the agent reaches on its own, not for the command
(telemetry, error reports: the profile's `profile_telemetry_hosts`, which the engine
writes to `/run/agent-sandbox/telemetry-hosts`), is left out of the note: it is still
refused and still in `refused.log`, but it is no blocked action of the session's, and
reported beside a command's result the model took it for one (#276). `--check` says so in
one line under its network lines.

The same holds for the tools the sandbox ships, in the tools environment
([config.md](config.md#the-tools-environment)) (#304). The engine keeps a table of
those that send usage telemetry on their own, with the host and the tool's own
opt-out: for `gh`, `cafe.github.com` and `GH_TELEMETRY=false`. Each tool's host is
added to `telemetry-hosts` beside the agent's own, so a refusal of it is left out of
the note, and its variable is set under every preset but `native`, with
`DO_NOT_TRACK=1` for every tool that honours that convention; with them the tool
makes no such request at all. The entry is there whether the tool is installed or
not. `--check` says it in one line, `telemetry: gh's usage telemetry is off
(GH_TELEMETRY=false, DO_NOT_TRACK=1) and cafe.github.com is refused; opt in with an
[allow] line`. To have a tool's telemetry, allow its host with an ordinary `[allow]`
line, and forward the tool's variable with your value (`[env] GH_TELEMETRY`, with
`GH_TELEMETRY=true` in your shell): a forwarded value comes after the engine's and
wins.

Under `native` the variables are not set. `native` is parity of the sandbox's state
with `--preset none`, and its environment is every exported variable; what still
applies there is engine policy that protects the mechanism, such as the network mode
and `DISABLE_AUTOUPDATER`. A telemetry opt-out protects nothing in the mechanism: it
is a preference, and under `native` preferences are yours, so the values in your shell
pass with the rest. The host is still in `telemetry-hosts` and still refused where the
allowlist applies, and `--check` says that instead: `telemetry: gh's cafe.github.com
is refused and not reported; under native its usage telemetry is not turned off
(GH_TELEMETRY and DO_NOT_TRACK are your shell's)`.

`blocked.log` itself is never bound into a sandbox: it records every session of
every project, and a session must not learn what the others tried. Nor is the
session directory, which holds its proxy token. A refusal with no session (`407`)
is in `blocked.log` only.

## Per-session hosts: `--allow`

```
asb --allow pypi.org --allow .example.org claude
```

opens those hosts for this session only, on top of the global allowlist. The
engine writes them to the session directory; the addon honours the file only
while the process stamped in `owner.id` (PID and start time) is alive, so a
session that dies without cleaning up cannot leave a host open, and a recycled
PID is never mistaken for the owner. The flag is ignored, with a note, in the
`open` and `none` modes. `--allow` is scoped to the session that granted it:
the engine mints a per-session token, points that sandbox's proxy URL at
`http://<token>@127.0.0.1:8888`, and the proxy addon grants the global
allowlist plus only the matching session's `--allow`. A concurrent session
with a different token sees the global allowlist only, so one session's
`--allow` hosts are not reachable from another.

**The proxy serves sessions only.** Every proxied launch gets a token, and a request
that carries none -- or the token of a session that is no longer alive -- is answered
`407 Proxy Authentication Required` with a Basic challenge, on CONNECT and on plain
HTTP alike, and logged with `no session`. The token is what a session's `[deny]`,
`retrieve-only` and git refusal hang on, and a client without it would otherwise get
the global allowlist and escape all three: git's libcurl sends proxy credentials only
when challenged, and anything inside can read the proxy URL and drop them. With the
challenge, git sends the credentials it already holds (measured), and a client that
drops them reaches nothing. A host tool pointed at the proxy by hand is refused the
same way: the proxy is the sandboxes', not the host's.

## Per-session denial: `[deny]`

A dot-file's `[deny]`, or `[deny:<role>]` for some roles only (#221), takes hosts
out of what a session may reach: out of the global allowlist and out of its own
grant. The engine writes them beside the session's `--allow`, and the addon refuses
them for that session's token at CONNECT and per request, with a 403 that says the
host is denied rather than absent. Other sessions keep the global allowlist. A line
that would take a host the agent's profile needs is left out, and said.

## Read, publish nothing: `retrieve-only`

```ini
[net:reviewer]
retrieve-only = on
```

(#223) refuses, for that session, every request but GET and HEAD to every host but
the agent profile's own -- the agent's API keeps working -- with two exceptions that
read: a GraphQL query, and git's fetch where `[net] git` allows it. The engine writes the
profile's hosts to the session's `retrieve-only.txt`; the addon applies it to that
session's token, at each request inside a tunnel, so a refusal names the method and
lands in `blocked.log`. GraphQL is the one exception it reads a body for: `gh` reads
issues and pull requests through POSTs to `api.github.com/graphql`, so a request there
passes when every operation in its document is a query, and is refused when one is a
mutation or a subscription (strings and comments do not count). Git's smart-HTTP
fetch is a POST too, to `git-upload-pack`, and it reads as a query does (#280): under
`git = fetch` or `git = allow` the upload-pack advertisement and endpoint pass, so the
session can `git clone`, `git fetch` and `pip install git+https://...`; under
`git = refuse` they are refused as git's transport. The `git-receive-pack` side is
refused whatever `[net] git` says -- a retrieve-only session never pushes. A role
that needs a repository gets `git = fetch` beside `retrieve-only = on`, not
`retrieve-only = off`.

What it does not stop: a secret carried out in a GET -- in a URL, to any allowed host.
A token that cannot write bounds what such a secret can do ([recipes.md](recipes.md)).

## Every public host: `hosts = public`

```ini
[net:market-*]
hosts = public
```

lets that role's sessions reach every public host: for each, the addon passes a host
the allowlist would refuse, at CONNECT and per request, while the session lives. What
is subtracted still is: `[deny]`, `retrieve-only`, the `git` refusals, and -- in
`server_connect`, on the address actually dialed -- every non-public destination, so
the reach is the public internet and nothing on this machine or its LAN. With
`mode = strict` there is no route around the proxy either. It is for work whose sites
cannot be listed in advance (the `market` model); what bounds such a role is what is
in reach of it, so give it nothing of yours (`preset = isolated`, no `gh`, no SSH).
Ignored in `open` and `none`, which have no proxy.

## No git transport: `git = refuse`, or no push: `git = fetch`

A host that serves pages serves git over HTTPS too, so an allowlist that lets a role
read `github.com` lets it push there. `[net] git = refuse` (#224), per role with
`[net:<role>]`, refuses git's smart-HTTP transport for that session to every host:
`/info/refs` with `service=git-upload-pack` or `git-receive-pack`, the
`git-upload-pack` and `git-receive-pack` endpoints, and any request with git's own
`git/...` user agent. Fetches are refused as well as pushes, on purpose: a role that
may not publish has the repository on disk as its only remote over HTTPS. The same
host's pages still load. `--ssh` and the file's `[ssh]` hosts are honoured all the same
(#293): see below.

`git = fetch` is the narrower line: git fetches over HTTPS as usual, and a push --
`/info/refs?service=git-receive-pack` and the `git-receive-pack` endpoint -- is refused,
for a role that reads repositories and must never publish to one. Under
`retrieve-only` the fetch passes too, recognised by its path, not by git's user agent;
a push is refused there under `git = allow` as well. `--ssh` and the file's `[ssh]`
hosts are honoured here too (#293).

The two layers are independent. `[net] git` (and `retrieve-only`) govern git over
HTTPS only, which is what the proxy can see. `[ssh]` and `--ssh` govern hosts only:
which hosts the role's key may sign in to, enforced by the broker. ssh knows nothing
about git, so git over SSH inherits the host list -- a role with an SSH host can push
over SSH to a remote on that host, whatever `[net] git` and `retrieve-only` say, where
the account allows it. The `--trust` review, `--check` and the briefing say so per host.
What SSH may do on a host is the remote's rule, not the sandbox's
([ssh.md](ssh.md#what-the-key-may-do-on-a-host)).

## The proxy CA

mitmproxy writes its CA to `~/.mitmproxy/` on first start (`install.sh` does
this). It is **not** installed into the host's trust store. In the `proxy` and
`strict` modes the engine builds `(system bundle + proxy CA)` under the session
base and bind-mounts it over `/etc/ssl/certs/ca-certificates.crt` inside the
sandbox, so everything in there trusts the proxy and nothing on the host does.
It also points the CA variables of tools that ship their own store at that
path: `SSL_CERT_FILE`, `SSL_CERT_DIR`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`,
`CONDA_SSL_VERIFY`, `MAMBA_SSL_VERIFY` (mamba 2.x and micromamba read only this one),
`PIP_CERT`, `GIT_SSL_CAINFO`, `NODE_EXTRA_CA_CERTS`, `NPM_CONFIG_CAFILE`,
`CARGO_HTTP_CAINFO`, unless you set them yourself. A tool
with yet another knob needs it forwarded via `AGENT_SANDBOX_FORWARD`.
`AGENT_SANDBOX_PROXY_CA` overrides the CA's location; a missing CA is a warning
at launch.

The bind is over a single file, and the kernel attaches a file bind to that directory
entry. When the host replaces `/etc/ssl/certs/ca-certificates.crt` by a rename -- a
`ca-certificates` upgrade does, unattended-upgrades at 06:00 included -- the bind under a
running role is detached: the sandbox sees the host's new bundle, without the proxy CA,
and every HTTPS request fails (`x509: certificate signed by unknown authority`) until the
role is restarted. A new launch binds again, so only a running role meets it. Each join
into a running role, and `--status`, check the keeper's bind (its mount namespace's
`mountinfo`, read on the host) and say, loud:

```
agent-sandbox: warning — role 'R': the host replaced /etc/ssl/certs/ca-certificates.crt (at 2026-10-21 06:00:12) and the sandbox lost the proxy's CA -- HTTPS fails until the role is restarted: asb --role R --shutdown claude
```

The join goes on. `asb --role R --shutdown claude`, then launching again, fixes it. With
the bind still there but the host's bundle no longer the one the role started with
(compared with the SHA-256 the launch recorded), the line is a `note:` instead: HTTPS
works, and the host's new certificates reach the role at its next launch. Nothing is
said outside the proxy modes, nor when the keeper's `mountinfo` cannot be read.

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
`asb --trust`. Same
rules as `--allow`, same per-session lifetime. See [config.md](config.md).
