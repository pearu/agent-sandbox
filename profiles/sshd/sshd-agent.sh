#!/usr/bin/env bash
# profiles/sshd/sshd-agent.sh -- the sshd profile's agent (#335). It runs INSIDE the
# sandbox, joined into the role's launch like any agent, so its environment is the
# launch's: the proxy URL with the session's token, the CA variables, the policy's [env]
# forwards and sets, PATH and the rest the engine composed. sshd gives a session an
# environment of its own, so this hands the launch's over: one SetEnv line, put before
# an Include of the configuration the profile wrote on the host, then exec sshd.
#
# EVERY VARIABLE PASSES BUT those sshd sets per session itself or that describe this
# process rather than the sandbox: HOME, USER, LOGNAME, SHELL, MAIL, TERM (the client's,
# for a pty), PWD, OLDPWD, SHLVL, _, every SSH_*, and the profile's own
# AGENT_SANDBOX_SSHD and AGENT_SANDBOX_SSHD_CONFIG. A value with a line break cannot be
# written into sshd_config: that variable is left out, and said.
#
# The file goes in the sandbox's private /tmp: the profile's directory is read-only
# inside. sshd reads it once, at start; each connection's sshd gets the configuration
# from the listener, not from the file.
set -euo pipefail
if [[ -z "${AGENT_SANDBOX_SSHD:-}" || -z "${AGENT_SANDBOX_SSHD_CONFIG:-}" ]]; then
  echo "sshd-agent.sh: the agent of the sshd profile, started by it (asb --profile sshd --role NAME): AGENT_SANDBOX_SSHD and AGENT_SANDBOX_SSHD_CONFIG are not set" >&2
  exit 2
fi
sshd="$AGENT_SANDBOX_SSHD" conf="$AGENT_SANDBOX_SSHD_CONFIG"

# One double-quoted sshd_config argument (see _sshd_q in profile.sh).
q() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

line="" kv="" name="" value=""
skipped=()
# This process's environment as it was given, not as bash has since changed it.
while IFS= read -r -d '' kv; do
  name="${kv%%=*}" value="${kv#*=}"
  case "$name" in
    HOME | USER | LOGNAME | SHELL | MAIL | TERM | PWD | OLDPWD | SHLVL | _ | SSH_* | AGENT_SANDBOX_SSHD | AGENT_SANDBOX_SSHD_CONFIG) continue ;;
  esac
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    skipped+=("$name")
    continue
  fi
  line+=" $(q "$name=$value")"
done </proc/$$/environ

umask 077
dir="$(mktemp -d /tmp/agent-sandbox-sshd.XXXXXX)"
{
  printf '# The sessions'"'"' environment: the launch'"'"'s, written by sshd-agent.sh at start (#335).\n'
  # sshd honours the first SetEnv line only (measured, OpenSSH 9.6): one line, every variable.
  [[ -z "$line" ]] || printf 'SetEnv%s\n' "$line"
  printf 'Include %s\n' "$(q "$conf")"
} >"$dir/sshd_config"
((${#skipped[@]} == 0)) \
  || echo "sshd-agent.sh: not passed to sessions, a value with a line break that sshd_config cannot hold: ${skipped[*]}" >&2
exec "$sshd" -D -e -f "$dir/sshd_config"
