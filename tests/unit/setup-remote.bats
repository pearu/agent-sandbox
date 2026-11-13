#!/usr/bin/env bats
# `asb --setup-remote ALIAS` (#344, steps 2 and 3): the refusals, the preflight of the
# host a [remote:ALIAS] section names, the report, and the verdict -- the admin's script,
# or the account's part and the local side. A stub `ssh` runs the probe it is fed on
# stdin locally, in a throwaway root (remote_host) whose stub tools and files shape every
# answer; with `-l ACCOUNT` it plays the account's side in a fake home there
# ($R/home/ACCOUNT, with a stub install.sh and a stub asb), and for the alias it plays
# the login (a stub id, curl and nvidia-smi, AGENT_SANDBOX=1). Nothing runs sudo.

# shellcheck disable=SC2016 # the admin's script's lines are matched as written, $ included
setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  R="$BATS_TEST_TMPDIR/root"
  ADMIN="$PROJ/.asb/remote/r1/admin.sh"
  ENGDIR="$(dirname -- "$(readlink -f -- "$ENGINE")")" # the engine's own checkout
  # The stub ssh: `-G` resolves a spec as ssh would (user@ pins the user; else tester),
  # with two IdentityFiles -- an alias of ~/.ssh/config (the block the account's part
  # writes) by the real ssh reading that file. The copy of the admin's script goes to
  # $H/copied.sh. With -l ACCOUNT, the account's side: the command runs in
  # $R/home/ACCOUNT, its argv to $H/acct.argv, its command to $H/acct.cmds; after a carry
  # the stub install.sh replaces the carried one. To the alias r1 (or ALIAS_NAME): the
  # login, its script to $H/check.sh. Anything else is the preflight, whose argv goes to
  # $H/ssh.argv and whose stdin, the probe, to $H/probe.sh, then runs in $R.
  cat >"$H/bin/ssh" <<'X'
#!/usr/bin/env bash
set +x
if [[ "$1" == -G ]]; then
  # SSH_G_FAIL: ssh -G fails, as it does on a broken ~/.ssh/config
  if [[ -n "${SSH_G_FAIL:-}" ]]; then
    echo "$HOME/.ssh/config line 3: Bad configuration option: bogus" >&2
    exit 255
  fi
  s="$2" u=tester pt=2223
  [[ "$s" == -p ]] && pt="$3" s="$4"
  if [[ -f "$HOME/.ssh/config" ]] && grep -qx "Host $s" "$HOME/.ssh/config"; then
    exec /usr/bin/ssh -G -F "$HOME/.ssh/config" "$s"
  fi
  [[ "$s" == *@* ]] && u="${s%@*}" s="${s#*@}"
  printf 'hostname %s.example.org\nuser %s\nport %s\nidentityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ed25519\n' "$s" "$u" "$pt"
  # SSH_G_MORE: the rest comes in a later write, as the real ssh's does (its output is
  # over 4096 bytes, written in two): a reader that stops at the user line has gone by
  # then, and the write dies of SIGPIPE -- under pipefail, the reader's pipeline fails.
  # The pause makes that race, which CI lost now and then, lost every time.
  if [[ -n "${SSH_G_MORE:-}" ]]; then
    sleep 0.3
    printf 'setenv %065536d\n' 0
  fi
  exit 0
fi
orig=("$@")
acct=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o | -p) shift 2 ;;
    -l) acct="$2" && shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
dest="$1"
shift
cmd="$*"
if [[ "$cmd" == *"umask 077; cat >"* ]]; then
  # the copy of the admin's script into the user's home there
  [[ -n "${COPY_FAIL:-}" ]] && exit 255
  printf '%s\n' "${orig[@]}" >"$PROBE_H/copy.argv"
  cat >"$PROBE_H/copied.sh"
  exit 0
fi
if [[ -n "$acct" ]]; then
  AH="$PROBE_R/home/$acct"
  mkdir -p "$AH"
  printf '%s\n' "${orig[@]}" >"$PROBE_H/acct.argv"
  printf '%s\n' "${orig[*]}" >>"$PROBE_H/acct.argvs"
  printf '%s\n' "$cmd" >>"$PROBE_H/acct.cmds"
  [[ -n "${ACCT_FAIL:-}" ]] && { echo "tob@qgpu3: Permission denied (publickey)." >&2; exit 255; }
  env -i HOME="$AH" PATH="$PROBE_H/acct-bin:/usr/bin:/bin" PROBE_H="$PROBE_H" INSTALL_RC="${INSTALL_RC:-0}" ASB_RC="${ASB_RC:-0}" /bin/bash -c "$cmd"
  rc=$?
  if [[ "$cmd" == *"tar -xf"* && -f "$AH/.local/share/agent-sandbox/src/install.sh" ]]; then
    cp "$PROBE_H/stub-install.sh" "$AH/.local/share/agent-sandbox/src/install.sh"
    echo carry >>"$PROBE_H/acct.log"
  fi
  exit "$rc"
fi
if [[ "$dest" == "${ALIAS_NAME:-r1}" ]]; then
  printf '%s\n' "${orig[@]}" >"$PROBE_H/login.argv"
  cat >"$PROBE_H/check.sh"
  # the login is the User the alias names
  u="$(/usr/bin/ssh -G -F "$HOME/.ssh/config" "$dest" | awk '$1 == "user" {print $2}')"
  exec env -i HOME=/nonexistent PATH="$PROBE_H/login-bin:/usr/bin:/bin" AGENT_SANDBOX=1 \
    LOGIN_USER="${LOGIN_USER:-$u}" DIRECT_OPEN="${DIRECT_OPEN:-}" LOGIN_GPUS="${LOGIN_GPUS:-GPU-1}" \
    ALLOWED_OUT="${ALLOWED_OUT:-200 200}" EX_OUT="${EX_OUT:-000 403}" \
    /bin/bash -s <"$PROBE_H/check.sh"
fi
printf '%s\n' "${orig[@]}" >"$PROBE_H/ssh.argv"
cat >"$PROBE_H/probe.sh"
[[ -n "${PROBE_FAIL:-}" ]] && { echo "ssh: connect to host x port 22: Connection refused" >&2; exit 255; }
exec env -i PATH="$PROBE_R/usr/bin:$PROBE_R/bin" HOME="$PROBE_R/home/tester" \
  AGENT_SANDBOX_TEST_PROBE_ROOT="$PROBE_R" AGENT_SANDBOX_TEST_PROBE_NET=127.0.0.1:1 /bin/bash -s <"$PROBE_H/probe.sh"
X
  printf '#!/usr/bin/env bash\nexit 1\n' >"$H/bin/ssh-add"
  chmod +x "$H/bin/ssh" "$H/bin/ssh-add"
  # The account's side: install.sh records its run and installs the stub asb, which
  # records each call, approves (a copy of the file approved), launches (a marker, and
  # the role's host key made once where the sshd profile keeps it), and says --status.
  mkdir -p "$H/acct-bin" "$H/login-bin"
  cat >"$H/stub-install.sh" <<'X'
#!/bin/bash
echo "install.sh $*" >>"$PROBE_H/install.calls"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/agent-sandbox/app"
cp "$PROBE_H/stub-asb" "$HOME/.local/bin/asb" && chmod +x "$HOME/.local/bin/asb"
: >"$HOME/.local/share/agent-sandbox/app/agent-sandbox"
if [[ "${INSTALL_RC:-0}" != 0 ]]; then
  echo "==> The proxy's environment"
  echo "    [err] micromamba create failed"
fi
exit "${INSTALL_RC:-0}"
X
  cat >"$H/stub-asb" <<'X'
#!/bin/bash
echo "$(pwd -P): asb $*" >>"$PROBE_H/asb.calls"
role="" verb=launch
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) role="$2" && shift 2 ;;
    --trust | --status | --shutdown) verb="${1#--}" && shift ;;
    *) shift ;;
  esac
