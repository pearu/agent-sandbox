#!/usr/bin/env bash
# A stand-in for `systemctl --user` for the end-to-end installer test, so the
# installer runs to completion without a user systemd instance. Every call is
# appended to $SYSTEMCTL_SHIM_LOG; start/restart run the unit's ExecStart
# themselves as a background process whose pid is kept under
# $SYSTEMCTL_SHIM_STATE; is-active checks that pid; stop kills it.
set -u
: "${SYSTEMCTL_SHIM_LOG:?}" "${SYSTEMCTL_SHIM_STATE:?}"
printf '%s\n' "$*" >>"$SYSTEMCTL_SHIM_LOG"
args=("$@")
[[ ${args[0]-} == --user ]] && args=("${args[@]:1}")
cmd=${args[0]-}
unit=""
((${#args[@]} > 0)) && unit=${args[-1]}
unit_file="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit"
pidfile="$SYSTEMCTL_SHIM_STATE/$unit.pid"

stop_unit() {
  [[ -f $pidfile ]] || return 0
  kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$pidfile"
}

case $cmd in
  daemon-reload | enable | disable) exit 0 ;;
  is-enabled) exit 1 ;; # nothing is enabled, in particular no legacy unit
  stop) stop_unit ;;
  start | restart)
    [[ -f $unit_file ]] || {
      echo "systemctl-shim: no unit file $unit_file" >&2
      exit 5
    }
    stop_unit
    # ExecStart= may continue over lines ending in a backslash; %h is $HOME.
    exec_line=$(awk '/^ExecStart=/ { s = 1 } s { c = ($0 ~ /\\$/); sub(/\\$/, ""); printf "%s ", $0; if (!c) exit }' "$unit_file")
    exec_line=${exec_line#ExecStart=}
    exec_line=${exec_line//%h/$HOME}
    mkdir -p "$SYSTEMCTL_SHIM_STATE"
    # shellcheck disable=SC2086  # the unit's command line is word-split, as systemd would
    nohup $exec_line >"$SYSTEMCTL_SHIM_STATE/$unit.log" 2>&1 &
    echo $! >"$pidfile"
    ;;
  is-active)
    [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
    ;;
  *) exit 0 ;;
esac
