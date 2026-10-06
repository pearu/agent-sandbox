#!/usr/bin/env bats
# The bwrap argv the engine produces is the contract. These tests pin its
# structure per configuration (binds, order, environment, network mode).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  BIN="$H/home/.local/share/claude/versions/2.1.300/claude"
}

@test "default (proxy): system read-only, fresh pseudo-filesystems, HOME tmpfs remounted ro after its binds, clearenv, profile state rw, CWD rw, proxy env, CA env" {
  run_engine LEAKED=secret -- asb claude --version --foo bar
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
  argv_has --cap-drop ALL # capabilities dropped (matters in strict; no-op here)
  argv_has --bind "$H/home/.claude" "$H/home/.claude"
  # the config file is bound INSIDE the state directory: Claude Code writes it
  # through a lock directory and a temp file beside it, which a read-only $HOME
  # refuses -- and the writer then gives up silently (measured, 2.1.274). What is
  # bound there is the role's seed-only store of it, never the host's file
  # (tests/unit/config-channel.bats has the rest).
  argv_has --bind "$H/home/.local/state/agent-sandbox/claude/$(printf '%s' "$(cd "$H/proj" && pwd -P)" | sed 's:[^A-Za-z0-9-]:-:g')/default/config/seed-only/$(printf '%s' "$H/home/.claude/.claude.json" | sed 's:^/::; s:/:_:g')" "$H/home/.claude/.claude.json"
  run ! argv_has --bind "$H/home/.claude.json" "$H/home/.claude/.claude.json"
  argv_has --ro-bind "$BIN" "$BIN"
  argv_has --bind "$H/proj" "$H/proj"
  argv_has --chdir "$H/proj"
  argv_has --remount-ro "$H/home"
  argv_has --share-net
  # the session token: the profile's [allow] opens its hosts for every launch (#181)
  [[ "$(setenv_value HTTPS_PROXY)" =~ ^http://[0-9a-f]{32}:x@127\.0\.0\.1:8888$ ]]
  [ "$(setenv_value HTTP_PROXY)" = "$(setenv_value HTTPS_PROXY)" ]
  [ "$(setenv_value NO_PROXY)" = "" ]
  [ "$(setenv_value DISABLE_AUTOUPDATER)" = "1" ]
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/.claude" ] # so Claude Code looks for the file where it is bound
  [ "$(setenv_value HOME)" = "$H/home" ]
  [ "$(setenv_value USER)" = "tester" ]
  [ "$(setenv_value AGENT_SANDBOX)" = "1" ] # marks the inside of a sandbox (nested-launcher detection)
  [ "$(setenv_value SSL_CERT_FILE)" = "/etc/ssl/certs/ca-certificates.crt" ]
  [ "$(setenv_value CONDA_SSL_VERIFY)" = "/etc/ssl/certs/ca-certificates.crt" ]
  run ! setenv_value LEAKED
  # HOME's binds come before the final remount-ro; the HOME tmpfs before them
  [ "$(argv_index --remount-ro)" -gt "$(argv_index "$H/home/.claude")" ]
  [ "$(argv_index "$H/home/.claude")" -gt "$(argv_index --tmpfs)" ]
  # the file bind layers on the directory bind, so it must come after it
  [ "$(argv_index "$H/home/.claude/.claude.json")" -gt "$(argv_index "$H/home/.claude")" ]
  # the launch runs the keeper's payload, and the agent is joined into it: its own
  # arguments passed through untouched and in order; the briefing's --settings goes
  # before them (a subcommand refuses it after it), which the harness splits off
  # into JOINB
  local i
  i="$(argv_index --)"
  [ "${ARGV[i + 1]}" = bash ]
  [ "${ARGV[-1]}" = agent-sandbox-keeper ]
  [ "${JOINV[0]}" = "$BIN" ]
  [ "${JOINV[1]}" = "--version" ]
  [ "${JOINV[2]}" = "--foo" ]
  [ "${JOINV[3]}" = "bar" ]
  [ "${#JOINV[@]}" -eq 4 ]           # ...and nothing after them
  [ "${JOINB[0]}" = "--settings" ]   # the briefing's, first
  [ "${#ARGV[@]}" -eq "$((i + 5))" ] # and after bwrap's --, only the payload
  # nothing binds the config file at $HOME any more, where its writes were lost
  run ! argv_has --bind "$H/home/.claude.json" "$H/home/.claude.json"
}

@test "none: no network at all; open: host network without proxy; neither sets proxy or CA variables" {
  run_engine AGENT_SANDBOX_NET=none -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --share-net
  run ! setenv_value HTTPS_PROXY
  run ! setenv_value SSL_CERT_FILE
  run ! argv_has --ro-bind "$H/base/ca-bundle.crt"
  run_engine AGENT_SANDBOX_NET=open -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --share-net
  run ! setenv_value HTTPS_PROXY
  run ! setenv_value SSL_CERT_FILE
}

@test "bwrap itself runs with no environment and its options off its command line: inside it is pid 1, readable there" {
  # Its --clearenv clears only the command's. The command's environment is all --setenv.
  run_engine SECRETISH=1 -- asb claude --version
  [ "$status" -eq 0 ]
  [ -f "$H/argv.env" ]
  [ ! -s "$H/argv.env" ]         # the stub was given nothing
  grep -qx args-fd "$H/argv.via" # and its options came through --args, not its command line
  argv_has --clearenv
  argv_has --setenv HOME "$H/home"
}

@test "environment allowlist: locale, profile, proxy/CA and CUDA names are forwarded only when set; FORWARD adds names; caller-set CA variables win" {
  run_engine LANG=C.UTF-8 TZ=UTC ANTHROPIC_API_KEY=k CUDA_HOME=/usr/local/cuda AWS_SECRET_ACCESS_KEY=x GH_TOKEN=y -- asb claude --version
  [ "$(setenv_value LANG)" = "C.UTF-8" ]
  [ "$(setenv_value TZ)" = "UTC" ]
  [ "$(setenv_value ANTHROPIC_API_KEY)" = "k" ]
  [ "$(setenv_value CUDA_HOME)" = "/usr/local/cuda" ]
  run ! setenv_value AWS_SECRET_ACCESS_KEY
  run ! setenv_value GH_TOKEN
  run ! setenv_value TERM_PROGRAM
  run_engine AGENT_SANDBOX_FORWARD="GH_TOKEN FOO:BAR" GH_TOKEN=y FOO="two words" -- asb claude --version
  [ "$(setenv_value GH_TOKEN)" = "y" ]
  [ "$(setenv_value FOO)" = "two words" ]
  run ! setenv_value BAR
  # names the profile pins are not forwardable: a later --setenv of the same
  # name would win over the profile's, and CLAUDE_CODE_PROJECT_DIR_NAME would
  # move memory and transcripts out from under the scoping. Said, not dropped.
  # (CLAUDE_CONFIG_DIR set in the shell also moves the base, #190: the pin carries it)
  run_engine AGENT_SANDBOX_FORWARD="CLAUDE_CONFIG_DIR CLAUDE_CODE_PROJECT_DIR_NAME DISABLE_AUTOUPDATER OK_VAR" \
    CLAUDE_CONFIG_DIR="$H/home/elsewhere" CLAUDE_CODE_PROJECT_DIR_NAME=one DISABLE_AUTOUPDATER=0 OK_VAR=1 -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/elsewhere" ]
  [[ "$output" == *"not forwarding CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" == *"not forwarding CLAUDE_CODE_PROJECT_DIR_NAME"* ]]
  [[ "$output" == *"not forwarding DISABLE_AUTOUPDATER"* ]]
  [ "$(setenv_value DISABLE_AUTOUPDATER)" = "1" ]
  [ "$(setenv_value OK_VAR)" = "1" ]
  [ "$(grep -c '^CLAUDE_CONFIG_DIR$' "$H/argv")" -eq 1 ]
  run ! setenv_value CLAUDE_CODE_PROJECT_DIR_NAME
  # Under `native` a refusal guards nothing and does not apply; a pin is policy and
  # still does; the base variable is the engine's to set, and native sets none (#173).
  TEST_PRESET="" run_engine CLAUDE_CODE_PROJECT_DIR_NAME=one DISABLE_AUTOUPDATER=0 -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CLAUDE_CODE_PROJECT_DIR_NAME)" = one ]
  [ "$(setenv_value DISABLE_AUTOUPDATER)" = "1" ]
  run ! setenv_value CLAUDE_CONFIG_DIR
  TEST_PRESET="" run_engine CLAUDE_CONFIG_DIR="$H/home/elsewhere" -- asb --preset native claude --version
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$H/home/elsewhere" ] # the user's, swept as under none
  run_engine PIP_CERT=/my/ca SSL_CERT_FILE=/my/bundle -- asb claude --version
  [ "$(setenv_value PIP_CERT)" = "/my/ca" ]
  [ "$(setenv_value SSL_CERT_FILE)" = "/my/bundle" ]
  [ "$(setenv_value CONDA_SSL_VERIFY)" = "/my/bundle" ]
  [ "$(grep -c '^PIP_CERT$' "$H/argv")" -eq 1 ]
}

@test "a path declared read-only or read-write binds the path; a missing one is skipped with a note" {
  mkdir -p "$H/ro1" "$H/rw1"
  run_engine -- asb --connect "$H/ro1 = read-only" --connect "$H/nope = read-only" \
    --connect "$H/rw1 = read-write" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/ro1" "$H/ro1"
  argv_has --bind "$H/rw1" "$H/rw1"
  [[ "$output" == *"'$H/nope' does not exist, so its declaration is skipped"* ]]
  run ! argv_has "$H/nope"
}

@test "conda: base bound read-only before the env; env read-only by default; the sandbox package cache and CONDA_PKGS_DIRS in both modes (#219); write mode makes only the env rw; tmpfs ~/.conda and read-only rc files" {
  local base="$H/conda" env="$H/conda/envs/myenv"
  mkdir -p "$env" "$base/pkgs" "$base/condabin" "$H/pkgs"
  : >"$H/home/.condarc"
  local -a cenv=(CONDA_PREFIX="$env" CONDA_DEFAULT_ENV=myenv CONDA_SHLVL=1)
  run_engine "${cenv[@]}" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$base" "$base"
  argv_has --ro-bind "$env" "$env"
  run ! argv_has --bind "$env" "$env"
  [ "$(argv_index "$base")" -lt "$(argv_index "$env")" ]
  argv_has --tmpfs "$H/home/.conda"
  argv_has --ro-bind "$H/home/.condarc" "$H/home/.condarc"
  [ "$(setenv_value CONDA_PREFIX)" = "$env" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = "myenv" ]
  argv_has --bind "$H/home/.cache/agent-sandbox/conda-pkgs" "$H/home/.cache/agent-sandbox/conda-pkgs"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$H/home/.cache/agent-sandbox/conda-pkgs,$base/pkgs" ]
  run_engine "${cenv[@]}" AGENT_SANDBOX_CONDA_WRITE=1 AGENT_SANDBOX_CONDA_PKGS="$H/pkgs" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$base" "$base"
  argv_has --bind "$env" "$env"
  argv_has --bind "$H/pkgs" "$H/pkgs"
  [ "$(setenv_value CONDA_PKGS_DIRS)" = "$H/pkgs,$base/pkgs" ]
  [ "$(argv_index --ro-bind)" -lt "$(argv_index "$env")" ]
}

@test "conda under native: what is inside HOME is already there and not bound again; a symlink out of HOME is bound at its target (#205)" {
  # Measured: `~/miniconda3 -> /mnt/...` with an active env refused every native launch
  # ("Can't mount on symlink destination"), since native binds HOME whole.
  local real="$H/disk/conda" link="$H/home/miniconda3" inside="$H/home/conda2"
  mkdir -p "$real/envs/e" "$inside/envs/f"
  ln -s "$real" "$link"
  : >"$H/home/.condarc"
  TEST_PRESET="" run_engine CONDA_PREFIX="$link/envs/e" MAMBA_ROOT_PREFIX="$link" -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --ro-bind "$link" "$link"
  run ! argv_has --ro-bind "$link/envs/e" "$link/envs/e"
  argv_has --ro-bind "$real" "$real"
  argv_has --ro-bind "$real/envs/e" "$real/envs/e"
  run ! argv_has --tmpfs "$H/home/.conda"                        # the host's own
  run ! argv_has --ro-bind "$H/home/.condarc" "$H/home/.condarc" # already there
  [ "$(setenv_value CONDA_PREFIX)" = "$link/envs/e" ]
  # an env plainly inside HOME: nothing to bind at all
  TEST_PRESET="" run_engine CONDA_PREFIX="$inside/envs/f" MAMBA_ROOT_PREFIX="$inside" -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --ro-bind "$inside" "$inside"
  run ! argv_has --ro-bind "$inside/envs/f" "$inside/envs/f"
  # and outside native nothing changes
  run_engine CONDA_PREFIX="$inside/envs/f" MAMBA_ROOT_PREFIX="$inside" -- asb claude --version
  argv_has --ro-bind "$inside" "$inside"
  argv_has --tmpfs "$H/home/.conda"
}

@test "CWD: \$HOME itself is not bound; /, a parent of \$HOME, and secret stores are refused" {
  RUN_CWD="$H/home" run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"CWD is \$HOME"* ]]
  RUN_CWD=/ run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [ ! -s "$H/argv" ]
  RUN_CWD="$(dirname "$H/home")" run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"contains \$HOME"* ]]
  mkdir -p "$H/home/.ssh" "$H/home/.config/agent-sandbox"
  RUN_CWD="$H/home/.ssh" run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it is the secret store"* ]] && [ ! -s "$H/argv" ]
  RUN_CWD="$H/home/.config/agent-sandbox" run_engine -- asb claude --version
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it is the sandbox's own control plane"* ]]
  RUN_CWD="$H/home/.config" run_engine -- asb claude --version # contains the trust store
  [ "$status" -eq 1 ] && [[ "$output" == *"as CWD: it contains"* ]] && [ ! -s "$H/argv" ]
  run ! argv_has --bind "$H/home" "$H/home"
}