done
m="$HOME/.running-$role"
case "$verb" in
  trust)
    read -r a
    echo "trust answered $a" >>"$PROBE_H/asb.calls"
    cp .agent-sandbox "$HOME/.approved"
    ;;
  status)
    if [[ -e "$m" ]]; then
      printf "role '%s' of %s: running since now (supervisor pid 1)\n  processes:\n         7  /usr/sbin/sshd -D -e -f /tmp/x/sshd_config\n" "$role" "$PWD"
    else
      printf "role '%s' of %s: not running\n" "$role" "$PWD"
    fi
    exit "${ASB_RC:-0}"
    ;;
  shutdown)
    [[ -e "$m" ]] && echo "agent-sandbox: role '$role': ended, with everything that ran in it" >&2
    rm -f "$m"
    exit "${ASB_RC:-0}"
    ;;
  launch)
    cmp -s .agent-sandbox "$HOME/.approved" || { echo "not approved" >&2 && exit 1; }
    slug="$(pwd -P)"
    d="$HOME/.local/state/agent-sandbox/sshd/${slug//[^A-Za-z0-9-]/-}/$role/sshd"
    mkdir -p "$d"
    [[ -f "$d/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -N '' -C "agent-sandbox sshd, role $role" -f "$d/ssh_host_ed25519_key" </dev/null
    : >"$m"
    ;;
esac
X
  # the account's nvidia-smi -q, as a 615 driver writes it (the lines it is read for)
  cat >"$H/acct-bin/nvidia-smi" <<'X'
#!/bin/bash
printf 'GPU 00000000:01:00.0\n    GPU UUID                  : GPU-0\n    Minor Number              : 0\n'
printf 'GPU 00000000:21:00.0\n    GPU UUID                  : GPU-1\n    Minor Number              : 1\n'
X
  printf '#!/bin/bash\n[[ "$1" == -un ]] && echo "$LOGIN_USER" || echo "uid=1001($LOGIN_USER)"\n' >"$H/login-bin/id"
  cat >"$H/login-bin/curl" <<'X'
#!/bin/bash
case "$*" in
  *--noproxy*) [[ -n "$DIRECT_OPEN" ]] && exit 0 || exit 7 ;;
  *example.com*) printf '%s' "$EX_OUT" && exit 56 ;;
  *) printf '%s' "$ALLOWED_OUT" ;;
esac
X
  printf '#!/bin/bash\nfor g in $LOGIN_GPUS; do echo "$g"; done\n' >"$H/login-bin/nvidia-smi"
  chmod +x "$H/stub-install.sh" "$H/stub-asb" "$H/acct-bin/"* "$H/login-bin/"*
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
    printf '[remote:r1]\nhost = %s\nport = %s\n' "${HOST:-qgpu3}" "${PORT:-0.0.0.0:2222}"
    printf '%s\n' "$@"
  } >"$PROJ/.agent-sandbox"
  [[ -n "${NOAPPROVE:-}" ]] && return 0
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
}

# setup_remote [VAR=value ...] [ARGS...] -- `--setup-remote ARGS...` (r1 by default) in the
# project, answered SR_ANSWER (printf %b; nothing by default).
setup_remote() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  engine_cmd
  run bash -c 'cd "$1" && n="$4" && printf "%b" "$7" | env -i HOME="$2" PATH="$3" PROBE_R="$5" PROBE_H="$6" "${@:8:n}" "${@:8+n}" 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#envs[@]}" "$R" "$H" "${SR_ANSWER:-}" ${envs[@]+"${envs[@]}"} "${ENGINE_CMD[@]}" --setup-remote "${@:-r1}"
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

@test "--setup-remote DEST: a word that is no section is a destination; its section, [remote:ACCOUNT-HOST] with your ssh login name, is appended for review, and declined the file is as it was, or absent (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  setup_remote qgpu3
  [ "$status" -eq 1 ]
  local q='agent-sandbox: remote tester-qgpu3:'
  [[ "$output" == *"$q qgpu3 is a destination, not a section of .agent-sandbox: its section is [remote:tester-qgpu3]"* ]]
  [[ "$output" == *"added to [remote:tester-qgpu3]: host = qgpu3"* ]]
  [[ "$output" == *"added to [remote:tester-qgpu3]: account = tester"* ]]
  [[ "$output" == *"added to [remote:tester-qgpu3]: port = 2222"* ]]
  [[ "$output" == *"added to [remote:tester-qgpu3]: scratch = ~/tester-qgpu3"* ]]
  [[ "$output" == *"$q not approved: .agent-sandbox is as it was (none); nothing was done" ]]
  [ ! -e "$PROJ/.agent-sandbox" ]
  [ ! -e "$H/ssh.argv" ]
  section
  cp "$PROJ/.agent-sandbox" "$BATS_TEST_TMPDIR/before"
  setup_remote r2
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: remote tester-r2: r2 is a destination, not a section of .agent-sandbox (it has: r1): its section is [remote:tester-r2]"* ]]
  [[ "$output" == *"agent-sandbox: remote tester-r2: not approved: .agent-sandbox is as it was; nothing was done" ]]
  cmp "$BATS_TEST_TMPDIR/before" "$PROJ/.agent-sandbox"
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: refused for a section that is unusable as written (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  printf '[remote:r1]\nhost = qgpu3\n' >"$PROJ/.agent-sandbox"
  setup_remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: [remote:r1] is unusable as written; agent-sandbox --check says why"* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: refused while the file is not approved, with the --trust hint (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  NOAPPROVE=1 section 'account = tob'
  setup_remote
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: .agent-sandbox is not approved as it stands, and [remote:r1] in it is what this acts on: review it first (agent-sandbox --trust)"* ]]
  [ ! -e "$H/ssh.argv" ]
}

