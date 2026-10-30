#!/usr/bin/env bats
# asb --roles ROLE... [ENGINE FLAGS] CMD [AGENT ARGS] (#317, #320): one tmux session,
# named after the project directory, with a pane per role, five to a window -- the first
# role of each window on top, the others in a row below -- each running
# `asb --role ROLE` with the rest of the command line. A stub `tmux` first on the
# harness's PATH dumps its argv, one token per line, to $TMUX_DUMP, and answers
# `has-session` from $TMUX_HAS (set: a session of that name is open), so these assert on
# the command the engine builds; the layout tmux makes of it was measured with tmux 3.4.
# shellcheck disable=SC2016 # ${SHELL:-bash} and #{@role} are the pane's and tmux's, not ours

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
if [[ "${1:-}" == attach-session ]]; then
  printf '%s\n' "$@" >"${TMUX_DUMP:?}.attach"
  exit
fi
: >"${TMUX_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$TMUX_DUMP"; done
STUB
  chmod +x "$1"
}

# window LINE... -- the command a pane runs for those engine words.
window() {
  local l
  printf -v l '%q ' "$SELF" "$@"
  printf '%s; exec "${SHELL:-bash}"' "${l% }"
}

# The chain's pieces, as the stub dumps them. WINDOW_OPTS: what a window gets after it is
# made; titled ROLE: the pane's title and the @role its border shows; split ROLE WORDS...:
# a pane below, laid out again; tail_of NAME: the first window and its top pane selected.
WINDOW_OPTS=(";" set-option -w main-pane-height 50% ";" set-option -w pane-border-status top
  ";" set-option -w pane-border-format " #{@role} ")
titled() { printf '%s\n' ";" select-pane -T "$1" ";" set-option -p @role "$1"; }
split() {
  local r="$1"
  shift
  printf '%s\n' ";" split-window -c "$PROJ" bash -c "$(window --role "$r" "$@")" ";" select-layout main-horizontal
  titled "$r"
}
tail_of() { printf '%s\n' ";" select-window -t "=$1:^" ";" select-pane -t "=$1:^.{top}"; }

# same_argv -- the dump in $TM is exactly the array `want`, token by token.
same_argv() {
  local -a T
  mapfile -t T <"$TM"
  local i
  for i in "${!want[@]}"; do
    [ "${T[i]-<none>}" = "${want[i]}" ] || {
      echo "token $i: got '${T[i]-<none>}', want '${want[i]}'"
      return 1
    }
  done
  [ "${#T[@]}" -eq "${#want[@]}" ] || {
    echo "${#T[@]} tokens, want ${#want[@]}"
    return 1
  }
}

