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

# A `systemctl` first on PATH that reaches a user manager (every call succeeds), or with
# NONE set, one that reaches none, as for an account that never logs in.
systemctl_stub() {
  mkdir -p "$T/home/.local/bin"
  if [[ "${1:-}" == none ]]; then
    printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' >"$T/home/.local/bin/systemctl"
  else
    printf '#!/bin/sh\nexit 0\n' >"$T/home/.local/bin/systemctl"
  fi
  chmod +x "$T/home/.local/bin/systemctl"
}

@test "--dry-run: writes config, renders the unit with the proxy path, symlinks asb and agent-sandbox; nothing privileged" {
  systemctl_stub
  dry
  [ "$status" -eq 0 ]
  [ -f "$T/home/.config/agent-sandbox/allowlist_addon.py" ]
  [ -f "$T/home/.config/agent-sandbox/allowlist.txt" ]
  # a profile's hosts are its dot-file's [allow], opened per launch, not seeded here (#181)
  [ "$(grep -c '^api.anthropic.com$' "$T/home/.config/agent-sandbox/allowlist.txt")" -eq 0 ]
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude/profile.sh" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/claude/agent-sandbox" ]
  [ ! -e "$T/home/.local/share/agent-sandbox/app/profiles/claude/test.bash" ] # the test suites', not installed
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

# ---- the proxy's environment: made with agent-sandbox's micromamba (#335) -----------

# host_conda_stubs -- a `conda`, `mamba` and `python3` first in $T/bin that record every
# call in $T/host-called and succeed: what install.sh must not build the proxy env with.
host_conda_stubs() {
  mkdir -p "$T/bin"
  local c
  for c in conda mamba python3; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/host-called"\nexit 0\n' "$c" "$T" >"$T/bin/$c"
    chmod +x "$T/bin/$c"
  done
}

@test "--dry-run: a new proxy env would be created with agent-sandbox's micromamba, whatever conda or python the host has" {
  host_conda_stubs
  local st="$T/home/.local/share/agent-sandbox"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    MAMBA_EXE="$T/bin/mamba" CONDA_EXE="$T/bin/conda" "$REPO_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) would create $st/proxy-env with micromamba ($st/micromamba/bin/micromamba) from conda-forge: 'mitmproxy>=12,<13' pip"* ]]
  [[ "$output" != *"proxy-venv"* ]]
  grep -q "^ExecStart=$st/proxy-env/bin/mitmdump" "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"
  # the micromamba comes first: its section is before the proxy's
  [[ "$output" == *"==> micromamba ("*"==> Egress proxy (mitmproxy)"* ]]
}

# proxy_step [ENV=VAL ...] -- install.sh's proxy-env step alone, for real, against a stub
# micromamba at the installed path; $T/bin (host_conda_stubs) first on PATH, and a
# systemctl there that does nothing, should anything get as far as the unit.
proxy_step() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/systemctl" && chmod +x "$T/bin/systemctl"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$@" \
    AGENT_SANDBOX_INSTALL_STEP=proxy "$REPO_ROOT/install.sh"
}

# a micromamba that "creates" -p PREFIX with a bin/mitmdump reporting mitmproxy 12.3.1
# and a bin/pip, registers it as micromamba does, and records its argv, CONDA_PKGS_DIRS
# and MAMBA_ROOT_PREFIX in $T/mm-called ($T/mm-fail present: it fails, after a partial env)
stub_proxy_micromamba() {
  local mm="$T/home/.local/share/agent-sandbox/micromamba/bin"
  mkdir -p "$mm"
  cat >"$mm/micromamba" <<STUB
#!/usr/bin/env bash
echo "\$* | CONDA_PKGS_DIRS=\${CONDA_PKGS_DIRS:-} MAMBA_ROOT_PREFIX=\${MAMBA_ROOT_PREFIX:-}" >>"$T/mm-called"
prefix=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == -p ]] && prefix="\$2"
  shift
done
mkdir -p "\$prefix/bin" "\$prefix/conda-meta" "\$HOME/.conda"
echo "\$prefix" >>"\$HOME/.conda/environments.txt"
[[ -e "$T/mm-fail" ]] && { echo "critical libmamba nothing provides mitmproxy" >&2; exit 1; }
printf '#!/bin/sh\necho "Mitmproxy: 12.3.1"\necho "Python: 3.14.10"\n' >"\$prefix/bin/mitmdump"
printf '#!/bin/sh\nexit 0\n' >"\$prefix/bin/pip"
chmod +x "\$prefix/bin/mitmdump" "\$prefix/bin/pip"
STUB
  chmod +x "$mm/micromamba"
}

@test "proxy env: created with agent-sandbox's micromamba from conda-forge, the tools env's root and cache; the host's conda and python untouched" {
  stub_proxy_micromamba
  host_conda_stubs
  local st="$T/home/.local/share/agent-sandbox"
  mkdir -p "$T/home/.conda" && echo /my/env >"$T/home/.conda/environments.txt"
  proxy_step MAMBA_EXE="$T/bin/mamba" CONDA_EXE="$T/bin/conda" MAMBA_ROOT_PREFIX=/host/conda CONDA_PREFIX=/host/conda
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating $st/proxy-env with micromamba from conda-forge: 'mitmproxy>=12,<13' pip"* ]]
  [[ "$output" == *"installed into $st/proxy-env"* ]]
  [[ "$output" == *"mitmdump 12.3.1 at $st/proxy-env/bin/mitmdump"* ]]
  [ "$(cat "$T/mm-called")" = "create -q -y -r $st/tools -p $st/proxy-env --override-channels -c conda-forge mitmproxy>=12,<13 pip | CONDA_PKGS_DIRS=$st/tools/pkgs MAMBA_ROOT_PREFIX=" ]
  [ ! -e "$T/host-called" ] # neither conda, mamba nor python3 was asked
  [ ! -e "$st/proxy-venv" ]
  [ ! -e "$st/proxy-env.log" ]
  # micromamba's registration of the env is undone; the user's own envs stay listed
  [ "$(cat "$T/home/.conda/environments.txt")" = /my/env ]
}