@test "--setup-remote: a host with everything present and working is ready: exit 0, no admin's script, one batch-mode ssh (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  [[ "$output" == *"$p ready for the account's part"$'\n'"$p the account's part, over ssh as "* ]]
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host sudo=none
  section
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p logged in as tester (no sudo; asb never uses it)"* ]]
  [[ "$output" == *"$p the account is the ssh user tester, home $R/home/tester, "* ]]
  [[ "$output" == *"$p ready for the account's part"$'\n'"$p the account's part, over ssh as "* ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: a gpu node the host lacks is said, and is no fault of the preflight (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  section 'gpu = /dev/nvidiactl /dev/nvidia3'
  setup_remote
  [[ "$output" == *"$p gpu /dev/nvidiactl mode 666"* ]]
  [[ "$output" == *"$p gpu /dev/nvidia3 missing on that host (the login's policy says the same at launch)"* ]]
  [[ "$output" == *"$p ready for the account's part"* ]]
  # and the check after the launch finds the login without that card
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p check: nvidia-smi inside lists 'GPU-1', where the section's nodes are 'unknown': FAILED"* ]]
}

@test "--setup-remote: the run line follows sudo: without a password, none, and root (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host sudo=root uid=0 user=root
  section
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the account is the ssh user, root: a login does not run as root; name an account in [remote:r1] (account = NAME)"* ]]
  [[ "$output" == *"$p not ready, for the reason above" ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: a preflight ssh cannot complete is said, exit 1 (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  section
  setup_remote PROBE_FAIL=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the preflight did not complete (ssh exit 255): ssh: connect to host x port 22: Connection refused"* ]]
  [[ "$output" == *"$p it needs ssh to reach qgpu3 without a question (BatchMode)"* ]]
  [ ! -e "$ADMIN" ]
}

@test "--setup-remote: an installed engine takes the profiles from the checkout install.manifest records, else says by hand (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
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
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host bwrap=missing pasta=missing cand=0.9.0-1ubuntu0.3 profiles= accounts=
  section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  local order
  order="$(script_code "$ADMIN" | grep -oE 'apt-get install|apparmor_parser -r /etc/apparmor.d/[a-z]+|--rebuild-bwrap|^  adduser' | paste -sd, -)"
  [ "$order" = "apt-get install,apparmor_parser -r /etc/apparmor.d/bwrap,apparmor_parser -r /etc/apparmor.d/pasta,--rebuild-bwrap,  adduser" ]
  grep -qx '#   - AppArmor profiles for bwrap and pasta' "$ADMIN"
}

# ---- the account's part and the local side (#344, step 3) ----

# full_section -- a section with every key, the login on that host's loopback.
full_section() {
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'gpu = /dev/nvidiactl /dev/nvidia1' \
    'allow = pypi.org files.pythonhosted.org' 'env = TMPDIR=/home/tob/bench/tmp' 'env = CUDA_VISIBLE_DEVICES=0'
}

# user_ssh_config -- a ~/.ssh/config of the user's own, before any run.
user_ssh_config() {
  mkdir -p "$H/home/.ssh"
  printf 'Host build\n  HostName build.example.org\n  User me\n\n# a comment of mine\nHost *.lan\n  ForwardAgent no' >"$H/home/.ssh/config"
  cp "$H/home/.ssh/config" "$BATS_TEST_TMPDIR/config.orig"
}

@test "--setup-remote: the account's part for a full section: install.sh as the account, exactly the policy, the keys file, approved, launched, the host key back under [127.0.0.1]:PORT, the alias through ProxyJump, the checks (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  user_ssh_config
  setup_remote
  [ "$status" -eq 0 ]
  local T="$R/home/tob"
  # as the account, never as the ssh user, never sudo
  grep -qx -- '-l' "$H/acct.argv"
  grep -qx 'tob' "$H/acct.argv"
  grep -qx 'BatchMode=yes' "$H/acct.argv"
  [[ "$output" == *"$p the account's part, over ssh as tob to qgpu3 (ssh -l tob qgpu3; BatchMode; never sudo)"* ]]
  [[ "$output" == *"$p not set up yet as tob (install: no, the login's store: no)"* ]]
  # the checkout carried as a git archive, install.sh run there
  [ "$(cat "$H/acct.log")" = carry ]
  [ -f "$T/.local/share/agent-sandbox/src/agent-sandbox" ]
  cmp "$T/.local/share/agent-sandbox/src/profiles/sshd/profile.sh" "$REPO_ROOT/profiles/sshd/profile.sh"
  [ "$(cat "$H/install.calls")" = "install.sh " ]
  [ "$(cat "$T/.local/share/agent-sandbox/src/.asb-carried")" = "$(git -C "$ENGDIR" describe --always --tags HEAD)" ]
  [[ "$output" == *"$p install.sh as tob (its output: ~/asb-install-r1.log there)"$'\n'"$p install.sh ok"* ]]
  # the policy, every line
  cat >"$BATS_TEST_TMPDIR/want" <<W
# Generated by \`asb --setup-remote r1\` from [remote:r1] of $PROJ.
# The next run of it overwrites this file: change the section there, not this file.
[net]
mode = strict
agent-port = 2222

[allow]
pypi.org
files.pythonhosted.org

[gpu]
devices = /dev/nvidiactl /dev/nvidia1

[env]
TMPDIR = /home/tob/bench/tmp
CUDA_VISIBLE_DEVICES = 0

[sshd]
authorized-keys = ~/.config/agent-sandbox/asb-r1-keys
home = project
W
  cmp "$BATS_TEST_TMPDIR/want" "$T/bench/.agent-sandbox"
  [[ "$output" == *"$p the policy $T/bench/.agent-sandbox: new, from the section"* ]]
  # the key: made once here, its public half the keys file there, outside the scratch
  [ -f "$H/home/.ssh/asb-r1" ]
  [[ "$(cat "$H/home/.ssh/asb-r1.pub")" == "ssh-ed25519 "*" agent-sandbox remote r1" ]]
  cmp "$H/home/.ssh/asb-r1.pub" "$T/.config/agent-sandbox/asb-r1-keys"
  [ "$(stat -c %a "$T/.config/agent-sandbox/asb-r1-keys")" = 600 ]
  # approved with a y, then launched in the scratch as the role r1
  grep -qxF "$T/bench: asb --profile sshd --trust" "$H/asb.calls"
  grep -qx 'trust answered y' "$H/asb.calls"
  grep -qxF "$T/bench: asb --profile sshd --role r1" "$H/asb.calls"
  [[ "$output" == *"$p the login is running there"* ]]
  # the host key back, under the name ssh looks up for the jump
  local hk
  hk="$(cut -d' ' -f1,2 "$T/.local/state/agent-sandbox/sshd/${T//[^A-Za-z0-9-]/-}-bench/r1/sshd/ssh_host_ed25519_key.pub")"
  [ "$(cat "$H/home/.ssh/known_hosts")" = "[127.0.0.1]:2222 $hk agent-sandbox remote r1 (#344)" ]
  # the alias block, appended; the rest of the file byte for byte, and its backup
  cat >"$BATS_TEST_TMPDIR/block" <<W
# >>> agent-sandbox remote r1 (#344) >>>
# Written by \`asb --setup-remote r1\` from [remote:r1] of $PROJ;
# every run rewrites these lines. Change the section, not them.
Host r1
  HostName 127.0.0.1
  Port 2222
  User tob
  IdentityFile ~/.ssh/asb-r1
  IdentitiesOnly yes
  ProxyJump qgpu3
# <<< agent-sandbox remote r1 <<<
W
  { cat "$BATS_TEST_TMPDIR/config.orig" && printf '\n\n' && cat "$BATS_TEST_TMPDIR/block"; } >"$BATS_TEST_TMPDIR/config.want"
  cmp "$BATS_TEST_TMPDIR/config.want" "$H/home/.ssh/config"
  cmp "$BATS_TEST_TMPDIR/config.orig" "$H/home/.ssh/config.before-agent-sandbox"
  [[ "$output" == *"$p the alias r1 in ~/.ssh/config (a marked block; the file as it was before: $H/home/.ssh/config.before-agent-sandbox)"* ]]
  # the checks, through the alias
  [ "$(tail -n 2 "$H/login.argv" | paste -sd' ' -)" = "bash -s" ]
  [[ "$output" == *"$p check: ssh r1 logs in as tob, inside the sandbox (AGENT_SANDBOX=1): ok"* ]]
  [[ "$output" == *"$p check: https://pypi.org/ through the proxy: the proxy opened the tunnel and the host answered HTTP 200: ok"* ]]
  [[ "$output" == *"$p check: a direct connection to https://pypi.org/, around the proxy, fails: ok"* ]]
  [[ "$output" == *"$p check: https://example.com/, not allowed, is refused by the proxy at CONNECT (403): ok"* ]]
  [[ "$output" == *"$p check: nvidia-smi inside lists exactly the card(s) of the section's nodes (GPU-1): ok"* ]]
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$p for a role to reach it: agent-sandbox --apply '[ssh:ROLE]' r1"$'\n'"$p after a reboot of qgpu3: agent-sandbox --setup-remote r1" ]]
  run ! grep -q sudo "$H/acct.cmds"
}

@test "--setup-remote: the policy there is never written through a link its sandbox left in the scratch: the old fixed temp name .agent-sandbox.asb-new pointing outside is left as it is, its target unchanged (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  local T="$R/home/tob"
  mkdir -p "$T/bench"
  printf 'KEEP\n' >"$T/outside"
  ln -s "$T/outside" "$T/bench/.agent-sandbox.asb-new"
  setup_remote
  [ "$(cat "$T/outside")" = KEEP ]
  [ "$status" -eq 0 ]
  [ -L "$T/bench/.agent-sandbox.asb-new" ]
  [ -f "$T/bench/.agent-sandbox" ] && [ ! -L "$T/bench/.agent-sandbox" ]
  grep -qx '\[sshd\]' "$T/bench/.agent-sandbox"
  # the account's umask (the stub account inherits this one), not mktemp's 600
  [ "$(stat -c %a "$T/bench/.agent-sandbox")" = "$(printf '%o' $((0666 & ~0$(umask))))" ]
  [ -z "$(find "$T/bench" -maxdepth 1 -name '.agent-sandbox.asb-new.*')" ] # no temp left
}

@test "--setup-remote: a policy written over one there keeps that file's mode, and its inode: written in place, as --init writes it (#344, #389)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  local T="$R/home/tob" ino
  mkdir -p "$T/bench"
  printf '# an older policy\n' >"$T/bench/.agent-sandbox"
  chmod 640 "$T/bench/.agent-sandbox"
  ino="$(stat -c %i "$T/bench/.agent-sandbox")"
  setup_remote
  [ "$status" -eq 0 ]
  grep -qx '\[sshd\]' "$T/bench/.agent-sandbox"
  [ "$(stat -c %a "$T/bench/.agent-sandbox")" = 640 ]
  [ "$(stat -c %i "$T/bench/.agent-sandbox")" = "$ino" ]
  [ -z "$(find "$T/bench" -maxdepth 1 -name '.agent-sandbox.?*')" ] # no temp left
}

@test "--setup-remote: .asb/remote/.gitignore is never written through a link a sandbox left there, a dangling one included (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host bwrap=missing pasta=missing profiles=
  section 'account = tob'
  mkdir -p "$PROJ/.asb/remote"
  ln -s "$H/created-outside" "$PROJ/.asb/remote/.gitignore"
  setup_remote
  [ "$status" -eq 1 ]
  [ -f "$ADMIN" ]
  [ ! -e "$H/created-outside" ]
  [ -L "$PROJ/.asb/remote/.gitignore" ]
}

