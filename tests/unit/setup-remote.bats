#!/usr/bin/env bats
# `asb --setup-remote ALIAS` (#344, step 2): the refusals, the preflight of the host a
# [remote:ALIAS] section names, the report, and the verdict -- ready, or the admin's
# script. A stub `ssh` runs the probe it is fed on stdin locally, in a throwaway root
# (remote_host) whose stub tools and files shape every answer. Nothing runs sudo.

# shellcheck disable=SC2016 # the admin's script's lines are matched as written, $ included
setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  R="$BATS_TEST_TMPDIR/root"
  ADMIN="$PROJ/.asb/remote/r1/admin.sh"
  ENGDIR="$(dirname -- "$(readlink -f -- "$ENGINE")")" # the engine's own checkout
  # The stub ssh: `-G` resolves a spec as ssh would (user@ pins the user; else tester),
  # with two IdentityFiles; anything else is the preflight, whose argv goes to
  # $H/ssh.argv and whose stdin, the probe, to $H/probe.sh, then runs in $R.
  cat >"$H/bin/ssh" <<'X'
#!/usr/bin/env bash
set +x
if [[ "$1" == -G ]]; then
  s="$2" u=tester
  [[ "$s" == *@* ]] && u="${s%@*}" s="${s#*@}"
  printf 'hostname %s.example.org\nuser %s\nport 2223\nidentityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ed25519\n' "$s" "$u"
  exit 0
fi
if [[ "$*" == *"umask 077; cat >"* ]]; then
  # the copy of the admin's script into the user's home there
  [[ -n "${COPY_FAIL:-}" ]] && exit 255
  cat >"$PROBE_H/copied.sh"
  exit 0
fi
printf '%s\n' "$@" >"$PROBE_H/ssh.argv"
cat >"$PROBE_H/probe.sh"
[[ -n "${PROBE_FAIL:-}" ]] && { echo "ssh: connect to host x port 22: Connection refused" >&2; exit 255; }
exec env -i PATH="$PROBE_R/usr/bin:$PROBE_R/bin" HOME="$PROBE_R/home/tester" \
  AGENT_SANDBOX_TEST_PROBE_ROOT="$PROBE_R" AGENT_SANDBOX_TEST_PROBE_NET=127.0.0.1:1 /bin/bash -s <"$PROBE_H/probe.sh"
X
  printf '#!/usr/bin/env bash\nexit 1\n' >"$H/bin/ssh-add"
  chmod +x "$H/bin/ssh" "$H/bin/ssh-add"
}

# stub NAME BODY -- an executable $R/usr/bin/NAME running BODY (bash).
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$R/usr/bin/$1"
  chmod +x "$R/usr/bin/$1"
}

