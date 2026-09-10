#!/usr/bin/env bats
# End to end: install.sh for real (no --dry-run) against a throwaway HOME, with
# a fake Claude binary planted where the claude profile looks and `systemctl
# --user` replaced by a shim that runs the unit's ExecStart itself; then the
# installed launcher runs the fake agent through the installed proxy.
#
# Opt-in (AGENT_SANDBOX_E2E=1). It installs mitmproxy into the throwaway HOME
# (network, about a minute) unless AGENT_SANDBOX_E2E_MITMDUMP names an existing
# mitmdump >= 12 to reuse. On a kernel that restricts unprivileged user
# namespaces the installer's AppArmor step uses sudo unless the profile is
# already installed. The proxy-dependent tests need port 8888 free and skip
# otherwise (the shim cannot start a second proxy on the same port).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# run_install OUT: the installer against the throwaway HOME, shim first on PATH;
# stdout+stderr to OUT, exit code to OUT.rc
run_install() {
  (
    cd "$E" && HOME="$H" PATH="$B:$PATH" AGENT_SANDBOX_HOME= \
      SYSTEMCTL_SHIM_LOG="$SYSTEMCTL_SHIM_LOG" SYSTEMCTL_SHIM_STATE="$SYSTEMCTL_SHIM_STATE" \
      "$REPO_ROOT/install.sh" >"$1" 2>&1
    echo $? >"$1.rc"
  )
}

# launch ARGS: the installed launcher, from the project dir, HOME = the throwaway home
launch() {
  (cd "$E/proj" && HOME="$H" PATH="$B:$PATH" "$H/.local/bin/claude" "$@")
}