@test "--setup-remote: a link at .asb, .asb/remote or the remote's directory is refused: nothing is made through it (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host bwrap=missing pasta=missing profiles=
  section 'account = tob'
  local l
  for l in .asb .asb/remote .asb/remote/r1; do
    rm -rf "$PROJ/.asb" "$H/outdir"
    mkdir -p "$H/outdir" "$PROJ/$(dirname "$l")"
    ln -s "$H/outdir" "$PROJ/$l"
    setup_remote
    [ -z "$(ls -A "$H/outdir")" ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"$p $l is a symlink; the admin's script is not written through it"* ]]
  done
}

@test "--setup-remote: a port published at an address: HostName the host's own, no ProxyJump, the host key as [HostName]:PORT; a literal address is the HostName, and our line replaced (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  section
  setup_remote
  [ "$status" -eq 0 ]
  # no account named: the ssh user is the account
  grep -qx 'tester' "$H/acct.argv"
  [[ "$output" == *"$p the alias r1 in ~/.ssh/config (created; a marked block)"* ]]
  [ ! -e "$H/home/.ssh/config.before-agent-sandbox" ] # no file before: nothing to back up
  grep -qx '  HostName qgpu3.example.org' "$H/home/.ssh/config"
  grep -qx '  Port 2222' "$H/home/.ssh/config"
  grep -qx '  User tester' "$H/home/.ssh/config"
  [[ "$(cat "$H/home/.ssh/known_hosts")" == "[qgpu3.example.org]:2222 ssh-ed25519 "*" agent-sandbox remote r1 (#344)" ]]
  run ! grep -q ProxyJump "$H/home/.ssh/config"
  PORT=192.0.2.7:2222 section
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p relaunching the login (the policy changed)"* ]]
  [ "$(grep -c '^Host ' "$H/home/.ssh/config")" -eq 1 ]
  grep -qx '  HostName 192.0.2.7' "$H/home/.ssh/config"
  [ "$(wc -l <"$H/home/.ssh/known_hosts")" -eq 1 ]
  [[ "$(cat "$H/home/.ssh/known_hosts")" == "[192.0.2.7]:2222 ssh-ed25519 "* ]]
}

@test "--setup-remote: a section whose host is its own name is a fault at the review, and refused by the command before any ssh (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  printf '[remote:qgpu3]\nhost = qgpu3\nport = 2222\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" == *".agent-sandbox: [remote:qgpu3] host = qgpu3: the remote's own name, which --setup-remote makes an alias in your ~/.ssh/config for the login, so it would shadow your alias qgpu3; name the section otherwise; unusable as written"* ]]
  [[ "$output" == *".agent-sandbox: [remote:qgpu3]: unusable as written, for the reasons above"* ]]
  setup_remote qgpu3
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: [remote:qgpu3] has host = qgpu3, its own name: the alias this writes into ~/.ssh/config, Host qgpu3, would shadow your alias qgpu3. Name the section otherwise"* ]]
  [ ! -e "$H/ssh.argv" ]
  [ ! -e "$H/home/.ssh/asb-qgpu3" ]
}

@test "--setup-remote: a scratch that is /, the home, or has a '..' component is refused; one that is the home by its absolute path, once the account's side says so (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  local s
  # shellcheck disable=SC2088 # the section's own words, written as they are
  for s in / '~' '~/' '~/a/../b' /srv/../etc; do
    section 'account = tob' "scratch = $s"
    setup_remote
    [ "$status" -eq 2 ]
    [[ "$output" == *"--setup-remote: [remote:r1] scratch = $s: the login's one writable place is a project directory, never / nor the account's home, nor a path with a '..' component"* ]]
    [ ! -e "$H/ssh.argv" ]
  done
  section 'account = tob' "scratch = $R/home/tob/"
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p scratch = $R/home/tob/ is tob's home there ($R/home/tob): the login's one writable place is a project directory, never the home itself"* ]]
  [ ! -e "$H/acct.log" ] # nothing carried
  [ ! -e "$R/home/tob/.agent-sandbox" ]
}

@test "--setup-remote: run again unchanged: nothing carried or installed, no approval, no relaunch -- up to date; the checks again (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  user_ssh_config
  setup_remote
  [ "$status" -eq 0 ]
  cp "$H/home/.ssh/config" "$BATS_TEST_TMPDIR/config.after"
  : >"$H/asb.calls"
  setup_remote
  [ "$status" -eq 0 ]
  local d T="$R/home/tob"
  d="$(git -C "$ENGDIR" describe --always --tags HEAD)"
  [[ "$output" == *"$p set up already: tob's install (of $d) and the login's store there; this run is the update"* ]]
  [[ "$output" == *"$p tob's install is of $d, as the checkout: nothing carried"* ]]
  [[ "$output" == *"$p the policy $T/bench/.agent-sandbox: unchanged"* ]]
  [[ "$output" == *"$p up to date: the login is running"* ]]
  [[ "$output" == *"$p the alias r1 in ~/.ssh/config: unchanged"* ]]
  [[ "$output" == *"$p check: ssh r1 logs in as tob, inside the sandbox (AGENT_SANDBOX=1): ok"* ]]
  [[ "$output" == *"$p set up: ssh r1"* ]]
  [ "$(cat "$H/acct.log")" = carry ]
  [ "$(wc -l <"$H/install.calls")" -eq 1 ]
  cmp "$BATS_TEST_TMPDIR/config.after" "$H/home/.ssh/config"
  cmp "$BATS_TEST_TMPDIR/config.orig" "$H/home/.ssh/config.before-agent-sandbox" # backed up once
  [ "$(wc -l <"$H/home/.ssh/known_hosts")" -eq 1 ]
  run ! grep -E 'trust|shutdown|--role r1$' "$H/asb.calls"
}

@test "--setup-remote: a changed section: the diff of the two policies said, approved again, shut down and relaunched (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  setup_remote
  [ "$status" -eq 0 ]
  : >"$H/asb.calls"
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'gpu = /dev/nvidiactl /dev/nvidia1' \
    'allow = pypi.org files.pythonhosted.org' 'allow = download.pytorch.org' 'env = TMPDIR=/home/tob/bench/tmp' 'env = CUDA_VISIBLE_DEVICES=0'
  setup_remote
  [ "$status" -eq 0 ]
  local T="$R/home/tob"
  [[ "$output" == *"$p the policy $T/bench/.agent-sandbox: changed:"$'\n'"$p   +download.pytorch.org"$'\n'* ]]
  [[ "$output" == *"$p relaunching the login (the policy changed)"* ]]
  grep -qx 'download.pytorch.org' "$T/bench/.agent-sandbox"
  [ "$(sed 's/^[^:]*: //' "$H/asb.calls" | grep -v -- '--status' | paste -sd, -)" = "asb --profile sshd --trust,trust answered y,asb --profile sshd --role r1 --shutdown,asb --profile sshd --role r1" ]
  [ "$(cat "$H/acct.log")" = carry ] # the checkout is the same: not carried again
}

