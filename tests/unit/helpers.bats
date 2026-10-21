#!/usr/bin/env bats
# Engine helper functions, called directly after sourcing the engine.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  source_engine
}

@test "_as_split splits on the given separators and does not glob" {
  local -a out=()
  _as_split out ':' '/a:/b*::/c'
  [ "${#out[@]}" -eq 4 ]
  [ "${out[0]}" = '/a' ]
  [ "${out[1]}" = '/b*' ]
  [ "${out[2]}" = '' ]
  [ "${out[3]}" = '/c' ]
  local -a e=()
  _as_split e $': \t\n' 'FOO BAR:BAZ'
  [ "${e[*]}" = 'FOO BAR BAZ' ]
}

@test "_as_path_protected: secret stores, the control plane and directories containing them; siblings pass" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh" "$HOME/.gnupg/sub" "$HOME/.config/gcloud" "$HOME/.kube" "$HOME/.config/gh" \
    "$HOME/.local/share/keyrings" "$HOME/.config/agent-sandbox/trust" "$HOME/.mitmproxy" \
    "$HOME/.local/share/agent-sandbox" "$HOME/.local/bin" "$HOME/.config/systemd/user" \
    "$HOME/.local/state/agent-sandbox/claude" \
    "$HOME/.config/nvim" "$HOME/.local/share/fonts" "$HOME/.cargo" "$HOME/.sshfoo" "$HOME/.local/state/other"
  : >"$HOME/.netrc"
  local p _prot_what _prot_path _prot_how
  for p in "$HOME/.ssh" "$HOME/.gnupg/sub" "$HOME/.config/gcloud" "$HOME/.kube" "$HOME/.config/gh" \
    "$HOME/.local/share/keyrings" "$HOME/.netrc" "$HOME/.git-credentials"; do
    _as_path_protected "$p"
    [ "$_prot_what" = "the secret store" ]
  done
  for p in "$HOME/.config/agent-sandbox/trust" "$HOME/.mitmproxy" "$HOME/.local/share/agent-sandbox" \
    "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.local/state/agent-sandbox/claude"; do
    _as_path_protected "$p"
    [ "$_prot_what" = "the sandbox's own control plane" ]
  done
  # a directory that contains a protected path exposes it
  for p in "$HOME/.config" "$HOME/.local" "$HOME/.local/share"; do
    _as_path_protected "$p"
    [ "$_prot_how" = contains ]
  done
  # ~/.local/bin, and what is in it, is not protected read-only; what contains it still is
  run ! _as_path_protected "$HOME/.local/bin" read-only
  run ! _as_path_protected "$HOME/.local/bin/claude" read-only
  _as_path_protected "$HOME/.local/bin" copy
  _as_path_protected "$HOME/.local" read-only
  # siblings and look-alikes are fine: the match is exact or by path component
  for p in "$HOME/.config/nvim" "$HOME/.local/share/fonts" "$HOME/.cargo" "$HOME/.sshfoo" "$HOME/.local/state/other"; do
    run ! _as_path_protected "$p"
  done
}

@test "_as_ssh_pick_key returns the first readable identity, skipping FIDO *_sk keys" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  : >"$HOME/.ssh/id_ed25519"
  local g=$'hostname x\nidentityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ed25519_sk\nidentityfile ~/.ssh/id_ed25519\nidentityfile ~/.ssh/id_dsa'
  run _as_ssh_pick_key "$g"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.ssh/id_ed25519" ]
  run _as_ssh_pick_key $'identityfile ~/.ssh/missing'
  [ "$status" -eq 1 ]
}

@test "_as_session_base honours the override, else XDG_RUNTIME_DIR, else /tmp" {
  AGENT_SANDBOX_SESSION_BASE="/x/y" run _as_session_base
  [ "$output" = "/x/y" ]
  unset AGENT_SANDBOX_SESSION_BASE
  XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" run _as_session_base
  [ "$output" = "$BATS_TEST_TMPDIR/agent-sandbox.$(id -u)" ]
  XDG_RUNTIME_DIR="/nonexistent/dir" run _as_session_base
  [ "$output" = "/tmp/agent-sandbox.$(id -u)" ]
}