setup_file() {
  [[ "${AGENT_SANDBOX_E2E:-0}" == 1 ]] || skip "set AGENT_SANDBOX_E2E=1 to run the end-to-end installer test"
  command -v bwrap >/dev/null && command -v curl >/dev/null || skip "bwrap and curl are required"
  E="$BATS_FILE_TMPDIR/e2e"
  H="$E/home"
  B="$E/bin"
  mkdir -p "$H/.local/share/claude/versions/9.9.9" "$B" "$E/proj" "$E/state"
  cp "$BATS_TEST_DIRNAME/../helpers/fake-claude.sh" "$H/.local/share/claude/versions/9.9.9/claude"
  cp "$BATS_TEST_DIRNAME/../helpers/systemctl-shim.sh" "$B/systemctl"
  chmod +x "$H/.local/share/claude/versions/9.9.9/claude" "$B/systemctl"
  if [[ -n "${AGENT_SANDBOX_E2E_MITMDUMP:-}" ]]; then
    mkdir -p "$H/.local/share/agent-sandbox/proxy-venv/bin"
    ln -s "$AGENT_SANDBOX_E2E_MITMDUMP" "$H/.local/share/agent-sandbox/proxy-venv/bin/mitmdump"
  fi
  PORT_FREE=1
  (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null && PORT_FREE=0
  export E H B PORT_FREE
  export SYSTEMCTL_SHIM_LOG="$E/systemctl.log" SYSTEMCTL_SHIM_STATE="$E/state"
  run_install "$E/install1.out"
  sleep 1 # let the shim-started proxy come up before the tests probe it
}

teardown_file() {
  [[ -n "${B:-}" && -x "$B/systemctl" ]] && "$B/systemctl" --user stop agent-sandbox-mitmproxy.service || true
}

@test "install.sh completes: fake agent found, proxy runtime, CA generated, config seeded, unit rendered, launcher symlinked, namespaces work" {
  [ "$(cat "$E/install1.out.rc")" -eq 0 ] || {
    cat "$E/install1.out"
    false
  }
  local out
  out=$(cat "$E/install1.out")
  [[ "$out" == *"claude: version 9.9.9 at $H/.local/share/claude/versions/9.9.9/claude"* ]]
  [[ "$out" == *"mitmdump 12."* ]]
  [[ "$out" == *"CA generated: $H/.mitmproxy/mitmproxy-ca-cert.pem"* ]]
  [ -f "$H/.mitmproxy/mitmproxy-ca-cert.pem" ]
  grep -q '^api.anthropic.com$' "$H/.config/agent-sandbox/allowlist.txt"
  cmp -s "$H/.config/agent-sandbox/allowlist_addon.py" "$REPO_ROOT/components/allowlist_addon.py"
  grep -q "^ExecStart=$H/.local/share/agent-sandbox/proxy-venv/bin/mitmdump" "$H/.config/systemd/user/agent-sandbox-mitmproxy.service"
  [ "$(readlink "$H/.local/bin/claude")" = "$H/.local/share/agent-sandbox/app/agent-sandbox" ] # a true install: a copy, not the checkout
  cmp -s "$H/.local/share/agent-sandbox/app/agent-sandbox" "$REPO_ROOT/agent-sandbox"
  [[ "$out" == *"bwrap can create user+pid namespaces"* ]]
  [[ "$out" == *"kernel does not restrict unprivileged userns"* ||
    "$out" == *"/etc/apparmor.d/bwrap already present"* ||
    "$out" == *"AppArmor profile for bwrap installed and loaded"* ]]
  grep -q '^--user daemon-reload$' "$SYSTEMCTL_SHIM_LOG"
  grep -q '^--user enable agent-sandbox-mitmproxy.service$' "$SYSTEMCTL_SHIM_LOG"
  grep -q '^--user restart agent-sandbox-mitmproxy.service$' "$SYSTEMCTL_SHIM_LOG"
  grep -q '^--user is-active --quiet agent-sandbox-mitmproxy.service$' "$SYSTEMCTL_SHIM_LOG"
}

@test "the installed unit runs a proxy that enforces the installed allowlist" {
  ((PORT_FREE)) || skip "port 8888 is in use by another proxy"
  local out
  out=$(cat "$E/install1.out")
  [[ "$out" == *"agent-sandbox-mitmproxy.service is active"* ]]
  [[ "$out" == *"proxy reaches an allowlisted host (api.anthropic.com)"* ]]
  # the installer's own negative smoke check asserts the other half of the contract
  [[ "$out" == *"proxy refuses a non-allowlisted host (example.com blocked at CONNECT)"* ]]
  [[ "$out" != *"SECURITY:"* ]]
  run curl -sS --cacert "$H/.mitmproxy/mitmproxy-ca-cert.pem" --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null https://example.com/
  [ "$status" -ne 0 ]
  [[ "$output" == *"403"* ]]
  grep -q $'\texample.com\tCONNECT\t-$' "$H/.config/agent-sandbox/blocked.log"
}

@test "the launcher runs the fake agent sandboxed: proxy variables set, TLS verified by the bound CA, allowed host reached, others refused and logged" {
  ((PORT_FREE)) || skip "port 8888 is in use by another proxy"
  run launch env
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTPS_PROXY=http://127.0.0.1:8888"* ]]
  [[ "$output" == *"SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"* ]]
  [[ "$output" == *"HOME=$H"* ]]
  run launch fetch https://api.anthropic.com/v1/models
  [[ "$output" == *"code=401 rc=0"* || "$output" == *"code=200 rc=0"* ]]
  run launch fetch https://example.com/
  # A refused CONNECT yields no HTTP response (code=000) and the proxy's 403 in
  # the error; curl's exit code for it varies by version (56, or 97 since 7.83),
  # so assert on those two facts, not the exit number.
  [[ "$output" == *"code=000"* && "$output" == *"403"* ]]
  run launch fetch http://example.com/
  [[ "$output" == *"code=403 rc=0"* ]]
  [ "$(grep -c $'\texample.com\t' "$H/.config/agent-sandbox/blocked.log")" -ge 3 ]
}

@test "a host-routed subcommand runs the fake agent unsandboxed through the installed launcher" {
  run launch update
  [ "$status" -eq 0 ]
  [[ "$output" == *"running '9.9.9 update' on the host"* ]]
  [[ "$output" == *"fake-claude: 'update' ran unsandboxed as $(id -un) in $E/proj"* ]]
}

@test "re-running install.sh reuses the proxy environment and CA, keeps the allowlist, restarts the service" {
  echo "my.custom.host" >>"$H/.config/agent-sandbox/allowlist.txt"
  run_install "$E/install2.out"
  [ "$(cat "$E/install2.out.rc")" -eq 0 ] || {
    cat "$E/install2.out"
    false
  }
  local out
  out=$(cat "$E/install2.out")
  [[ "$out" == *"reusing $H/.local/share/agent-sandbox/proxy-"* ]] # venv or conda env, whichever this host got
  [[ "$out" == *"CA present: $H/.mitmproxy/mitmproxy-ca-cert.pem"* ]]
  [[ "$out" == *"already exists (kept as-is)"* ]]
  [[ "$out" == *"already points at the engine"* ]]
  grep -q '^my.custom.host$' "$H/.config/agent-sandbox/allowlist.txt"
  [ "$(grep -c '^api.anthropic.com$' "$H/.config/agent-sandbox/allowlist.txt")" -eq 1 ]
  [ "$(grep -c '^--user restart agent-sandbox-mitmproxy.service$' "$SYSTEMCTL_SHIM_LOG")" -eq 2 ]
  if ((PORT_FREE)); then
    sleep 1
    "$B/systemctl" --user is-active --quiet agent-sandbox-mitmproxy.service
  fi
}

@test "re-running install.sh detects a broken proxy environment and recreates it" {
  local env="" d
  for d in "$H/.local/share/agent-sandbox/proxy-venv" "$H/.local/share/agent-sandbox/proxy-env"; do
    [[ -d "$d" ]] && env="$d" && break
  done
  [ -n "$env" ]
  # Break it the way a swapped interpreter does: mitmdump runs but cannot import.
  cat >"$env/bin/mitmdump" <<'X'
#!/usr/bin/env bash
echo "ModuleNotFoundError: No module named 'mitmproxy'" >&2
exit 1
X
  chmod +x "$env/bin/mitmdump"
  run_install "$E/install3.out"
  [ "$(cat "$E/install3.out.rc")" -eq 0 ] || {
    cat "$E/install3.out"
    false
  }
  local out
  out=$(cat "$E/install3.out")
  [[ "$out" == *"is broken: ModuleNotFoundError: No module named 'mitmproxy' -- recreating it"* ]]
  # a working runtime is back, and it is the one the rendered unit runs
  local md
  md=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$H/.config/systemd/user/agent-sandbox-mitmproxy.service")
  [ -x "$md" ]
  "$md" --version 2>/dev/null | grep -q '^Mitmproxy: 12'
}