@test "a path declaration into a secret store or a parent of HOME is refused before bwrap runs" {
  mkdir -p "$H/home/.aws"
  run_engine -- asb --connect "$H/home/.aws = read-write" claude --version
  [ "$status" -ne 0 ] && [ ! -s "$H/argv" ]
  run_engine -- asb --connect "$H/home/.aws = read-only" claude --version
  [ "$status" -ne 0 ]
  run_engine -- asb --connect "$(dirname "$H/home") = read-write" claude --version
  [ "$status" -ne 0 ]
}

@test "--allow writes the session file with a header and the hosts, and the session dir is removed after bwrap exits" {
  # a probing stub: snapshot the session base while "inside"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"; for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/*; do printf '== %s\n' "$f"; cat "$f"; done >"${BWRAP_PROBE:?}" 2>&1
. "${0%/*}/keeper-tail"
STUB
  run_engine BWRAP_PROBE="$H/probe" -- asb --allow pypi.org --allow=.example.org claude --version
  [ "$status" -eq 0 ]
  grep -q '^== .*/allow.txt$' "$H/probe"
  grep -q '^pypi.org$' "$H/probe"
  grep -q '^\.example\.org$' "$H/probe"
  grep -q '^== .*/owner.id$' "$H/probe"
  # owner.id: two fields, the pid's real start time
  local pid start
  read -r pid start < <(sed -n '/owner.id$/{n;p}' "$H/probe")
  [ -n "$pid" ] && [ -n "$start" ] && [ "$start" != 0 ]
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
  run ! argv_has allow.txt
}