@test "_as_session_begin stamps the owner's own pid and its real start time" {
  # Regression: $BASHPID inside a $(...) is the substitution's subshell, so the
  # recorded start time used to belong to the wrong process and every liveness
  # check saw the owner as dead.
  # shellcheck disable=SC2030 # each @test is its own subshell; this export is for this test only
  export AGENT_SANDBOX_SESSION_BASE="$BATS_TEST_TMPDIR/base"
  (
    _session_dir=""
    _as_session_begin
    read -r pid start <"$_session_dir/owner.id"
    real="$(awk '{print $22}' "/proc/$pid/stat")"
    [ "$pid" = "$BASHPID" ]
    [ "$start" = "$real" ]
    [ -n "$start" ] && [ "$start" != 0 ]
    trap - EXIT # leave the dir for the check below
  )
  [ -d "$BATS_TEST_TMPDIR/base" ]
  compgen -G "$BATS_TEST_TMPDIR/base/session.*" >/dev/null
}

@test "_as_session_sweep reaps dead and recycled-pid dirs, keeps live and unstamped" {
  local base="$BATS_TEST_TMPDIR/base"
  mkdir -p "$base/session.dead" "$base/session.live" "$base/session.unstamped" "$base/session.recycled"
  sleep 300 &
  local live=$!
  echo "999999 1" >"$base/session.dead/owner.id"
  printf '%s %s\n' "$live" "$(awk '{print $22}' "/proc/$live/stat")" >"$base/session.live/owner.id"
  printf '%s %s\n' "$live" "1" >"$base/session.recycled/owner.id"
  _as_session_sweep "$base"
  kill "$live" 2>/dev/null
  [ ! -d "$base/session.dead" ]
  [ ! -d "$base/session.recycled" ]
  [ -d "$base/session.live" ]
  [ -d "$base/session.unstamped" ]
}

@test "_as_system_ca_bundle finds the system bundle" {
  run _as_system_ca_bundle
  [ "$status" -eq 0 ]
  [ -r "$output" ]
  grep -q 'BEGIN CERT' "$output"
}

@test "_as_ca_bind builds system+CA and binds it over the system bundle; rebuilds every launch (even a rotated CA that is not newer); skips when the CA is missing" {
  # shellcheck disable=SC2031 # set afresh here; the earlier test's export died with its subshell
  export AGENT_SANDBOX_SESSION_BASE="$BATS_TEST_TMPDIR/base"
  export AGENT_SANDBOX_PROXY_CA="$BATS_TEST_TMPDIR/ca.pem"
  local bundle
  bundle="$(_as_system_ca_bundle)"
  # missing CA: warning, no bind
  local -a args=()
  run _as_ca_bind
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"not found"* ]]
  make_fake_ca "$AGENT_SANDBOX_PROXY_CA"
  args=()
  _as_ca_bind
  [ "${#args[@]}" -eq 3 ]
  [ "${args[0]}" = "--ro-bind" ]
  [ "${args[1]}" = "$AGENT_SANDBOX_SESSION_BASE/ca-bundle.crt" ]
  [ "${args[2]}" = "$bundle" ]
  local combined="${args[1]}"
  local n_sys n_comb
  n_sys=$(grep -c 'BEGIN CERT' "$bundle")
  n_comb=$(grep -c 'BEGIN CERT' "$combined")
  [ "$n_comb" -eq $((n_sys + 1)) ]
  grep -q "$(sed -n 2p "$AGENT_SANDBOX_PROXY_CA")" "$combined"
  # Staleness regression: the proxy CA is ROTATED to a different cert whose file
  # mtime is NOT newer than the cached bundle (an mtime-only cache would keep
  # serving the old CA here, and every agent verifying the proxy leaf then fails
  # TLS). The rebuild must replace the cached CA with the current one regardless.
  local old_line
  old_line="$(sed -n 2p "$AGENT_SANDBOX_PROXY_CA")" # a body line unique to the old CA
  make_fake_ca "$BATS_TEST_TMPDIR/ca2.pem"
  cp "$BATS_TEST_TMPDIR/ca2.pem" "$AGENT_SANDBOX_PROXY_CA" # rotate in place
  touch -d '2001-01-01' "$AGENT_SANDBOX_PROXY_CA"          # older than the cached bundle
  args=()
  _as_ca_bind
  grep -q "$(sed -n 2p "$AGENT_SANDBOX_PROXY_CA")" "$combined" # new CA present
  run ! grep -qF "$old_line" "$combined"                       # old CA gone
}