@test "--setup-remote: not running (a reboot): launched again, without approval; the keys file, the host key and the alias block mended (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  setup_remote
  [ "$status" -eq 0 ]
  local T="$R/home/tob"
  rm "$T/.running-r1"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther someone' >>"$T/.config/agent-sandbox/asb-r1-keys"
  : >"$H/home/.ssh/known_hosts"
  sed -i 's/^  Port 2222$/  Port 9999/' "$H/home/.ssh/config"
  cp "$H/home/.ssh/config" "$BATS_TEST_TMPDIR/config.edited"
  : >"$H/asb.calls"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p the login is not running (a reboot of qgpu3?): launching it"* ]]
  [ "$(sed 's/^[^:]*: //' "$H/asb.calls" | grep -v -- '--status' | paste -sd, -)" = "asb --profile sshd --role r1" ]
  cmp "$H/home/.ssh/asb-r1.pub" "$T/.config/agent-sandbox/asb-r1-keys"
  [ "$(wc -l <"$H/home/.ssh/known_hosts")" -eq 1 ]
  grep -qx '  Port 2222' "$H/home/.ssh/config"
  [[ "$output" == *"$p the alias r1 in ~/.ssh/config (its marked block rewritten)"* ]]
}

@test "--setup-remote: a checkout at another commit than the account's install is carried and installed again, and the login relaunched (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  setup_remote
  [ "$status" -eq 0 ]
  echo v0.0.0-1-gdeadbee >"$R/home/tob/.local/share/agent-sandbox/src/.asb-carried"
  : >"$H/asb.calls"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p set up already: tob's install (of v0.0.0-1-gdeadbee) and the login's store there; this run is the update"* ]]
  [[ "$output" == *"$p carrying the checkout $ENGDIR (the engine's own checkout) at $(git -C "$ENGDIR" describe --always --tags HEAD) into tob's ~/.local/share/agent-sandbox"* ]]
  [[ "$output" == *"$p relaunching the login (the install changed)"* ]]
  [ "$(paste -sd, "$H/acct.log")" = carry,carry ]
  [ "$(wc -l <"$H/install.calls")" -eq 2 ]
}

@test "--setup-remote: your micromamba is carried into the account's install, where install.sh looks for it (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  mkdir -p "$H/home/.local/share/agent-sandbox/micromamba/bin"
  printf 'not the pinned build\n' >"$H/home/.local/share/agent-sandbox/micromamba/bin/micromamba"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"and your micromamba into tob's ~/.local/share/agent-sandbox"* ]]
  [[ "$output" == *"$p your micromamba ($H/home/.local/share/agent-sandbox/micromamba/bin/micromamba) is not the build $ENGDIR's install.sh pins: install.sh there fetches that one (curl)"* ]]
  cmp "$H/home/.local/share/agent-sandbox/micromamba/bin/micromamba" "$R/home/tob/.local/share/agent-sandbox/micromamba/bin/micromamba"
  [ "$(stat -c %a "$R/home/tob/.local/share/agent-sandbox/micromamba/bin/micromamba")" = 755 ]
}

@test "--setup-remote: the account unreachable, install.sh failing, a check failing: each said, exit 1 (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  setup_remote ACCT_FAIL=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p cannot read the account's state as tob (ssh exit 255): tob@qgpu3: Permission denied (publickey)."* ]]
  [[ "$output" == *"$p it needs ssh -l tob qgpu3 to work without a question: your public key in tob's ~/.ssh/authorized_keys"* ]]
  setup_remote INSTALL_RC=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p install.sh failed there (exit 1); its last lines:"$'\n'"$p   ==> The proxy's environment"$'\n'"$p       [err] micromamba create failed" ]]
  [ ! -e "$H/asb.calls" ]
  [ ! -e "$R/home/tob/.local/share/agent-sandbox/src/.asb-carried" ]
  setup_remote DIRECT_OPEN=1
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p check: a direct connection to https://pypi.org/, around the proxy, succeeded: FAILED"* ]]
  [[ "$output" == *"$p set up, and 1 check(s) failed (above): ssh r1"* ]]
}

@test "--setup-remote: a block of yours above the alias that sets its options first is said, exit 1 (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  mkdir -p "$H/home/.ssh"
  printf 'Host *\n  User someone\n' >"$H/home/.ssh/config"
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p ssh -G r1 does not resolve to the block (user): a Host or Match block above it in ~/.ssh/config sets that first. Move the marked block above it"* ]]
}

@test "--setup-remote: an [ssh] line that names the remote: no --apply line to say (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  section 'account = tob' '[ssh:impl-1]' 'r1'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$p after a reboot of qgpu3: agent-sandbox --setup-remote r1" ]]
}

# apply_remote ANSWERS ARGS... -- `--apply ARGS...` in the project, ANSWERS on stdin.
apply_remote() {
  local answers="$1"
  shift
  engine_cmd
  run bash -c 'cd "$1" && printf "%b" "$2" | env -i HOME="$3" PATH="$4" "${@:5}" 2>&1' _ \
    "$PROJ" "$answers" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --apply "$@"
}

@test "--apply on a [remote:ALIAS] section: appended under it, the review says the line, then the --setup-remote line; a new one created; [remote] without a name refused (#344)" {
  section 'account = tob' '' '[allow]' 'pypi.org'
  apply_remote 'y\n' '[remote:r1]' 'allow = download.pytorch.org'
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to [remote:r1]: allow = download.pytorch.org"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1] allow = download.pytorch.org: the login's sandbox reaches these hosts through its allowlist proxy there"* ]]
  [[ "$output" == *"approved."* ]]
  [[ "$output" == *"agent-sandbox: then: agent-sandbox --setup-remote r1" ]]
  [[ "$output" != *"first role section"* && "$output" != *"applies at the next launch"* ]]
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[remote:r1]\nhost = qgpu3\nport = 0.0.0.0:2222\naccount = tob\nallow = download.pytorch.org\n\n[allow]\npypi.org' ]
  apply_remote 'y\n' '[remote:r2]' 'host = qgpu3' 'port = 2224'
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: then: agent-sandbox --setup-remote r2" ]]
  [ "$(tail -n 3 "$PROJ/.agent-sandbox")" = $'[remote:r2]\nhost = qgpu3\nport = 2224' ]
  apply_remote 'y\n' '[remote]' 'host = qgpu3'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply: [remote] takes the remote's name, letters, digits, '-', '_' and '.': --apply '[remote:ALIAS]' 'allow = HOST ...'"* ]]
}

@test "--setup-remote: a pasta whose build names no version is ok, said so; one without --hostname gets no note (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host pasta='unknown version'
  section
  setup_remote
  [[ "$output" == *"$p pasta ok (its build names no version)"$'\n'* ]]
  [[ "$output" != *"pasta version ok"* ]]
  remote_host
  stub pasta "case \"\$1\" in --version) printf 'pasta 2024_02_20.1e6f92b\n' ;; --help) echo '  --config-net' ;; *) true ;; esac"
  setup_remote
  [[ "$output" == *"$p pasta 2024_02_20.1e6f92b ok"$'\n'* ]]
  [[ "$output" != *"--hostname"* ]]
}