@test "proxy env: a working one is kept, proxy-env or an older proxy-venv; nothing is created" {
  stub_proxy_micromamba
  local st="$T/home/.local/share/agent-sandbox" d
  for d in proxy-env proxy-venv; do
    rm -rf "${st:?}/proxy-env" "$st/proxy-venv" "$T/mm-called"
    mkdir -p "$st/$d/bin"
    printf '#!/bin/sh\necho "Mitmproxy: 12.1.2"\n' >"$st/$d/bin/mitmdump"
    chmod +x "$st/$d/bin/mitmdump"
    proxy_step
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing $st/$d"* ]]
    [[ "$output" == *"mitmdump 12.1.2 at $st/$d/bin/mitmdump"* ]]
    [ ! -e "$T/mm-called" ]
  done
}

@test "proxy env: a broken one is removed and the proxy env recreated with micromamba" {
  stub_proxy_micromamba
  local st="$T/home/.local/share/agent-sandbox" d
  for d in proxy-venv proxy-env; do
    rm -rf "${st:?}/proxy-env" "$st/proxy-venv" "$T/mm-called"
    mkdir -p "$st/$d/bin"
    printf '#!/bin/sh\necho "ModuleNotFoundError: No module named mitmproxy" >&2\nexit 1\n' >"$st/$d/bin/mitmdump"
    chmod +x "$st/$d/bin/mitmdump"
    proxy_step
    [ "$status" -eq 0 ]
    [[ "$output" == *"[warn] $st/$d is broken: ModuleNotFoundError: No module named mitmproxy -- recreating it"* ]]
    grep -q "^create -q -y -r $st/tools -p $st/proxy-env --override-channels -c conda-forge mitmproxy>=12,<13 pip |" "$T/mm-called"
    [[ "$output" == *"mitmdump 12.3.1 at $st/proxy-env/bin/mitmdump"* ]]
    if [ "$d" = proxy-venv ]; then [ ! -e "$st/$d" ]; fi
  done
}

