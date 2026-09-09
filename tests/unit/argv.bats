#!/usr/bin/env bats
# The bwrap argv the engine produces is the contract. These tests pin its
# structure per configuration (binds, order, environment, network mode).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  BIN="$H/home/.local/share/claude/versions/2.1.300/claude"
}

@test "default (proxy): system read-only, fresh pseudo-filesystems, HOME tmpfs remounted ro after its binds, clearenv, profile state rw, CWD rw, proxy env, CA env" {
  run_engine LEAKED=secret -- claude --version --foo bar
  [ "$status" -eq 0 ]
  argv_has --ro-bind /usr /usr
  argv_has --ro-bind-try /etc /etc
  argv_has --proc /proc
  argv_has --dev /dev
  argv_has --tmpfs /tmp
  argv_has --tmpfs /run
  argv_has --tmpfs "$H/home"
  argv_has --tmpfs "$H/home/.cache"
  argv_has --unshare-all
  argv_has --die-with-parent
  argv_has --new-session
  argv_has --clearenv
  argv_has --bind "$H/home/.claude" "$H/home/.claude"
  argv_has --bind "$H/home/.claude.json" "$H/home/.claude.json"
  argv_has --ro-bind "$BIN" "$BIN"
  argv_has --bind "$H/proj" "$H/proj"
  argv_has --chdir "$H/proj"
  argv_has --remount-ro "$H/home"
  argv_has --share-net
  [ "$(setenv_value HTTPS_PROXY)" = "http://127.0.0.1:8888" ]
  [ "$(setenv_value HTTP_PROXY)" = "http://127.0.0.1:8888" ]
  [ "$(setenv_value NO_PROXY)" = "" ]
  [ "$(setenv_value DISABLE_AUTOUPDATER)" = "1" ]
  [ "$(setenv_value HOME)" = "$H/home" ]
  [ "$(setenv_value USER)" = "tester" ]
  [ "$(setenv_value SSL_CERT_FILE)" = "/etc/ssl/certs/ca-certificates.crt" ]
  [ "$(setenv_value CONDA_SSL_VERIFY)" = "/etc/ssl/certs/ca-certificates.crt" ]
  ! setenv_value LEAKED
  # HOME's binds come before the final remount-ro; the HOME tmpfs before them
  [ "$(argv_index --remount-ro)" -gt "$(argv_index "$H/home/.claude")" ]
  [ "$(argv_index "$H/home/.claude")" -gt "$(argv_index --tmpfs)" ]
  # the command line ends with the agent and its untouched arguments
  local n=${#ARGV[@]}
  [ "${ARGV[n - 5]}" = "--" ]
  [ "${ARGV[n - 4]}" = "$BIN" ]
  [ "${ARGV[n - 3]}" = "--version" ]
  [ "${ARGV[n - 2]}" = "--foo" ]
  [ "${ARGV[n - 1]}" = "bar" ]
}

@test "none: no network at all; open: host network without proxy; neither sets proxy or CA variables" {
  run_engine AGENT_SANDBOX_NET=none -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --share-net
  ! setenv_value HTTPS_PROXY
  ! setenv_value SSL_CERT_FILE
  ! argv_has --ro-bind "$H/base/ca-bundle.crt"
  run_engine AGENT_SANDBOX_NET=open -- claude --version
  [ "$status" -eq 0 ]
  argv_has --share-net
  ! setenv_value HTTPS_PROXY
  ! setenv_value SSL_CERT_FILE
}

@test "environment allowlist: locale, profile, proxy/CA and CUDA names are forwarded only when set; PASSENV adds names; caller-set CA variables win" {
  run_engine LANG=C.UTF-8 TZ=UTC ANTHROPIC_API_KEY=k CUDA_HOME=/usr/local/cuda AWS_SECRET_ACCESS_KEY=x GH_TOKEN=y -- claude --version
  [ "$(setenv_value LANG)" = "C.UTF-8" ]
  [ "$(setenv_value TZ)" = "UTC" ]
  [ "$(setenv_value ANTHROPIC_API_KEY)" = "k" ]
  [ "$(setenv_value CUDA_HOME)" = "/usr/local/cuda" ]
  ! setenv_value AWS_SECRET_ACCESS_KEY
  ! setenv_value GH_TOKEN
  ! setenv_value TERM_PROGRAM
  run_engine AGENT_SANDBOX_PASSENV="GH_TOKEN FOO:BAR" GH_TOKEN=y FOO="two words" -- claude --version
  [ "$(setenv_value GH_TOKEN)" = "y" ]
  [ "$(setenv_value FOO)" = "two words" ]
  ! setenv_value BAR
  run_engine PIP_CERT=/my/ca SSL_CERT_FILE=/my/bundle -- claude --version
  [ "$(setenv_value PIP_CERT)" = "/my/ca" ]
  [ "$(setenv_value SSL_CERT_FILE)" = "/my/bundle" ]
  [ "$(setenv_value CONDA_SSL_VERIFY)" = "/my/bundle" ]
  [ "$(grep -c '^PIP_CERT$' "$H/argv")" -eq 1 ]
}

@test "RO and RW knobs bind the listed paths; a missing path is skipped with a warning" {
  mkdir -p "$H/ro1" "$H/rw1"
  run_engine AGENT_SANDBOX_RO="$H/ro1:$H/nope" AGENT_SANDBOX_RW="$H/rw1" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/ro1" "$H/ro1"
  argv_has --bind "$H/rw1" "$H/rw1"
  ! argv_has "$H/nope"
  [[ "$output" == *"skipping missing path"* ]]
}

@test "conda: base bound read-only before the env; env read-only by default; write mode makes only the env rw, adds the sandbox package cache, CONDA_PKGS_DIRS, tmpfs ~/.conda and read-only rc files" {
  local base="$H/conda" env="$H/conda/envs/myenv"
  mkdir -p "$env" "$base/pkgs" "$base/condabin" "$H/pkgs"
  : >"$H/home/.condarc"
  local -a cenv=(CONDA_PREFIX="$env" CONDA_DEFAULT_ENV=myenv CONDA_SHLVL=1)
  run_engine "${cenv[@]}" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$base" "$base"
  argv_has --ro-bind "$env" "$env"
  ! argv_has --bind "$env" "$env"
  [ "$(argv_index "$base")" -lt "$(argv_index "$env")" ]
  argv_has --tmpfs "$H/home/.conda"
  argv_has --ro-bind "$H/home/.condarc" "$H/home/.condarc"
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = "myenv" ]
  ! setenv_value CONDA_PKGS_DIRS
  run_engine "${cenv[@]}" AGENT_SANDBOX_CONDA_WRITE=1 AGENT_SANDBOX_CONDA_PKGS="$H/pkgs" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$base" "$base"
  argv_has --bind "$env" "$env"
  argv_has --bind "$H/pkgs" "$H/pkgs"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$H/pkgs,$base/pkgs" ]
  [ "$(argv_index --ro-bind)" -lt "$(argv_index "$env")" ]
}