@test "--setup-remote: host = HOST:SSHPORT -- that port for every ssh to the host: the preflight, the admin's copy and its run line, the account's part, and ProxyJump HOST:SSHPORT (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host bwrap=missing
  HOST=qgpu3:2224 PORT=2222 section 'account = tob'
  setup_remote
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p the preflight, over ssh to tester@qgpu3.example.org port 2224 (-p 2224 qgpu3), read-only"* ]]
  [ "$(grep -A1 -x -- -p "$H/ssh.argv" | paste -sd' ' -)" = "-p 2224" ]
  [ "$(grep -A1 -x -- -p "$H/copy.argv" | paste -sd' ' -)" = "-p 2224" ]
  [[ "$output" == *"$p   ssh -t -p 2224 qgpu3 sudo bash asb-admin-r1.sh"$'\n'* ]]
  grep -qxF '#   ssh -t -p 2224 qgpu3 sudo bash asb-admin-r1.sh' "$ADMIN"
  remote_host
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p the account's part, over ssh as tob to qgpu3 (ssh -p 2224 -l tob qgpu3; BatchMode; never sudo)"* ]]
  [[ "$output" == *"$p check: ssh r1 logs in as tob, inside the sandbox (AGENT_SANDBOX=1): ok"* ]]
  grep -qx '  ProxyJump qgpu3:2224' "$H/home/.ssh/config"
  grep -qx '  Port 2222' "$H/home/.ssh/config"
  # every session as the account carried the port
  [ "$(grep -c . "$H/acct.argvs")" -ge 3 ]
  run ! grep -v -- '-p 2224 ' "$H/acct.argvs"
}

@test "--setup-remote: gpu = none is no GPU: said at the review, [gpu] mode = off in the policy, no GPU check (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  PORT=2222 section 'account = tob' 'gpu = none'
  [[ "$output" == *".agent-sandbox: [remote:r1] gpu = none: no GPU device node of that host is passed into the login's sandbox"* ]]
  [[ "$output" != *"unusable"* ]]
  setup_remote
  [ "$status" -eq 0 ]
  grep -qx 'mode = off' "$R/home/tob/r1/.agent-sandbox"
  [ "$(grep -A1 -x '\[gpu\]' "$R/home/tob/r1/.agent-sandbox" | paste -sd' ' -)" = "[gpu] mode = off" ]
  [[ "$output" != *"nvidia-smi inside"* ]]
}

@test "--setup-remote DEST --port: the section appended exactly, approved through the review, then set up as [remote:ACCOUNT-HOST]: the ssh port, the login's port, the scratch (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  SR_ANSWER='y\n' setup_remote ALIAS_NAME=tob-qgpu3 tob@qgpu3:2223 --port 2224
  [ "$status" -eq 0 ]
  local q='agent-sandbox: remote tob-qgpu3:'
  [ "$(cat "$PROJ/.agent-sandbox")" = $'[remote:tob-qgpu3]\nhost = qgpu3:2223\naccount = tob\nport = 2224\nscratch = ~/tob-qgpu3' ]
  [[ "$output" == *"$q appending [remote:tob-qgpu3] to $PROJ/.agent-sandbox, for your review"* ]]
  [[ "$output" == *".agent-sandbox: [remote:tob-qgpu3] host = qgpu3:2223: the host the login runs on, reached over ssh as you reach it from here, its sshd at port 2223"* ]]
  [[ "$output" == *"approved."* ]]
  [[ "$output" != *"then: agent-sandbox --setup-remote"* ]]
  [[ "$output" == *"$q the preflight, over ssh to tester@qgpu3.example.org port 2223 (-p 2223 qgpu3), read-only"* ]]
  [[ "$output" == *"$q the policy $R/home/tob/tob-qgpu3/.agent-sandbox: new, from the section"* ]]
  grep -qx 'agent-port = 2224' "$R/home/tob/tob-qgpu3/.agent-sandbox"
  grep -qx 'home = project' "$R/home/tob/tob-qgpu3/.agent-sandbox"
  grep -qx '  ProxyJump qgpu3:2223' "$H/home/.ssh/config"
  grep -qx '  Port 2224' "$H/home/.ssh/config"
  [[ "$output" == *"$q set up: ssh tob-qgpu3"* ]]
  # run again: the section is there now, and used
  SR_ANSWER='' setup_remote ALIAS_NAME=tob-qgpu3 tob@qgpu3:2223 --port 2224
  [ "$status" -eq 0 ]
  [[ "$output" == *"$q [remote:tob-qgpu3] of .agent-sandbox is used"* ]]
  [[ "$output" == *"$q up to date: the login is running"* ]]
}

@test "--setup-remote DEST: a section of that name that says otherwise is refused, each difference said; --port against an ALIAS's port too; a word that is neither is refused (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  printf '[remote:tob-qgpu3]\nhost = qgpu3\naccount = tob\nport = 2222\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  local q='agent-sandbox: remote tob-qgpu3:'
  setup_remote tob@qgpu3:2223 --port 2224
  [ "$status" -eq 2 ]
  [[ "$output" == *"$q [remote:tob-qgpu3] has host = qgpu3, where tob@qgpu3:2223 says qgpu3:2223"* ]]
  [[ "$output" == *"$q [remote:tob-qgpu3] has port = 2222, where --port says 2224"* ]]
  [[ "$output" == *"--setup-remote: [remote:tob-qgpu3] of .agent-sandbox says otherwise than the command line (above); refusing rather than choosing. Change the section, or run --setup-remote tob-qgpu3 for it as written"* ]]
  [[ "$output" != *"has account"* ]]
  [ ! -e "$H/ssh.argv" ]
  printf '[remote:tob-qgpu3]\nhost = qgpu3\nport = 2222\n' >"$PROJ/.agent-sandbox"
  setup_remote SSH_G_MORE=1 tob@qgpu3
  [ "$status" -eq 2 ]
  [[ "$output" == *"$q [remote:tob-qgpu3] has account = tester, where tob@qgpu3 says tob"* ]]
  # no account in the destination either: both from ssh -G, read to its end (SSH_G_MORE)
  printf '[remote:tester-qgpu3]\nhost = qgpu3\nport = 2222\n' >"$PROJ/.agent-sandbox"
  setup_remote SSH_G_MORE=1 qgpu3 --port 2224
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent-sandbox: remote tester-qgpu3: [remote:tester-qgpu3] has port = 2222, where --port says 2224"* ]]
  [[ "$output" != *"has account"* ]]
  # a failing ssh -G is said, with its error, for the destination's account and the section's
  setup_remote SSH_G_FAIL=1 qgpu3
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --setup-remote: cannot resolve 'qgpu3' (ssh -G failed, exit 255): $H/home/.ssh/config line 3: Bad configuration option: bogus"* ]]
  printf '[remote:tob-qgpu3]\nhost = qgpu3\nport = 2222\n' >"$PROJ/.agent-sandbox"
  setup_remote SSH_G_FAIL=1 tob@qgpu3
  [ "$status" -eq 1 ]
  [[ "$output" == *"$q cannot resolve 'qgpu3' (ssh -G failed, exit 255): $H/home/.ssh/config line 3: Bad configuration option: bogus"* ]]
  [[ "$output" != *"says otherwise"* ]]
  printf '[remote:tob-qgpu3]\nhost = qgpu3\naccount = tob\nport = 2222\n' >"$PROJ/.agent-sandbox"
  setup_remote tob-qgpu3 --port 2224
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote: [remote:tob-qgpu3] has port = 2222, where --port says 2224; refusing rather than choosing. Change the section, or leave --port out"* ]]
  local w
  for w in a@b@c qgpu3:70000 'Tob@qgpu3'; do
    setup_remote "$w"
    [ "$status" -eq 2 ]
  done
  setup_remote a@b@c
  [[ "$output" == *"--setup-remote: 'a@b@c' is neither a [remote:ALIAS] section of .agent-sandbox (it has: tob-qgpu3) nor a destination [ACCOUNT@]HOST[:SSHPORT]"* ]]
  setup_remote Tob@qgpu3
  [[ "$output" == *"--setup-remote: the account 'Tob' is not an account name adduser takes"* ]]
  setup_remote r1 --port
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote takes a [remote:ALIAS] section of this project's .agent-sandbox, or a destination, and nothing after it but --port"* ]]
  [ ! -e "$H/ssh.argv" ]
}

# ---- a host that is this machine; the egress check by the proxy's CONNECT (#344, step 4) ----

# this_machine -- the throwaway root reports this machine's machine-id and boot id, as the
# preflight reads them on the host it runs on.
this_machine() {
  mkdir -p "$R/proc/sys/kernel/random"
  cp /etc/machine-id "$R/etc/machine-id"
  cat /proc/sys/kernel/random/boot_id >"$R/proc/sys/kernel/random/boot_id"
}

