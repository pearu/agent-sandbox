#!/usr/bin/env bats
# install.sh in --dry-run mode against a throwaway HOME, plus bundle sync.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  T="$BATS_TEST_TMPDIR/t"
  mkdir -p "$T/home"
}

dry() { # dry [ENV=VAL ...] -- extra install.sh args
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" "${envs[@]}" "$REPO_ROOT/install.sh" --dry-run "$@"
}

@test "--dry-run: writes config, seeds the profile hosts, renders the unit with the proxy path, symlinks asb and agent-sandbox; nothing privileged" {
  dry
  [ "$status" -eq 0 ]
  [ -f "$T/home/.config/agent-sandbox/allowlist_addon.py" ]
  [ -f "$T/home/.config/agent-sandbox/allowlist.txt" ]
  grep -q '^api.anthropic.com$' "$T/home/.config/agent-sandbox/allowlist.txt"
  grep -q 'claude profile (added by install.sh)' "$T/home/.config/agent-sandbox/allowlist.txt"
  local unit="$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
  [ -f "$unit" ]
  grep -qE "^ExecStart=$T/home/.local/share/agent-sandbox/proxy-(env|venv)/bin/mitmdump" "$unit"
  grep -q "^Documentation=file:$T/home/.local/share/agent-sandbox/app/agent-sandbox" "$unit"
  grep -q -- '--set http2=false' "$unit"
  [ "$(readlink "$T/home/.local/bin/asb")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [ "$(readlink "$T/home/.local/bin/agent-sandbox")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [ ! -e "$T/home/.local/bin/claude" ] # nothing at the agent's own name (#151)
  grep -q "^command	$T/home/.local/bin/asb	symlink " "$T/home/.local/share/agent-sandbox/install.manifest" 2>/dev/null \
    || [[ "$output" == *"(dry-run) would record"* ]]
  [ -f "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # a real copy, not the checkout
  cmp -s "$T/home/.local/share/agent-sandbox/app/agent-sandbox" "$REPO_ROOT/agent-sandbox"
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude.sh" ]
  [ "$(cat "$T/home/.local/share/agent-sandbox/app/VERSION")" = "$(cat "$REPO_ROOT/VERSION")" ] # version copied with the engine
  [[ "$output" == *"(dry-run) would run: systemctl --user daemon-reload"* ]]
  [[ "$output" == *"(dry-run) proxy request skipped"* ]]
  [[ "$output" != *"sudo "* ]] || [[ "$output" == *"(dry-run)"*"sudo"* ]]
  run ! grep -q '@' "$unit"
  cmp -s "$T/home/.config/agent-sandbox/allowlist_addon.py" "$REPO_ROOT/components/allowlist_addon.py"
}

@test "re-run is idempotent: allowlist kept, seed hosts not duplicated, symlink already correct" {
  dry
  echo "my.custom.host" >>"$T/home/.config/agent-sandbox/allowlist.txt"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists (kept as-is)"* ]]
  [[ "$output" == *"claude profile hosts already present"* ]]
  [[ "$output" == *"already points at the engine"* ]]
  [ "$(grep -c '^api.anthropic.com$' "$T/home/.config/agent-sandbox/allowlist.txt")" -eq 1 ]
  grep -q '^my.custom.host$' "$T/home/.config/agent-sandbox/allowlist.txt"
}

@test "--dev points asb at the checkout and warns; a later true install re-points it to the copy" {
  dry -- --dev
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/home/.local/bin/asb")" = "$REPO_ROOT/agent-sandbox" ]
  [ ! -e "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # --dev copies nothing
  [[ "$output" == *"run on the host at the next launch"* ]]
  grep -q "^Documentation=file:$REPO_ROOT/agent-sandbox" "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
  dry # default (copy) re-points it away from the checkout
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/home/.local/bin/asb")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [[ "$output" == *"re-pointed"* ]]
}

@test "a dangling symlink at asb is replaced; someone else's asb is left untouched with a warning" {
  mkdir -p "$T/home/.local/bin"
  ln -s /gone/binary "$T/home/.local/bin/asb"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced dangling symlink $T/home/.local/bin/asb"* ]]
  rm -f "$T/home/.local/bin/asb"
  printf '#!/bin/sh\necho other\n' >"$T/home/.local/bin/asb"
  chmod +x "$T/home/.local/bin/asb"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"$T/home/.local/bin/asb exists and is not agent-sandbox (left untouched)"* ]]
  [ "$("$T/home/.local/bin/asb")" = other ]
  [ ! -e "$T/home/.local/bin/asb.pre-agent-sandbox" ] # never moved aside
  # the other name is still installed
  [ "$(readlink "$T/home/.local/bin/agent-sandbox")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
}

@test "--help prints usage and exits 0; an unknown argument exits 2" {
  run "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  run "$REPO_ROOT/install.sh" --bogus
  [ "$status" -eq 2 ]
}

@test "standalone: a lone install.sh clones the repository and installs from the clone" {
  mkdir -p "$T/alone"
  cp "$REPO_ROOT/install.sh" "$T/alone/"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" AGENT_SANDBOX_REPO="$REPO_ROOT" "$T/alone/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloning $REPO_ROOT"* ]]
  [ -f "$T/home/.local/share/agent-sandbox/src/agent-sandbox" ]
  [ "$(readlink "$T/home/.local/bin/asb")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # copied out of the clone
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" AGENT_SANDBOX_REPO="$REPO_ROOT" "$T/alone/install.sh" --dry-run
  [[ "$output" == *"updating $T/home/.local/share/agent-sandbox/src"* ]]
}

@test "install.sh is what scripts/bundle.sh produces from install.sh.in and components/" {
  mkdir -p "$T/repo/scripts"
  cp -r "$REPO_ROOT/components" "$REPO_ROOT/install.sh.in" "$T/repo/"
  cp "$REPO_ROOT/scripts/bundle.sh" "$T/repo/scripts/"
  cp "$REPO_ROOT/install.sh" "$T/repo/install.sh"
  run "$T/repo/scripts/bundle.sh"
  [ "$status" -eq 0 ]
  cmp -s "$T/repo/install.sh" "$REPO_ROOT/install.sh"
  run "$T/repo/scripts/bundle.sh"
  cmp -s "$T/repo/install.sh" "$REPO_ROOT/install.sh"
}

@test "--dry-run chooses a dedicated conda proxy env when mamba/conda is on PATH (a venv only otherwise)" {
  mkdir -p "$T/bin" "$T/home"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/mamba"
  chmod +x "$T/bin/mamba"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would create $T/home/.local/share/agent-sandbox/proxy-env with mamba"* ]]
  grep -q "^ExecStart=$T/home/.local/share/agent-sandbox/proxy-env/bin/mitmdump" \
    "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
}

# a bwrap that only knows its version; any other invocation succeeds (the smoke test)
stub_bwrap() {
  cat >"$T/bin/bwrap" <<STUB
#!/usr/bin/env bash
[[ "\$1" == --version ]] && echo "bubblewrap $1"
exit 0
STUB
  chmod +x "$T/bin/bwrap"
}

@test "--dry-run warns when bubblewrap is older than 0.12.0 (CVE-2026-87766), and not at 0.12.0 or newer" {
  mkdir -p "$T/bin"
  local v
  for v in 0.9.0 0.11.1; do
    stub_bwrap "$v"
    run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"bwrap installed:    bubblewrap $v"* ]]
    [[ "$output" == *"bubblewrap $v is older than 0.12.0"*"CVE-2026-87766"* ]]
    [[ "$output" == *"docs/troubleshooting.md"* ]]
  done
  for v in 0.12.0 0.12.1 1.0.0; do
    stub_bwrap "$v"
    run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"bwrap installed:    bubblewrap $v"* ]]
    [[ "$output" != *"older than 0.12.0"* ]]
  done
}

