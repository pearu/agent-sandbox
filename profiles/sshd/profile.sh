#!/usr/bin/env bash
# profiles/sshd/profile.sh -- agent-sandbox profile whose agent is an OpenSSH server (#335).
#
#   asb --profile sshd --role NAME
#
# run in a project directory gives other machines a sandboxed ssh login to this account:
# command sessions, `bash -s`, sftp, rsync, detached jobs and pty sessions, each inside
# the role's sandbox, its egress through the sandbox's allowlist proxy, its policy the
# project's .agent-sandbox. The launch runs sshd in the foreground (`sshd -D -e`; its log
# goes to the launch's stderr): background it yourself (nohup, tmux); `asb --profile
# sshd --role NAME --shutdown` ends it and every job in it.
#
# Sourced by the engine on the HOST, before the sandbox exists, under `set -euo
# pipefail`. The contract is in profiles/claude/profile.sh and docs/profiles.md; what
# this profile declares of it:
#
#   profile_command           this directory's sshd-agent.sh, a path: the engine binds it
#                             read-only at itself, so it runs inside whatever the
#                             account's PATH (sshd itself is in /usr/sbin, often off a
#                             user's PATH). It writes the sessions' environment into
#                             sshd's configuration and execs sshd.
#   profile_self_contained=1  a proxy of its own for every launch, its sessions under the
#                             role's store: no user manager, no linger, no unit needed.
#   profile_project_env_set=1 the project's [env] NAME = VALUE is set inside (a cache
#                             directory in the project, say): remote scripts get it.
#   profile_by_name_only=1    never the profile a verb with no command defaults to.
#   profile_ro_binds          the role's sshd directory, read-only at itself, and its
#                             /etc/group without the tty line over /etc/group.
#
# NOTHING NAMES AN ACCOUNT, A HOME OR A PORT: the account is whoever launches, the role
# is --role, the port and address are the launch's one agent-port token, the keys file
# is the policy's [sshd] authorized-keys.

# The profile_* variables below are the contract: the engine reads them after sourcing
# this file, so shellcheck sees them as unused here.
# shellcheck disable=SC2034
profile_command="${BASH_SOURCE[0]%/*}/sshd-agent.sh"
# shellcheck disable=SC2034
profile_self_contained=1
# shellcheck disable=SC2034
profile_project_env_set=1
# shellcheck disable=SC2034
profile_by_name_only=1
# Keys this profile reads from a project's [sshd] section; the review warns of any other.
# shellcheck disable=SC2034
profile_dotfile_keys=(authorized-keys)

# _sshd_q STRING -- STRING as one double-quoted sshd_config argument: a backslash and a
# double quote escaped, which is what sshd's argument splitting undoes (measured with
# `sshd -T`, OpenSSH 9.6: spaces, tabs, `#`, `'`, `$` and backslashes come through).
_sshd_q() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