@test "the host's GPUs are passed in by default: their device nodes, and /sys read-only for the driver's library" {
  mkdir -p "$H/dev/dri"
  : >"$H/dev/nvidia0"
  : >"$H/dev/nvidiactl"
  run_engine AGENT_SANDBOX_GPU_DEVICES="$H/dev/nvidia* $H/dev/kfd $H/dev/dri" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --dev-bind "$H/dev/nvidia0" "$H/dev/nvidia0"
  argv_has --dev-bind "$H/dev/nvidiactl" "$H/dev/nvidiactl"
  argv_has --dev-bind "$H/dev/dri" "$H/dev/dri"
  run ! argv_has --dev-bind "$H/dev/kfd" "$H/dev/kfd" # not on this host
  argv_has --ro-bind /sys /sys
  [ "$(argv_index --dev-bind)" -gt "$(argv_index --dev)" ] # over the minimal /dev
}

@test "[gpu] mode = off (or AGENT_SANDBOX_GPU=off) keeps them out; a bad value is refused; no GPUs, no /sys" {
  : >"$H/dev-nvidia0"
  run_engine AGENT_SANDBOX_GPU=off AGENT_SANDBOX_GPU_DEVICES="$H/dev-nvidia0" -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --dev-bind "$H/dev-nvidia0" "$H/dev-nvidia0"
  run ! argv_has --ro-bind /sys /sys
  local PROJ
  PROJ="$(cd "$H/proj" && pwd -P)"
  printf '[gpu]\nmode = off\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$H/home/.config/agent-sandbox/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 >"$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  run_engine AGENT_SANDBOX_GPU_DEVICES="$H/dev-nvidia0" -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --dev-bind "$H/dev-nvidia0" "$H/dev-nvidia0"
  rm "$PROJ/.agent-sandbox"
  rm -rf "$H/home/.config/agent-sandbox/trust"
  run_engine AGENT_SANDBOX_GPU=maybe -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"AGENT_SANDBOX_GPU=maybe: expected on or off"* ]]
  run_engine AGENT_SANDBOX_GPU_DEVICES="$H/none*" -- asb claude --version
  run ! argv_has --ro-bind /sys /sys
}
