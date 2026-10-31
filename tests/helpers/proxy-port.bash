# shellcheck shell=bash
# The proxy's port as the engine resolves it (_as_proxy_port, #335), for the suites that
# reach a proxy: a test probes the port its environment actually has, not a constant.
# Loaded by common.bash; a suite that does not load that loads this alone:
#   load "$BATS_TEST_DIRNAME/../helpers/proxy-port"

# test_proxy_port [HOME] -- $AGENT_SANDBOX_PROXY_PORT, else the number install.sh
# recorded in HOME/.config/agent-sandbox/proxy-port (HOME defaults to $HOME: pass the
# HOME the engine under test runs with), else 8888. A value that is not a port
# 1024-65535 counts as absent, as the engine reads the file (a bad variable refuses
# the launch there, so a test using one fails on its own).
test_proxy_port() {
  local home="${1:-$HOME}" v=""
  if [[ -n "${AGENT_SANDBOX_PROXY_PORT:-}" ]]; then
    printf '%s' "$AGENT_SANDBOX_PROXY_PORT"
    return 0
  fi
  [[ -f "$home/.config/agent-sandbox/proxy-port" ]] \
    && v="$(tr -d '[:space:]' <"$home/.config/agent-sandbox/proxy-port")"
  if [[ "$v" =~ ^[1-9][0-9]{3,4}$ ]] && ((v >= 1024 && v <= 65535)); then
    printf '%s' "$v"
  else
    printf '8888'
  fi
}
