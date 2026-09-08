#!/usr/bin/env bats
# strict net mode wiring. The engine drives pasta (isolated netns + userspace
# forward) with an nftables rule allowing only the proxy on the gateway, and
# bwrap shares that netns. Stub pasta/nft/ip on PATH (shadowing the real ones)
# capture what the engine invokes; real pasta is never run. The missing-tool
# error paths are not unit-tested, since a host with passt installed cannot hide
# the real binaries; docs/network.md and the integration test cover the rest.

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
  printf '#!/usr/bin/env bash\n[[ "$*" == "route show default" ]] && echo "default via 10.9.9.1 dev eth0 proto static"\nexit 0\n' >"$H/bin/ip"
  chmod +x "$H/bin/pasta" "$H/bin/nft" "$H/bin/ip"
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

@test "strict: pasta with an isolated netns, an nft rule allowing only gateway:8888, bwrap sharing the net, proxy at the gateway, CA bound, port forwarding off both ways" {
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
  has http://10.9.9.1:8888                                       # HTTPS_PROXY points at the gateway
  has /etc/ssl/certs/ca-certificates.crt                         # CA bound as in proxy mode
  grepd 'policy drop'                                            # the firewall drops by default
  grepd 'ip daddr 10.9.9.1 tcp dport 8888 accept'                # and allows only the proxy
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

@test "strict: refuses to launch when there is no default-route gateway" {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$H/bin/ip" # ip reports no default route
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"default-route gateway"* ]]
  [ ! -e "$H/pasta_argv" ] || [ ! -s "$H/pasta_argv" ] # pasta was never invoked
}