# pane_cmds -- PC: the command of every pane, in the order of the chain.
pane_cmds() {
  local -a T
  mapfile -t T <"$TM"
  PC=()
  local i
  for ((i = 2; i < ${#T[@]}; i++)); do
    [[ "${T[i - 2]}" == bash && "${T[i - 1]}" == -c ]] && PC+=("${T[i]}")
  done
  return 0
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

@test "--roles, one role: one pane, its border showing the role, in the project, running --role ROLE with the engine words before and after; not at a terminal, detached and the attach line printed" {
  run_engine TMUX_DUMP="$TM" -- asb --verbose --roles planner-1 --allow pypi.org claude --continue -x
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n planner-1 -c "$PROJ" bash -c "$(window --role planner-1 --verbose --allow pypi.org claude --continue -x)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(titled planner-1 && tail_of proj)
  same_argv
  [[ "$output" == *"tmux session 'proj': a pane per role (planner-1). To attach to it: tmux attach -t proj"* ]]
  # the session is looked up by its exact name: tmux matches a prefix otherwise
  [ "$(cat "$TM.has")" = $'has-session\n-t\n=proj' ]
  [ ! -s "$H/argv" ] # nothing launched from here
}

@test "--roles, two roles: the first on top, the second split below it and laid out main-horizontal" {
  run_engine TMUX_DUMP="$TM" -- asb --verbose --roles planner-1 rev.2 --allow pypi.org claude --continue -x
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n planner-1 -c "$PROJ" bash -c "$(window --role planner-1 --verbose --allow pypi.org claude --continue -x)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(titled planner-1 && split rev.2 --verbose --allow pypi.org claude --continue -x && tail_of proj)
  same_argv
  [[ "$output" == *"a pane per role (planner-1 rev.2)"* ]]
}

@test "--roles, five roles: one window, the first role on top and four split below, each laid out again; the first window's top pane selected last" {
  run_engine TMUX_DUMP="$TM" -- asb --roles supervisor planner-1 implementer-1 reviewer-1 gate claude --continue
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n supervisor -c "$PROJ" bash -c "$(window --role supervisor claude --continue)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(
    titled supervisor
    for r in planner-1 implementer-1 reviewer-1 gate; do split "$r" claude --continue; done
    tail_of proj
  )
  same_argv
  [ "$(grep -cx new-window "$TM")" -eq 0 ] && [ "$(grep -cx split-window "$TM")" -eq 4 ]
  [ "$(grep -cx 'main-horizontal' "$TM")" -eq 4 ]
}

@test "--roles, six roles: the sixth starts a second window, named by it and laid out the same way" {
  run_engine TMUX_DUMP="$TM" -- asb --roles r1 r2 r3 r4 r5 r6 claude
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n r1 -c "$PROJ" bash -c "$(window --role r1 claude)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(
    titled r1
    for r in r2 r3 r4 r5; do split "$r" claude; done
    printf '%s\n' ";" new-window -n r6 -c "$PROJ" bash -c "$(window --role r6 claude)" "${WINDOW_OPTS[@]}"
    titled r6
    tail_of proj
  )
  same_argv
  # eleven roles: three windows, named by the first, sixth and eleventh
  run_engine TMUX_DUMP="$TM" -- asb --roles r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  local -a names=()
  local i
  for i in "${!T[@]}"; do
    [[ "${T[i]}" == new-window ]] && names+=("${T[i + 2]}")
  done
  [ "${names[*]}" = "r6 r11" ] && [ "${T[5]}" = r1 ]
  [ "$(grep -cx split-window "$TM")" -eq 8 ]
}

@test "--roles: at a terminal, the chain ends with the first window and its top pane selected, and a tmux of its own then attaches to the session" {
  run_engine_tty '' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[*]: -8}" = "; select-window -t =proj:^ ; select-pane -t =proj:^.{top}" ]
  [ "$(cat "$TM.attach")" = $'attach-session\n-t\n=proj' ]
  [[ "$output" != *"To attach to it"* ]]
  # not at a terminal: no attach
  rm -f "$TM.attach"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  [ ! -e "$TM.attach" ]
}

@test "--roles: the roles end at a word that starts with - or names a profile; a path to the agent, --profile alone, and --serve each reach every pane" {
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${#PC[@]}" -eq 2 ] && [ "${PC[0]}" = "$(window --role a claude)" ] && [ "${PC[1]}" = "$(window --role b claude)" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a "$H/bin/claude" -p hi
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a "$H/bin/claude" -p hi)" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --profile claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --profile claude)" ] # no empty command word
  # a served role in a pane: --serve is one of the words, and needs no --role here
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --serve claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[1]}" = "$(window --role b --serve claude)" ]
}

@test "--roles: the session name is the project directory's, with . and : made _" {
  mkdir -p "$H/my.pro:j"
  RUN_CWD="$H/my.pro:j" run_engine TMUX_DUMP="$TM" -- asb --roles a claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[3]}" = my_pro_j ] && [ "${T[7]}" = "$(cd "$H/my.pro:j" && pwd -P)" ]
  [ "${T[*]: -8}" = "; select-window -t =my_pro_j:^ ; select-pane -t =my_pro_j:^.{top}" ]
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
  [[ "$output" == *"--roles opens its panes with tmux, and there is none: not on PATH, nor in the tools env. install.sh installs it there"* ]]
  [ ! -e "$TM" ]
  local tools="$H/home/.local/share/agent-sandbox/tools"
  stub_tmux "$tools/a/bin/tmux"
  ln -s a "$tools/current"
  run_engine TMUX_DUMP="$TM" PATH="$NOTMUX" -- asb --roles a claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[0]}" = new-session ] && [ "${T[10]}" = "$(window --role a claude)" ]
}

