#!/usr/bin/env bats
# The sshd profile (#335) and the engine declarations it brought: the generated sshd
# configuration, its refusals, the group file and the read-only binds, a project's
# [env] NAME = VALUE, the [sshd] review lines, the proxy of its own and the session base
# under the role's store. The stub bwrap and pasta of the unit harness; a stub sshd and
# ssh-keygen (a host without openssh-server runs these too), and a stub mitmdump that
# records how it was started and listens where it was told.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  # pasta, ip and nft as tests/unit/strict.bats has them: pasta runs its wrapper, which
  # reads the gateway from `ip` and loads the rule with a stub nft.
  cat >"$H/bin/pasta" <<'S'
#!/usr/bin/env bash
set +x
if [ -n "${PASTA_DUMP:-}" ]; then
  : >"$PASTA_DUMP"
  for a in "$@"; do printf '%s\n' "$a" >>"$PASTA_DUMP"; done
fi
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
S
  cat >"$H/bin/ip" <<'S'
#!/usr/bin/env bash
set +x
[ "$1 $2 $3 $4" = "-4 route show default" ] && echo "default via 10.9.9.1 dev eth0"
exit 0
S
  printf '#!/usr/bin/env bash\nexit 0\n' >"$H/bin/nft"
  # sshd: `-t -f CFG` checks a configuration; the stub accepts it (the real one is
  # asked below, where there is one).
  # shellcheck disable=SC2016 # the stub's own $1
  printf '#!/usr/bin/env bash\nset +x\n[ "$1" = -t ] && exit 0\nexit 1\n' >"$H/bin/sshd"
  # ssh-keygen: writes the two files of a key pair, the private one a fresh random line.
  cat >"$H/bin/ssh-keygen" <<'S'
#!/usr/bin/env bash
set +x
f=""
while [ "$#" -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$f"
echo "ssh-ed25519 AAAA test" >"$f.pub"
S
  # mitmdump: the engine starts it with no environment but HOME, USER, PATH, the session
  # base and PYTHONUNBUFFERED, so the stub reads its mode from a file beside it: listen
  # (default), `exit` (fails at once), `sleep` (never listens). It writes its argv and
  # environment beside itself.
  cat >"$H/bin/fake-mitmdump" <<'S'
#!/usr/bin/env bash
set +x
d="${0%/*}"
printf '%s\n' "$@" >"$d/../mitm.argv"
env >"$d/../mitm.env"
mode="$(cat "$d/mitm.mode" 2>/dev/null || echo listen)"
port=""
while [ "$#" -gt 0 ]; do [ "$1" = --listen-port ] && port="$2"; shift; done
case "$mode" in
  exit) echo "fake-mitmdump: failing" >&2; exit 1 ;;
  sleep) exec sleep 60 ;;
esac
exec python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept(); c.close()
' "$port"
S
  chmod +x "$H/bin/pasta" "$H/bin/nft" "$H/bin/ip" "$H/bin/sshd" "$H/bin/ssh-keygen" "$H/bin/fake-mitmdump"
  make_fake_ca "$H/ca.pem"
  mkdir -p "$H/home/.config/agent-sandbox"
  : >"$H/home/.config/agent-sandbox/allowlist_addon.py"
  PROJ="$(cd "$H/proj" && pwd -P)"
  printf 'ssh-ed25519 AAAAkey1 someone@there\n' >"$H/keys"
  PORT="$(free_port)"
}

teardown() {
  [[ -n "${LISTENER:-}" ]] && kill "$LISTENER" 2>/dev/null
  true
}

# A TCP port nothing listens on now.
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Record approval of the project's .agent-sandbox the way --trust would.
trust() {
  local t="$H/home/.config/agent-sandbox/trust"
  mkdir -p "$t"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 >"$t/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

# policy [EXTRA LINES...] -- a trusted .agent-sandbox for the profile: strict, the keys
# file outside the project, and the lines given (printf %b).
policy() {
  printf '[net]\nmode = strict\n\n[sshd]\nauthorized-keys = %s\n' "$H/keys" >"$PROJ/.agent-sandbox"
  local l
  for l in "$@"; do printf '%b\n' "$l" >>"$PROJ/.agent-sandbox"; done
  trust
}

# The role's store and its sshd directory.
role_dir() {
  local slug
  slug="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9-]/-/g')"
  printf '%s/home/.local/state/agent-sandbox/sshd/%s/%s' "$H" "$slug" "${1:-default}"
}

# sshd_launch [VAR=value ...] -- [ENGINE FLAGS] -- the profile's launch, through the stub
# mitmdump, with the session base the engine picks (the harness's is cleared).
sshd_launch() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  run_engine PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_PROXY_CA="$H/ca.pem" AGENT_SANDBOX_MITMDUMP="$H/bin/fake-mitmdump" \
    AGENT_SANDBOX_PROXY_PORT="$PORT" AGENT_SANDBOX_SESSION_BASE= ${envs[@]+"${envs[@]}"} -- asb --profile sshd "$@"
}

