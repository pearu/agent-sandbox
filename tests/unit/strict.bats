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
}

@test "strict: pasta with an isolated netns, an nft rule allowing only gateway:8888, bwrap sharing the net, proxy at the gateway, CA bound" {
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- claude --version
  [ "$status" -eq 0 ]
  local -a P
  mapfile -t P <"$H/pasta_argv"
  has() { printf '%s\n' "${P[@]}" | grep -qxF -- "$1"; }
  grepd() { printf '%s\n' "${P[@]}" | grep -q -- "$1"; }
  has --config-net                                # pasta owns the netns
  has bwrap                                       # bwrap is the command pasta execs
  has --share-net                                 # bwrap shares pasta's netns (not the host's)
  has http://10.9.9.1:8888                        # HTTPS_PROXY points at the gateway
  has /etc/ssl/certs/ca-certificates.crt          # CA bound as in proxy mode
  grepd 'policy drop'                             # the firewall drops by default
  grepd 'ip daddr 10.9.9.1 tcp dport 8888 accept' # and allows only the proxy
  ! grepd '10.0.2.2'                              # not the old slirp gateway
  [ ! -s "$H/argv" ]                              # bwrap did not run directly; it went via pasta
}

@test "strict: refuses to launch when there is no default-route gateway" {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$H/bin/ip" # ip reports no default route
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"default-route gateway"* ]]
  [ ! -e "$H/pasta_argv" ] || [ ! -s "$H/pasta_argv" ] # pasta was never invoked
}
