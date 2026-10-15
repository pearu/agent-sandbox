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

@test "--dry-run: writes config, renders the unit with the proxy path, symlinks asb and agent-sandbox; nothing privileged" {
  dry
  [ "$status" -eq 0 ]
  [ -f "$T/home/.config/agent-sandbox/allowlist_addon.py" ]
  [ -f "$T/home/.config/agent-sandbox/allowlist.txt" ]
  # a profile's hosts are its dot-file's [allow], opened per launch, not seeded here (#181)
  [ "$(grep -c '^api.anthropic.com$' "$T/home/.config/agent-sandbox/allowlist.txt")" -eq 0 ]
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude/profile.sh" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude/agent-sandbox" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/models/roles/agent-sandbox" ]
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
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude/profile.sh" ]
  [ "$(cat "$T/home/.local/share/agent-sandbox/app/VERSION")" = "$(cat "$REPO_ROOT/VERSION")" ] # version copied with the engine
  [[ "$output" == *"(dry-run) would run: systemctl --user daemon-reload"* ]]
  [[ "$output" == *"(dry-run) proxy request skipped"* ]]
  [[ "$output" != *"sudo "* ]] || [[ "$output" == *"(dry-run)"*"sudo"* ]]
  run ! grep -q '@' "$unit"
  cmp -s "$T/home/.config/agent-sandbox/allowlist_addon.py" "$REPO_ROOT/components/allowlist_addon.py"
}

@test "re-run is idempotent: allowlist kept, symlink already correct" {
  dry
  echo "my.custom.host" >>"$T/home/.config/agent-sandbox/allowlist.txt"
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists (kept as-is)"* ]]
  [[ "$output" == *"already points at the engine"* ]]
  grep -qx my.custom.host "$T/home/.config/agent-sandbox/allowlist.txt"
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

# apt-cache policy with this Candidate (none: apt has no bubblewrap), then a version
# table far above a pipe buffer: a reader that stops at the Candidate line kills
# apt-cache with SIGPIPE, which pipefail turned into the installer's death (#251)
stub_apt_cache() {
  cat >"$T/bin/apt-cache" <<STUB
#!/usr/bin/env bash
printf 'bubblewrap:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' '$1'
for i in \$(seq 1 4000); do
  printf '        500 http://example/%s/ubuntu resolute/main amd64 Packages\n' "\$i"
done
STUB
  chmod +x "$T/bin/apt-cache"
}

# an /etc/os-release for AGENT_SANDBOX_OS_RELEASE: ID, ID_LIKE, VERSION_CODENAME
fake_os_release() {
  printf 'ID=%s\nID_LIKE="%s"\nVERSION_CODENAME=%s\n' "$1" "$2" "$3" >"$T/os-release"
}

@test "--dry-run warns when bubblewrap is older than 0.12.0 (CVE-2026-87766), and not at 0.12.0 or newer" {
  mkdir -p "$T/bin"
  stub_apt_cache '(none)'
  fake_os_release fedora '' ''
  local v
  for v in 0.9.0 0.11.1; do
    stub_bwrap "$v"
    run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
      AGENT_SANDBOX_OS_RELEASE="$T/os-release" "$REPO_ROOT/install.sh" --dry-run
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

@test "the old-bubblewrap warning names the route that applies: apt, --rebuild-bwrap on Ubuntu, the docs elsewhere" {
  mkdir -p "$T/bin"
  stub_bwrap 0.11.1
  warned() { # warned CANDIDATE ID ID_LIKE
    stub_apt_cache "$1"
    fake_os_release "$2" "$3" resolute
    run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
      AGENT_SANDBOX_OS_RELEASE="$T/os-release" "$REPO_ROOT/install.sh" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"bubblewrap 0.11.1 is older than 0.12.0"*"CVE-2026-87766"* ]]
  }
  # apt already has a fixed one: install it, no rebuild
  warned 0.12.0-1 ubuntu debian
  [[ "$output" == *"apt offers bubblewrap 0.12.0-1: sudo apt install bubblewrap"* ]]
  [[ "$output" != *"--rebuild-bwrap"* ]]
  # Ubuntu (by ID or ID_LIKE) whose apt has none: the option
  warned 0.11.1-1ubuntu0.3 ubuntu debian
  [[ "$output" == *"run: ./install.sh --rebuild-bwrap (Ubuntu's own 0.12.0-1 source"* ]]
  [[ "$output" != *"sudo apt install bubblewrap"* ]]
  warned 0.11.1-1ubuntu0.3 pop "ubuntu debian"
  [[ "$output" == *"run: ./install.sh --rebuild-bwrap"* ]]
  # not Ubuntu: the docs, never the option
  warned '(none)' fedora ''
  [[ "$output" == *"see docs/troubleshooting.md, 'bubblewrap older than 0.12.0'"* ]]
  [[ "$output" != *"--rebuild-bwrap"* ]]
}