@test "_as_ca_bind records the system bundle it bound, and the SHA-256 of what it put in the bundle" {
  local AGENT_SANDBOX_SESSION_BASE="$BATS_TEST_TMPDIR/base" AGENT_SANDBOX_PROXY_CA="$BATS_TEST_TMPDIR/ca.pem"
  make_fake_ca "$AGENT_SANDBOX_PROXY_CA"
  local -a args=()
  local _ca_record=""
  _as_ca_bind
  local bundle
  bundle="$(_as_system_ca_bundle)"
  [ "$_ca_record" = "$bundle"$'\t'"$(sha256sum "$bundle" | cut -d' ' -f1)" ]
  rm -f "$AGENT_SANDBOX_PROXY_CA"
  _ca_record=""
  _as_ca_bind 2>/dev/null
  [ -z "$_ca_record" ] # nothing bound, nothing recorded
}

# ca_check_fixture -- a keeper directory whose CA record names a bundle of the test's
# own, and two mountinfo files: one with a mount at that path, one without.
ca_check_fixture() {
  SB="$BATS_TEST_TMPDIR/sb"
  B="$BATS_TEST_TMPDIR/etc ssl/ca-certificates.crt" # a space: mountinfo escapes it
  mkdir -p "$SB/keeper" "${B%/*}"
  printf 'CERTS\n' >"$B"
  touch -d '2026-10-21 06:00:12' "$B"
  printf '%s\t%s\n' "$B" "$(sha256sum "$B" | cut -d' ' -f1)" >"$SB/keeper/ca"
  printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n2 1 0:2 /x %s ro - ext4 /dev/x ro\n' \
    "${B// /\\040}" >"$BATS_TEST_TMPDIR/mi.bound"
  printf '1 0 0:1 / / rw - tmpfs tmpfs rw\n3 1 0:3 /x %s ro - ext4 /dev/x ro\n' \
    "${B%/*}" >"$BATS_TEST_TMPDIR/mi.lost"
  # shellcheck disable=SC2034 # read by the engine's functions, by dynamic scope
  invoked=asb profile=claude _cmd_word=claude _profile_given=0 _role=gate
}

@test "_as_ca_check: the bind gone from the keeper's mountinfo is a loud line naming when, and the --shutdown" {
  ca_check_fixture
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.lost"
  [ "$_ca_note" = "warning — role 'gate': the host replaced $B (at 2026-10-21 06:00:12) and the sandbox lost the proxy's CA -- HTTPS fails until the role is restarted: asb --role gate --shutdown claude" ]
  # the profile as it was chosen
  _profile_given=1
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.lost"
  [[ "$_ca_note" == *": asb --role gate --shutdown --profile claude" ]]
}

@test "_as_ca_check: the bind there but the host's bundle changed since is a note" {
  ca_check_fixture
  printf 'CERTS\nNEW\n' >"$B"
  touch -d '2026-10-21 06:00:12' "$B"
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.bound"
  [ "$_ca_note" = "note: role 'gate': the host's $B has changed (at 2026-10-21 06:00:12) since the role started; it keeps the bundle it started with, the proxy's CA included, so HTTPS works -- the host's new one applies at its next launch" ]
}

