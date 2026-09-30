#!/usr/bin/env bats
# End to end: install.sh for real (no --dry-run) against a throwaway HOME, with
# a fake Claude installed the way Claude Code's native installer does it (a binary
# under versions/, linked from ~/.local/bin/claude) and `systemctl --user`
# replaced by a shim that runs the unit's ExecStart itself; then the installed
# `asb claude` runs the fake agent through the installed proxy (#151).
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
    cd "$E" && HOME="$H" PATH="$H/.local/bin:$B:$PATH" AGENT_SANDBOX_HOME='' \
      SYSTEMCTL_SHIM_LOG="$SYSTEMCTL_SHIM_LOG" SYSTEMCTL_SHIM_STATE="$SYSTEMCTL_SHIM_STATE" \
      "$REPO_ROOT/install.sh" "${@:2}" >"$1" 2>&1
    echo $? >"$1.rc"
  )
}

# launch ARGS: the installed asb, from the project dir, HOME = the throwaway home and
# its ~/.local/bin first on PATH, as a user's would be. ARGS as typed after `asb`.
# A missing asb means the install in setup_file did not complete. Say so, with the
# install's own output, rather than let every later test fail on a bare 127 that reads
# like a bug in the test itself.
launch() {
  if [[ ! -x "$H/.local/bin/asb" ]]; then
    echo "launch: no installed asb at $H/.local/bin/asb -- the install did not complete (exit $(cat "$E/install1.out.rc" 2>/dev/null)); its output:"
    sed 's/^/  | /' "$E/install1.out" 2>/dev/null | tail -40
    return 127
  fi
  (cd "$E/proj" && HOME="$H" PATH="$H/.local/bin:$B:$PATH" "$H/.local/bin/asb" "$@")
}

