#!/usr/bin/env bats
# strict net mode wiring. The engine drives pasta (isolated netns + userspace
# forward) with an nftables rule allowing only the proxy on the gateway, and
# bwrap shares that netns. A stub pasta on PATH captures what the engine invokes;
# real pasta is never run, so the gateway (which the wrapper reads INSIDE the
# netns) is never resolved here -- the tests assert on the wrapper script the
# engine hands pasta, not a concrete gateway. The missing-tool error paths are
# not unit-tested, since a host with passt installed cannot hide the real
# binaries; docs/network.md and the integration test cover the rest.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  cat >"$H/bin/pasta" <<'S'
#!/usr/bin/env bash
: >"${PASTA_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$PASTA_DUMP"; done
exit 0
S
  printf '#!/usr/bin/env bash\nexit 0\n' >"$H/bin/nft"
  chmod +x "$H/bin/pasta" "$H/bin/nft"
  make_fake_ca "$H/ca.pem"
  PROJ="$(cd "$H/proj" && pwd -P)"
}

# Record approval of the project's .agent-sandbox the way --trust would.
trust() {
  local t="$H/home/.config/agent-sandbox/trust"
  mkdir -p "$t"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 >"$t/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

pasta_argv() {
  mapfile -t P <"$H/pasta_argv"
  JOINED=" ${P[*]} "
}

@test "strict: pasta owns the netns, the wrapper derives the gateway inside it and builds the nft rule + proxy env there, bwrap shares the net, CA bound, port forwarding off both ways" {
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- claude --version
  [ "$status" -eq 0 ]
  local -a P
  mapfile -t P <"$H/pasta_argv"
  has() { printf '%s\n' "${P[@]}" | grep -qxF -- "$1"; }
  grepd() { printf '%s\n' "${P[@]}" | grep -q -- "$1"; }
  has --config-net # pasta owns the netns
  local joined=" ${P[*]} "
  [[ "$joined" == *" -T none "* && "$joined" == *" -U none "* ]] # no host port is mirrored into the netns
  [[ "$joined" == *" -t none "* && "$joined" == *" -u none "* ]] # no sandbox listener is published on the host
  has bwrap                                                      # bwrap is the command pasta execs
  has --share-net                                                # bwrap shares pasta's netns (not the host's)
  has /etc/ssl/certs/ca-certificates.crt                         # CA bound as in proxy mode
  grepd -- '-4 route show default'                               # the gateway is read INSIDE the netns
  grepd 'policy drop'                                            # the firewall drops by default
  grepd 'ip daddr %s tcp dport 8888 accept'                      # allows only the gateway proxy (filled in from $gw)
  grepd 'setenv HTTPS_PROXY "http://\$gw:8888"'                  # proxy env points at the in-netns gateway
  ! grepd '10\.9\.9\.1'                                          # no gateway is baked in on the host side
  ! grepd '10.0.2.2'                                             # not the old slirp gateway
  [ ! -s "$H/argv" ]                                             # bwrap did not run directly; it went via pasta
}

@test "strict: --host-port/--agent-port, the knobs and a trusted [net] section open exactly those TCP ports in pasta; none closes a direction" {
  printf '[net]\nhost-port = 11434\nagent-port = 3000   # vite\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" \
    AGENT_SANDBOX_HOST_PORTS="5432, 11434" -- claude --host-port 5432 --agent-port 8000 --version
  [ "$status" -eq 0 ]
  pasta_argv
  [[ "$JOINED" == *" -T 5432,11434 "* ]]                         # flags, knob, dot-file: a union, deduplicated
  [[ "$JOINED" == *" -t 127.0.0.1/8000,3000 "* ]]                # published on the host's loopback only
  [[ "$JOINED" == *" -U none "* && "$JOINED" == *" -u none "* ]] # UDP stays off
  [[ "$output" == *"host ports the sandbox may reach at 127.0.0.1: 5432 11434"* ]]
  [[ "$output" == *"agent ports published at the host's 127.0.0.1: 8000 3000"* ]]
  # none anywhere closes that direction for the session, whatever the others list
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" \
    AGENT_SANDBOX_AGENT_PORTS=none -- claude --host-port none --agent-port 8000 --version
  [ "$status" -eq 0 ]
  pasta_argv
  [[ "$JOINED" == *" -T none "* && "$JOINED" == *" -t none "* ]]
  [[ "$output" == *"host ports: none this session"* ]]
  [[ "$output" == *"agent ports: none this session"* ]]
}

@test "strict: the host's routes no longer gate the launch; the gateway is resolved inside the netns (with an in-netns refusal if none)" {
  # No `ip` on the host at all: the engine must still reach pasta (it used to
  # refuse here on a host-side gateway guess). The refusal for a gateway-less
  # netns now lives in the wrapper the engine hands pasta.
  rm -f "$H/bin/ip"
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/pasta_argv" ]                                                 # pasta WAS invoked
  grep -q 'no IPv4 gateway inside the network namespace' "$H/pasta_argv" # the wrapper refuses if the netns has none
}

@test "strict: --ssh-unrestricted is refused (the firewall must pin named hosts), before any agent starts" {
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" \
    AGENT_SANDBOX_SESSION_BASE="$H/base" -- claude --ssh-unrestricted --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ssh-unrestricted is not supported in strict mode"* ]]
  [ -z "$(find "$H/base" -name agent.sock 2>/dev/null)" ] # no agent socket created
  [ ! -e "$H/pasta_argv" ] || [ ! -s "$H/pasta_argv" ]    # pasta never invoked
}