@test "sshd: the generated configuration, line by line; Port from --agent-port, ListenAddress 0.0.0.0; the keys copied; the group file without tty; bound read-only" {
  policy
  sshd_launch -- --agent-port 40123
  [ "$status" -eq 0 ]
  local d cfg
  d="$(role_dir)/sshd"
  cfg="$d/sshd_config"
  [ -f "$cfg" ]
  grep -v '^#' "$cfg" >"$H/cfg.lines"
  local sftp=internal-sftp c
  for c in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server \
    /usr/libexec/ssh/sftp-server /usr/libexec/sftp-server /usr/lib/sftp-server; do
    [[ -x "$c" ]] && sftp="$c" && break
  done
  cat >"$H/cfg.want" <<EOF
Port 40123
ListenAddress 0.0.0.0
HostKey "$d/ssh_host_ed25519_key"
AuthorizedKeysFile "$d/authorized_keys"
PidFile none
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitUserEnvironment no
PermitUserRC no
DisableForwarding yes
PermitTunnel no
StrictModes no
Subsystem sftp $sftp
LogLevel VERBOSE
EOF
  diff "$H/cfg.want" "$H/cfg.lines"
  # the keys are a copy, taken at launch, only the owner's to read
  cmp -s "$H/keys" "$d/authorized_keys"
  [ "$(stat -c %a "$d/authorized_keys")" = 600 ]
  [ -s "$d/ssh_host_ed25519_key" ]
  # /etc/group without the tty line, everything else as it is
  run ! grep -q '^tty:' "$d/group"
  diff <(grep -v '^tty:' /etc/group) "$d/group"
  # the declaration's binds, after /etc and $HOME, and the agent's two variables
  argv_has --ro-bind "$d" "$d"
  argv_has --ro-bind "$d/group" /etc/group
  local etc grp
  etc="$(argv_index /etc)" grp="$(argv_index "$d/group")"
  ((etc < grp))
  [ "$(setenv_value AGENT_SANDBOX_SSHD_CONFIG)" = "$cfg" ]
  [ "$(setenv_value AGENT_SANDBOX_SSHD)" = "$H/bin/sshd" ]
  # the agent is the profile's sshd-agent.sh, by its path
  [ "${JOINV[0]}" = "$(readlink -f -- "$(dirname -- "$ENGINE")/profiles/sshd/sshd-agent.sh")" ]
  [ "${#JOINV[@]}" -eq 1 ]
}

@test "sshd: Port from AGENT_SANDBOX_AGENT_PORTS and from [net] agent-port, ListenAddress 0.0.0.0 whatever the token's address; the host key is kept across launches" {
  policy
  sshd_launch AGENT_SANDBOX_AGENT_PORTS=0.0.0.0:40124 --
  [ "$status" -eq 0 ]
  local cfg
  cfg="$(role_dir)/sshd/sshd_config"
  grep -qx 'Port 40124' "$cfg"
  grep -qx 'ListenAddress 0.0.0.0' "$cfg"
  local key1
  key1="$(cat "$(role_dir)/sshd/ssh_host_ed25519_key")"
  printf '[net]\nmode = strict\nagent-port = 192.168.7.7:40125\n\n[sshd]\nauthorized-keys = %s\n' "$H/keys" >"$PROJ/.agent-sandbox"
  trust
  sshd_launch --
  [ "$status" -eq 0 ]
  grep -qx 'Port 40125' "$cfg"
  grep -qx 'ListenAddress 0.0.0.0' "$cfg" # not the token's 192.168.7.7
  [ "$(cat "$(role_dir)/sshd/ssh_host_ed25519_key")" = "$key1" ]
}

