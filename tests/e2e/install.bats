#!/usr/bin/env bats
# End to end: install.sh for real (no --dry-run) against a throwaway HOME, with
# the shared fake agent (tests/helpers/fake-agent.sh) planted for every profile with a
# test adapter, where a launch runs it from (profiles/<name>/test.bash, test_plant;
# claude: installed as `asb --install claude` installs it, #6), and
# `systemctl --user` replaced by a shim that runs the unit's ExecStart itself; then the
# installed `asb CMD` runs each fake agent through the installed proxy (#151).
#
# The installer and proxy tests are the installer's own; the agent tests are one block
# per adapter, named after it, in the same places in the order (the uninstall last).
#
# Opt-in (AGENT_SANDBOX_E2E=1). It installs mitmproxy into the throwaway HOME
# with the micromamba it fetches (network, about a minute) unless
# AGENT_SANDBOX_E2E_MITMDUMP names an existing mitmdump >= 12 to reuse. On a kernel that restricts unprivileged user
# namespaces the installer's AppArmor step uses sudo unless the profile is
# already installed. The proxy's port is the installer's choice (#335): 8888, or,
# when another listener holds 8888 (this account's real proxy, on a dev box), the
# next free port above it. The suite reads the port the install recorded in the
# throwaway HOME and probes that, so it runs whether or not 8888 is busy here.

# shellcheck disable=SC2030,SC2031
# (file-wide: the agent tests are functions registered with bats_test_function, which
# ShellCheck takes for code beside the @test subshells, so it reports their $status and
# $output as modified in a subshell. SC2314 cannot flag a bare `! cmd` in them either:
# scripts/check.sh's grep for one is the guard.)
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
load "$BATS_TEST_DIRNAME/../helpers/proxy-port"
load "$BATS_TEST_DIRNAME/../helpers/adapters"

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

# `run !` needs bats 1.5's flag handling, bats_test_function 1.11; this suite does not
# load helpers/common.bash,
# which declares it for the others, so it says so itself (else bats warns BW02).
bats_require_minimum_version 1.11.0

