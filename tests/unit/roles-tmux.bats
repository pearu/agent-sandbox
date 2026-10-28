#!/usr/bin/env bats
# asb --roles ROLE... [ENGINE FLAGS] CMD [AGENT ARGS] (#317): one tmux session, named
# after the project directory, with a window per role, each running `asb --role ROLE`
# with the rest of the command line. A stub `tmux` first on the harness's PATH dumps its
# argv, one token per line, to $TMUX_DUMP, and answers `has-session` from $TMUX_HAS (set:
# a session of that name is open), so these assert on the command the engine builds.
# shellcheck disable=SC2016 # ${SHELL:-bash} is the window's, not ours

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  SELF="$(cd "$H/bin" && pwd -P)/asb"
  REC="$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  TM="$H/tmux"
  stub_tmux "$H/bin/tmux"
}

# stub_tmux PATH -- the stub tmux, at PATH.
stub_tmux() {
  mkdir -p "${1%/*}"
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set +x
if [[ "${1:-}" == has-session ]]; then
  printf '%s\n' "$@" >"${TMUX_DUMP:?}.has"
  [[ -n "${TMUX_HAS:-}" ]]
  exit
fi
: >"${TMUX_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$TMUX_DUMP"; done
STUB
  chmod +x "$1"
}

# window LINE... -- the command a window runs for those engine words.
window() {
  local l
  printf -v l '%q ' "$SELF" "$@"
  printf '%s; exec "${SHELL:-bash}"' "${l% }"
}

# a PATH with the system's commands but tmux: symlinks to /usr/bin and /bin, and $H/bin
no_tmux_path() {
  local f
  mkdir -p "$H/sys"
  for f in /usr/bin/* /bin/*; do
    [[ "${f##*/}" == tmux ]] || ln -sfn "$f" "$H/sys/${f##*/}"
  done
  rm -f "$H/bin/tmux"
  NOTMUX="$H/bin:$H/sys"
}

@test "--roles: a window per role in order, named by it, in the project, running --role ROLE with the engine words before and after, then select the first; not at a terminal, detached and the attach line printed" {
  run_engine TMUX_DUMP="$TM" -- asb --verbose --roles planner-1 rev.2 --allow pypi.org claude --continue -x
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  local -a want=(
    new-session -d -s proj -n planner-1 -c "$PROJ" bash -c "$(window --role planner-1 --verbose --allow pypi.org claude --continue -x)"
    ";" new-window -n rev.2 -c "$PROJ" bash -c "$(window --role rev.2 --verbose --allow pypi.org claude --continue -x)"
    ";" select-window -t "=proj:^"
  )
  [ "${#T[@]}" -eq "${#want[@]}" ]
  local i
  for i in "${!want[@]}"; do [ "${T[i]}" = "${want[i]}" ]; done
  [[ "$output" == *"tmux session 'proj': a window per role (planner-1 rev.2). To attach to it: tmux attach -t proj"* ]]
  # the session is looked up by its exact name: tmux matches a prefix otherwise
  [ "$(cat "$TM.has")" = $'has-session\n-t\n=proj' ]
  [ ! -s "$H/argv" ] # nothing launched from here
}

@test "--roles: at a terminal, the chain ends attached to the session" {
  run_engine_tty '' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[*]: -8}" = "; select-window -t =proj:^ ; attach-session -t =proj" ]
  [[ "$output" != *"To attach to it"* ]]
}

@test "--roles: the roles end at a word that starts with - or names a profile; a path to the agent, --profile alone, and --serve each reach every window" {
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[10]}" = "$(window --role a claude)" ] && [ "${T[19]}" = "$(window --role b claude)" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a "$H/bin/claude" -p hi
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[10]}" = "$(window --role a "$H/bin/claude" -p hi)" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --profile claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[10]}" = "$(window --role a --profile claude)" ] # no empty command word
  # a served role in a window: --serve is one of the words, and needs no --role here
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --serve claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[19]}" = "$(window --role b --serve claude)" ]
}

@test "--roles: the session name is the project directory's, with . and : made _" {
  mkdir -p "$H/my.pro:j"
  RUN_CWD="$H/my.pro:j" run_engine TMUX_DUMP="$TM" -- asb --roles a claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[3]}" = my_pro_j ] && [ "${T[7]}" = "$(cd "$H/my.pro:j" && pwd -P)" ]
  [ "${T[*]: -4}" = "; select-window -t =my_pro_j:^" ]
}