@test "sshd: refused without an agent port, with two, outside strict, and without a usable [sshd] authorized-keys" {
  policy
  sshd_launch --
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile sshd needs exactly one agent port, the one sshd listens on (--agent-port [ADDR:]PORT, AGENT_SANDBOX_AGENT_PORTS or [net] agent-port); this launch has 0. Refusing to launch"* ]]
  sshd_launch -- --agent-port 40123 --agent-port 40124
  [ "$status" -ne 0 ]
  [[ "$output" == *"this launch has 2: 40123 40124. Refusing to launch"* ]]
  sshd_launch AGENT_SANDBOX_AGENT_PORTS=none -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"this launch has 0"* ]]
  printf '[sshd]\nauthorized-keys = %s\n' "$H/keys" >"$PROJ/.agent-sandbox"
  trust
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile sshd needs the strict network mode ([net] mode = strict, or AGENT_SANDBOX_NET=strict)"* ]]
  printf '[net]\nmode = strict\n' >"$PROJ/.agent-sandbox"
  trust
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile sshd needs [sshd] authorized-keys = PATH in this project's .agent-sandbox"* ]]
  printf '[net]\nmode = strict\n[sshd]\nauthorized-keys = keys\n' >"$PROJ/.agent-sandbox"
  trust
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"[sshd] authorized-keys = keys is a relative path"* ]]
  printf '[net]\nmode = strict\n[sshd]\nauthorized-keys = %s\n' "$H/no-such-keys" >"$PROJ/.agent-sandbox"
  trust
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"[sshd] authorized-keys = $H/no-such-keys is not a readable file"* ]]
  policy
  chmod 000 "$H/keys"
  if [[ ! -r "$H/keys" ]]; then # (root reads it anyway)
    sshd_launch -- --agent-port 40123
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a readable file"* ]]
  fi
  chmod 600 "$H/keys"
  # nothing was started for any of them
  [ ! -e "$H/mitm.argv" ]
}

@test "sshd: a command or arguments are refused; a running role refuses a second launch, naming --shutdown" {
  policy
  sshd_launch -- --agent-port 40123 /usr/sbin/sshd
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile sshd runs sshd itself, with no command and no arguments"* ]]
  engine_bg PASTA_DUMP="$H/pasta_argv" AGENT_SANDBOX_PROXY_CA="$H/ca.pem" AGENT_SANDBOX_MITMDUMP="$H/bin/fake-mitmdump" \
    AGENT_SANDBOX_PROXY_PORT="$PORT" -- asb --profile sshd --agent-port 40123
  run_engine AGENT_SANDBOX_PROXY_CA="$H/ca.pem" AGENT_SANDBOX_MITMDUMP="$H/bin/fake-mitmdump" \
    AGENT_SANDBOX_PROXY_PORT="$PORT" -- asb --profile sshd --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'default' is running already, its sshd with it, and a second sshd cannot listen on its port. End it first: asb --profile sshd --role default --shutdown"* ]]
  [ ! -s "$H/join" ] # nothing was joined
  # --status names the proxy of its own
  run_engine AGENT_SANDBOX_PROXY_PORT="$PORT" -- asb --profile sshd --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy: its own, at 127.0.0.1:$PORT"* ]]
  release_bg
}

@test "sshd: a proxy of its own on the account's port when it is free: the unit's options, the installed addon, the role's session base; the strict chain and the proxy URL use it" {
  policy
  sshd_launch -- --agent-port 40123
  [ "$status" -eq 0 ]
  [[ "$output" == *"sshd: proxy of its own at 127.0.0.1:$PORT"* ]]
  [[ "$output" != *"is in use"* ]]
  mapfile -t M <"$H/mitm.argv"
  [ "${M[*]}" = "--listen-host 127.0.0.1 --listen-port $PORT --set block_global=false --set termlog_verbosity=info --set flow_detail=0 --set http2=false -s $H/home/.config/agent-sandbox/allowlist_addon.py" ]
  grep -qx "AGENT_SANDBOX_SESSION_BASE=$(role_dir)/sessions" "$H/mitm.env"
  grep -qx "HOME=$H/home" "$H/mitm.env"
  run ! grep -q '^BWRAP_DUMP=' "$H/mitm.env" # nothing else of the launching shell's
  grep -A1 -x HTTPS_PROXY "$H/argv" | tail -1 | grep -qE "^http://[0-9a-f]{32}:x@10\.9\.9\.1:$PORT\$"
  grep -qx -- "$PORT" "$H/pasta_argv" # the wrapper's port argument, which the nft rule takes
  # its log is the keeper's, and it ended with the keeper
  grep -q "proxy of its own: $H/bin/fake-mitmdump on 127.0.0.1:$PORT" "$(role_dir)/keeper.log"
  local i
  for ((i = 0; i < 100; i++)); do
    _listening "$PORT" || break
    sleep 0.05
  done
  run ! _listening "$PORT"
}