@test "--roles reviews an unapproved dot-file once, here, before the panes open; a pane's launch then starts without a review" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  # no terminal: refused, nothing opened (every pane would ask)
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"--roles: .agent-sandbox needs your review, and there is no terminal here to ask at: run asb --trust first"* ]]
  [ ! -e "$TM" ] && [ ! -e "$REC.approved" ]
  # no at the terminal: nothing recorded, nothing opened
  run_engine_tty 'n\n' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"not approved; --roles opens no panes."* ]]
  [ ! -e "$TM" ] && [ ! -e "$REC.approved" ]
  # yes: one review for both panes, recorded as a launch records it
  run_engine_tty 'y\n' TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  [ "$(grep -c 'approve this .agent-sandbox' <<<"$output")" -eq 1 ]
  [[ "$output" == *"[allow]"*"pypi.org"*"approved."* ]]
  cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
  [ ! -s "$H/argv" ] # nothing launched from here
  # a pane's command, at a terminal of its own: it launches, and asks nothing
  pane_cmds
  local line="${PC[1]%; exec*}"
  [ "$line" = "$(printf '%q ' "$SELF" --role b claude | sed 's/ $//')" ]
  : >"$H/argv"
  {
    printf 'cd %q && exec' "$PROJ"
    printf ' %q' env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
      BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
      AGENT_SANDBOX_PRESET=shared AGENT_SANDBOX_VERBOSE=on SHELL=true bash -c "${PC[1]}"
  } >"$H/win.sh"
  run bash -c 'printf "n\n" | script -qec "bash $1" /dev/null' _ "$H/win.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"approve this"* ]]
  [[ "$output" == *"session allowlist: pypi.org"* ]] # under the approved file
  [ -s "$H/argv" ]
}

# THE HOST TAKES RESETS (#329). --roles starts one watcher beside the session, out of
# the terminal's session; it is the engine again, with the internal word __roles-resets.

# stub_setsid -- a setsid first on PATH that records a start of the watcher (its argv in
# $H/setsid, where its stdin and stdout point in $H/setsid.fds, and whether the tmux
# session had been made by then) and runs anything else as the real one does.
stub_setsid() {
  cat >"$H/bin/setsid" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == -f && "${3:-}" == __roles-resets ]]; then
  printf '%s\n' "$@" >"$SETSID_DUMP"
  printf '%s\n' "$(readlink /proc/$$/fd/0)" "$(readlink /proc/$$/fd/1)" >"$SETSID_DUMP.fds"
  [[ -e "$TMUX_DUMP" ]] && echo made >>"$SETSID_DUMP.fds"
  exit 0
fi
exec /usr/bin/setsid "$@"
STUB
  chmod +x "$H/bin/setsid"
}

@test "--roles starts the host side that takes resets once the session is made: setsid -f, the engine with __roles-resets, tmux, the session, the project, /clear and the roles; stdin /dev/null, its output to the project's .roles-resets.log" {
  stub_setsid
  mkdir -p "$PROJ/.asb/coord/to"
  local log
  log="$H/home/.local/state/agent-sandbox/claude/$(printf '%s' "$PROJ" | sed 's:[^A-Za-z0-9-]:-:g')/.roles-resets.log"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b.2 claude --continue
  [ "$status" -eq 0 ]
  mapfile -t S <"$H/setsid"
  local -a want=(-f "$SELF" __roles-resets "$H/bin/tmux" proj "$PROJ" /clear a b.2)
  [ "${S[*]}" = "${want[*]}" ] && [ "${#S[@]}" -eq "${#want[@]}" ]
  [ "$(cat "$H/setsid.fds")" = "$(printf '/dev/null\n%s\nmade' "$log")" ]
  [[ "$output" == *"the host takes resets: an empty .asb/coord/to/ROLE.reset types /clear in that role's pane, then goes (log: $log)"* ]]
  [[ "$output" == *"To attach to it: tmux attach -t proj"* ]]
  # served roles: their loop takes the marker; a project without the inboxes: nothing to take
  rm -f "$H/setsid"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b --serve claude
  [ "$status" -eq 0 ]
  [ ! -e "$H/setsid" ] && [[ "$output" != *"takes resets"* ]]
  rm -r "$PROJ/.asb"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b claude
  [ "$status" -eq 0 ]
  [ ! -e "$H/setsid" ] && [[ "$output" != *"takes resets"* ]]
}