@test "proxy env: a failed create stops the install with micromamba's last line and the log; no half-made env is left" {
  stub_proxy_micromamba
  local st="$T/home/.local/share/agent-sandbox"
  : >"$T/mm-fail"
  proxy_step
  [ "$status" -eq 1 ]
  [[ "$output" == *"[err] creating $st/proxy-env with micromamba failed (critical libmamba nothing provides mitmproxy); the log is $st/proxy-env.log"* ]]
  [ ! -e "$st/proxy-env" ]
  [ -s "$st/proxy-env.log" ]
  [ ! -s "$T/home/.conda/environments.txt" ]
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

@test "--dry-run without curl: a micromamba already in place (as --setup-remote carries it to a remote account) needs none; without one, curl is a missing package (#344)" {
  [[ "$(uname -m)" == x86_64 ]] || skip "the asset name asserted here is linux-64's"
  stub_no_host_conda
  # PATH: the system's tools without curl
  local f
  mkdir -p "$T/nocurl"
  for f in /usr/bin/* /bin/*; do
    [[ "${f##*/}" == curl || -e "$T/nocurl/${f##*/}" ]] || ln -s "$f" "$T/nocurl/${f##*/}"
  done
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:$T/nocurl" "$REPO_ROOT/install.sh" --dry-run
  [[ "$output" == *"(dry-run) missing packages a real run needs: "*curl* ]]
  # micromamba there, by the pinned sum (a sha256sum that agrees: the fake is "the release")
  local mm="$T/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  mkdir -p "${mm%/*}"
  printf 'fake micromamba\n' >"$mm"
  chmod 755 "$mm"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sha256sum"
  chmod +x "$T/bin/sha256sum"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:$T/nocurl" "$REPO_ROOT/install.sh" --dry-run
  [[ "$output" == *"no curl: micromamba 2.9.0-0 is here already ($mm), so nothing is fetched with it"* ]]
  [[ "$output" != *"missing packages a real run needs: "*curl* ]]
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

# a curl whose GitHub release download fails; micro.mamba.pm serves a conda package with
# a fake bin/micromamba, unless $1 is "down" (then it fails too)
stub_curl_github_down() {
  mkdir -p "$T/bin" "$T/pkg/bin"
  printf 'fake micromamba\n' >"$T/pkg/bin/micromamba"
  tar -cjf "$T/pkg.tar.bz2" -C "$T/pkg" bin/micromamba
  cat >"$T/bin/curl" <<STUB
#!/usr/bin/env bash
out=""
for ((i = 1; i <= \$#; i++)); do [[ "\${!i}" == -o ]] && { j=\$((i + 1)); out="\${!j}"; }; done
url="\${!#}"
echo "curl \$url" >>"$T/called"
case "\$url" in
  https://micro.mamba.pm/*) [[ "${1:-}" != down ]] && cp "$T/pkg.tar.bz2" "\$out" && exit 0 ;;
esac
exit 22
STUB
  chmod +x "$T/bin/curl"
}

@test "the micromamba step: GitHub's download failing, the same build from micro.mamba.pm, checked against the pinned sum" {
  [[ "$(uname -m)" == x86_64 ]] || skip "the pinned sum and platform asserted here are linux-64's"
  local mm="$T/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  stub_no_host_conda
  : >"$T/answers"
  # the fake binary is not the release: the pinned sum refuses it, nothing installed
  stub_curl_github_down
  step
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed; trying https://micro.mamba.pm/api/micromamba/linux-64/2.9.0 (the same build, as a conda package)"* ]]
  [[ "$output" == *"micromamba-linux-64 does not match the pinned SHA-256 $MM_SUM_X86; nothing was installed"* ]]
  [ ! -e "$mm" ] && [ ! -e "$mm.part" ]
  # a sha256sum that agrees: installed from the fallback; the release's .sha256 cannot be had
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sha256sum"
  chmod +x "$T/bin/sha256sum"
  : >"$T/called"
  step
  [ "$status" -eq 0 ]
  [[ "$output" == *"micromamba 2.9.0-0 installed: $mm (SHA-256 $MM_SUM_X86)"* ]]
  [[ "$output" == *"could not fetch micromamba-linux-64.sha256 to cross-check; the pinned SHA-256 matched"* ]]
  [ "$(cat "$mm")" = "fake micromamba" ]
  [ "$(stat -c %a "$mm")" = 755 ]
  grep -qx "curl https://micro.mamba.pm/api/micromamba/linux-64/2.9.0" "$T/called"
  # both down: refused, nothing installed
  rm -f "$mm"
  stub_curl_github_down down
  step
  [ "$status" -ne 0 ]
  [[ "$output" == *"and https://micro.mamba.pm/api/micromamba/linux-64/2.9.0 too"* ]]
  [ ! -e "$mm" ] && [ ! -e "$mm.part" ]
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

@test "--uninstall: the micromamba and the tools env go; the sandboxes' conda environments are asked about, and --yes keeps them" {
  fake_install
  local st="$T/home/.local/share/agent-sandbox"
  mkdir -p "$st/micromamba/bin" "$st/conda/envs/dev" "$st/tools/a/bin"
  : >"$st/micromamba/bin/micromamba"
  ln -s a "$st/tools/current"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove agent-sandbox's micromamba, $st/micromamba/bin/micromamba"* ]]
  [[ "$output" == *"remove the sandboxes' tools env, $st/tools"* ]]
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

# ---- the tools env: conda-forge CLI tools on PATH inside every sandbox ------------------

# tools_step -- install.sh's tools step alone, for real, against a stub micromamba at the
# installed path ($T/mm-fail present: it fails).
tools_step() {
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="/usr/bin:/bin" \
    AGENT_SANDBOX_INSTALL_STEP=tools "$REPO_ROOT/install.sh"
}

# a micromamba that "creates" -p PREFIX with each spec as a package shipping bin/<name>
# (`nobin` ships none), plus a python dependency nobody listed; it records its argv and
# CONDA_PKGS_DIRS in $T/mm-called
stub_tools_micromamba() {
  local mm="$T/home/.local/share/agent-sandbox/micromamba/bin"
  mkdir -p "$mm"
  cat >"$mm/micromamba" <<STUB
#!/usr/bin/env bash
echo "\$* | CONDA_PKGS_DIRS=\${CONDA_PKGS_DIRS:-}" >>"$T/mm-called"
[[ -e "$T/mm-fail" ]] && { echo "critical libmamba nothing provides what was asked" >&2; exit 1; }
prefix="" specs=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -p) prefix="\$2"; shift ;;
    -r | -c) shift ;;
    -*) ;;
    *) specs+=("\$1") ;;
  esac
  shift
done
mkdir -p "\$prefix/conda-meta" "\$prefix/bin" "\$HOME/.conda"
echo "\$prefix" >>"\$HOME/.conda/environments.txt" # as micromamba registers an env
record() { # record NAME FILE...
  local n="\$1" f files=""
  shift
  for f in "\$@"; do files+="\${files:+,}
    \"\$f\""; : >"\$prefix/\$f"; chmod +x "\$prefix/\$f"; done
  printf '{\n  "name": "%s",\n  "version": "1.0",\n  "files": [%s\n  ]\n}\n' "\$n" "\$files" >"\$prefix/conda-meta/\$n-1.0-0.json"
}
record python bin/python3 bin/python
for s in "\${specs[@]}"; do
  n="\${s%%[<>=!~,]*}"; n="\${n##*::}"
  if [[ "\$n" == nobin ]]; then record nobin; else record "\$n" "bin/\$n"; fi
done
STUB
  chmod +x "$mm/micromamba"
}

@test "tools env: gh and tmux by default (#317), built into a slot whose bin/ holds the listed packages' executables only; current names it" {
  stub_tools_micromamba
  local tools="$T/home/.local/share/agent-sandbox/tools"
  mkdir -p "$T/home/.conda" && echo /my/env >"$T/home/.conda/environments.txt"
  tools_step
  [ "$status" -eq 0 ]
  [ "$(readlink "$tools/current")" = a ]
  [ "$(readlink "$tools/a/bin/gh")" = ../env/bin/gh ]
  [ -x "$tools/a/bin/gh" ]
  [ "$(readlink "$tools/a/bin/tmux")" = ../env/bin/tmux ]
  # the dependency's python is in the env, not on the sandbox's PATH
  [ -x "$tools/a/env/bin/python3" ]
  [ "$(find "$tools/a/bin" -mindepth 1 -printf '%f\n' | sort | paste -sd' ')" = "gh tmux" ]
  [[ "$output" == *"building the tools env gh tmux (the default; list your own in $T/home/.config/agent-sandbox/tools.txt) from conda-forge"* ]]
  [[ "$output" == *"tools env $tools/a ("*"): gh 1.0 (gh); tmux 1.0 (tmux)"* ]]
  # from conda-forge alone, into the env's own package cache
  # with agent-sandbox's own gnupg (#6), whose executables are in engine-bin/, not bin/
  grep -qF "create -q -y -r $tools -p $tools/a/env --override-channels -c conda-forge gh tmux gnupg | CONDA_PKGS_DIRS=$tools/pkgs" "$T/mm-called"
  [ "$(readlink "$tools/a/engine-bin/gnupg")" = ../env/bin/gnupg ]
  [ "$(find "$tools/a/engine-bin" -mindepth 1 -printf '%f\n')" = gnupg ]
  [[ "$output" != *gnupg* ]]
  [ ! -e "$T/home/.config/agent-sandbox/tools.txt" ] # the default is not written
  # micromamba's registration of the env is undone; the user's own envs stay listed
  [ "$(cat "$T/home/.conda/environments.txt")" = /my/env ]
  # every run rebuilds (so updates), into the other slot; the one before stays
  tools_step
  [ "$status" -eq 0 ]
  [ "$(readlink "$tools/current")" = b ]
  [ -x "$tools/b/bin/gh" ] && [ -x "$tools/a/bin/gh" ]
  tools_step
  [ "$(readlink "$tools/current")" = a ]
}

@test "tools env: a failed update keeps the working one and warns; a failed first build warns; install.sh goes on" {
  stub_tools_micromamba
  local tools="$T/home/.local/share/agent-sandbox/tools"
  : >"$T/mm-fail"
  tools_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] building the tools env failed (critical libmamba nothing provides what was asked); the log is $tools/a.log"* ]]
  [[ "$output" == *"sandboxes get the system's tools until a later install.sh run builds it"* ]]
  [ ! -e "$tools/current" ] && [ ! -e "$tools/a" ]
  rm "$T/mm-fail"
  tools_step
  [ "$(readlink "$tools/current")" = a ]
  : >"$T/mm-fail"
  tools_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"sandboxes keep the previous tools env, $tools/a"* ]]
  [ "$(readlink "$tools/current")" = a ] && [ -x "$tools/a/bin/gh" ] && [ ! -e "$tools/b" ]
  # no micromamba at all: said, not fatal
  rm "$T/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  tools_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] no micromamba at $T/home/.local/share/agent-sandbox/micromamba/bin/micromamba: the tools env (gh tmux) was not built"* ]]
}

@test "tools env: ~/.config/agent-sandbox/tools.txt is the list -- comments, blanks, spaces in a spec, a channel prefix; one with none leaves agent-sandbox's own gnupg" {
  stub_tools_micromamba
  local tools="$T/home/.local/share/agent-sandbox/tools" list="$T/home/.config/agent-sandbox/tools.txt"
  mkdir -p "${list%/*}"
  printf '# my tools\n\ngh >=2.60   # current gh\nconda-forge::ripgrep\n  nobin\n' >"$list"
  tools_step
  [ "$status" -eq 0 ]
  grep -qF -- "-c conda-forge gh>=2.60 conda-forge::ripgrep nobin gnupg |" "$T/mm-called"
  [ "$(find "$tools/a/bin" -mindepth 1 -printf '%f\n' | sort | paste -sd' ')" = "gh ripgrep" ]
  [[ "$output" == *"[warn] tools: package nobin 1.0 has no executables in bin/; nothing of it is on PATH"* ]]
  [[ "$output" == *"tools env $tools/a ($list): gh 1.0 (gh); ripgrep 1.0 (ripgrep)"* ]]
  printf '# nothing\n' >"$list"
  : >"$T/mm-called"
  tools_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"building the tools env with no tools of yours ($list) from conda-forge"* ]]
  [[ "$output" == *"tools env $tools/b ($list): no tools of yours"* ]]
  grep -qF -- "-c conda-forge gnupg |" "$T/mm-called"
  [ -z "$(ls -A "$tools/b/bin")" ]
  [ -L "$tools/b/engine-bin/gnupg" ]
  [ "$(readlink "$tools/current")" = b ]
  # listed by the user too: once in the env, on the sandboxes' PATH and in engine-bin/
  printf 'gnupg >=2.4\n' >"$list"
  : >"$T/mm-called"
  tools_step
  [ "$status" -eq 0 ]
  grep -qF -- "-c conda-forge gnupg>=2.4 |" "$T/mm-called"
  [ -L "$tools/a/bin/gnupg" ]
  [ -L "$tools/a/engine-bin/gnupg" ]
}

@test "--dry-run: the tools env's plan, nothing built" {
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) would build the tools env gh tmux (the default; list your own in $T/home/.config/agent-sandbox/tools.txt) from conda-forge with $T/home/.local/share/agent-sandbox/micromamba/bin/micromamba under $T/home/.local/share/agent-sandbox/tools"* ]]
  [ ! -e "$T/home/.local/share/agent-sandbox/tools" ]
}

# ---- the proxy's port (#335) ------------------------------------------------
# What listens is a stub `ss` first on PATH; whether our unit runs is a stub
# `systemctl` whose is-active answers $T/active (present: active).

port_stubs() { # port_stubs PORT... -- the ports something listens on
  mkdir -p "$T/home/.local/bin"
  {
    printf '#!/bin/sh\necho "State Recv-Q Send-Q Local Address:Port Peer Address:Port"\n'
    local p
    for p in "$@"; do printf 'echo "LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*"\n' "$p"; done
  } >"$T/home/.local/bin/ss"
  # shellcheck disable=SC2016 # $2 is the stub's own argument
  printf '#!/bin/sh\n[ "$2" = is-active ] && { [ -e "%s/active" ]; exit; }\nexit 0\n' "$T" >"$T/home/.local/bin/systemctl"
  chmod +x "$T/home/.local/bin/ss" "$T/home/.local/bin/systemctl"
}
unit_port() { sed -n 's/^ *--listen-port \([^ ]*\) .*/\1/p' "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service"; }

@test "proxy port: 8888 when it is free, recorded and in the unit; the summary says nothing of it" {
  port_stubs 22 631
  dry
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 8888 ]
  [ "$(stat -c %a "$T/home/.config/agent-sandbox/proxy-port")" = 644 ]
  [ "$(unit_port)" = 8888 ]
  [[ "$output" == *"[ok] proxy port 8888 (the default), in $T/home/.config/agent-sandbox/proxy-port"* ]]
  [[ "$output" != *"The proxy listens on"* ]]
}

@test "proxy port: --proxy-port N is recorded and in the unit; a bad N exits 2" {
  port_stubs
  dry -- --proxy-port 9123
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 9123 ]
  [ "$(unit_port)" = 9123 ]
  [[ "$output" == *"[ok] proxy port 9123 (--proxy-port)"* ]]
  [[ "$output" == *"The proxy listens on 127.0.0.1:9123, not 8888 (--proxy-port)."* ]]
  dry -- --proxy-port=9124
  [ "$(unit_port)" = 9124 ]
  local v
  for v in 80 70000 x ''; do
    dry -- --proxy-port "$v"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--proxy-port '$v': expected a port, 1024-65535"* ]]
  done
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 9124 ] # a refused run changed nothing
}