_listening() { (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

@test "sshd: the account's port in use -- the proxy of its own takes the next free one, and the launch line says why" {
  policy
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$PORT" &
  LISTENER=$!
  local i
  for ((i = 0; i < 100; i++)); do
    _listening "$PORT" && break
    sleep 0.05
  done
  sshd_launch -- --agent-port 40123
  [ "$status" -eq 0 ]
  local got
  got="$(sed -n '/^--listen-port$/{n;p}' "$H/mitm.argv")"
  [ "$got" -gt "$PORT" ]
  [[ "$output" == *"sshd: proxy of its own at 127.0.0.1:$got (the account's port, $PORT, is in use)"* ]]
  grep -A1 -x HTTPS_PROXY "$H/argv" | tail -1 | grep -qE ":$got\$"
}

@test "sshd: a proxy of its own that does not come up refuses the launch, naming the keeper's log" {
  policy
  echo exit >"$H/bin/mitm.mode"
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'default': its proxy of its own did not come up on 127.0.0.1:$PORT; refusing to launch. Its output is in $(role_dir)/keeper.log"* ]]
  grep -q 'fake-mitmdump: failing' "$(role_dir)/keeper.log"
  [ ! -s "$H/join" ]
  # one that runs and never listens: refused once the wait is over
  echo sleep >"$H/bin/mitm.mode"
  sshd_launch -- --agent-port 40123
  [ "$status" -ne 0 ]
  [[ "$output" == *"its proxy of its own did not come up on 127.0.0.1:$PORT"* ]]
  run ! pgrep -f "^sleep 60\$"
}

@test "sshd: the session base is the role's store; an explicit AGENT_SANDBOX_SESSION_BASE still wins; claude keeps the runtime one" {
  policy
  sshd_launch -- --agent-port 40123
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(role_dir)/sessions/ca-bundle.crt" /etc/ssl/certs/ca-certificates.crt
  sshd_launch AGENT_SANDBOX_SESSION_BASE="$H/base" -- --agent-port 40123
  [ "$status" -eq 0 ]
  grep -qx "AGENT_SANDBOX_SESSION_BASE=$H/base" "$H/mitm.env"
  argv_has --ro-bind "$H/base/ca-bundle.crt" /etc/ssl/certs/ca-certificates.crt
  # claude is not self-contained: no proxy of its own, the session base as before
  rm -f "$H/mitm.argv"
  mkdir -p "$H/run"
  run_engine AGENT_SANDBOX_NET=strict AGENT_SANDBOX_PROXY_CA="$H/ca.pem" AGENT_SANDBOX_MITMDUMP="$H/bin/fake-mitmdump" \
    AGENT_SANDBOX_SESSION_BASE= XDG_RUNTIME_DIR="$H/run" -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$H/mitm.argv" ]
  argv_has --ro-bind "$H/run/agent-sandbox.$(id -u)/ca-bundle.crt" /etc/ssl/certs/ca-certificates.crt
}

@test "sshd: a project's [env] NAME = VALUE is set under the profile, per role, never over the profile's own pins; under claude it is still dropped" {
  policy '[env]\nTMPDIR = ~/scratch-tmp\nAGENT_SANDBOX_SSHD_CONFIG = /elsewhere\nHOME = /x\n[env:probe]\nCACHE = for-probe\n[env:other]\nCACHE = for-other'
  sshd_launch -- --role probe --agent-port 40123
  [ "$status" -eq 0 ]
  [ "$(setenv_value TMPDIR)" = "$H/home/scratch-tmp" ]
  [ "$(setenv_value CACHE)" = for-probe ]
  [[ "$output" == *"not setting AGENT_SANDBOX_SSHD_CONFIG from .agent-sandbox [env]: profile 'sshd' or the engine sets it inside the sandbox"* ]]
  [[ "$output" == *"not setting HOME from .agent-sandbox [env]"* ]]
  [ "$(setenv_value AGENT_SANDBOX_SSHD_CONFIG)" = "$(role_dir probe)/sshd/sshd_config" ]
  [ "$(grep -c -x -- --setenv "$H/argv")" -gt 0 ]
  [ "$(awk 'p { print; p = 0 } $0 == "--setenv" { getline n; if (n == "HOME") p = 1 }' "$H/argv" | sort -u)" = "$H/home" ]
  # claude: a project's file only forwards
  run_engine AGENT_SANDBOX_PROXY_CA="$H/ca.pem" -- asb --role probe claude --version
  [ "$status" -eq 0 ]
  run ! setenv_value TMPDIR
  run ! setenv_value CACHE
}

@test "sshd: the review says what a project's [env] NAME = VALUE sets, for which roles and under which profiles; and of [sshd] authorized-keys" {
  printf '[env]\nTMPDIR = /p/tmp\n[env:probe]\nCACHE = /p/c\n[sshd]\nauthorized-keys = %s\nport = 22\n' "$H/keys" >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [env] TMPDIR = /p/tmp: sets TMPDIR inside, for every role, under the profile sshd; ignored under claude, where a project's file only forwards"* ]]
  [[ "$output" == *".agent-sandbox: [env:probe] CACHE = /p/c: sets CACHE inside, for the roles probe, under the profile sshd; ignored under claude"* ]]
  [[ "$output" != *"setting a variable is a profile's. Ignoring"* ]]
  [[ "$output" == *".agent-sandbox: [sshd] authorized-keys = $H/keys: whoever holds a key listed there logs in to this project's sshd roles, in their sandbox; the file is copied at each launch"* ]]
  [[ "$output" == *".agent-sandbox: [sshd] key 'port' is not one this profile reads; ignoring"* ]]
  [[ "$output" != *"inside the project directory"* ]]
  printf '[sshd]\nauthorized-keys = %s/keys\n' "$PROJ" >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: warning -- [sshd] authorized-keys = $PROJ/keys is inside the project directory, which every session can write: a session could add a key that the next launch lets in. Keep it outside the project"* ]]
  printf '[sshd]\nauthorized-keys = keys\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [sshd] authorized-keys = keys: a relative path; a launch refuses it (an absolute path, or under ~)"* ]]
}

@test "sshd: never the default profile -- a verb with no command still acts on claude, the only other one" {
  run_engine -- asb --status
  [ "$status" -eq 0 ]
  [[ "$output" != *"there are several"* ]]
  run_engine -- asb --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"there are several"* ]]
}