# stub_tmux_watched -- a tmux for the watcher: every call appended to $H/calls; has-session
# succeeds for its first $HAS_N calls; list-panes prints $H/panes.
stub_tmux_watched() {
  cat >"$H/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$1" in
  has-session)
    n=$(($(cat "$CALLS.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$CALLS.n"
    ((n <= HAS_N))
    ;;
  list-panes) cat "$PANES" ;;
esac
STUB
  chmod +x "$H/bin/tmux"
}

# resets ROLE... -- run the watcher for session `sess` of the project, as --roles starts it
resets() {
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" CALLS="$H/calls" PANES="$H/panes" HAS_N="${HAS_N:-1}" \
    "$ENGINE" __roles-resets "$H/bin/tmux" sess "$PROJ" /clear "$@" </dev/null
}

@test "the host side of --roles: a role's marker types /clear Enter in its pane and goes, a link removed and never followed; nothing for a role without one, nor for a marker with no pane; it ends when the session has gone" {
  stub_tmux_watched
  local to="$PROJ/.asb/coord/to"
  mkdir -p "$to"
  printf '%%1 a\n%%2 b\n%%3 c\n%%4 \n' >"$H/panes"
  : >"$to/a.reset"
  echo keep >"$H/victim"
  ln -s "$H/victim" "$to/b.reset"
  : >"$to/d.reset" # no pane is role d's
  resets a b c d
  [ "$status" -eq 0 ]
  local fmt='#{pane_id} #{@role}'
  local -a want=(
    "has-session -t =sess"
    "list-panes -s -t =sess -F $fmt"
    "send-keys -t %1 /clear Enter"
    "list-panes -s -t =sess -F $fmt"
    "send-keys -t %2 /clear Enter"
    "list-panes -s -t =sess -F $fmt"
    "has-session -t =sess"
  )
  mapfile -t C <"$H/calls"
  [ "$(printf '%s\n' "${C[@]}")" = "$(printf '%s\n' "${want[@]}")" ]
  [ ! -e "$to/a.reset" ] && [ ! -L "$to/b.reset" ]
  [ "$(cat "$H/victim")" = keep ]
  [ -e "$to/d.reset" ] # nobody took it: the Supervisor sees that
  [[ "$output" == *"role 'a': a reset marker -- typed /clear in pane %1, and removed the marker"* ]]
  [[ "$output" == *"role 'b': a reset marker -- typed /clear in pane %2, and removed the marker"* ]]
  [[ "$output" == *"tmux session 'sess' is gone; no more resets taken"* ]]
  # no session at all: one look, and it ends
  rm -f "$H/calls" "$H/calls.n"
  HAS_N=0 resets a
  [ "$status" -eq 0 ]
  [ "$(cat "$H/calls")" = "has-session -t =sess" ]
}

@test "the host side of --roles: a marker it cannot remove is typed for once, not at every second" {
  stub_tmux_watched
  local to="$PROJ/.asb/coord/to"
  mkdir -p "$to"
  printf '%%1 a\n' >"$H/panes"
  : >"$to/a.reset"
  chmod 555 "$to"
  HAS_N=3 resets a
  chmod 755 "$to"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send-keys' "$H/calls")" -eq 1 ]
  [ "$(grep -c '^has-session' "$H/calls")" -eq 4 ]
  [[ "$output" == *"--roles: could not remove $PROJ/.asb/coord/to/a.reset; no reset"* ]]
}