# ---- --rebuild-bwrap ---------------------------------------------------------
# Ubuntu's own 0.12.0-1 source, rebuilt locally; its dry run touches nothing.

rebuild() { # rebuild [extra args...] -- with $T/bin first on PATH and the fake os-release
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_OS_RELEASE="$T/os-release" TMPDIR="$T/tmp" "$REPO_ROOT/install.sh" --rebuild-bwrap "$@"
}

# commands a dry run must never call; each records that it was
stub_recorders() {
  local c
  for c in sudo curl dpkg-source dpkg-buildpackage; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/called"\n' "$c" "$T" >"$T/bin/$c"
    chmod +x "$T/bin/$c"
  done
}

@test "--rebuild-bwrap --dry-run prints the plan, with the local version and the pinned sums, and runs nothing" {
  mkdir -p "$T/bin"
  stub_bwrap 0.11.1
  stub_apt_cache 0.11.1-1ubuntu0.3
  fake_os_release ubuntu debian resolute
  stub_recorders
  rebuild --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"builds bubblewrap 0.12.0-1~resolute1 from https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/bubblewrap/0.12.0-1 in $T/tmp/agent-sandbox-bwrap-0.12.0-1"* ]]
  [[ "$output" == *"e81987f8d90b30b581299870592affaa8d9a17caf05112d303916312b7afd60a  bubblewrap_0.12.0-1.dsc"* ]]
  [[ "$output" == *"9760d007363e3abba7c747489910f9f82d9fca53ba3bd3282e396fa3c97a3314  bubblewrap_0.12.0.orig.tar.xz"* ]]
  [[ "$output" == *"60691fa8488db2de4dd19d59fb0b084e692695c38616dcf8e20b08a4d372ab93  bubblewrap_0.12.0-1.debian.tar.xz"* ]]
  [[ "$output" == *"(dry-run) would run: sudo apt-mark hold bubblewrap"*"(dry-run) would run: sudo apt-get build-dep -y ./bubblewrap_0.12.0-1.dsc"*"dpkg-buildpackage -us -uc -b"*"(dry-run) would run: sudo apt-get install -y --allow-change-held-packages ./bubblewrap_0.12.0-1~resolute1_"*".deb"*"(dry-run) would run: sudo apt-mark unhold bubblewrap"* ]]
  [ ! -e "$T/called" ] # no sudo, no download, no build
  [ ! -e "$T/tmp/agent-sandbox-bwrap-0.12.0-1" ]
  [ ! -e "$T/home/.local/share/agent-sandbox" ] # and none of the plain install on the way
}

@test "--rebuild-bwrap refuses off Ubuntu, and says where to look" {
  mkdir -p "$T/bin"
  stub_bwrap 0.11.1
  stub_recorders
  fake_os_release fedora '' ''
  rebuild --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs Ubuntu with apt-get and dpkg"*"docs/troubleshooting.md"* ]]
  [ ! -e "$T/called" ]
}

