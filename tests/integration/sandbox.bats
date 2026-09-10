#!/usr/bin/env bats
# What the agent actually sees, with the real bwrap: filesystem, environment,
# network modes, the CA bundle.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
w() { touch "$1" 2>/dev/null && { rm -f "$1"; echo yes; } || echo no; }
say home_writable "$(w "$HOME/x")"
say cwd_writable "$(w "$PWD/x")"
say cache_writable "$(w "$HOME/.cache/x")"
say host_tmp_marker_visible "$([[ -e ${TMP_MARKER-/nonexistent} ]] && echo yes || echo no)"
say tmp_writable "$(w /tmp/x)"
say secret_visible "$([[ -e $HOME/.ssh/id_secret ]] && echo yes || echo no)"
say etc_ro "$(touch /etc/x 2>/dev/null && echo no || echo yes)"
say leaked "${LEAKED-unset}"
say home_env "$HOME"
say proxy "${HTTPS_PROXY-unset}"
say ssl_cert_file "${SSL_CERT_FILE-unset}"
say net_ifaces "$(awk -F: 'NR>2{gsub(/ /,"",$1); printf "%s ", $1}' /proc/net/dev)"
say bundle_certs "$(grep -c 'BEGIN CERT' /etc/ssl/certs/ca-certificates.crt 2>/dev/null)"
say has_marker_ca "$([[ -n ${CA_LINE2-} ]] && grep -c "$CA_LINE2" /etc/ssl/certs/ca-certificates.crt || echo n/a)"
say pid1 "$(cat /proc/1/comm 2>/dev/null)"
say argv "$*"
PROBE
  mkdir -p "$IHOME/.ssh"
  echo secret >"$IHOME/.ssh/id_secret"
  TMP_MARKER="$(mktemp /tmp/agent-sandbox-test-marker.XXXXXX)"
}

teardown() { rm -f "${TMP_MARKER:-}"; }

@test "filesystem: HOME read-only, CWD and ~/.cache writable, fresh /tmp, system read-only, secrets invisible; pid namespace; arguments pass through" {
  run_sandboxed AGENT_SANDBOX_NET=none LEAKED=1 AGENT_SANDBOX_FORWARD=TMP_MARKER TMP_MARKER="$TMP_MARKER" -- --my-arg value
  [ "$status" -eq 0 ]
  [ "$(report home_writable)" = no ]
  [ "$(report cwd_writable)" = yes ]
  [ "$(report cache_writable)" = yes ]
  [ "$(report host_tmp_marker_visible)" = no ]
  [ "$(report tmp_writable)" = yes ]
  [ "$(report secret_visible)" = no ]
  [ "$(report etc_ro)" = yes ]
  [ "$(report leaked)" = unset ]
  [ "$(report home_env)" = "$IHOME" ]
  [ "$(report argv)" = "--my-arg value" ]
  [ "$(report pid1)" != "$(cat /proc/1/comm)" ] || [ "$(report pid1)" = "bwrap" ]
}

@test "net=none: no interfaces but loopback, no proxy variables" {
  run_sandboxed AGENT_SANDBOX_NET=none -- run
  [ "$status" -eq 0 ]
  [ "$(report net_ifaces)" = "lo " ]
  [ "$(report proxy)" = unset ]
  [ "$(report ssl_cert_file)" = unset ]
}

@test "net=proxy: proxy variables set, host interfaces visible, and the CA bundle inside is the system bundle plus the proxy CA" {
  make_fake_ca "$I/ca.pem"
  local host_n
  host_n=$(grep -c 'BEGIN CERT' /etc/ssl/certs/ca-certificates.crt)
  run_sandboxed AGENT_SANDBOX_PROXY_CA="$I/ca.pem" AGENT_SANDBOX_FORWARD=CA_LINE2 CA_LINE2="$(sed -n 2p "$I/ca.pem")" -- run
  [ "$status" -eq 0 ]
  [ "$(report proxy)" = "http://127.0.0.1:8888" ]
  [ "$(report ssl_cert_file)" = "/etc/ssl/certs/ca-certificates.crt" ]
  [ "$(report bundle_certs)" -eq $((host_n + 1)) ]
  [ "$(report has_marker_ca)" = 1 ]
  [[ "$(report net_ifaces)" != "lo " ]]
}

@test "net=proxy without a CA file: warning, and the bundle inside is the plain system bundle" {
  local host_n
  host_n=$(grep -c 'BEGIN CERT' /etc/ssl/certs/ca-certificates.crt)
  run_sandboxed AGENT_SANDBOX_PROXY_CA="$I/missing.pem" -- run
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"not found"* ]]
  [ "$(report bundle_certs)" -eq "$host_n" ]
}