setup_file() {
  [[ "${AGENT_SANDBOX_E2E:-0}" == 1 ]] || skip "set AGENT_SANDBOX_E2E=1 to run the end-to-end installer test"
  { command -v bwrap && command -v curl; } >/dev/null || skip "bwrap and curl are required"
  E="$BATS_FILE_TMPDIR/e2e"
  H="$E/home"
  B="$E/bin"
  mkdir -p "$H/.local/bin" "$B" "$E/proj" "$E/state"
  # every adapter's fake, planted before the install runs, so it reports each agent; and
  # what each launcher pointed at then, for the uninstall to be measured against
  local a
  for a in $(test_adapters); do
    (
      export HOME="$H"
      use_adapter "$a"
      plant_fake_agent "$H"
      printf '%s\n' "$TEST_LAUNCHER" "$TEST_BIN" "$(readlink "$TEST_LAUNCHER")" >"$E/plant.$a"
    )
  done
  cp "$BATS_TEST_DIRNAME/../helpers/systemctl-shim.sh" "$B/systemctl"
  chmod +x "$B/systemctl"
  if [[ -n "${AGENT_SANDBOX_E2E_MITMDUMP:-}" ]]; then
    mkdir -p "$H/.local/share/agent-sandbox/proxy-venv/bin"
    ln -s "$AGENT_SANDBOX_E2E_MITMDUMP" "$H/.local/share/agent-sandbox/proxy-venv/bin/mitmdump"
  fi
  export E H B
  export SYSTEMCTL_SHIM_LOG="$E/systemctl.log" SYSTEMCTL_SHIM_STATE="$E/state"
  run_install "$E/install1.out"
  # the port the install chose, as the installed engine reads it
  PP="$(test_proxy_port "$H")"
  export PP
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
  # every adapter's agent found where its fake was planted (setup_file): asb's install of
  # it, by version, for a profile with an install recipe (#6); else the binary its
  # command on PATH resolves to
  local a launcher bin link v pin
  for a in $(test_adapters); do
    { read -r launcher && read -r bin && read -r link; } <"$E/plant.$a"
    if [ -n "$(HOME="$H" profile_facts "$a" install)" ]; then
      # its current version against the profile's pin, and nothing installed or moved
      v="$(readlink "$H/.local/state/agent-sandbox/$a/install/current")"
      pin="$(HOME="$H" profile_facts "$a" pin)"
      if [ -z "$pin" ]; then
        [[ "$out" == *"$a $v"$'\n'* ]]
      elif [ "$v" = "$pin" ]; then
        [[ "$out" == *"$a $v, the pin"* ]]
      else
        [[ "$out" == *"$a $v, pinned $pin: asb --install $a moves to the pin"* ]]
      fi
      [[ "$out" != *"$a: not installed"* ]]
    else
      [[ "$out" == *"$a: \`${launcher##*/}\` is $bin"* ]]
    fi
  done
  [[ "$out" == *"mitmdump 12."* ]]
  # agent-sandbox's own micromamba, fetched and checked against the pinned sum, and its root
  [[ "$out" == *"micromamba 2.9.0-0 installed: $H/.local/share/agent-sandbox/micromamba/bin/micromamba"* ]]
  "$H/.local/share/agent-sandbox/micromamba/bin/micromamba" --version
  [ -d "$H/.local/share/agent-sandbox/conda" ]
  grep -qxE 'host|sandbox' "$H/.config/agent-sandbox/conda" # no terminal: host if it has conda, else sandbox
  # the tools env, built from conda-forge with that micromamba: conda-forge's gh
  [[ "$out" == *"tools env $H/.local/share/agent-sandbox/tools/a (the default; "*"): gh "*" (gh)"* ]]
  "$H/.local/share/agent-sandbox/tools/current/bin/gh" --version
  # and tmux, for asb --roles (#317)
  [[ "$out" == *"tools env $H/.local/share/agent-sandbox/tools/a (the default; "*"); tmux "*" (tmux)"* ]]
  "$H/.local/share/agent-sandbox/tools/current/bin/tmux" -V
  [[ "$out" == *"CA generated: $H/.mitmproxy/mitmproxy-ca-cert.pem"* ]]
  [ -f "$H/.mitmproxy/mitmproxy-ca-cert.pem" ]
  grep -q '^api.github.com$' "$H/.config/agent-sandbox/allowlist.txt"
  run ! grep -q '^api.anthropic.com$' "$H/.config/agent-sandbox/allowlist.txt" # the profile's [allow], per launch
  cmp -s "$H/.config/agent-sandbox/allowlist_addon.py" "$REPO_ROOT/components/allowlist_addon.py"
  grep -qE "^ExecStart=$H/.local/share/agent-sandbox/proxy-(env|venv)/bin/mitmdump" "$H/.config/systemd/user/agent-sandbox-mitmproxy.service"
  # the proxy's port (#335): recorded, in the unit, and 8888 unless 8888 was held here
  grep -q -- "--listen-port $PP " "$H/.config/systemd/user/agent-sandbox-mitmproxy.service"
  [[ "$out" == *"proxy port $PP ("* ]]
  if (echo >/dev/tcp/127.0.0.1/8888) 2>/dev/null && [ "$PP" != 8888 ]; then
    [[ "$out" == *"8888 is held by another listener; the next free port"* ]]
  else
    [ "$PP" = 8888 ]
  fi
  [ "$(readlink "$H/.local/bin/asb")" = "$H/.local/share/agent-sandbox/app/agent-sandbox" ] # a true install: a copy, not the checkout
  [ "$(readlink "$H/.local/bin/agent-sandbox")" = "$H/.local/share/agent-sandbox/app/agent-sandbox" ]
  # and each agent's command is still the agent's own launcher, untouched (#151)
  for a in $(test_adapters); do
    { read -r launcher && read -r bin && read -r link; } <"$E/plant.$a"
    [ "$(readlink "$launcher")" = "$link" ]
  done
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
  local out
  out=$(cat "$E/install1.out")
  [[ "$out" == *"agent-sandbox-mitmproxy.service is active"* ]]
  grep -i 'proxy\|allowlist' <<<"$out" # shown if an assertion below fails
  [[ "$out" == *"proxy reaches an allowlisted host (api.github.com)"* ]]
  # the installer's own negative smoke check asserts the other half of the contract
  [[ "$out" == *"proxy refuses a non-allowlisted host (example.com blocked at CONNECT)"* ]]
  [[ "$out" == *"proxy refuses a client with no session token (407)"* ]]
  [[ "$out" != *"SECURITY:"* ]]
  # a client with no session token: refused at CONNECT with the challenge, and logged
  run curl -sS --cacert "$H/.mitmproxy/mitmproxy-ca-cert.pem" --proxy "http://127.0.0.1:$PP" --max-time 20 -o /dev/null https://example.com/
  [ "$status" -ne 0 ]
  [[ "$output" == *"407"* ]]
  grep -q $'\texample.com\tCONNECT\t-\tno session$' "$H/.config/agent-sandbox/blocked.log"
  # the installer's probe session asked as a session: example.com refused for its host
  grep -q $'\texample.com\tCONNECT\t-$' "$H/.config/agent-sandbox/blocked.log"
}