@test "--rebuild-bwrap, stubbed for real: apt can read the work dir and the .deb; sudo steps in order" {
  mkdir -p "$T/bin"
  stub_apt_cache 0.11.1-1ubuntu0.3
  fake_os_release ubuntu debian resolute
  stub_recorders
  local deb
  deb="bubblewrap_0.12.0-1~resolute1_$(dpkg --print-architecture).deb"
  # bwrap is 0.11.1 until sudo installs the .deb, 0.12.0 after; the build tools make
  # what the next step reads, the .deb owner-only as a 077 umask would leave it
  cat >"$T/bin/bwrap" <<STUB
#!/usr/bin/env bash
[[ "\$1" == --version ]] && { [[ -e "$T/installed" ]] && echo "bubblewrap 0.12.0" || echo "bubblewrap 0.11.1"; }
exit 0
STUB
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s/called"\n[[ "$*" == *.deb ]] && touch "%s/installed"\nexit 0\n' "$T" "$T" >"$T/bin/sudo"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sha256sum"
  cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
touch "$3"
STUB
  cat >"$T/bin/dpkg-source" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$3/debian" && echo old >"$3/debian/changelog"
STUB
  printf '#!/usr/bin/env bash\ntouch "../%s" && chmod 600 "../%s"\n' "$deb" "$deb" >"$T/bin/dpkg-buildpackage"
  chmod +x "$T/bin/"*
  rebuild
  [ "$status" -eq 0 ]
  [[ "$output" == *"bubblewrap 0.12.0 is installed and runs a sandbox"* ]]
  local work="$T/tmp/agent-sandbox-bwrap-0.12.0-1"
  [ "$(stat -c %a "$work")" = 755 ]
  [ "$(stat -c %a "$work/$deb")" = 644 ]
  grep -q '^bubblewrap (0.12.0-1~resolute1) resolute; urgency=medium$' "$work/src/debian/changelog"
  [ "$(grep '^sudo ' "$T/called")" = "sudo apt-mark hold bubblewrap
sudo apt-get update
sudo apt-get install -y build-essential fakeroot dpkg-dev
sudo apt-get build-dep -y ./bubblewrap_0.12.0-1.dsc
sudo apt-get install -y --allow-change-held-packages ./$deb
sudo apt-mark unhold bubblewrap" ]
}

@test "--rebuild-bwrap has nothing to do at 0.12.0, and sends to apt when apt has 0.12.0" {
  mkdir -p "$T/bin"
  stub_recorders
  fake_os_release ubuntu debian noble
  stub_apt_cache 0.9.0-1ubuntu0.3
  stub_bwrap 0.12.0
  rebuild
  [ "$status" -eq 0 ]
  [[ "$output" == *"bubblewrap 0.12.0 is installed, 0.12.0 or newer: nothing to rebuild"* ]]
  [[ "$output" != *"would run"* ]]
  stub_bwrap 0.9.0
  stub_apt_cache 0.12.0-1
  rebuild
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt offers bubblewrap 0.12.0-1, 0.12.0 or newer: run  sudo apt install bubblewrap  instead"* ]]
  [ ! -e "$T/called" ]
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

# ---- agent-sandbox's own micromamba, and which conda sandboxes use --------------------
MM_SUM_X86=366cd9cd8be14df1ab8ed50352a82111082a36686b2d389fdb79a92c3fafb3e3

# step [ENV=VAL ...] [-- ARGS] -- install.sh's micromamba step alone, for real (not a dry
# run), with $T/bin first on PATH; answers to its question from $T/answers.
step() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  mkdir -p "$T/bin"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_INSTALL_STEP=micromamba AGENT_SANDBOX_TTY="$T/answers" "${envs[@]}" "$REPO_ROOT/install.sh" "$@"
}

# no host conda: a CI runner has conda on PATH, so `conda`/`mamba` stubs that find no base
# come first ($T/bin), and env -i leaves none of MAMBA_ROOT_PREFIX, CONDA_ROOT_PREFIX,
# CONDA_PYTHON_EXE, CONDA_PREFIX, CONDA_EXE, MAMBA_EXE in the installer's environment
stub_no_host_conda() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$T/bin/mamba"
  chmod +x "$T/bin/conda" "$T/bin/mamba"
}