@test "proxy port: 8888 held by another listener -> the next free port; held by our own active unit -> 8888" {
  port_stubs 8888 8889
  dry
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 8890 ]
  [ "$(unit_port)" = 8890 ]
  [[ "$output" == *"proxy port 8890 (8888 is held by another listener; the next free port)"* ]]
  [[ "$output" == *"The proxy listens on 127.0.0.1:8890, not 8888"* ]]
  # an install from before the file: its active unit is what holds 8888
  rm "$T/home/.config/agent-sandbox/proxy-port"
  : >"$T/active"
  dry
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 8888 ]
  [ "$(unit_port)" = 8888 ]
}

@test "proxy port: a re-run keeps the recorded port, busy with our unit or not; it warns when another listener holds it" {
  port_stubs 8888 8889
  dry
  [ "$(unit_port)" = 8890 ]
  port_stubs 8890 # now our own proxy listens there
  : >"$T/active"
  dry
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 8890 ]
  [[ "$output" == *"proxy port 8890 (recorded by an earlier run)"* ]]
  [[ "$output" != *"[warn] 127.0.0.1:8890"* ]]
  port_stubs # 8888 is free again: still not moved
  dry
  [ "$(unit_port)" = 8890 ]
  port_stubs 8890 # held, and our unit is not running: said, not moved
  rm "$T/active"
  dry
  [ "$(unit_port)" = 8890 ]
  [[ "$output" == *"[warn] 127.0.0.1:8890 is in use by something other than this account's proxy: re-run with --proxy-port N to move it"* ]]
  dry -- --proxy-port 8888 # the flag moves it
  [ "$(cat "$T/home/.config/agent-sandbox/proxy-port")" = 8888 ]
}