# ---- --uninstall (issue #22) ----------------------------------------------
# It removes what the installer created, and never touches what it did not.

uninst() { # uninst [extra args...] -- a real (not dry) uninstall, no prompt
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --yes "$@"
}

# a HOME that looks like a completed install, the manifest as install.sh writes it
fake_install() {
  local st="$T/home/.local/share/agent-sandbox" c
  mkdir -p "$T/home/.local/bin" "$st/app" "$T/home/.config/agent-sandbox/trust" \
    "$T/home/.config/systemd/user"
  cp "$REPO_ROOT/agent-sandbox" "$st/app/agent-sandbox"
  printf 'version\t1\n' >"$st/install.manifest"
  for c in asb agent-sandbox; do
    ln -sfn "$st/app/agent-sandbox" "$T/home/.local/bin/$c"
    printf 'command\t%s\t%s\n' "$T/home/.local/bin/$c" "symlink $st/app/agent-sandbox" >>"$st/install.manifest"
  done
  printf 'example.com\n' >"$T/home/.config/agent-sandbox/allowlist.txt"
  : >"$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
}

@test "--uninstall removes the engine, its commands and the unit; the agent's own command is untouched" {
  fake_install
  native_launcher
  uninst
  [ "$status" -eq 0 ]
  [ ! -e "$T/home/.local/bin/asb" ]
  [ ! -e "$T/home/.local/bin/agent-sandbox" ]
  [ "$("$T/home/.local/bin/claude")" = native ] # still a working agent
  [ ! -d "$T/home/.local/share/agent-sandbox" ] # engine and proxy runtime gone
  [ ! -f "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
}

@test "--uninstall keeps your allowlist and trust store; --purge-config removes them" {
  fake_install
  uninst
  [ -f "$T/home/.config/agent-sandbox/allowlist.txt" ] # a reinstall reuses them
  [[ "$output" == *"kept"* ]]
  fake_install
  uninst --purge-config
  [ ! -d "$T/home/.config/agent-sandbox" ]
}

@test "--uninstall --dry-run changes nothing, and installs nothing on the way" {
  fake_install
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove $T/home/.local/bin/asb"* ]]
  [ -L "$T/home/.local/bin/asb" ] # still there
  [ -d "$T/home/.local/share/agent-sandbox" ]
  [ -f "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
  # and the engine was NOT copied in on the way past: the uninstall must run
  # before the install work, or it installs what it is about to delete
  [ ! -d "$T/home/.local/share/agent-sandbox/app/profiles" ]
}

@test "--uninstall removes the asb and agent-sandbox it added, and only while they are as it left them" {
  local st="$T/home/.local/share/agent-sandbox"
  mkdir -p "$T/home/.local/bin" "$st/app"
  cp "$REPO_ROOT/agent-sandbox" "$st/app/agent-sandbox"
  ln -sfn "$st/app/agent-sandbox" "$T/home/.local/bin/asb"
  ln -sfn "$st/app/agent-sandbox" "$T/home/.local/bin/agent-sandbox"
  {
    printf 'version\t1\n'
    printf 'command\t%s\t%s\n' "$T/home/.local/bin/asb" "symlink $st/app/agent-sandbox"
    printf 'command\t%s\t%s\n' "$T/home/.local/bin/agent-sandbox" "symlink $st/app/agent-sandbox"
  } >"$st/install.manifest"
  rm "$T/home/.local/bin/agent-sandbox"
  printf '#!/bin/sh\n' >"$T/home/.local/bin/agent-sandbox" # replaced since: not ours to remove
  uninst
  [ "$status" -eq 0 ]
  [ ! -e "$T/home/.local/bin/asb" ]
  [ -f "$T/home/.local/bin/agent-sandbox" ]
  [[ "$output" == *"leave alone: $T/home/.local/bin/agent-sandbox (changed since install"* ]]
}

@test "--uninstall on a machine with nothing installed does nothing at all" {
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" != *"removed"* ]]
  [[ "$output" != *"leave alone"* ]]
}

# ---- the agent's own command is left alone (#151) --------------------------
# The installer adds `asb` and `agent-sandbox` and nothing at the agent's own name.

native_launcher() { # a machine with Claude Code installed the normal way
  mkdir -p "$T/home/.local/bin" "$T/home/.local/share/claude/versions"
  printf '#!/bin/sh\necho native\n' >"$T/home/.local/share/claude/versions/9.9.9"
  chmod +x "$T/home/.local/share/claude/versions/9.9.9"
  ln -sfn "$T/home/.local/share/claude/versions/9.9.9" "$T/home/.local/bin/claude"
}

@test "Claude Code's own launcher is left exactly as it is, and the install says how to reach the sandbox" {
  native_launcher
  dry
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/home/.local/bin/claude")" = "$T/home/.local/share/claude/versions/9.9.9" ]
  [ ! -e "$T/home/.local/bin/claude.pre-agent-sandbox" ]
  [[ "$output" != *"leave alone"* ]] # the agent's own command is not a finding
  [[ "$output" == *"\`claude\` is the agent itself"*"asb claude"* ]]
}

@test "the install writes only into its own HOME: a link to the engine at the agent's name elsewhere on PATH is left as it is" {
  # A local e2e run of the installer before #151 followed PATH out of the HOME it
  # was installing into and re-pointed the user's real launcher.
  mkdir -p "$T/elsewhere" "$T/home/.local/bin"
  ln -s "$REPO_ROOT/agent-sandbox" "$T/elsewhere/claude"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" \
    PATH="$T/home/.local/bin:$T/elsewhere:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/elsewhere/claude")" = "$REPO_ROOT/agent-sandbox" ]
  [ ! -e "$T/elsewhere/asb" ]
  [ "$(readlink "$T/home/.local/bin/asb")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [[ "$output" == *"\`claude\` on PATH is agent-sandbox, not the agent ($T/elsewhere/claude)"* ]]
}

@test "asb goes in ~/.local/bin even when that is not on PATH, with the line to add" {
  mkdir -p "$T/other"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" \
    PATH="$T/other:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [ -L "$T/home/.local/bin/asb" ]
  [ ! -e "$T/other/asb" ]
  [[ "$output" == *"is not on your PATH, so \`asb\` will not be found yet"*"export PATH="* ]]
}

@test "uninstall is re-runnable: what is already gone is reported, not an error" {
  fake_install
  rm "$T/home/.local/bin/asb"
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" == *"$T/home/.local/bin/asb is already gone"* ]]
  [ ! -e "$T/home/.local/bin/agent-sandbox" ]
  uninst # again, on a machine that is already clean
  [ "$status" -eq 0 ]
}

# ---- single-user tool: not through sudo -----------------------------------

@test "refuses to run through sudo, and says why, for install and uninstall alike" {
  # SUDO_USER set with euid 0 is the precise signal: a normal user reached root
  # through sudo. Faked here, since the test suite does not run as root.
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin \
    SUDO_USER=someone "$REPO_ROOT/tests/helpers/as-root.sh" "$REPO_ROOT/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"do not run this with sudo"* ]]
  [[ "$output" == *"single-user tool"* ]]
  [[ "$output" == *"systemd --user unit"* ]]
  [[ "$output" == *"asks for sudo itself"* ]] # ...and which step needs it
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin \
    SUDO_USER=someone "$REPO_ROOT/tests/helpers/as-root.sh" "$REPO_ROOT/install.sh" --uninstall
  [ "$status" -eq 2 ]
  # the uninstall case is the dangerous one: it would report success on the
  # wrong home, so the refusal names that outcome specifically
  [[ "$output" == *"report success while"* ]]
}

@test "plain root with no SUDO_USER is allowed: that is a container, not a mistake" {
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" \
    PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/tests/helpers/as-root.sh" "$REPO_ROOT/install.sh" --dry-run
  [[ "$output" != *"do not run this with sudo"* ]]
}