# a host conda the engine's discovery finds: `conda info --base` names $T/hostconda
stub_host_conda() {
  mkdir -p "$T/bin" "$T/hostconda"
  # shellcheck disable=SC2016 # $1 $2 are the stub's own arguments
  printf '#!/bin/sh\n[ "$1 $2" = "info --base" ] && echo %s\n' "$T/hostconda" >"$T/bin/conda"
  chmod +x "$T/bin/conda"
}

# a curl that serves a fake micromamba, and as its .sha256 the given sum
stub_curl_micromamba() {
  mkdir -p "$T/bin"
  cat >"$T/bin/curl" <<STUB
#!/usr/bin/env bash
out=""
for ((i = 1; i <= \$#; i++)); do [[ "\${!i}" == -o ]] && { j=\$((i + 1)); out="\${!j}"; }; done
url="\${!#}"
echo "curl \$url" >>"$T/called"
if [[ "\$url" == *.sha256 ]]; then echo "$1"; else printf 'fake micromamba\n' >"\$out"; fi
STUB
  chmod +x "$T/bin/curl"
}

@test "--dry-run: the micromamba step prints the fetch, the pinned sum and the paths; the conda question's answer is not written" {
  [[ "$(uname -m)" == x86_64 ]] || skip "the pinned sum asserted here is linux-64's"
  stub_no_host_conda
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  local st="$T/home/.local/share/agent-sandbox"
  [[ "$output" == *"(dry-run) would fetch https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-64"* ]]
  [[ "$output" == *"(dry-run) check it against the pinned SHA-256 $MM_SUM_X86 (and the release's micromamba-linux-64.sha256)"* ]]
  [[ "$output" == *"(dry-run) and install it as $st/micromamba/bin/micromamba (mode 755)"* ]]
  [[ "$output" == *"(dry-run) would create the conda root $st/conda (empty; environments go under envs/)"* ]]
  [ ! -e "$st/micromamba" ] && [ ! -e "$st/conda" ]
  # no conda on this host: sandbox, said, not written
  [[ "$output" == *"(dry-run) would write 'sandbox' to $T/home/.config/agent-sandbox/conda (no conda on this host)"* ]]
  [ ! -e "$T/home/.config/agent-sandbox/conda" ]
  # a host conda: the question, printed
  stub_host_conda
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) would ask: Sandboxes use the host's conda at $T/hostconda, or agent-sandbox's own micromamba? [host/sandbox]"* ]]
  [ ! -e "$T/home/.config/agent-sandbox/conda" ]
}

@test "the micromamba step for real: fetched, checked against the pinned sum and the release's .sha256, installed 755; then present" {
  [[ "$(uname -m)" == x86_64 ]] || skip "the pinned sum asserted here is linux-64's"
  local mm="$T/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  # the fake binary is not the release: the pinned sum refuses it, nothing installed
  stub_curl_micromamba "$MM_SUM_X86"
  step
  [ "$status" -ne 0 ]
  [[ "$output" == *"micromamba-linux-64 does not match the pinned SHA-256 $MM_SUM_X86; nothing was installed"* ]]
  [ ! -e "$mm" ] && [ ! -e "$mm.part" ]
  # a sha256sum that agrees (the fake is "the release"): installed, the cross-check fetched
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sha256sum"
  chmod +x "$T/bin/sha256sum"
  step
  [ "$status" -eq 0 ]
  [[ "$output" == *"micromamba 2.9.0-0 installed: $mm (SHA-256 $MM_SUM_X86)"* ]]
  [[ "$output" == *"created the conda root $T/home/.local/share/agent-sandbox/conda"* ]]
  [ "$(stat -c %a "$mm")" = 755 ]
  [ -d "$T/home/.local/share/agent-sandbox/conda" ]
  grep -qx "curl https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-64.sha256" "$T/called"
  # again: present and verified, nothing fetched
  : >"$T/called"
  step
  [ "$status" -eq 0 ]
  [[ "$output" == *"micromamba 2.9.0-0 present: $mm"* ]]
  [ ! -s "$T/called" ]
  # the release's .sha256 disagreeing with the pin: refused
  rm -f "$mm"
  stub_curl_micromamba 0000000000000000000000000000000000000000000000000000000000000000
  step
  [ "$status" -ne 0 ]
  [[ "$output" == *"the release's micromamba-linux-64.sha256 says 0000"*", the pinned sum is $MM_SUM_X86; nothing was installed"* ]]
  [ ! -e "$mm" ]
}

@test "which conda sandboxes use: asked where the host has conda, sandbox without asking where it has none, --yes says host, a file there is kept" {
  [[ "$(uname -m)" == x86_64 ]] || skip "the stubbed .sha256 is linux-64's"
  local f="$T/home/.config/agent-sandbox/conda"
  stub_curl_micromamba "$MM_SUM_X86"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sha256sum"
  chmod +x "$T/bin/sha256sum"
  # no conda on the host: sandbox, nothing asked
  stub_no_host_conda
  : >"$T/answers"
  step
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = sandbox ]
  [[ "$output" == *"(no conda on this host): wrote 'sandbox' to $f"* ]]
  [[ "$output" != *"[host/sandbox]"* ]]
  # a file there is kept, and not asked over
  stub_host_conda
  step
  [ "$status" -eq 0 ]
  [[ "$output" == *"$f kept (sandbox): sandboxes use agent-sandbox's micromamba"* ]]
  [[ "$output" != *"[host/sandbox]"* ]]
  # a host conda, answered host (after an answer that is neither)
  rm "$f"
  printf 'maybe\nhost\n' >"$T/answers"
  step
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sandboxes use the host's conda at $T/hostconda, or agent-sandbox's own micromamba? [host/sandbox]"* ]]
  [ "$(cat "$f")" = host ]
  # answered sandbox
  rm "$f"
  printf 'sandbox\n' >"$T/answers"
  step
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = sandbox ]
  # --yes: host, not asked
  rm "$f"
  printf 'sandbox\n' >"$T/answers"
  step -- --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = host ]
  [[ "$output" != *"[host/sandbox]"* ]]
  # nothing to ask on: host, said
  rm "$f"
  step AGENT_SANDBOX_TTY="$T/no/such/tty"
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = host ]
  [[ "$output" == *"no terminal to ask on"* ]]
}