@test "sshd: the real sshd accepts the generated configuration and the agent's SetEnv line, quoting included" {
  local real=""
  for real in /usr/sbin/sshd /sbin/sshd; do [[ -x "$real" ]] && break; done
  [[ -x "$real" ]] || skip "no sshd on this host"
  command -v ssh-keygen >/dev/null || skip "no ssh-keygen on this host"
  rm -f "$H/bin/sshd" "$H/bin/ssh-keygen"
  ln -s "$real" "$H/bin/sshd"
  policy
  sshd_launch -- --agent-port 40123
  [ "$status" -eq 0 ]
  local cfg
  cfg="$(role_dir)/sshd/sshd_config"
  # What sshd-agent.sh writes inside, from an environment with awkward values.
  mkdir -p "$H/inside"
  # shellcheck disable=SC2016 # literal values, and the inner shell's own $1 and $2
  env -i AGENT_SANDBOX_SSHD="$real" AGENT_SANDBOX_SSHD_CONFIG="$cfg" HOME=/h USER=u TERM=t SSH_X=1 \
    "A=one two" 'B=x"y' 'C=back\slash' 'D=#hash' "E=it's" 'F=$HOME' "G=" "NL=a
b" PATH=/usr/bin:/bin bash -c '
      sed -e "s|exec \"\$sshd\" -D -e -f|cp -- \"\$dir/sshd_config\" \"$1/cfg\"; exit 0; :|" "$2" >"$1/agent"
      bash "$1/agent"' _ "$H/inside" "$(dirname -- "$ENGINE")/profiles/sshd/sshd-agent.sh" 2>"$H/inside/err"
  grep -q 'not passed to sessions, a value with a line break that sshd_config cannot hold: NL' "$H/inside/err"
  run "$real" -T -f "$H/inside/cfg"
  [ "$status" -eq 0 ]
  local want
  # shellcheck disable=SC2016 # literal values
  for want in "setenv A=one two" 'setenv B=x"y' 'setenv C=back\slash' 'setenv D=#hash' "setenv E=it's" 'setenv F=$HOME' "setenv G=" \
    "setenv PATH=/usr/bin:/bin" "port 40123" "listenaddress 0.0.0.0:40123" "permituserenvironment no" "disableforwarding yes"; do
    printf '%s\n' "$output" | grep -qixF -- "$want" || {
      echo "missing: $want"
      false
    }
  done
  # what sshd sets per session itself, and the agent's own, are not passed
  run ! grep -qE '"(HOME|USER|TERM|SSH_X|AGENT_SANDBOX_SSHD|AGENT_SANDBOX_SSHD_CONFIG)=' "$H/inside/cfg"
}