@test "--setup-remote: a host that is this machine (machine-id and boot id): the alias at 127.0.0.1 with no ProxyJump, for a bare port and 0.0.0.0 alike; the host key as [127.0.0.1]:PORT; another boot id is another machine (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  [ -s /etc/machine-id ]
  remote_host
  this_machine
  PORT=2222 section 'account = tob'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p qgpu3 is this machine (its machine-id and boot id are this one's): the alias goes to the login over 127.0.0.1"* ]]
  grep -qx '  HostName 127.0.0.1' "$H/home/.ssh/config"
  grep -qx '  Port 2222' "$H/home/.ssh/config"
  run ! grep -q ProxyJump "$H/home/.ssh/config"
  [[ "$(cat "$H/home/.ssh/known_hosts")" == "[127.0.0.1]:2222 ssh-ed25519 "*" agent-sandbox remote r1 (#344)" ]]
  PORT=0.0.0.0:2222 section 'account = tob'
  setup_remote
  [ "$status" -eq 0 ]
  grep -qx '  HostName 127.0.0.1' "$H/home/.ssh/config"
  run ! grep -q ProxyJump "$H/home/.ssh/config"
  [ "$(wc -l <"$H/home/.ssh/known_hosts")" -eq 1 ]
  [[ "$(cat "$H/home/.ssh/known_hosts")" == "[127.0.0.1]:2222 ssh-ed25519 "* ]]
  # the same machine-id, another boot id: another machine (one cloned from the same image)
  echo 00000000-0000-0000-0000-000000000000 >"$R/proc/sys/kernel/random/boot_id"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" != *"is this machine"* ]]
  grep -qx '  HostName qgpu3.example.org' "$H/home/.ssh/config"
  [[ "$(cat "$H/home/.ssh/known_hosts")" == "[qgpu3.example.org]:2222 ssh-ed25519 "* ]]
}

@test "--setup-remote: on this machine the end names the roles' [net:ROLE] host-port line, for the roles [ssh] names it with, unless a host-port line gives the port; a login at one other address is said unreached (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  [ -s /etc/machine-id ]
  remote_host
  this_machine
  local q="$p and as it is on this machine, a strict role reaches it only at 127.0.0.1: agent-sandbox --apply"
  local last="$p after a reboot of qgpu3: agent-sandbox --setup-remote r1"
  PORT=2222 section 'account = tob'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$p for a role to reach it: agent-sandbox --apply '[ssh:ROLE]' r1"$'\n'"$q '[net:ROLE]' 'host-port = 2222'"$'\n'"$last" ]]
  PORT=2222 section 'account = tob' '[ssh:impl-1]' 'r1'
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$q '[net:impl-1]' 'host-port = 2222'"$'\n'"$last" ]]
  # the line it says, applied: then nothing more to say
  apply_remote 'y\n' '[net:impl-1]' 'host-port = 2222'
  [ "$status" -eq 0 ]
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$last" ]]
  PORT=2222 section 'account = tob' '[ssh:impl-1]' 'r1' '[net:impl-*]' 'host-port = 2222'
  setup_remote
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$last" ]]
  PORT=2222 section 'account = tob' '[ssh]' 'r1' '[net]' 'host-port = 8080'
  setup_remote
  [[ "$output" == *"$p set up: ssh r1"$'\n'"$q '[net]' 'host-port = 2222'"$'\n'"$last" ]]
  PORT=192.0.2.7:2222 section 'account = tob'
  setup_remote
  [ "$status" -eq 0 ]
  grep -qx '  HostName 192.0.2.7' "$H/home/.ssh/config"
  [[ "$output" == *"$p a role on this machine does not reach it: it listens at 192.0.2.7 only, and a strict sandbox here has this machine's addresses as its own; port = 2222 or 0.0.0.0:2222 in [remote:r1] is reached over 127.0.0.1"$'\n'"$last" ]]
  [[ "$output" != *"host-port"* ]]
}

@test "--setup-remote: the egress check goes by the proxy's CONNECT: an allowed host's own 403 through the tunnel passes, a refusal at CONNECT or no answer fails; example.com must be refused at CONNECT (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  setup_remote ALLOWED_OUT='403 200'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p check: https://pypi.org/ through the proxy: the proxy opened the tunnel and the host answered HTTP 403: ok"* ]]
  setup_remote ALLOWED_OUT='000 403'
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p check: https://pypi.org/ through the proxy: refused by the proxy at CONNECT (403), where it is allowed: FAILED"* ]]
  setup_remote ALLOWED_OUT='000 000'
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p check: https://pypi.org/ through the proxy: no answer (HTTP 000, the proxy's CONNECT 000): FAILED"* ]]
  # example.com answering 403 itself, through an opened tunnel, is no refusal
  setup_remote EX_OUT='403 200'
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p check: https://example.com/, not allowed, answered '403 200' (code, then the proxy's CONNECT code), where the proxy's refusal at CONNECT (403) is expected: FAILED"* ]]
}

@test "--setup-remote: with no allow line the egress check takes the first host of the account's allowlist.txt; with none there, it says why it is not measured (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  PORT=2222 section 'account = tob'
  mkdir -p "$R/home/tob/.config/agent-sandbox"
  printf '# the starter\n\n.githubusercontent.com\n  github.com  # code\npypi.org\n' >"$R/home/tob/.config/agent-sandbox/allowlist.txt"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p check: https://github.com/ (the first host of tob's allowlist.txt there) through the proxy: the proxy opened the tunnel and the host answered HTTP 200: ok"* ]]
  [[ "$output" == *"$p check: a direct connection to https://github.com/, around the proxy, fails: ok"* ]]
  grep -qx 'try=github.com ex=1' "$H/check.sh"
  rm "$R/home/tob/.config/agent-sandbox/allowlist.txt"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p check: the egress to an allowed host, not measured: neither the section nor tob's allowlist.txt there names a host"* ]]
}

@test "--setup-remote: a new block in a ~/.ssh/config that has another remote's block is said appended, the rest byte for byte, no backup (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  mkdir -p "$H/home/.ssh"
  printf 'Host build\n  HostName build.example.org\n\n# >>> agent-sandbox remote r0 (#344) >>>\nHost r0\n  HostName 127.0.0.1\n# <<< agent-sandbox remote r0 <<<\n' >"$H/home/.ssh/config"
  cp "$H/home/.ssh/config" "$BATS_TEST_TMPDIR/config.orig"
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p the alias r1 in ~/.ssh/config (a marked block, appended)"* ]]
  [ ! -e "$H/home/.ssh/config.before-agent-sandbox" ]
  head -n "$(wc -l <"$BATS_TEST_TMPDIR/config.orig")" "$H/home/.ssh/config" | cmp - "$BATS_TEST_TMPDIR/config.orig"
  grep -qx 'Host r1' "$H/home/.ssh/config"
}