# ---- an account with no user manager; the sshd profile (#335) ----------------

@test "no user manager: a note naming the sshd profile's own proxy, the unit written anyway, nothing started, the install goes on" {
  systemctl_stub none
  dry
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: this account has no user manager (systemctl --user reaches none), so the proxy unit is written but not started."* ]]
  [[ "$output" == *"The sshd profile (asb --profile sshd) runs a proxy of its own at every launch and needs no unit."* ]]
  [[ "$output" != *"would run: systemctl --user daemon-reload"* ]]
  [[ "$output" != *"would enable and (re)start"* ]]
  [ -f "$T/home/.config/systemd/user/agent-sandbox-mitmproxy.service" ]
  [ "$(readlink "$T/home/.local/bin/asb")" = "$T/home/.local/share/agent-sandbox/app/agent-sandbox" ] # what follows still ran
  [[ "$output" == *"Next steps:"* ]]
}

@test "the sshd profile is installed with its agent, which the Agents section names as shipped, not as missing from PATH" {
  systemctl_stub
  dry
  [ "$status" -eq 0 ]
  [ -x "$T/home/.local/share/agent-sandbox/app/profiles/sshd/sshd-agent.sh" ]
  [ -f "$T/home/.local/share/agent-sandbox/app/profiles/sshd/profile.sh" ]
  [[ "$output" == *"[ok] sshd: its agent ships with the profile (sshd-agent.sh)"* ]]
  [[ "$output" != *"sshd-agent.sh\` is not on PATH"* ]]
  [[ "$output" != *"/sshd-agent.sh is not on PATH"* ]]
}