@test "CWD: \$HOME itself is not bound; /, a parent of \$HOME, and secret stores are refused" {
  RUN_CWD="$H/home" run_engine -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --bind "$H/home" "$H/home"
  [[ "$output" == *"CWD is \$HOME"* ]]
  RUN_CWD=/ run_engine -- claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
  RUN_CWD="$(dirname "$H/home")" run_engine -- claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"contains \$HOME"* ]]
  mkdir -p "$H/home/.ssh" "$H/home/.config/agent-sandbox"
  RUN_CWD="$H/home/.ssh" run_engine -- claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it is the secret store"* ]] && [ ! -s "$H/argv" ]
  RUN_CWD="$H/home/.config/agent-sandbox" run_engine -- claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it is the sandbox's own control plane"* ]]
  RUN_CWD="$H/home/.config" run_engine -- claude --version # contains the trust store
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it contains"* ]] && [ ! -s "$H/argv" ]
}

@test "RW into a secret store or a parent of HOME is refused before bwrap runs" {
  mkdir -p "$H/home/.aws"
  run_engine AGENT_SANDBOX_RW="$H/home/.aws" -- claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
  run_engine AGENT_SANDBOX_RO="$H/home/.aws" -- claude --version
  [ "$status" -eq 1 ]
  run_engine AGENT_SANDBOX_RW="$(dirname "$H/home")" -- claude --version
  [ "$status" -eq 1 ]
}

@test "--allow writes the session file with a header and the hosts, and the session dir is removed after bwrap exits" {
  # a probing stub: snapshot the session base while "inside"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"; for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/*; do printf '== %s\n' "$f"; cat "$f"; done >"${BWRAP_PROBE:?}" 2>&1
exit 0
STUB
  run_engine BWRAP_PROBE="$H/probe" -- claude --allow pypi.org --allow=.example.org --version
  [ "$status" -eq 0 ]
  grep -q '^== .*/allow.txt$' "$H/probe"
  grep -q '^pypi.org$' "$H/probe"
  grep -q '^\.example\.org$' "$H/probe"
  grep -q '^== .*/owner.id$' "$H/probe"
  # owner.id: two fields, the pid's real start time
  local pid start
  read -r pid start < <(sed -n '/owner.id$/{n;p}' "$H/probe")
  [ -n "$pid" ] && [ -n "$start" ] && [ "$start" != 0 ]
  ! argv_has allow.txt
  # a per-session proxy token is minted and carried in the proxy URL as userinfo,
  # so the addon can scope --allow to this session (issue #5). The userinfo is
  # TOKEN:x, not TOKEN: an empty proxy password hangs Node's HTTP stack, so the
  # agent could not reach the API when --allow was set; the addon reads the token
  # from the username and ignores the password.
  grep -q '^== .*/proxy.token$' "$H/probe"
  local tok
  tok=$(sed -n '/proxy.token$/{n;p}' "$H/probe")
  [ -n "$tok" ]
  [ "$(setenv_value HTTPS_PROXY)" = "http://$tok:x@127.0.0.1:8888" ]
  [ "$(setenv_value HTTP_PROXY)" = "http://$tok:x@127.0.0.1:8888" ]
  [ -z "$(ls -A "$H/base")" ]
  [[ "$output" == *"session allowlist: pypi.org .example.org"* ]]
}