@test "--roles: refused with no role, a role twice, a bad name, twice, with --role, a verb, --exec, a review" {
  run_engine TMUX_DUMP="$TM" -- asb --roles claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles needs the roles to open, before the command"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b a claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'a' is listed twice"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a 'b@x' claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: 'b@x' is not a role name"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --roles b claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles is given once"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --role x --roles a claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"not combined with --role"* ]]
  local w
  for w in --status --shutdown --delete "--reset skills" --list --list-all --check --trust "--init roles" "--apply [allow] x.org"; do
    # shellcheck disable=SC2086 # the words of each
    run_engine TMUX_DUMP="$TM" -- asb --roles a $w claude
    [ "$status" -eq 2 ] || {
      echo "$w: $status $output"
      false
    }
    [[ "$output" == *"--roles opens a session of role launches; it is not combined with --exec, a verb or a review"* ]]
  done
  run_engine TMUX_DUMP="$TM" -- asb --roles a --profile claude --exec bash
  [ "$status" -eq 2 ]
  [[ "$output" == *"not combined with --exec"* ]]
  # --summarize (#314) refuses first, in its own words, naming --roles
  run_engine TMUX_DUMP="$TM" -- asb --roles a --summarize claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--summarize runs one turn in a stopped role's sandbox; it is not combined with --exec, --serve, --roles, a verb or a review"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles is refused inside a sandbox" {
  # Inside is pid 1 being bubblewrap (_as_inside_sandbox), which a unit test cannot
  # arrange; the engine is sourced and that one test answered yes.
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" TMUX_DUMP="$TM" bash -c '
    cd "$1" && source "$2" && _as_inside_sandbox() { return 0; } && agent_sandbox --roles a claude
  ' _ "$PROJ" "$ENGINE" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles opens a tmux session on the host, and this is a sandbox"* ]]
  [ ! -e "$TM" ]
}

@test "--roles: a session of that name already open is refused, naming how to return to it and how to end it" {
  run_engine TMUX_DUMP="$TM" TMUX_HAS=1 -- asb --roles a b claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"a tmux session named 'proj' is already open. To return to it: tmux attach -t proj"* ]]
  [[ "$output" == *"to end it, and every launch in it: tmux kill-session -t proj"* ]]
  [ ! -e "$TM" ] # nothing created
}

@test "--roles: no tmux on PATH nor in the tools env is refused, naming install.sh; the tools env's is used when the host has none" {
  no_tmux_path
  run_engine TMUX_DUMP="$TM" PATH="$NOTMUX" -- asb --roles a claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--roles opens its windows with tmux, and there is none: not on PATH, nor in the tools env. install.sh installs it there"* ]]
  [ ! -e "$TM" ]
  local tools="$H/home/.local/share/agent-sandbox/tools"
  stub_tmux "$tools/a/bin/tmux"
  ln -s a "$tools/current"
  run_engine TMUX_DUMP="$TM" PATH="$NOTMUX" -- asb --roles a claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[0]}" = new-session ] && [ "${T[10]}" = "$(window --role a claude)" ]
}

@test "--roles reviews an unapproved dot-file once, here, before the windows open; a window's launch then starts without a review" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  # no terminal: refused, nothing opened (every window would ask)
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--roles: .agent-sandbox needs your review, and there is no terminal here to ask at: run asb --trust first"* ]]
  [ ! -e "$TM" ] && [ ! -e "$REC.approved" ]
  # no at the terminal: nothing recorded, nothing opened
  run_engine_tty 'n\n' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"not approved; --roles opens no windows."* ]]
  [ ! -e "$TM" ] && [ ! -e "$REC.approved" ]
  # yes: one review for both windows, recorded as a launch records it
  run_engine_tty 'y\n' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  [ "$(grep -c 'approve this .agent-sandbox' <<<"$output")" -eq 1 ]
  [[ "$output" == *"[allow]"*"pypi.org"*"approved."* ]]
  cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
  [ ! -s "$H/argv" ] # nothing launched from here
  # a window's command, at a terminal of its own: it launches, and asks nothing
  mapfile -t T <"$TM"
  local line="${T[19]%; exec*}"
  [ "$line" = "$(printf '%q ' "$SELF" --role b claude | sed 's/ $//')" ]
  : >"$H/argv"
  {
    printf 'cd %q && exec' "$PROJ"
    printf ' %q' env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
      BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_VERBOSE=on SHELL=true bash -c "${T[19]}"
  } >"$H/win.sh"
  run bash -c 'printf "n\n" | script -qec "bash $1" /dev/null' _ "$H/win.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"approve this"* ]]
  [[ "$output" == *"session allowlist: pypi.org"* ]] # under the approved file
  [ -s "$H/argv" ]
}