@test "--setup-remote ALIAS --status: over ssh as the account, its own asb --status in the scratch, its answer said and its exit status followed; no preflight, nothing written there or here (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  HOST=qgpu3:2224 full_section
  user_ssh_config
  setup_remote
  [ "$status" -eq 0 ]
  local T="$R/home/tob" f
  rm -f "$H/ssh.argv" "$H/acct.argvs" "$H/login.argv"
  : >"$H/asb.calls"
  mkdir "$BATS_TEST_TMPDIR/before"
  for f in config known_hosts asb-r1 asb-r1.pub; do cp "$H/home/.ssh/$f" "$BATS_TEST_TMPDIR/before/"; done
  cp "$PROJ/.agent-sandbox" "$BATS_TEST_TMPDIR/before/proj.dot"
  cp "$T/bench/.agent-sandbox" "$BATS_TEST_TMPDIR/before/policy"
  setup_remote r1 --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p --status, over ssh as tob to qgpu3 (ssh -p 2224 -l tob qgpu3; BatchMode; never sudo): asb --profile sshd --role r1 --status in ~/bench there"* ]]
  [[ "$output" == *"$p   role 'r1' of $T/bench: running since now (supervisor pid 1)"$'\n'"$p     processes:"* ]]
  [ "$(cat "$H/asb.calls")" = "$T/bench: asb --profile sshd --role r1 --status" ]
  # one session, as the account, batch mode, the host's ssh port; no preflight, no login
  [ "$(wc -l <"$H/acct.argvs")" -eq 1 ]
  grep -qx -- '-l' "$H/acct.argv"
  grep -qx 'BatchMode=yes' "$H/acct.argv"
  [ "$(grep -A1 -x -- -p "$H/acct.argv" | paste -sd' ' -)" = "-p 2224" ]
  [ ! -e "$H/ssh.argv" ]
  [ ! -e "$H/login.argv" ]
  for f in config known_hosts asb-r1 asb-r1.pub; do cmp "$BATS_TEST_TMPDIR/before/$f" "$H/home/.ssh/$f"; done
  cmp "$BATS_TEST_TMPDIR/before/proj.dot" "$PROJ/.agent-sandbox"
  cmp "$BATS_TEST_TMPDIR/before/policy" "$T/bench/.agent-sandbox"
  # its exit status is this one's
  setup_remote ASB_RC=3 r1 --status
  [ "$status" -eq 3 ]
  [[ "$output" == *"$p   role 'r1' of $T/bench: running since now"* ]]
  # not set up there: said, exit 1
  rm "$T/.local/bin/asb"
  setup_remote r1 --status
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p tob has no ~/.local/bin/asb there: not set up (agent-sandbox --setup-remote r1 sets it up)"* ]]
}

@test "--setup-remote ALIAS --shutdown: the account's own asb --shutdown in the scratch; nothing removed there or here; how to start it again; --status then says not running (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  full_section
  user_ssh_config
  setup_remote
  [ "$status" -eq 0 ]
  local T="$R/home/tob" f
  mkdir "$BATS_TEST_TMPDIR/before"
  for f in config known_hosts asb-r1 asb-r1.pub; do cp "$H/home/.ssh/$f" "$BATS_TEST_TMPDIR/before/"; done
  cp "$PROJ/.agent-sandbox" "$BATS_TEST_TMPDIR/before/proj.dot"
  : >"$H/asb.calls"
  setup_remote r1 --shutdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p   agent-sandbox: role 'r1': ended, with everything that ran in it"$'\n'"$p the login is not running there now; nothing was removed, there or here: to start it again, agent-sandbox --setup-remote r1" ]]
  [ "$(cat "$H/asb.calls")" = "$T/bench: asb --profile sshd --role r1 --shutdown" ]
  [ ! -e "$T/.running-r1" ]
  # nothing removed: the policy, the keys file, the store, the install there; the files here
  [ -f "$T/bench/.agent-sandbox" ]
  [ -f "$T/.config/agent-sandbox/asb-r1-keys" ]
  [ -d "$T/.local/state/agent-sandbox/sshd/${T//[^A-Za-z0-9-]/-}-bench/r1" ]
  [ -x "$T/.local/bin/asb" ]
  for f in config known_hosts asb-r1 asb-r1.pub; do cmp "$BATS_TEST_TMPDIR/before/$f" "$H/home/.ssh/$f"; done
  cmp "$BATS_TEST_TMPDIR/before/proj.dot" "$PROJ/.agent-sandbox"
  setup_remote r1 --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p   role 'r1' of $T/bench: not running" ]]
  # a failing --shutdown there is this one's failure, and no restart line
  setup_remote ASB_RC=1 r1 --shutdown
  [ "$status" -eq 1 ]
  [[ "$output" != *"to start it again"* ]]
  # and --setup-remote r1 starts it again
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" == *"$p the login is not running (a reboot of qgpu3?): launching it"* ]]
}

@test "--setup-remote --status/--shutdown: refused for a destination, with --port, in a sandbox, and while the file is not approved, before any ssh; an unreachable account is said (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  section 'account = tob'
  setup_remote tob@qgpu3 --status
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote tob@qgpu3 --status: --status acts on a [remote:ALIAS] section of .agent-sandbox (it has: r1), and 'tob@qgpu3' is not one: --setup-remote ALIAS --status"* ]]
  setup_remote r1 --shutdown --port 2222
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote ALIAS [--status | --shutdown]"* ]]
  setup_remote AGENT_SANDBOX=1 r1 --shutdown
  [ "$status" -eq 2 ]
  [[ "$output" == *"--setup-remote runs on the host"* ]]
  NOAPPROVE=1 section 'account = tob' 'allow = pypi.org'
  setup_remote r1 --status
  [ "$status" -eq 2 ]
  [[ "$output" == *"review it first (agent-sandbox --trust)"* ]]
  [ ! -e "$H/ssh.argv" ]
  [ ! -e "$H/acct.argv" ]
  section 'account = tob'
  setup_remote ACCT_FAIL=1 r1 --status
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p cannot ask as tob (ssh exit 255): tob@qgpu3: Permission denied (publickey)."* ]]
  [[ "$output" == *"$p it needs ssh -l tob qgpu3 to work without a question: your public key in tob's ~/.ssh/authorized_keys"* ]]
  [ ! -e "$H/ssh.argv" ]
  # no account line: your ssh login name for the host, ssh -G read to its end (SSH_G_MORE)
  section
  setup_remote SSH_G_MORE=1 ACCT_FAIL=1 r1 --status
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p cannot ask as tester (ssh exit 255)"* ]]
  setup_remote SSH_G_FAIL=1 r1 --status
  [ "$status" -eq 1 ]
  [[ "$output" == *"$p cannot resolve 'qgpu3' (ssh -G failed, exit 255): $H/home/.ssh/config line 3: Bad configuration option: bogus"* ]]
  [[ "$output" != *"over ssh as"* ]]
}

@test "--setup-remote: env TMPDIR under the scratch ('~' the account's home, or absolute) is made there, said once, before the login's line; the last TMPDIR line is the one; outside the scratch, through '..', or another variable: not made, nothing said (#344)" {
  require_host "asb --setup-remote is the host's; the engine refuses it inside a sandbox"
  remote_host
  local T="$R/home/tob"
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'env = TMPDIR=~/bench/tmp/x/'
  setup_remote
  [ "$status" -eq 0 ]
  [ -d "$T/bench/tmp/x" ]
  [[ "$output" == *"$p made TMPDIR $T/bench/tmp/x there, under the scratch (the section's env)"* ]]
  # said before the login's line
  [[ "$output" == *"made TMPDIR"*"the login is running there"* ]]
  setup_remote
  [ "$status" -eq 0 ]
  [[ "$output" != *"made TMPDIR"* ]]
  PORT=2222 section 'account = tob' 'scratch = ~/bench' "env = TMPDIR=$T/bench/t2"
  setup_remote
  [ "$status" -eq 0 ]
  [ -d "$T/bench/t2" ]
  # the last TMPDIR line is the one
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'env = TMPDIR=~/bench/t3' 'env = TMPDIR=~/out'
  setup_remote
  [ "$status" -eq 0 ]
  [ ! -e "$T/bench/t3" ]
  [ ! -e "$T/out" ]
  # outside the scratch, through '..', a sibling, or another variable: not made, nothing said
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'env = TMPDIR=~/other/tmp' 'env = XDG_CACHE_HOME=~/bench/cache'
  setup_remote
  [ "$status" -eq 0 ]
  [ ! -e "$T/other" ]
  [ ! -e "$T/bench/cache" ]
  [[ "$output" != *"made TMPDIR"* ]]
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'env = TMPDIR=~/bench/../escape'
  setup_remote
  [ "$status" -eq 0 ]
  [ ! -e "$T/escape" ]
  [[ "$output" != *"made TMPDIR"* ]]
  PORT=2222 section 'account = tob' 'scratch = ~/bench' 'env = TMPDIR=~/bench2/tmp'
  setup_remote
  [ "$status" -eq 0 ]
  [ ! -e "$T/bench2" ]
}