# ---- the Agents section: what asb runs, and the default agent (#6) ----------------------
# install.sh never installs, updates or removes an agent; it reports, and asks once for
# the default agent at a terminal.

# agents_step [ENV=VAL ...] [-- ARGS] -- install.sh's Agents section alone, for real, with
# the engine copied in as a run copies it, from $SRC (the checkout, or a scratch copy with
# more profiles: two_agents); $T/bin first on PATH; answers from $T/answers.
agents_step() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  mkdir -p "$T/bin"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_INSTALL_STEP=agents AGENT_SANDBOX_TTY="$T/answers" "${envs[@]}" "${SRC:-$REPO_ROOT}/install.sh" "$@"
}

# installed VERSION... -- claude's install dir with those versions, current the last one
installed() {
  local root="$T/home/.local/state/agent-sandbox/claude/install" v
  for v in "$@"; do mkdir -p "$root/$v"; done
  ln -sfn "${!#}" "$root/current"
}

# two_agents -- SRC: a scratch checkout with the repo's profiles and `other`, a profile
# with no install recipe whose command, otherbin, is on PATH ($T/bin): with claude, two
# agents asb can run.
two_agents() {
  SRC="$T/src"
  mkdir -p "$SRC/profiles/other" "$T/bin"
  cp "$REPO_ROOT/install.sh" "$REPO_ROOT/agent-sandbox" "$REPO_ROOT/VERSION" "$SRC/"
  cp -r "$REPO_ROOT/profiles/claude" "$REPO_ROOT/profiles/sshd" "$SRC/profiles/"
  printf ':\n' >"$SRC/profiles/other/profile.sh"
  printf '[agent]\ncommand = otherbin\n' >"$SRC/profiles/other/agent-sandbox"
  printf '#!/bin/sh\n' >"$T/bin/otherbin"
  chmod +x "$T/bin/otherbin"
}

@test "Agents: an agent asb installs is reported by its current version against the pin; never installed or updated here" {
  local pin
  pin="$(awk '$2 == "pinned" {print $1}' "$REPO_ROOT/profiles/claude/versions")"
  [ -n "$pin" ]
  # a curl that records a call: nothing is downloaded, whatever is installed
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "curl $*" >>%q\nexit 1\n' "$T/called" >"$T/bin/curl"
  chmod +x "$T/bin/curl"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] claude: not installed; asb --install claude, or it is offered at the first launch"* ]]
  installed 2.1.300
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] claude 2.1.300, pinned $pin: asb --install claude moves to the pin"* ]]
  [ "$(readlink "$T/home/.local/state/agent-sandbox/claude/install/current")" = 2.1.300 ] # not moved
  installed 2.1.300 "$pin"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] claude $pin, the pin"* ]]
  [ -d "$T/home/.local/state/agent-sandbox/claude/install/2.1.300" ] # not pruned
  # current naming no version beside it: not installed, as the engine has it
  ln -sfn ../.. "$T/home/.local/state/agent-sandbox/claude/install/current"
  agents_step
  [[ "$output" == *"[warn] claude: not installed; asb --install claude"* ]]
  # a profile whose table pins none: the version alone
  two_agents
  printf '2.1.300\n' >"$SRC/profiles/claude/versions"
  installed 2.1.300
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] claude 2.1.300"$'\n'* ]]
  [ ! -e "$T/called" ]
}