@test "_as_ca_check: silent with the bind there and the bundle unchanged, with no record, and with no mountinfo to read" {
  ca_check_fixture
  _ca_note=x
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.bound"
  [ -z "$_ca_note" ]
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/no-such-mountinfo" # cannot be read: no alarm
  [ -z "$_ca_note" ]
  : >"$BATS_TEST_TMPDIR/mi.empty"
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.empty"
  [ -z "$_ca_note" ]
  rm -f "$SB/keeper/ca" # not a proxy mode, or no CA was bound
  _as_ca_check "$SB" "$BATS_TEST_TMPDIR/mi.lost"
  [ -z "$_ca_note" ]
}

@test "_as_ca_env points the CA variables at the bundle unless the caller set them" {
  local -a args=()
  (
    unset SSL_CERT_FILE PIP_CERT
    _as_ca_env
    [ "${#args[@]}" -gt 0 ]
  )
  unset SSL_CERT_FILE PIP_CERT SSL_CERT_DIR
  _as_ca_env
  local bundle
  bundle="$(_as_system_ca_bundle)"
  local i found_pip=0 found_dir=0
  for ((i = 0; i + 2 < ${#args[@]}; i++)); do
    [[ "${args[i]}" == --setenv && "${args[i + 1]}" == PIP_CERT && "${args[i + 2]}" == "$bundle" ]] && found_pip=1
    [[ "${args[i]}" == --setenv && "${args[i + 1]}" == SSL_CERT_DIR && "${args[i + 2]}" == "$(dirname "$bundle")" ]] && found_dir=1
  done
  [ "$found_pip" -eq 1 ]
  [ "$found_dir" -eq 1 ]
  # caller-set PIP_CERT is not overridden here (it is forwarded elsewhere)
  args=()
  PIP_CERT=/my/ca _as_ca_env
  for ((i = 0; i + 2 < ${#args[@]}; i++)); do
    [[ "${args[i]}" == --setenv && "${args[i + 1]}" == PIP_CERT ]] && return 1
  done
  true
}

@test "_as_ssh_sysconfig_copies: each system ssh include is copied, owned by you, and bound over the original -- at a symlink's target" {
  local d="$BATS_TEST_TMPDIR/ssh_config.d" lib="$BATS_TEST_TMPDIR/lib"
  mkdir -p "$d" "$lib"
  printf 'Host .host\n  CheckHostIP no\n' >"$lib/20-systemd-ssh-proxy.conf"
  ln -s "$lib/20-systemd-ssh-proxy.conf" "$d/20-systemd-ssh-proxy.conf"
  printf 'Host *\n  ServerAliveInterval 30\n' >"$d/50-local.conf"
  mkdir "$d/not-a-file"
  _session_dir="$BATS_TEST_TMPDIR/session"
  mkdir -p "$_session_dir"
  local -a args=()
  _as_ssh_sysconfig_copies "$d"
  [ "${#args[@]}" -eq 6 ]
  [ "${args[*]}" = "--ro-bind $_session_dir/ssh_config.d/20-systemd-ssh-proxy.conf $lib/20-systemd-ssh-proxy.conf --ro-bind $_session_dir/ssh_config.d/50-local.conf $d/50-local.conf" ]
  cmp "$_session_dir/ssh_config.d/20-systemd-ssh-proxy.conf" "$lib/20-systemd-ssh-proxy.conf" # the host's content
  [ ! -L "$_session_dir/ssh_config.d/20-systemd-ssh-proxy.conf" ]
  [ "$(stat -c %u "$_session_dir/ssh_config.d/50-local.conf")" = "$(id -u)" ]
  args=()
  _as_ssh_sysconfig_copies "$BATS_TEST_TMPDIR/missing" # no such directory: nothing
  [ "${#args[@]}" -eq 0 ]
}
