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

@test "_as_check_paths refuses secret stores for RO and for RW" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh" "$HOME/.gnupg/sub" "$HOME/.config/gcloud" "$HOME/.kube"
  for knob in RO RW; do
    for p in "$HOME/.ssh" "$HOME/.gnupg/sub" "$HOME/.config/gcloud" "$HOME/.kube"; do
      run _as_check_paths "$knob" "$p"
      [ "$status" -eq 1 ]
      [[ "$output" == *"refusing AGENT_SANDBOX_$knob="*"sensitive path"* ]]
    done
  done
}

@test "_as_check_paths refuses /, \$HOME and any parent of \$HOME; allows others" {
  HOME="$BATS_TEST_TMPDIR/deep/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/ok"
  for p in / "$HOME" "$BATS_TEST_TMPDIR/deep" "$BATS_TEST_TMPDIR"; do
    run _as_check_paths RW "$p"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HOME or a parent of it"* ]]
  done
  run _as_check_paths RO "$BATS_TEST_TMPDIR/ok:/opt"
  [ "$status" -eq 0 ]
  run _as_check_paths RW ""
  [ "$status" -eq 0 ]
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
  ls "$BATS_TEST_TMPDIR/base" | grep -q '^session\.'
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

@test "_as_ca_bind builds system+CA and binds it over the system bundle; rebuilds when the CA is newer; skips when the CA is missing" {
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
  local n_sys n_comb
  n_sys=$(grep -c 'BEGIN CERT' "$bundle")
  n_comb=$(grep -c 'BEGIN CERT' "${args[1]}")
  [ "$n_comb" -eq $((n_sys + 1)) ]
  grep -q "$(sed -n 2p "$AGENT_SANDBOX_PROXY_CA")" "${args[1]}"
  # rebuild when the CA is newer
  local m1
  m1=$(stat -c %Y "${args[1]}")
  sleep 1.1
  touch "$AGENT_SANDBOX_PROXY_CA"
  args=()
  _as_ca_bind
  [ "$(stat -c %Y "${args[1]}")" -gt "$m1" ]
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