# remote_host [NAME=VALUE ...] -- the throwaway root the probe runs in. The defaults are
# a host with everything present and working (Ubuntu 24.04, the restriction on, both
# profiles there, bwrap 0.12.0, sudo with a password, the account tob, two GPUs); each
# NAME=VALUE changes one thing: bwrap=missing|VER, cand=VER (apt's candidate),
# pasta=missing|VER, nft=0, sshd=0, restrict=0|1|na, bwrap_userns=ok|blocked,
# pasta_netns=ok|blocked, profiles="bwrap pasta", sudo=ok|password|none, uid=N,
# user=NAME, accounts="NAME ...", pm=apt-get|dnf|..., os=ID:VERSION:LIKE.
remote_host() {
  local bwrap=0.12.0 cand=0.12.0 pasta=2025_09_19.623dbf6 nft=1 sshd=1 restrict=1
  local bwrap_userns=ok pasta_netns=ok profiles="bwrap pasta" sudo=password uid=1000 user=tester
  local accounts="tob" pm=apt-get os=ubuntu:24.04:debian
  local "$@"
  rm -rf -- "$R"
  mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/etc/apparmor.d" "$R/proc/sys/kernel" "$R/dev" "$R/home/tester"
  local t
  for t in df stat timeout; do ln -s "$(command -v "$t")" "$R/usr/bin/$t"; done
  IFS=: read -r a b c <<<"$os"
  printf 'NAME="Test"\nID=%s\nVERSION_ID="%s"\nID_LIKE=%s\n' "$a" "$b" "$c" >"$R/etc/os-release"
  echo 6.8.0-test >"$R/proc/sys/kernel/osrelease"
  [[ "$restrict" == na ]] || echo "$restrict" >"$R/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
  for t in $profiles; do : >"$R/etc/apparmor.d/$t"; done
  local groups="$user"
  [[ "$sudo" == password ]] && groups+=" sudo"
  stub id "case \"\$1\" in -un) echo $user ;; -u) echo $uid ;; -nG) echo '$groups' ;; *) echo 'uid=$uid($user)' ;; esac"
  stub "$pm" 'exit 0'
  [[ "$pm" == apt-get ]] && stub apt-cache "printf 'bubblewrap:\n  Installed: (none)\n  Candidate: %s\n' '$cand'"
  [[ "$bwrap" == missing ]] || stub bwrap "[[ \"\$1\" == --version ]] && { echo 'bubblewrap $bwrap'; exit 0; }; [[ $bwrap_userns == ok ]]"
  [[ "$pasta" == missing ]] || stub pasta "case \"\$1\" in --version) printf 'pasta $pasta\nCopyright\n' ;; --help) echo '  --hostname NAME' ;; *) [[ $pasta_netns == ok ]] ;; esac"
  stub unshare 'exit 1'
  if ((nft)); then printf '#!/bin/bash\nexit 0\n' >"$R/usr/sbin/nft" && chmod +x "$R/usr/sbin/nft"; fi
  if ((sshd)); then printf '#!/bin/bash\nexit 0\n' >"$R/usr/sbin/sshd" && chmod +x "$R/usr/sbin/sshd"; fi
  case "$sudo" in
    ok) stub sudo 'exit 0' ;;
    password | none) stub sudo 'echo "sudo: a password is required" >&2; exit 1' ;;
  esac
  stub getent "for a in $accounts; do [[ \"\$2\" == \"\$a\" ]] && echo \"\$a:x:1001:1001::$R/home/tester:/bin/bash\" && exit 0; done; exit 2"
  stub nvidia-smi "printf 'GPU 0: NVIDIA GeForce RTX 2060 (UUID: GPU-0)\nGPU 1: NVIDIA GeForce RTX 2060 (UUID: GPU-1)\n'"
  for t in nvidiactl nvidia-uvm nvidia-uvm-tools nvidia1; do : >"$R/dev/$t" && chmod 666 "$R/dev/$t"; done
}

# section [LINE...] -- [remote:r1] with host, port and the LINEs; approved unless NOAPPROVE.
section() {
  {
    printf '[remote:r1]\nhost = qgpu3\nport = 0.0.0.0:2222\n'
    printf '%s\n' "$@"
  } >"$PROJ/.agent-sandbox"
  [[ -n "${NOAPPROVE:-}" ]] && return 0
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
}

# setup_remote [VAR=value ...] -- `--setup-remote r1` in the project, answered nothing.
setup_remote() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  engine_cmd
  run bash -c 'cd "$1" && n="$4" && env -i HOME="$2" PATH="$3" PROBE_R="$5" PROBE_H="$6" "${@:7:n}" "${@:7+n}" 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#envs[@]}" "$R" "$H" ${envs[@]+"${envs[@]}"} "${ENGINE_CMD[@]}" --setup-remote "${@:-r1}"
}

# heredoc_body FILE MARKER -- the lines of FILE between `<<'MARKER'` and MARKER.
heredoc_body() {
  awk -v m="$2" 'index($0, "<<'"'"'" m "'"'"'") {on = 1; next} on && $0 == m {exit} on {print}' "$1"
}

# script_code FILE -- FILE's lines that run: no comment, no heredoc body.
script_code() {
  awk 'on && $0 == m {on = 0; next} on {next} /^[[:space:]]*#/ {next}
    match($0, /<<'"'"'[A-Z_]+'"'"'/) {m = substr($0, RSTART + 3, RLENGTH - 4); on = 1} {print}' "$1"
}