# _sshd_find NAME DIR... -- the first executable NAME on PATH or in DIR..., resolved.
_sshd_find() {
  local n="$1" c d
  shift
  c="$(command -v "$n" 2>/dev/null || true)"
  if [[ "$c" != /* ]]; then
    c=""
    for d in "$@"; do
      [[ -x "$d/$n" ]] && c="$d/$n" && break
    done
  fi
  [[ -n "$c" ]] || return 1
  readlink -f -- "$c"
}

# _sshd_authorized_keys -- the [sshd] authorized-keys file of the launch's policy, checked:
# absolute (or under ~) and a readable file. Prints it; says why and fails otherwise.
# Reads the engine's _df_profile_kv (the approved dot-file's [sshd] pairs).
# shellcheck disable=SC2154
_sshd_authorized_keys() {
  local kv ak=""
  for kv in ${_df_profile_kv[@]+"${_df_profile_kv[@]}"}; do
    [[ "${kv%%=*}" == authorized-keys ]] && ak="${kv#*=}"
  done
  if [[ -z "$ak" ]]; then
    _as_msg "profile sshd needs [sshd] authorized-keys = PATH in this project's .agent-sandbox: the file of public keys that may log in. Refusing to launch"
    return 1
  fi
  [[ "$ak" == \~ || "$ak" == \~/* ]] && ak="$HOME${ak#\~}"
  if [[ "$ak" != /* ]]; then
    _as_msg "profile sshd: [sshd] authorized-keys = $ak is a relative path; it is an absolute path (or under ~), outside the project. Refusing to launch"
    return 1
  fi
  if [[ ! -f "$ak" || ! -r "$ak" ]]; then
    _as_msg "profile sshd: [sshd] authorized-keys = $ak is not a readable file. Refusing to launch"
    return 1
  fi
  printf '%s' "$ak"
}

# The launch, on the host: what the profile requires of it, then the role's sshd directory
# -- the host key (made once, kept), a copy of the authorized keys taken now, /etc/group
# without the tty line, and sshd's configuration -- bound read-only inside.
# Reads the engine's _knob_net, _agent_ports, profile_role_dir and _role.
# shellcheck disable=SC2154
profile_prepare() {
  if [[ "${_knob_net:-proxy}" != strict ]]; then
    _as_msg "profile sshd needs the strict network mode ([net] mode = strict, or AGENT_SANDBOX_NET=strict): its sessions reach nothing but the proxy only there. Refusing to launch"
    return 1
  fi
  if ((${#_agent_ports[@]} != 1)); then
    _as_msg "profile sshd needs exactly one agent port, the one sshd listens on (--agent-port [ADDR:]PORT, AGENT_SANDBOX_AGENT_PORTS or [net] agent-port); this launch has ${#_agent_ports[@]}${_agent_ports[*]:+: ${_agent_ports[*]}}. Refusing to launch"
    return 1
  fi
  local tok="${_agent_ports[0]}" port addr=127.0.0.1 ak sshd keygen sftp="" c dir out
  port="${tok##*:}"
  [[ "$tok" == *:* ]] && addr="${tok%:*}"
  ak="$(_sshd_authorized_keys)" || return 1
  sshd="$(_sshd_find sshd /usr/sbin /sbin /usr/local/sbin)" || {
    _as_msg "profile sshd: no sshd on PATH or in /usr/sbin, /sbin (Debian/Ubuntu: sudo apt install openssh-server). Refusing to launch"
    return 1
  }
  keygen="$(_sshd_find ssh-keygen /usr/bin /bin /usr/local/bin)" || {
    _as_msg "profile sshd: no ssh-keygen on PATH or in /usr/bin (Debian/Ubuntu: sudo apt install openssh-client). Refusing to launch"
    return 1
  }
  # sftp-server where each distribution keeps it: Debian/Ubuntu, Fedora/RHEL, Arch, SUSE.
  for c in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server \
    /usr/libexec/ssh/sftp-server /usr/libexec/sftp-server /usr/lib/sftp-server; do
    [[ -x "$c" ]] && sftp="$c" && break
  done
  if [[ -z "$sftp" ]]; then
    _as_msg "profile sshd: no sftp-server on this host; sftp is sshd's own (internal-sftp)"
    sftp=internal-sftp
  fi
  dir="$profile_role_dir/sshd"
  (umask 077 && mkdir -p -- "$dir") || return 1
  if [[ ! -f "$dir/ssh_host_ed25519_key" ]]; then
    "$keygen" -q -t ed25519 -N '' -C "agent-sandbox sshd, role ${_role:-default}" -f "$dir/ssh_host_ed25519_key" </dev/null || {
      _as_msg "profile sshd: ssh-keygen could not make the host key in $dir. Refusing to launch"
      return 1
    }
  fi
  (umask 077 && cp -- "$ak" "$dir/authorized_keys.new" && chmod 600 "$dir/authorized_keys.new" \
    && mv -f -- "$dir/authorized_keys.new" "$dir/authorized_keys") || {
    _as_msg "profile sshd: could not copy $ak into $dir. Refusing to launch"
    return 1
  }
  # A pty session chowns its terminal to the group `tty`, gid 5, which the sandbox's user
  # namespace does not map (EINVAL); with no tty group sshd uses the user's own (measured).
  grep -v '^tty:' /etc/group >"$dir/group" || :
  chmod 644 "$dir/group"
  out="$dir/sshd_config"
  {
    printf '# The sshd profile'"'"'s configuration for role %s, written at every launch (#335).\n' "${_role:-default}"
    printf '# Inside the sandbox its agent (sshd-agent.sh) puts the SetEnv line before it.\n'
    printf 'Port %s\n' "$port"
    printf 'ListenAddress %s\n' "$addr"
    printf 'HostKey %s\n' "$(_sshd_q "$dir/ssh_host_ed25519_key")"
    printf 'AuthorizedKeysFile %s\n' "$(_sshd_q "$dir/authorized_keys")"
    printf 'PidFile none\n'
    printf 'UsePAM no\n'
    printf 'PasswordAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'PermitUserEnvironment no\n'
    printf 'PermitUserRC no\n'
    printf 'DisableForwarding yes\n'
    printf 'PermitTunnel no\n'
    printf 'StrictModes no\n'
    printf 'Subsystem sftp %s\n' "$sftp"
    printf 'LogLevel VERBOSE\n'
  } >"$out.new" && mv -f -- "$out.new" "$out" || return 1
  local err
  if ! err="$("$sshd" -t -f "$out" 2>&1)"; then
    _as_msg "profile sshd: sshd refuses its configuration $out: $err. Refusing to launch"
    return 1
  fi
  profile_ro_binds+=("$dir" "$dir/group"$'\t'/etc/group)
  # sshd and sftp-server are bound only when outside the system directories the sandbox
  # already has read-only.
  for c in "$sshd" "$sftp"; do
    case "$c" in internal-sftp | /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /opt/*) ;; *) profile_ro_binds+=("$c") ;; esac
  done
  profile_env_set+=("AGENT_SANDBOX_SSHD=$sshd" "AGENT_SANDBOX_SSHD_CONFIG=$out")
  _sshd_cold=1
  return 0
}

# A launch of a running role joins it, and a second sshd could not listen on its port:
# refused, naming the way to end the first. (A launch that started the role passes.)
# shellcheck disable=SC2154
profile_before_join() {
  ((${_sshd_cold:-0})) && return 0
  _as_msg "role '${_role:-default}' is running already, its sshd with it, and a second sshd cannot listen on its port. End it first: asb --profile sshd --role ${_role:-default} --shutdown"
  return 1
}

# No command and no arguments: the profile runs sshd itself (--exec runs a command in
# the role's sandbox, as under any profile).
# shellcheck disable=SC2154
profile_route() {
  ((${_do_exec:-0})) && return 0
  if [[ -n "${_cmd_word:-}" ]] || (($#)); then
    _as_msg "profile sshd runs sshd itself, with no command and no arguments: asb --profile sshd --role NAME, in the project whose .agent-sandbox is its policy"
    return 1
  fi
  return 0
}

# The review of a project's [sshd] lines (profile_trust_notes, #335): who may log in,
# and a keys file the sessions could write.
profile_trust_notes() {
  local cwd="$1" kv v p
  shift
  for kv in "$@"; do
    [[ "${kv%%=*}" == authorized-keys ]] || continue
    v="${kv#*=}" p="${kv#*=}"
    [[ "$p" == \~ || "$p" == \~/* ]] && p="$HOME${p#\~}"
    if [[ "$p" != /* ]]; then
      printf '[sshd] authorized-keys = %s: a relative path; a launch refuses it (an absolute path, or under ~)\n' "$v"
      continue
    fi
    printf '[sshd] authorized-keys = %s: whoever holds a key listed there logs in to this project'"'"'s sshd roles, in their sandbox; the file is copied at each launch\n' "$v"
    p="$(realpath -m -- "$p")"
    if [[ "$p" == "$cwd" || "$p" == "$cwd"/* ]]; then
      printf 'warning -- [sshd] authorized-keys = %s is inside the project directory, which every session can write: a session could add a key that the next launch lets in. Keep it outside the project\n' "$v"
    fi
  done
}