@test "Agents: a profile with no install recipe is its command on PATH, as before; the sshd profile's ships with it" {
  two_agents
  agents_step AGENT_SANDBOX_TTY="$T/no/such/tty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] other: \`otherbin\` is $T/bin/otherbin"* ]]
  [[ "$output" == *"[ok] sshd: its agent ships with the profile (sshd-agent.sh)"* ]]
  rm "$T/bin/otherbin"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] other: \`otherbin\` is not on PATH"* ]]
  [[ "$output" == *"Install it, then re-run. asb runs it once \`otherbin\` is on PATH (or: asb --profile other /path/to/it)."* ]]
  # one agent asb can run (sshd is chosen by --profile alone): the default, nothing asked
  [[ "$output" == *"[ok] the default agent is claude, the only one asb can run here"* ]]
  [[ "$output" != *"Which is the default"* ]]
}

@test "the default agent: asked at a terminal when asb can run several and none is set, written by the installed engine" {
  require_host "asb --set-default-agent is the host's; the engine refuses it inside a sandbox"
  two_agents
  local df="$T/home/.config/agent-sandbox/default-agent"
  # an answer that is neither a number in the list nor a name is asked again
  printf '7\nnobody\nother\n' >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"asb can run several agents here: 1) claude 2) other"* ]]
  [[ "$output" == *"Which is the default, the one \`asb --login\` and a role verb run when none is named? [number or name; empty: none for now]"* ]]
  [ "$(grep -c 'Which is the default' <<<"$output")" -eq 3 ]
  [ "$(cat "$df")" = other ]
  [[ "$output" == *"[ok] the default agent is now other (~/.config/agent-sandbox/default-agent)"* ]]
  # set: reported, never asked over
  : >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" != *"Which is the default"* ]]
  [[ "$output" == *"[ok] the default agent is other ($df); change it: asb --set-default-agent AGENT"* ]]
  # one set that asb cannot run here: said, with how to change it
  printf 'gone\n' >"$df"
  agents_step
  [[ "$output" == *"[warn] the default agent 'gone' ($df) is not one asb can run here (claude other); set another: asb --set-default-agent AGENT"* ]]
  [ "$(cat "$df")" = gone ]
  # by number
  rm "$df"
  printf '1\n' >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [ "$(cat "$df")" = claude ]
  # an empty answer: none set, and how to set it later
  rm "$df"
  printf '\n' >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [ ! -e "$df" ]
  [[ "$output" == *"asb can run several agents here (claude other) and no default is set: set it, asb --set-default-agent AGENT"* ]]
}

@test "the default agent: not asked with no terminal, with --yes, or in a dry run; none is set" {
  two_agents
  local df="$T/home/.config/agent-sandbox/default-agent"
  agents_step AGENT_SANDBOX_TTY="$T/no/such/tty"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Which is the default"* ]]
  [[ "$output" == *"asb can run several agents here (claude other) and no default is set: set it, asb --set-default-agent AGENT"* ]]
  [ ! -e "$df" ]
  printf 'other\n' >"$T/answers"
  agents_step -- --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"Which is the default"* ]]
  [ ! -e "$df" ]
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    AGENT_SANDBOX_TTY="$T/answers" "$SRC/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"(dry-run) would ask which is the default agent: claude other"* ]]
  [ ! -e "$df" ]
}

@test "the default agent: the question at a real terminal (a pty), answered there" {
  require_host "asb --set-default-agent is the host's; the engine refuses it inside a sandbox"
  command -v script >/dev/null || skip "script(1) is needed for a pty"
  two_agents
  local df="$T/home/.config/agent-sandbox/default-agent"
  printf 'cd %q && exec env -i HOME=%q PATH=%q AGENT_SANDBOX_INSTALL_STEP=agents %q\n' \
    "$T" "$T/home" "$T/bin:/usr/bin:/bin" "$SRC/install.sh" >"$T/tty.sh"
  run bash -c 'printf "2\n" | script -qec "bash $1" /dev/null' _ "$T/tty.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Which is the default"* ]]
  [ "$(cat "$df")" = other ]
  [[ "$output" == *"the default agent is now other"* ]]
}

@test "--uninstall removes the agents asb installed; the sandboxes' state and the accounts' logins are kept, and named" {
  fake_install
  local as="$T/home/.local/state/agent-sandbox"
  installed 2.1.300 2.1.321
  mkdir -p "$as/claude/accounts/work" "$as/claude/-proj/r/transcripts"
  printf 'secret\n' >"$as/claude/accounts/work/.credentials.json"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove the agent asb installed, $as/claude/install (2.1.300 2.1.321; asb --install puts it back)"* ]]
  [[ "$output" == *"keep $as (the sandboxes' state: role stores, transcripts; rm -rf it to remove)"* ]]
  [[ "$output" == *"and the accounts' logins there: claude/accounts/work"* ]]
  [ -d "$as/claude/install/2.1.321" ]
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] removed $as/claude/install"* ]]
  [ ! -e "$as/claude/install" ]
  [ "$(cat "$as/claude/accounts/work/.credentials.json")" = secret ]
  [ -d "$as/claude/-proj/r/transcripts" ]
  [[ "$output" == *"$as kept: the sandboxes' state and the accounts' logins."* ]]
  # a symlink at install/ is not followed, nor removed
  mkdir -p "$T/elsewhere/9.9.9"
  ln -s "$T/elsewhere" "$as/claude/install"
  fake_install
  uninst
  [ "$status" -eq 0 ]
  [ -d "$T/elsewhere/9.9.9" ] && [ -L "$as/claude/install" ]
}

@test "a terminal tput cannot colour (TERM unset, dumb, vt100) does not end the install" {
  command -v script >/dev/null || skip "script(1) is needed for a pty"
  local term
  for term in unset dumb vt100; do
    printf 'cd %q && exec env -i HOME=%q PATH=%q %s AGENT_SANDBOX_INSTALL_STEP=agents AGENT_SANDBOX_TTY=%q %q\n' \
      "$T" "$T/home" "/usr/bin:/bin" "$([[ "$term" == unset ]] || printf 'TERM=%s' "$term")" \
      "$T/no/such/tty" "$REPO_ROOT/install.sh" >"$T/tty.sh"
    run bash -c 'script -qec "bash $1" /dev/null </dev/null' _ "$T/tty.sh"
    [ "$status" -eq 0 ] || {
      echo "TERM=$term: $output"
      false
    }
    [[ "$output" == *"==> Agents"* ]]
    [[ "$output" != *"tput:"* ]]
  done
}

@test "the candidates follow the engine's rule: a profile that fails to load, one naming no command, and one chosen by --profile alone (a recipe's included) are none" {
  require_host "asb --set-default-agent is the host's; the engine refuses it inside a sandbox"
  two_agents
  mkdir -p "$SRC/profiles/broken" "$SRC/profiles/nocmd"
  printf 'return 1\n' >"$SRC/profiles/broken/profile.sh"
  printf 'profile_command=\n' >"$SRC/profiles/nocmd/profile.sh"
  cp -r "$SRC/profiles/claude" "$SRC/profiles/claude2"
  printf '\nprofile_by_name_only=1\n' >>"$SRC/profiles/claude2/profile.sh"
  printf '1\n' >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] broken: its profile failed to load ($SRC/profiles/broken/profile.sh)"* ]]
  [[ "$output" == *"nocmd: names no command; asb runs it by path only (asb --profile nocmd /path/to/it)"* ]]
  [[ "$output" != *"nocmd\` is"* ]]
  # claude2 is reported, and not offered
  [[ "$output" == *"claude2: not installed; asb --install claude2"* ]]
  [[ "$output" == *"asb can run several agents here: 1) claude 2) other"$'\n'* ]]
  [ "$(cat "$T/home/.config/agent-sandbox/default-agent")" = claude ]
}

@test "XDG_STATE_HOME moves the agents' installs: the report and the uninstall read them there" {
  local xs="$T/xdg/agent-sandbox" pin
  pin="$(awk '$2 == "pinned" {print $1}' "$REPO_ROOT/profiles/claude/versions")"
  mkdir -p "$xs/claude/install/$pin" "$xs/claude/accounts/work"
  ln -s "$pin" "$xs/claude/install/current"
  installed 2.1.300 # the default place: not what is read
  agents_step XDG_STATE_HOME="$T/xdg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] claude $pin, the pin"* ]]
  fake_install
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" XDG_STATE_HOME="$T/xdg" \
    "$REPO_ROOT/install.sh" --uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"and the accounts' logins there: claude/accounts/work"* ]]
  [ ! -e "$xs/claude/install" ] && [ -d "$xs/claude/accounts/work" ]
  [ -d "$T/home/.local/state/agent-sandbox/claude/install/2.1.300" ]
}

@test "--uninstall removes only the install dirs of profiles it knows, never through a symlinked profile directory" {
  local as="$T/home/.local/state/agent-sandbox"
  # not a profile install.sh knows: kept
  mkdir -p "$as/notaprofile/install/1.0"
  # the profile's directory a symlink: what it points at is not removed
  mkdir -p "$T/elsewhere/claude/install/9.9.9"
  ln -s "$T/elsewhere/claude" "$as/claude"
  fake_install
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" != *"remove the agent asb installed"* ]]
  [ -d "$as/notaprofile/install/1.0" ]
  [ -d "$T/elsewhere/claude/install/9.9.9" ]
}

@test "--uninstall removes an agent's install with a read-only directory in it, and goes on to the rest" {
  fake_install
  local as="$T/home/.local/state/agent-sandbox"
  installed 2.1.321
  mkdir -p "$as/claude/install/2.1.321/pkg/ro"
  : >"$as/claude/install/2.1.321/pkg/ro/file"
  chmod 555 "$as/claude/install/2.1.321/pkg/ro"
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok] removed $as/claude/install"* ]]
  [ ! -e "$as/claude/install" ]
  [ ! -d "$T/home/.local/share/agent-sandbox" ] # what follows it still ran
  [[ "$output" == *"agent-sandbox is gone"* ]]
}

@test "--uninstall: an install it cannot remove is said, naming what is left, and the rest still goes" {
  fake_install
  local as="$T/home/.local/state/agent-sandbox"
  installed 2.1.321
  # chmod and rm that fail, as on a file system that refuses them
  mkdir -p "$T/home/.local/bin"
  printf '#!/bin/sh\nexit 1\n' >"$T/home/.local/bin/chmod"
  printf '#!/bin/sh\ncase "$*" in *install*) exit 1 ;; esac\nexec /bin/rm "$@"\n' >"$T/home/.local/bin/rm"
  chmod +x "$T/home/.local/bin/chmod" "$T/home/.local/bin/rm"
  uninst
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn] could not remove all of $as/claude/install; left: 2.1.321 (remove it by hand)"* ]]
  [ -d "$as/claude/install/2.1.321" ]
  [ ! -d "$T/home/.local/share/agent-sandbox" ]
}

@test "the pin is read as the engine reads the versions table: a pinned line that is not an exact version is no pin" {
  two_agents
  printf 'latest pinned\n2.1.300\n' >"$SRC/profiles/claude/versions"
  installed 2.1.300
  agents_step AGENT_SANDBOX_TTY="$T/no/such/tty"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned latest"* ]]
  [[ "$output" == *"[ok] claude 2.1.300"$'\n'* ]]
}

@test "the default agent: an answer with a leading zero is a number (08 is not octal); an install dir with no version says none" {
  require_host "asb --set-default-agent is the host's; the engine refuses it inside a sandbox"
  two_agents
  printf '08\n02\n' >"$T/answers"
  agents_step
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great"* ]]
  [ "$(grep -c 'Which is the default' <<<"$output")" -eq 2 ] # 08 is out of range: asked again
  [ "$(cat "$T/home/.config/agent-sandbox/default-agent")" = other ]
  # an empty install dir in the uninstall's plan
  fake_install
  mkdir -p "$T/home/.local/state/agent-sandbox/claude/install"
  run env -i ${BASH_ENV:+BASH_ENV="$BASH_ENV"} HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" \
    "$REPO_ROOT/install.sh" --uninstall --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"remove the agent asb installed, $T/home/.local/state/agent-sandbox/claude/install (none; asb --install puts it back)"* ]]
}