p='agent-sandbox: remote r1:'

@test "--setup-remote: refused inside a sandbox, before any ssh (#344)" {
  remote_host
  section
  setup_remote AGENT_SANDBOX=1
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote runs on the host: it holds your ssh access; a role proposes the line, you run it."* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: refused without a .agent-sandbox, and without a [remote:ALIAS] of that name (#344)" {
  remote_host
  setup_remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: no .agent-sandbox in $PROJ: a remote is described there, in [remote:r1]"* ]]
  section
  setup_remote r2
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: .agent-sandbox has no [remote:r2] (it has: r1)"* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: refused for a section that is unusable as written (#344)" {
  remote_host
  printf '[remote:r1]\nhost = qgpu3\n' >"$PROJ/.agent-sandbox"
  setup_remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: [remote:r1] is unusable as written; agent-sandbox --check says why"* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: refused while the file is not approved, with the --trust hint (#344)" {
  remote_host
  NOAPPROVE=1 section 'account = tob'
  setup_remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: .agent-sandbox is not approved as it stands, and [remote:r1] in it is what this acts on: review it first (agent-sandbox --trust)"* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: a host with everything present and working is ready: exit 0, no admin's script, one batch-mode ssh (#344)" {
  remote_host
  section 'account = tob' 'gpu = /dev/nvidiactl /dev/nvidia1'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p the preflight, over ssh to tester@qgpu3.example.org port 2223 (qgpu3), read-only"* ]]
  [[ "$output" == *"$p ubuntu 24.04, kernel 6.8.0-test, packages by apt-get"* ]]
  [[ "$output" == *"$p logged in as tester (sudo with a password; asb never uses it)"* ]]
  [[ "$output" == *"$p bwrap 0.12.0 ok"* ]]
  [[ "$output" == *"$p pasta 2025_09_19.623dbf6 ok"* ]]
  [[ "$output" == *"$p nft $R/usr/sbin/nft ok"* ]]
  [[ "$output" == *"$p sshd $R/usr/sbin/sshd ok"* ]]
  [[ "$output" == *"$p user namespaces blocked for an unconfined binary (unshare -Urn; apparmor_restrict_unprivileged_userns=1)"* ]]
  [[ "$output" == *"$p bwrap's namespaces ok"* ]]
  [[ "$output" == *"$p pasta's namespaces ok"* ]]
  [[ "$output" == *"$p the account tob present, home $R/home/tester, "* ]]
  [[ "$output" == *"$p GPU 0: NVIDIA GeForce RTX 2060 (UUID: GPU-0)"* ]]
  [[ "$output" == *"$p gpu /dev/nvidia1 mode 666"* ]]
  [[ "$output" == *"$p 127.0.0.1:1 unreachable (the account's part needs it)"* ]]
  [[ "$output" == *"$p ready for the account's part (not in this version yet: step 3 of #344)" ]]
  [ ! -e "$ADMIN" ]
  [ ! -e "$PROJ/.asb" ]
  grep -qx 'BatchMode=yes' "$H/ssh.argv"
  grep -qx 'ConnectTimeout=15' "$H/ssh.argv"
  [ "$(tail -n 2 "$H/ssh.argv" | paste -sd' ' -)" = "bash -s" ]
  # the probe is read-only: no redirection into a file but /dev/null (and the TCP probe's
  # socket), and sudo only as `sudo -n true`
  [ "$(grep -oE '[0-9]?>[^[:space:]&)]+' "$H/probe.sh" | grep -vxE '[0-9]?>/dev/null')" = '>"/dev/tcp/$1/$2"'"'" ]
  [ "$(grep -oE 'sudo -[a-zA-Z]+( [a-z]+)?' "$H/probe.sh")" = "sudo -n true" ]
}

@test "--setup-remote: bwrap and pasta missing where the kernel restricts user namespaces: the admin's script installs those two and both profiles, exit 1, the run line (#344)" {
  remote_host bwrap=missing pasta=missing profiles=
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p bwrap missing (package bubblewrap)"* ]]
  [[ "$output" == *"$p pasta missing (package passt)"* ]]
  [[ "$output" == *"$p bwrap's namespaces not measured (bwrap missing; apparmor_restrict_unprivileged_userns=1, no profile for bwrap)"* ]]
  [[ "$output" == *"$p the admin's script carries install.sh's AppArmor profiles from $ENGDIR (the engine's own checkout)"* ]]
  [[ "$output" == *"$p qgpu3 needs root once: ~/asb-admin-r1.sh there does it. Read it, then run:"$'\n'"$p   ssh -t qgpu3 sudo bash asb-admin-r1.sh"$'\n'* ]]
  cmp -s "$ADMIN" "$H/copied.sh" # the copy there is the script here, byte for byte
  [[ "$output" == *"$p then: agent-sandbox --setup-remote r1" ]]
  [ "$(stat -c %a "$ADMIN")" = 600 ]
  grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap passt </dev/null' "$ADMIN"
  grep -qx 'set -euo pipefail' "$ADMIN"
  grep -qx 'apparmor_parser -r /etc/apparmor.d/bwrap </dev/null' "$ADMIN"
  grep -qx 'apparmor_parser -r /etc/apparmor.d/pasta </dev/null' "$ADMIN"
  [ "$(heredoc_body "$ADMIN" AA_BWRAP_EOF)" = "$(cat "$REPO_ROOT/components/apparmor/bwrap")" ]
  [ "$(heredoc_body "$ADMIN" AA_PASTA_EOF)" = "$(cat "$REPO_ROOT/components/apparmor/pasta")" ]
  run ! grep -E 'nftables|openssh|adduser|useradd|rebuild-bwrap' <(script_code "$ADMIN")
  bash -n "$ADMIN"
}

@test "drift: the profile texts the admin's script carries are install.sh's, byte for byte (#344)" {
  remote_host bwrap=missing pasta=missing profiles=
  section
  setup_remote
  [ "$status" -eq 1 ]
  # files, not $(...), which would drop a trailing blank line from both sides
  local m
  for m in AA_BWRAP_EOF AA_PASTA_EOF; do
    heredoc_body "$REPO_ROOT/install.sh" "$m" >"$BATS_TEST_TMPDIR/want"
    heredoc_body "$ADMIN" "$m" >"$BATS_TEST_TMPDIR/got"
    [ -s "$BATS_TEST_TMPDIR/want" ]
    cmp "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
  done
}

@test "--setup-remote: a named account that is absent gets adduser and your public key in the admin's script (#344)" {
  remote_host accounts=
  mkdir -p "$H/home/.ssh"
  : >"$H/home/.ssh/id_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKey owner@laptop\n' >"$H/home/.ssh/id_ed25519.pub"
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the account tob absent (adduser; the home of tester, $R/home/tester, has "* ]]
  [[ "$output" == *"$p the admin's script puts your public key ($H/home/.ssh/id_ed25519.pub) into tob's authorized_keys, your own way in"* ]]
  grep -qx 'if ! getent passwd tob >/dev/null; then' "$ADMIN"
  grep -qx "  adduser --disabled-password --gecos '' tob </dev/null" "$ADMIN"
  grep -qx '  install -d -m 700 -o tob -g "$asb_group" "$asb_home/.ssh"' "$ADMIN"
  grep -qxF "  printf '%s\n' ssh-ed25519\\ AAAAC3NzaC1lZDI1NTE5AAAAIKey >>\"\$asb_home/.ssh/authorized_keys\"" "$ADMIN"
  grep -qx '  chmod 600 "$asb_home/.ssh/authorized_keys"' "$ADMIN"
  run ! grep -E 'apt-get|apparmor_parser' <(script_code "$ADMIN")
  bash -n "$ADMIN"
  # no key of yours: the script and the command say to add one by hand
  rm -f "$H/home/.ssh/id_ed25519.pub"
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p no public key of yours found (no .pub beside an IdentityFile of ssh -G qgpu3, none in ssh-add -L): add one to tob's ~/.ssh/authorized_keys by hand"* ]]
  grep -q '^# BY HAND: no public key of yours was found' "$ADMIN"
  run ! grep -q authorized_keys\" "$ADMIN"
}

@test "--setup-remote: a dnf host gets the dnf line, and useradd (#344)" {
  remote_host pm=dnf os=fedora:42:"" bwrap=missing sshd=0 restrict=na profiles= accounts=
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p fedora 42, kernel 6.8.0-test, packages by dnf"* ]]
  grep -qx 'dnf install -y bubblewrap openssh-server </dev/null' "$ADMIN"
  grep -qx '  useradd -m -s /bin/bash tob </dev/null' "$ADMIN"
  run ! grep -E 'apt-get|apparmor_parser|rebuild-bwrap' <(script_code "$ADMIN")
}

@test "--setup-remote: no restriction and user namespaces working: bwrap missing is the package alone, no profile (#344)" {
  remote_host bwrap=missing restrict=0 profiles= cand=unknown
  stub unshare 'exit 0'
  section
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p user namespaces ok (unshare -Urn)"* ]]
  grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap </dev/null' "$ADMIN"
  run ! grep -E 'apparmor|AA_|rebuild-bwrap' <(script_code "$ADMIN")
}

@test "--setup-remote: bubblewrap 0.9.0 gets the rebuild, install.sh carried whole (#344)" {
  remote_host bwrap=0.9.0 cand=0.9.0
  section
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p bwrap 0.9.0: below 0.12.0, which fixes CVE-2026-87766; a rebuild is needed"* ]]
  [[ "$output" == *"$p the admin's script carries install.sh, for the rebuild, from $ENGDIR (the engine's own checkout)"* ]]
  grep -qx '(cd "$asb_work" \&\& env -u SUDO_USER TMPDIR="$asb_work" bash ./install.sh --rebuild-bwrap </dev/null)' "$ADMIN"
  [ "$(heredoc_body "$ADMIN" ASB_INSTALL_SH_EOF)" = "$(cat "$REPO_ROOT/install.sh")" ]
  run ! grep -E 'apt-get install|apparmor_parser' <(script_code "$ADMIN")
  bash -n "$ADMIN"
  # bwrap missing, and apt offers one below 0.12.0 (a Debian version, as apt-cache
  # says it): the package, then the rebuild
  remote_host bwrap=missing cand=0.9.0-1ubuntu0.1
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p bwrap missing (package bubblewrap; apt offers 0.9.0-1ubuntu0.1, below 0.12.0, so a rebuild follows it)"* ]]
  grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap </dev/null' "$ADMIN"
  grep -q -- '--rebuild-bwrap </dev/null)$' "$ADMIN"
}

@test "--setup-remote: a user with no sudo on a host with everything present is ready (#344)" {
  remote_host sudo=none
  section
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p logged in as tester (no sudo; asb never uses it)"* ]]
  [[ "$output" == *"$p the account is the ssh user tester, home $R/home/tester, "* ]]
  [[ "$output" == *"$p ready for the account's part (not in this version yet: step 3 of #344)" ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: a gpu node the host lacks is said, and is no fault of the preflight (#344)" {
  remote_host
  section 'gpu = /dev/nvidiactl /dev/nvidia3'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p gpu /dev/nvidiactl mode 666"* ]]
  [[ "$output" == *"$p gpu /dev/nvidia3 missing on that host (the login's policy says the same at launch)"* ]]
  [[ "$output" == *"$p ready for the account's part"* ]]
}

@test "--setup-remote: the run line follows sudo: without a password, none, and root (#344)" {
  remote_host sudo=ok accounts=
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p   ssh -t qgpu3 sudo bash asb-admin-r1.sh"$'\n'* ]]
  remote_host sudo=none accounts=
  setup_remote
  [[ "$output" == *"$p qgpu3 needs root once, and you have no sudo there: the host's admin runs the script (~/asb-admin-r1.sh there, or .asb/remote/r1/admin.sh here):"$'\n'"$p   ssh root@qgpu3 bash -s < .asb/remote/r1/admin.sh"$'\n'* ]]
  remote_host sudo=root uid=0 user=root accounts=
  setup_remote
  [[ "$output" == *"$p logged in as root (root; asb never uses it)"* ]]
  [[ "$output" == *"$p   ssh -t qgpu3 bash asb-admin-r1.sh"$'\n'* ]]
}

@test "--setup-remote: a copy of the admin's script that fails is said, with the scp to do it by hand, and the run line still (#344)" {
  remote_host bwrap=missing pasta=missing profiles=
  section 'account = tob'
  rm -f "$H/copied.sh"
  setup_remote COPY_FAIL=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p qgpu3 needs root once: .asb/remote/r1/admin.sh does it, but the copy to qgpu3 failed (ssh exit 255). Copy it yourself (scp .asb/remote/r1/admin.sh qgpu3:asb-admin-r1.sh), read it there, then run:"$'\n'"$p   ssh -t qgpu3 sudo bash asb-admin-r1.sh"$'\n'* ]]
  [ ! -e "$H/copied.sh" ]
  [ -s "$ADMIN" ]
}

@test "--setup-remote: root as the ssh user with no account named is not ready, and no admin's script fixes it (#344)" {
  remote_host sudo=root uid=0 user=root
  section
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the account is the ssh user, root: a login does not run as root; name an account in [remote:r1] (account = NAME)"* ]]
  [[ "$output" == *"$p not ready, for the reason above" ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: a preflight ssh cannot complete is said, exit 1 (#344)" {
  remote_host
  section
  setup_remote PROBE_FAIL=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the preflight did not complete (ssh exit 255): ssh: connect to host x port 22: Connection refused"* ]]
  [[ "$output" == *"$p it needs ssh to reach qgpu3 without a question (BatchMode)"* ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: an installed engine takes the profiles from the checkout install.manifest records, else says by hand (#344)" {
  local app="$H/app"
  mkdir -p "$app" "$H/home/.local/share/agent-sandbox"
  cp "$ENGINE" "$app/agent-sandbox"
  ln -s "$REPO_ROOT/profiles" "$app/profiles"
  remote_host bwrap=missing pasta=missing profiles=
  section
  printf 'version\t1\ncheckout\t%s\n' "$REPO_ROOT" >"$H/home/.local/share/agent-sandbox/install.manifest"
  engine_cmd "$app/agent-sandbox"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" PROBE_R="$4" PROBE_H="$5" "${@:6}" --setup-remote r1 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$R" "$H" "${ENGINE_CMD[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the admin's script carries install.sh's AppArmor profiles from $REPO_ROOT (the checkout install.sh ran from, as install.manifest records it)"* ]]
  [ "$(heredoc_body "$ADMIN" AA_BWRAP_EOF)" = "$(cat "$REPO_ROOT/components/apparmor/bwrap")" ]
  rm "$H/home/.local/share/agent-sandbox/install.manifest"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" PROBE_R="$4" PROBE_H="$5" "${@:6}" --setup-remote r1 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$R" "$H" "${ENGINE_CMD[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p no checkout of agent-sandbox found (none beside the engine, none in install.manifest): the admin's script says what to do by hand for the profiles and the rebuild"* ]]
  grep -q '^# BY HAND: no checkout of agent-sandbox was found where asb ran' "$ADMIN"
  run ! grep -q AA_BWRAP_EOF "$ADMIN"
}

@test "--setup-remote: the order of a script that does everything: packages, profiles, the rebuild (its last step runs bwrap in a user namespace), the account (#344)" {
  remote_host bwrap=missing pasta=missing cand=0.9.0-1ubuntu0.3 profiles= accounts=
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  local order
  order="$(script_code "$ADMIN" | grep -oE 'apt-get install|apparmor_parser -r /etc/apparmor.d/[a-z]+|--rebuild-bwrap|^  adduser' | paste -sd, -)"
  [ "$order" = "apt-get install,apparmor_parser -r /etc/apparmor.d/bwrap,apparmor_parser -r /etc/apparmor.d/pasta,--rebuild-bwrap,  adduser" ]
  grep -qx '#   - AppArmor profiles for bwrap and pasta' "$ADMIN"
}
