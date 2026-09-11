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
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin "${envs[@]}" "$REPO_ROOT/install.sh" --dry-run "$@"
}

@test "--dry-run: writes config, seeds the profile hosts, renders the unit with the proxy path, symlinks the profile command; nothing privileged" {
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
  ! grep -q '@' "$unit"
  [ "$(readlink "$T/home/.local/bin/claude")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # a real copy, not the checkout
  cmp -s "$T/home/.local/share/agent-sandbox/app/agent-sandbox" "$REPO_ROOT/agent-sandbox"
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude.sh" ]
  [ "$(cat "$T/home/.local/share/agent-sandbox/app/VERSION")" = "$(cat "$REPO_ROOT/VERSION")" ] # version copied with the engine
  [[ "$output" == *"(dry-run) would run: systemctl --user daemon-reload"* ]]
  [[ "$output" == *"(dry-run) proxy request skipped"* ]]
  [[ "$output" != *"sudo "* ]] || [[ "$output" == *"(dry-run)"*"sudo"* ]]
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

@test "legacy layout is migrated: config dir moved, old unit reported, claude.sh symlink re-pointed" {
  mkdir -p "$T/home/.config/claude-sandbox" "$T/home/.config/systemd/user" "$T/home/.local/bin"
  echo "github.com" >"$T/home/.config/claude-sandbox/allowlist.txt"
  : >"$T/home/.config/systemd/user/claude-mitmproxy.service"
  ln -s /somewhere/claude.sh "$T/home/.local/bin/claude"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrated ~/.config/claude-sandbox"* ]]
  [ ! -d "$T/home/.config/claude-sandbox" ]
  grep -q '^github.com$' "$T/home/.config/agent-sandbox/allowlist.txt"
  grep -q '^api.anthropic.com$' "$T/home/.config/agent-sandbox/allowlist.txt"
  [[ "$output" == *"would disable and remove the legacy claude-mitmproxy.service"* ]]
  [[ "$output" == *"re-pointed"*"legacy claude.sh"* ]]
  [ "$(readlink "$T/home/.local/bin/claude")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
}

@test "--dev points the launcher at the checkout and warns; a later true install re-points it to the copy" {
  dry -- --dev
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/home/.local/bin/claude")" = "$REPO_ROOT/agent-sandbox" ]
  [ ! -e "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # --dev copies nothing
  [[ "$output" == *"run on the host at the next launch"* ]]
  grep -q "^Documentation=file:$REPO_ROOT/agent-sandbox" "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
  dry # default (copy) re-points the launcher away from the checkout
  [ "$status" -eq 0 ]
  [ "$(readlink "$T/home/.local/bin/claude")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [[ "$output" == *"re-pointed"* ]]
}

@test "a dangling symlink is replaced; a regular file is left untouched with a warning" {
  mkdir -p "$T/home/.local/bin"
  ln -s /gone/binary "$T/home/.local/bin/claude"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced dangling symlink"* ]]
  rm -f "$T/home/.local/bin/claude"
  echo x >"$T/home/.local/bin/claude"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the expected symlink (left untouched)"* ]]
  [ "$(cat "$T/home/.local/bin/claude")" = x ]
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
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin AGENT_SANDBOX_REPO="$REPO_ROOT" "$T/alone/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloning $REPO_ROOT"* ]]
  [ -f "$T/home/.local/share/agent-sandbox/src/agent-sandbox" ]
  [ "$(readlink "$T/home/.local/bin/claude")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # copied out of the clone
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin AGENT_SANDBOX_REPO="$REPO_ROOT" "$T/alone/install.sh" --dry-run
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

# ---- --uninstall (issue #22) ----------------------------------------------
# The launcher is a symlink to the engine, so a careless uninstall leaves no
# `claude` on PATH at all. These pin the two rules: repoint rather than delete,
# and never touch what the installer did not create.

uninst() { # uninst [extra args...] -- a real (not dry) uninstall, no prompt
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin \
    "$REPO_ROOT/install.sh" --uninstall --yes "$@"
}

# a HOME that looks like a completed install
fake_install() {
  mkdir -p "$T/home/.local/bin" "$T/home/.local/share/agent-sandbox/app" \
    "$T/home/.local/share/claude/versions" "$T/home/.config/agent-sandbox/trust" \
    "$T/home/.config/systemd/user"
  printf '#!/bin/sh\necho real-claude\n' >"$T/home/.local/share/claude/versions/9.9.9"
  chmod +x "$T/home/.local/share/claude/versions/9.9.9"
  cp "$REPO_ROOT/agent-sandbox" "$T/home/.local/share/agent-sandbox/app/agent-sandbox"
  ln -sfn "$T/home/.local/share/agent-sandbox/app/agent-sandbox" "$T/home/.local/bin/claude"
  printf 'example.com\n' >"$T/home/.config/agent-sandbox/allowlist.txt"
  : >"$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
}

@test "--uninstall: the launcher is repointed at the agent's own binary, not deleted" {
  fake_install
  uninst
  [ "$status" -eq 0 ]
  [ -L "$T/home/.local/bin/claude" ]
  [ "$(readlink -f "$T/home/.local/bin/claude")" = "$T/home/.local/share/claude/versions/9.9.9" ]
  [ "$("$T/home/.local/bin/claude")" = "real-claude" ] # still a working agent
  [ ! -d "$T/home/.local/share/agent-sandbox" ]        # engine and proxy runtime gone
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
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH=/usr/bin:/bin \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repoint"* ]]
  [ -d "$T/home/.local/share/agent-sandbox" ] # still there
  [ -f "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
  # and the engine was NOT copied in on the way past: the uninstall must run
  # before the install work, or it installs what it is about to delete
  [ ! -d "$T/home/.local/share/agent-sandbox/app/profiles" ]
}

@test "--uninstall leaves a launcher that is not ours alone" {
  fake_install
  rm -f "$T/home/.local/bin/claude"
  printf '#!/bin/sh\necho someone-elses\n' >"$T/home/.local/bin/claude"
  chmod +x "$T/home/.local/bin/claude"
  uninst
  [ "$status" -eq 0 ]
  [ "$("$T/home/.local/bin/claude")" = "someone-elses" ]
  [[ "$output" == *"leave alone"* ]]
}

@test "--uninstall does not repoint into nothing when the agent's binary is gone" {
  fake_install
  rm -rf "$T/home/.local/share/claude"
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" == *"leave alone"* ]]
  # ...and it says the launcher is now broken, rather than leaving that to be
  # discovered the next time the user types the command
  [[ "$output" == *"broken link"* ]]
}

@test "--uninstall on a machine with nothing installed does nothing at all" {
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" != *"removed"* ]]
  [[ "$output" != *"repoint"* ]]
}