# probe_session -- a live session of the test's own, in the session base the proxy reads
# (the engine's rule), since the proxy serves sessions only (#233); sets PX to a proxy URL
# carrying its token and SESS to the directory.
probe_session() {
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -d "$rt" && -w "$rt" ]] || rt=/tmp
  mkdir -p "$rt/agent-sandbox.$(id -u)"
  SESS="$(mktemp -d "$rt/agent-sandbox.$(id -u)/session.XXXXXX")"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$SESS/owner.id"
  echo e2eprobe >"$SESS/proxy.token"
  : >"$SESS/allow.txt"
  PX="http://e2eprobe:x@127.0.0.1:$PP"
}

@test "F1: the proxy gates the real destination, not a spoofed Host header, and refuses non-public addresses" {
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

  # asked as a live session, so these reach the gates under test rather than the 407
  probe_session
  # (a) Host-header spoof: allowlisted Host, real destination 127.0.0.1 -> refused
  run curl -sS --proxy "$PX" --max-time 20 -o /dev/null -w '%{http_code}' -H 'Host: spoof.example' http://127.0.0.1:8099/SECRET
  [[ "$output" != 200 && "$output" != 407 ]]
  # (b) destination gate: 127.0.0.1 is allowlisted by name yet must be refused as non-public
  run curl -sS --proxy "$PX" --max-time 20 -o /dev/null -w '%{http_code}' http://127.0.0.1:8099/DIRECT
  [[ "$output" != 200 && "$output" != 407 ]]
  rm -rf "$SESS"

  kill "$listener" 2>/dev/null || true
  # the loopback listener must have received NOTHING through the proxy
  run grep -c 'GET /' "$E/f1-listener.log"
  [ "$output" -eq 0 ]
  # and the refusals are recorded
  grep -q $'\t127.0.0.1\t' "$blog"
}

# agent_setup NAME -- the adapter in use, under the throwaway HOME, and where setup_file
# planted its fake: TEST_LAUNCHER (the command), TEST_BIN (the binary), TEST_LINK (what the
# command pointed at then).
agent_setup() {
  HOME="$H" use_adapter "$1"
  { read -r TEST_LAUNCHER && read -r TEST_BIN && read -r TEST_LINK; } <"$E/plant.$1"
}

agent_runs() {
  agent_setup "$1"
  run launch "$TEST_CMD" env
  [ "$status" -eq 0 ]
  # the session token: the profile's [allow] opens its hosts for this launch (#181)
  [[ "$output" =~ HTTPS_PROXY=http://[0-9a-f]{32}:x@127\.0\.0\.1:$PP ]]
  [[ "$output" == *"SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"* ]]
  [[ "$output" == *"HOME=$H"* ]]
  # a host of the profile's own [allow] (its first exact name), reached through the proxy
  # with TLS verified by the bound CA: any HTTP status is the host's answer, as a refused
  # CONNECT has none (code=000)
  local host
  host="$(HOME="$H" profile_get "$1" _profile_allow_hosts | grep -v '^\.' | head -n 1)"
  [ -n "$host" ]
  run launch "$TEST_CMD" fetch "https://$host/"
  [[ "$output" =~ code=[1-5][0-9][0-9]\ rc=0 ]]
  local blocked_before
  blocked_before="$(grep -c $'\texample.com\t' "$H/.config/agent-sandbox/blocked.log" 2>/dev/null || true)"
  run launch "$TEST_CMD" fetch https://example.com/
  # A refused CONNECT yields no HTTP response (code=000) and the proxy's 403 in
  # the error; curl's exit code for it varies by version (56, or 97 since 7.83),
  # so assert on those two facts, not the exit number.
  [[ "$output" == *"code=000"* && "$output" == *"403"* ]]
  run launch "$TEST_CMD" fetch http://example.com/
  [[ "$output" == *"code=403 rc=0"* ]]
  # both of THIS test's refusals are logged (counted from before them, so another test's
  # requests, or their absence, cannot decide it)
  [ "$(grep -c $'\texample.com\t' "$H/.config/agent-sandbox/blocked.log")" -ge "$((${blocked_before:-0} + 2))" ]
}

for a in $(test_adapters); do
  bats_test_function --description "$a: asb runs the fake agent sandboxed: proxy variables set, TLS verified by the bound CA, allowed host reached, others refused and logged" -- agent_runs "$a"
done

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
  # the port is kept, not moved because its own proxy now holds it (#335)
  [[ "$out" == *"proxy port $PP (recorded by an earlier run)"* ]]
  [[ "$out" != *"[warn] 127.0.0.1:$PP"* ]]
  sleep 1
  "$B/systemctl" --user is-active --quiet agent-sandbox-mitmproxy.service
}

@test "re-running install.sh detects a broken proxy environment and recreates it" {
  local env="" d
  for d in "$H/.local/share/agent-sandbox/proxy-venv" "$H/.local/share/agent-sandbox/proxy-env"; do
    [[ -d "$d" ]] && env="$d" && break
  done
  [ -n "$env" ]
  # Break it the way a swapped interpreter does: mitmdump runs but cannot import.
  # Replace the file, never write through it: with AGENT_SANDBOX_E2E_MITMDUMP set, the
  # launcher here is a symlink to a real install's mitmdump, which `cat >` would overwrite.
  rm -f "$env/bin/mitmdump"
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

agent_bg() {
  agent_setup "$1"
  local -a daemon=() verb=()
  mapfile -t daemon < <(HOME="$H" profile_get "$1" profile_daemon_argv)
  mapfile -t verb < <(HOME="$H" profile_get "$1" profile_status_argv)
  ((${#daemon[@]} && ${#verb[@]})) || skip "the $1 profile has no background daemon ([agent] daemon and status)"
  run launch "$TEST_CMD" --bg 'do a thing'
  [ "$status" -eq 0 ]
  [[ "$output" == *"backgrounded"*"SANDBOXED, wrapper=none"* ]]
  # the daemon the --bg left behind holds the role's launch, and a verb joins it
  sleep 3 # past the keeper's idle grace
  run launch "$TEST_CMD" "${verb[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${verb[0]}: daemon running"* ]]
  # --status shows what --shutdown would end: the daemon among its processes, and the
  # sessions a joined status verb lists
  run launch --status "$TEST_CMD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running since"* ]]
  [[ "$output" == *"${daemon[*]}"* ]]
  [[ "$output" == *"background sessions:"*"${verb[0]}: daemon running"* ]]
  run launch --shutdown "$TEST_CMD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended, with everything that ran in it"* ]]
  # and afterwards a question gets the empty answer, without starting anything
  run launch "$TEST_CMD" "${verb[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not running"* ]]
  [[ "$output" != *"${verb[0]}:"* ]]
}