@test "strict: --ssh HOST opens a firewall pinhole to the host's resolved IPv4(s) and binds an /etc/hosts mapping" {
  # Stub the ssh toolchain and name resolution so _as_ssh_setup succeeds without
  # a real agent or a trusted key; the engine's pasta argv is the contract.
  cat >"$H/bin/ssh" <<'X'
#!/usr/bin/env bash
[[ "$1" == -G ]] && { printf 'hostname %s
user tester
port 22
' "${2:-h}"; exit 0; }
exit 0
X
  printf '#!/usr/bin/env bash
exit 0
' >"$H/bin/ssh-keygen" # ssh-keygen -F: host key "found"
  printf '#!/usr/bin/env bash
exit 0
' >"$H/bin/ssh-add"
  cat >"$H/bin/ssh-agent" <<'X'
#!/usr/bin/env bash
sock=""; while [[ $# -gt 0 ]]; do [[ "$1" == -a ]] && sock="$2"; shift; done
: >"$sock" 2>/dev/null
echo "SSH_AGENT_PID=99999; export SSH_AGENT_PID;"
X
  cat >"$H/bin/getent" <<'X'
#!/usr/bin/env bash
[[ "$1" == ahostsv4 ]] && { printf '10.20.30.40 STREAM %s
10.20.30.41 STREAM %s
' "$2" "$2"; exit 0; }
exit 2
X
  chmod +x "$H/bin/ssh" "$H/bin/ssh-keygen" "$H/bin/ssh-add" "$H/bin/ssh-agent" "$H/bin/getent"
  mkdir -p "$H/home/.ssh"
  : >"$H/home/.ssh/known_hosts"
  : >"$H/key"
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" \
    AGENT_SANDBOX_SESSION_BASE="$H/base" -- claude --ssh git.example --ssh-key "$H/key" --version
  [ "$status" -eq 0 ]
  pasta_argv
  # both resolved IPs pinned on port 22, spliced into the ruleset
  grep -q 'ip daddr 10.20.30.40 tcp dport 22 accept' "$H/pasta_argv"
  grep -q 'ip daddr 10.20.30.41 tcp dport 22 accept' "$H/pasta_argv"
  [[ "$JOINED" == *" --ro-bind "*"/etc-hosts /etc/hosts "* ]] # /etc/hosts injected
  [[ "$JOINED" == *" SSH_AUTH_SOCK "* ]]                      # the agent socket is still bound
  # both resolved IPs reported for the name (the /etc-hosts file is torn down
  # with the session dir; the bind above and these lines prove it)
  [[ "$output" == *"git.example reachable at 10.20.30.40 10.20.30.41 on port 22"* ]]
}