setup_file() {
  [[ "${AGENT_SANDBOX_E2E:-0}" == 1 ]] || skip "set AGENT_SANDBOX_E2E=1 to run the end-to-end installer test"
  { command -v bwrap && command -v curl; } >/dev/null || skip "bwrap and curl are required"
  E="$BATS_FILE_TMPDIR/e2e"
  H="$E/home"
  B="$E/bin"
  mkdir -p "$H/.local/share/claude/versions/9.9.9" "$H/.local/bin" "$B" "$E/proj" "$E/state"
  cp "$BATS_TEST_DIRNAME/../helpers/fake-claude.sh" "$H/.local/share/claude/versions/9.9.9/claude"
  cp "$BATS_TEST_DIRNAME/../helpers/systemctl-shim.sh" "$B/systemctl"
  chmod +x "$H/.local/share/claude/versions/9.9.9/claude" "$B/systemctl"
  ln -s "$H/.local/share/claude/versions/9.9.9/claude" "$H/.local/bin/claude"
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

@test "install.sh completes: fake agent found, proxy runtime, CA generated, config seeded, unit rendered, asb symlinked, namespaces work" {
  [ "$(cat "$E/install1.out.rc")" -eq 0 ] || {
    cat "$E/install1.out"
    false
  }
  local out
  out=$(cat "$E/install1.out")
  [[ "$out" == *"claude: \`claude\` is $H/.local/share/claude/versions/9.9.9/claude"* ]]
  [[ "$out" == *"mitmdump 12."* ]]
  [[ "$out" == *"CA generated: $H/.mitmproxy/mitmproxy-ca-cert.pem"* ]]
  [ -f "$H/.mitmproxy/mitmproxy-ca-cert.pem" ]
  grep -q '^api.github.com$' "$H/.config/agent-sandbox/allowlist.txt"
  run ! grep -q '^api.anthropic.com$' "$H/.config/agent-sandbox/allowlist.txt" # the profile's [allow], per launch
  cmp -s "$H/.config/agent-sandbox/allowlist_addon.py" "$REPO_ROOT/components/allowlist_addon.py"
  grep -qE "^ExecStart=$H/.local/share/agent-sandbox/proxy-(env|venv)/bin/mitmdump" "$H/.config/systemd/user/agent-sandbox-mitmproxy.service"
  [ "$(readlink "$H/.local/bin/asb")" = "$H/.local/share/agent-sandbox/app/agent-sandbox" ] # a true install: a copy, not the checkout
  [ "$(readlink "$H/.local/bin/agent-sandbox")" = "$H/.local/share/agent-sandbox/app/agent-sandbox" ]
  # and `claude` is still Claude Code's own launcher, untouched (#151)
  [ "$(readlink "$H/.local/bin/claude")" = "$H/.local/share/claude/versions/9.9.9/claude" ]
  [[ "$out" == *"\`asb\` on PATH resolves to the agent-sandbox engine"* ]]
  cmp -s "$H/.local/share/agent-sandbox/app/agent-sandbox" "$REPO_ROOT/agent-sandbox"
  # The components the ENGINE runs on the host land beside it, and byte-identical.
  # A piped install has no checkout to copy from, so they travel embedded in
  # install.sh -- which means a bundling mistake that dropped one would leave a
  # perfectly working installer and a `copy` connection that refuses at launch.
  # Nothing else here would notice: this is the assertion that does.
  cmp -s "$H/.local/share/agent-sandbox/app/components/connect-sync.py" \
    "$REPO_ROOT/components/connect-sync.py"
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
  [[ "$out" == *"proxy reaches an allowlisted host (api.github.com)"* ]]
  # the installer's own negative smoke check asserts the other half of the contract
  [[ "$out" == *"proxy refuses a non-allowlisted host (example.com blocked at CONNECT)"* ]]
  [[ "$out" != *"SECURITY:"* ]]
  run curl -sS --cacert "$H/.mitmproxy/mitmproxy-ca-cert.pem" --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null https://example.com/
  [ "$status" -ne 0 ]
  [[ "$output" == *"403"* ]]
  grep -q $'\texample.com\tCONNECT\t-$' "$H/.config/agent-sandbox/blocked.log"
}

@test "F1: the proxy gates the real destination, not a spoofed Host header, and refuses non-public addresses" {
  ((PORT_FREE)) || skip "port 8888 is in use by another proxy"
  local allow="$H/.config/agent-sandbox/allowlist.txt"
  local blog="$H/.config/agent-sandbox/blocked.log"

  # a throwaway loopback "host service" the sandbox must never reach through the proxy
  python3 -m http.server 8099 --bind 127.0.0.1 >"$E/f1-listener.log" 2>&1 &
  local listener=$!
  # allowlist a public host to spoof, and 127.0.0.1 so the destination gate (not
  # the name gate) is what must refuse the loopback dial
  printf 'spoof.example
127.0.0.1
' >>"$allow"
  # give the listener a moment
  for _ in $(seq 1 25); do
    (echo >/dev/tcp/127.0.0.1/8099) 2>/dev/null && break
    sleep 0.2
  done

  # (a) Host-header spoof: allowlisted Host, real destination 127.0.0.1 -> refused
  run curl -sS --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' -H 'Host: spoof.example' http://127.0.0.1:8099/SECRET
  [[ "$output" != 200 ]]
  # (b) destination gate: 127.0.0.1 is allowlisted by name yet must be refused as non-public
  run curl -sS --proxy http://127.0.0.1:8888 --max-time 20 -o /dev/null -w '%{http_code}' http://127.0.0.1:8099/DIRECT
  [[ "$output" != 200 ]]

  kill "$listener" 2>/dev/null || true
  # the loopback listener must have received NOTHING through the proxy
  run grep -c 'GET /' "$E/f1-listener.log"
  [ "$output" -eq 0 ]
  # and the refusals are recorded
  grep -q $'\t127.0.0.1\t' "$blog"
}

@test "asb claude runs the fake agent sandboxed: proxy variables set, TLS verified by the bound CA, allowed host reached, others refused and logged" {
  ((PORT_FREE)) || skip "port 8888 is in use by another proxy"
  run launch claude env
  [ "$status" -eq 0 ]
  # the session token: the profile's [allow] opens api.anthropic.com for this launch (#181)
  [[ "$output" =~ HTTPS_PROXY=http://[0-9a-f]{32}:x@127\.0\.0\.1:8888 ]]
  [[ "$output" == *"SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"* ]]
  [[ "$output" == *"HOME=$H"* ]]
  run launch claude fetch https://api.anthropic.com/v1/models
  [[ "$output" == *"code=401 rc=0"* || "$output" == *"code=200 rc=0"* ]]
  run launch claude fetch https://example.com/
  # A refused CONNECT yields no HTTP response (code=000) and the proxy's 403 in
  # the error; curl's exit code for it varies by version (56, or 97 since 7.83),
  # so assert on those two facts, not the exit number.
  [[ "$output" == *"code=000"* && "$output" == *"403"* ]]
  run launch claude fetch http://example.com/
  [[ "$output" == *"code=403 rc=0"* ]]
  [ "$(grep -c $'\texample.com\t' "$H/.config/agent-sandbox/blocked.log")" -ge 3 ]
}

@test "a host-routed subcommand runs the fake agent unsandboxed through asb" {
  run launch claude update
  [ "$status" -eq 0 ]
  [[ "$output" == *"running '$H/.local/share/claude/versions/9.9.9/claude update' on the host"* ]]
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
  [ "$(grep -c '^api.github.com$' "$H/.config/agent-sandbox/allowlist.txt")" -eq 1 ]
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

@test "asb claude --bg runs in the role: sandboxed, its daemon inside and holding the launch, ended by --shutdown (#123)" {
  run launch claude --bg 'do a thing'
  [ "$status" -eq 0 ]
  [[ "$output" == *"backgrounded"*"SANDBOXED, wrapper=none"* ]]
  # the daemon the --bg left behind holds the role's launch, and a verb joins it
  sleep 3 # past the keeper's idle grace
  run launch claude agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents: daemon running"* ]]
  # --status shows what --shutdown would end: the daemon among its processes, and the
  # sessions a joined `agents` lists
  run launch --status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"running since"* ]]
  [[ "$output" == *"daemon run"* ]]
  [[ "$output" == *"background sessions:"*"agents: daemon running"* ]]
  run launch --shutdown claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended, with everything that ran in it"* ]]
  # and afterwards a question gets the empty answer, without starting anything
  run launch claude agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not running"* ]]
  [[ "$output" != *"agents:"* ]]
}

@test "--uninstall removes asb, agent-sandbox and our state, leaves the agent's claude alone, and is re-runnable" {
  local native="$H/.local/share/claude/versions/9.9.9/claude"
  [ "$(readlink "$H/.local/bin/claude")" = "$native" ]
  run_install "$E/uninstall.out" --uninstall --yes
  [ "$(cat "$E/uninstall.out.rc")" -eq 0 ] || {
    cat "$E/uninstall.out"
    false
  }
  # the machine is as it was before agent-sandbox: its own claude, no asb, our state gone
  [ "$(readlink "$H/.local/bin/claude")" = "$native" ]
  [ ! -e "$H/.local/bin/asb" ]
  [ ! -e "$H/.local/bin/agent-sandbox" ]
  [ ! -d "$H/.local/share/agent-sandbox" ]
  [ ! -f "$H/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
  # the allowlist and trust store are kept, as a reinstall should find them
  [ -f "$H/.config/agent-sandbox/allowlist.txt" ]
  # and it is re-runnable on a machine that is already clean
  (
    cd "$E" && HOME="$H" PATH="$B:$PATH" AGENT_SANDBOX_HOME='' \
      SYSTEMCTL_SHIM_LOG="$SYSTEMCTL_SHIM_LOG" SYSTEMCTL_SHIM_STATE="$SYSTEMCTL_SHIM_STATE" \
      "$REPO_ROOT/install.sh" --uninstall --yes >"$E/uninstall2.out" 2>&1
    echo $? >"$E/uninstall2.out.rc"
  )
  [ "$(cat "$E/uninstall2.out.rc")" -eq 0 ]
}