for a in $(test_adapters); do
  bats_test_function --description "$a: asb --bg runs in the role: sandboxed, its daemon inside and holding the launch, ended by --shutdown (#123)" -- agent_bg "$a"
done

# The first adapter's run uninstalls; a later one's runs it again on a machine that is
# already clean, which is the re-run this test asks for anyway.
agent_uninstall() {
  agent_setup "$1"
  # what the command pointed at (nothing, for an agent asb installs: the binary itself)
  local native="$TEST_LINK"
  [ "$(readlink "$TEST_LAUNCHER")" = "$native" ]
  run_install "$E/uninstall.$1.out" --uninstall --yes
  [ "$(cat "$E/uninstall.$1.out.rc")" -eq 0 ] || {
    cat "$E/uninstall.$1.out"
    false
  }
  # the machine is as it was before agent-sandbox: the agent's own command, no asb, our
  # state gone
  [ "$(readlink "$TEST_LAUNCHER")" = "$native" ]
  if [ -n "$(HOME="$H" profile_facts "$1" install)" ]; then
    # an agent asb installed is asb's: removed with it (#6); the rest of the engine's
    # state directory -- role stores, transcripts, accounts' logins -- is kept
    [ ! -e "$H/.local/state/agent-sandbox/$1/install" ]
    [ -d "$H/.local/state/agent-sandbox/$1" ]
  else
    [ -x "$TEST_BIN" ]
  fi
  [ ! -e "$H/.local/bin/asb" ]
  [ ! -e "$H/.local/bin/agent-sandbox" ]
  # our state gone but the sandboxes' conda environments, which --yes keeps
  [ "$(ls -A "$H/.local/share/agent-sandbox")" = conda ]
  [ ! -f "$H/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
  # the allowlist and trust store are kept, as a reinstall should find them
  [ -f "$H/.config/agent-sandbox/allowlist.txt" ]
  # and it is re-runnable on a machine that is already clean
  (
    cd "$E" && HOME="$H" PATH="$B:$PATH" AGENT_SANDBOX_HOME='' \
      SYSTEMCTL_SHIM_LOG="$SYSTEMCTL_SHIM_LOG" SYSTEMCTL_SHIM_STATE="$SYSTEMCTL_SHIM_STATE" \
      "$REPO_ROOT/install.sh" --uninstall --yes >"$E/uninstall2.$1.out" 2>&1
    echo $? >"$E/uninstall2.$1.out.rc"
  )
  [ "$(cat "$E/uninstall2.$1.out.rc")" -eq 0 ]
}

for a in $(test_adapters); do
  bats_test_function --description "$a: --uninstall removes asb, agent-sandbox, our state and the agents asb installed, leaves any other agent and the sandboxes' state alone, and is re-runnable" -- agent_uninstall "$a"
done