@test "--uninstall: the micromamba goes; the sandboxes' conda environments are asked about, and --yes keeps them" {
  fake_install
  local st="$T/home/.local/share/agent-sandbox"
  mkdir -p "$st/micromamba/bin" "$st/conda/envs/dev"
  : >"$st/micromamba/bin/micromamba"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove agent-sandbox's micromamba, $st/micromamba/bin/micromamba"* ]]
  [[ "$output" == *"remove $st, all but $st/conda (asked below)"* ]]
  [[ "$output" == *"(dry-run) would ask: $st/conda -- the sandboxes' conda environments live there: remove? [y/N] (--yes keeps it)"* ]]
  [ -e "$st/micromamba/bin/micromamba" ]
  # --yes: everything but the environments
  uninst
  [ "$status" -eq 0 ]
  [ "$(ls -A "$st")" = conda ] && [ -d "$st/conda/envs/dev" ]
  [[ "$output" == *"$st/conda kept: the sandboxes' conda environments"* ]]
  # asked, and answered yes (then the plan's own question): all of it
  fake_install
  printf 'y\ny\n' >"$T/answers"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_TTY="$T/answers" "$REPO_ROOT/install.sh" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"the sandboxes' conda environments live there: remove? [y/N]"* ]]
  [ ! -d "$st" ]
}
