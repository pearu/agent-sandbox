#!/usr/bin/env bats
# asb --roles ROLE... [ENGINE FLAGS] (#317, #320, #355): one tmux session, named after
# the project directory, with a pane per role, five to a window -- the first role of
# each window on top, the others in a row below -- each running `asb --role ROLE` with
# the rest of the engine words. There is no command: each pane resolves its role's agent
# from the approved dot-file, and carries `--agent AGENT` only when the line named that
# role's agent. A stub `tmux` first on the harness's PATH dumps its argv, one token per
# line, to $TMUX_DUMP, and answers `has-session` from $TMUX_HAS (set: a session of that
# name is open), so these assert on the command the engine builds; the layout tmux makes
# of it was measured with tmux 3.4.
# shellcheck disable=SC2016 # ${SHELL:-bash} and #{@role} are the pane's and tmux's, not ours

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  SELF="$(cd "$H/bin" && pwd -P)/asb"
  REC="$H/home/.config/agent-sandbox/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  TM="$H/tmux"
  stub_tmux "$H/bin/tmux"
  # every role's agent, from the project's file, approved
  agents '[agent]' 'command = claude'
}

# agents LINE... -- the project's .agent-sandbox is these lines, approved.
agents() {
  printf '%s\n' "$@" >"$PROJ/.agent-sandbox"
  engine_cmd
  (cd "$PROJ" && printf 'y\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
}

# two_profiles -- $H/profiles2: the claude profile and a stub `codex`, with a codex on
# PATH. CLEAR, when set, is the stub's [agent] clear; RESUME its [agent] resume, --last
# unless set (empty: none).
two_profiles() {
  mkdir -p "$H/profiles2/codex"
  ln -sfn "$REPO_ROOT/profiles/claude" "$H/profiles2/claude"
  printf 'profile_command=codex\n' >"$H/profiles2/codex/profile.sh"
  printf '[agent]\n' >"$H/profiles2/codex/agent-sandbox"
  [[ -z "${CLEAR:-}" ]] || printf 'clear = %s\n' "$CLEAR" >>"$H/profiles2/codex/agent-sandbox"
  [[ -z "${RESUME---last}" ]] || printf 'resume = %s\n' "${RESUME---last}" >>"$H/profiles2/codex/agent-sandbox"
  printf '#!/bin/sh\n' >"$H/bin/codex"
  chmod +x "$H/bin/codex"
  P2="AGENT_SANDBOX_PROFILE_DIR=$H/profiles2"
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

# run_pane CMD -- a pane's command, run as tmux would run it, but not at a terminal: the
# launch's argv in $H/argv and what it joined in JOINV, as run_engine sets them.
run_pane() {
  : >"$H/argv"
  : >"$H/join"
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm LANG=C.UTF-8 \
    BWRAP_DUMP="$H/argv" JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_SESSION_BASE="$H/base" AGENT_SANDBOX_SECCOMP_DIR="$H/no-such-seccomp" \
    AGENT_SANDBOX_PRESET=shared SHELL=true bash -c "cd $(printf '%q' "$PROJ") && $1" </dev/null
  mapfile -t JOIN <"$H/join"
  JOINV=()
  local i
  for ((i = 0; i < ${#JOIN[@]}; i++)); do
    [[ "${JOIN[i]}" == -- ]] && JOINV=("${JOIN[@]:i+1}") && break
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

@test "--roles, one role: one pane, its border showing the role, in the project, running --role ROLE with the engine words before and after and no agent word; not at a terminal, detached and the attach line printed" {
  run_engine TMUX_DUMP="$TM" -- asb --verbose --roles planner-1 --allow pypi.org
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n planner-1 -c "$PROJ" bash -c "$(window --role planner-1 --verbose --allow pypi.org)"
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
  run_engine TMUX_DUMP="$TM" -- asb --verbose --roles planner-1 rev.2 --allow pypi.org
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n planner-1 -c "$PROJ" bash -c "$(window --role planner-1 --verbose --allow pypi.org)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(titled planner-1 && split rev.2 --verbose --allow pypi.org && tail_of proj)
  same_argv
  [[ "$output" == *"a pane per role (planner-1 rev.2)"* ]]
}

@test "--roles, five roles: one window, the first role on top and four split below, each laid out again; the first window's top pane selected last" {
  run_engine TMUX_DUMP="$TM" -- asb --roles supervisor planner-1 implementer-1 reviewer-1 gate --resume
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n supervisor -c "$PROJ" bash -c "$(window --role supervisor --resume)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(
    titled supervisor
    for r in planner-1 implementer-1 reviewer-1 gate; do split "$r" --resume; done
    tail_of proj
  )
  same_argv
  [ "$(grep -cx new-window "$TM")" -eq 0 ] && [ "$(grep -cx split-window "$TM")" -eq 4 ]
  [ "$(grep -cx 'main-horizontal' "$TM")" -eq 4 ]
}

@test "--roles, six roles: the sixth starts a second window, named by it and laid out the same way" {
  run_engine TMUX_DUMP="$TM" -- asb --roles r1 r2 r3 r4 r5 r6
  [ "$status" -eq 0 ]
  local -a want=(
    new-session -d -s proj -n r1 -c "$PROJ" bash -c "$(window --role r1)"
    "${WINDOW_OPTS[@]}"
  )
  mapfile -t -O "${#want[@]}" want < <(
    titled r1
    for r in r2 r3 r4 r5; do split "$r"; done
    printf '%s\n' ";" new-window -n r6 -c "$PROJ" bash -c "$(window --role r6)" "${WINDOW_OPTS[@]}"
    titled r6
    tail_of proj
  )
  same_argv
  # eleven roles: three windows, named by the first, sixth and eleventh
  run_engine TMUX_DUMP="$TM" -- asb --roles r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11
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
  run_engine_tty '' TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[*]: -8}" = "; select-window -t =proj:^ ; select-pane -t =proj:^.{top}" ]
  [ "$(cat "$TM.attach")" = $'attach-session\n-t\n=proj' ]
  [[ "$output" != *"To attach to it"* ]]
  # not at a terminal: no attach
  rm -f "$TM.attach"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  [ ! -e "$TM.attach" ]
}

@test "--roles: the roles end at the first word that starts with -; --resume, --serve and the other engine words reach every pane, before or after the roles" {
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${#PC[@]}" -eq 2 ] && [ "${PC[0]}" = "$(window --role a)" ] && [ "${PC[1]}" = "$(window --role b)" ]
  # every pane takes --resume itself; the line opening them adds no resume words
  run_engine TMUX_DUMP="$TM" -- asb --allow pypi.org --roles a b --resume
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --allow pypi.org --resume)" ]
  [ "${PC[1]}" = "$(window --role b --allow pypi.org --resume)" ]
  run ! grep -qF -- --continue "$TM"
  # a served role in a pane: --serve is one of the words, and needs no --role here
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --serve
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --serve)" ] && [ "${PC[1]}" = "$(window --role b --serve)" ]
}

@test "--roles takes no command: a command or agent arguments after the engine words are refused, and a role word naming a profile is a misread agent (#355)" {
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --resume claude --model x
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles takes no command: name the agents with --agent or [agent:<glob>] command; native arguments go in command =, or asb --role ROLE CMD ARGS"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --allow x.org nosuch
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles takes no command"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"'claude' names an agent, not a role: --agent claude, or [agent:<glob>] command"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a "$H/bin/claude"
  [ "$status" -eq 2 ]
  [[ "$output" == *"names an agent, not a role"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --profile claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles takes no --profile: each role's agent names its profile"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles: [agent:a] command = claude -x gives a's pane no agent word; the pane, run, resolves claude -x from the file and records where (#355)" {
  agents '[agent]' 'command = claude' '[agent:a]' 'command = claude -x'
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a)" ] && [ "${PC[1]}" = "$(window --role b)" ]
  run_pane "${PC[0]}"
  [ "$status" -eq 0 ]
  [ "${JOINV[0]##*/}" = claude ] && [ "${JOINV[-1]}" = -x ] # after the briefing's own arguments
  local slug="${PROJ//[^A-Za-z0-9-]/-}"
  [ "$(cat "$H/home/.local/state/agent-sandbox/claude/$slug/a/agent")" = $'dotfile:[agent:a]\nclaude -x' ]
}

@test "--roles --agent: the role's form reaches its pane alone, as a bare --agent; a bare one reaches every pane (#355)" {
  two_profiles
  run_engine TMUX_DUMP="$TM" "$P2" -- asb --roles a b --agent b=codex --resume
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --resume)" ]
  [ "${PC[1]}" = "$(window --role b --agent codex --resume)" ]
  # a glob, the = form, and an exact role beating a bare form
  run_engine TMUX_DUMP="$TM" "$P2" -- asb --agent claude --roles a b1 b2 '--agent=b*=codex' --agent b2=claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --agent claude)" ]
  [ "${PC[1]}" = "$(window --role b1 --agent codex)" ]
  [ "${PC[2]}" = "$(window --role b2 --agent claude)" ]
  # a bare --agent: every pane
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --agent claude)" ] && [ "${PC[1]}" = "$(window --role b --agent claude)" ]
}

@test "--roles --agent: a role or glob matching none of the listed roles, two agents for one role, and an agent naming no profile are refused, and tmux is never called (#355)" {
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent z=claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"--agent z=claude: 'z' matches none of the roles --roles opens (a b); nothing was opened"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent 'q*=claude'
  [ "$status" -eq 2 ]
  [[ "$output" == *"'q*' matches none of the roles --roles opens"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent b=claude --agent b=other
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'b' is given two agents"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent b=nosuch
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'b': its agent 'nosuch' (named on the line) names no profile installed here"*"Nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles --account: the role's form reaches its pane alone, as a bare --account; a bare one every pane; the pane, run, binds the account; a file's account gives no pane a word (#355)" {
  local acc="$H/home/.local/state/agent-sandbox/claude/accounts"
  mkdir -p "$acc/x" "$acc/work"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --account b=x --resume
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --resume)" ]
  [ "${PC[1]}" = "$(window --role b --account x --resume)" ]
  run_pane "${PC[1]}"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2034 # read by argv_has (common.bash)
  mapfile -t ARGV <"$H/argv"
  argv_has --bind "$acc/x" "$H/home/.claude"
  # a bare one, a glob, '-' and the = form, with --agent beside them
  run_engine TMUX_DUMP="$TM" -- asb --account work --roles a b1 b2 '--account=b*=-' --account b2=x --agent b1=claude
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a --account work)" ]
  [ "${PC[1]}" = "$(window --role b1 --agent claude --account -)" ]
  [ "${PC[2]}" = "$(window --role b2 --account x)" ]
  # the file's account: the pane resolves it itself
  agents '[agent]' 'command = claude' 'account = work'
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  pane_cmds
  [ "${PC[0]}" = "$(window --role a)" ] && [ "${PC[1]}" = "$(window --role b)" ]
}

@test "--roles --account: a role matching none of the listed roles, an account missing for one role, and an account under --preset native are refused up front, and tmux is never called (#355)" {
  local acc="$H/home/.local/state/agent-sandbox/claude/accounts"
  mkdir -p "$acc/work"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --account z=work
  [ "$status" -eq 2 ]
  [[ "$output" == *"--account z=work: 'z' matches none of the roles --roles opens (a b); nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --account b=nosuch
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'nosuch' (--account): there is no $acc/nosuch for the agent claude: log it in with asb --agent claude --account nosuch --login"*"--roles: role 'b' cannot start; nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  agents '[agent]' 'command = claude' '[agent:b]' 'account = gone'
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'gone' (.agent-sandbox [agent:b] account): there is no $acc/gone"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --preset native --account b=work
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'b': the account 'work' (--account): --preset native binds no account's directory; --account b=- runs it on the base. Nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles: one role with no agent, or one whose agent cannot start, is refused up front, by name, and tmux is never called (#355)" {
  agents '[agent:a]' 'command = claude'
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: no agent for role 'b'. Name it on the line, --agent b=AGENT (or --agent AGENT for every role), or in .agent-sandbox, [agent:b] command = AGENT, or for every role: asb --apply '[agent]' 'command = claude'; nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  agents '[agent]' 'command = claude' '[agent:b]' 'command = nosuch'
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'b': its agent 'nosuch' (.agent-sandbox [agent:b]) names no profile installed here"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  # --resume, and a role whose agent's profile cannot resume
  RESUME="" two_profiles
  run_engine TMUX_DUMP="$TM" "$P2" -- asb --roles a b --agent b=codex --resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'b': --resume: profile 'codex' says nothing of how to resume a session ([agent] resume); nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  # a profile, but no binary to run
  rm "$H/bin/codex"
  run_engine TMUX_DUMP="$TM" "$P2" -- asb --roles a b --agent b=codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"no 'codex' on PATH to run. Install the agent, or name its binary for role 'b': --agent b=/path/to/codex, or in .agent-sandbox, [agent:b] command = /path/to/codex"*"--roles: role 'b' cannot start; nothing was opened"* ]]
  [[ "$output" != *"--profile"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  # an agent asb installs, not installed (#6): the line that installs it, as a launch says
  mv "${STUB_AGENT_DIR%/*}" "$H/install.away"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b --agent claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude is not installed for agent-sandbox: install it, asb --install claude"*"--roles: role 'a' cannot start; nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  mv "$H/install.away" "${STUB_AGENT_DIR%/*}"
  # no file at all: no agent for the first role
  rm "$PROJ/.agent-sandbox" "$REC" "$REC.approved"
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: no agent for role 'a'"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
  # two profiles installed, codex's command gone from PATH: the example names claude (#6)
  run_engine TMUX_DUMP="$TM" "$P2" -- asb --roles a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"or for every role: asb --apply '[agent]' 'command = claude'; nothing was opened"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles: the session name is the project directory's, with . and : made _" {
  mkdir -p "$H/my.pro:j"
  RUN_CWD="$H/my.pro:j" run_engine TMUX_DUMP="$TM" -- asb --roles a --agent claude
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[3]}" = my_pro_j ] && [ "${T[7]}" = "$(cd "$H/my.pro:j" && pwd -P)" ]
  [ "${T[*]: -8}" = "; select-window -t =my_pro_j:^ ; select-pane -t =my_pro_j:^.{top}" ]
}

@test "--roles: refused with no role, a role twice, a bad name, twice, with --role, a verb, --exec, a review" {
  run_engine TMUX_DUMP="$TM" -- asb --roles --resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles needs the roles to open: asb --roles ROLE... [ENGINE FLAGS]"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a b a
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: role 'a' is listed twice"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a 'b@x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles: 'b@x' is not a role name"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --roles a --roles b
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles is given once"* ]]
  run_engine TMUX_DUMP="$TM" -- asb --role x --roles a
  [ "$status" -eq 2 ]
  [[ "$output" == *"not combined with --role"* ]]
  local w
  for w in --status --shutdown --delete "--reset skills" --list --list-all --check --trust "--init roles" "--apply [allow] x.org" "--setup-remote qq"; do
    # shellcheck disable=SC2086 # the words of each
    run_engine TMUX_DUMP="$TM" -- asb --roles a $w
    [ "$status" -eq 2 ] || {
      echo "$w: $status $output"
      false
    }
    [[ "$output" == *"--roles opens a session of role launches; it is not combined with --exec, a verb or a review"* ]]
  done
  run_engine TMUX_DUMP="$TM" -- asb --roles a --exec bash
  [ "$status" -eq 2 ]
  [[ "$output" == *"not combined with --exec"* ]]
  # --summarize (#314) refuses first, in its own words, naming --roles
  run_engine TMUX_DUMP="$TM" -- asb --roles a --summarize
  [ "$status" -eq 2 ]
  [[ "$output" == *"--summarize runs one turn in a stopped role's sandbox; it is not combined with --exec, --serve, --roles, a verb or a review"* ]]
  [ ! -e "$TM" ] && [ ! -e "$TM.has" ]
}

@test "--roles is refused inside a sandbox" {
  # Inside is pid 1 being bubblewrap (_as_inside_sandbox), which a unit test cannot
  # arrange; the engine is sourced and that one test answered yes.
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" TMUX_DUMP="$TM" bash -c '
    cd "$1" && source "$2" && _as_inside_sandbox() { return 0; } && agent_sandbox --roles a
  ' _ "$PROJ" "$ENGINE" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--roles opens a tmux session on the host, and this is a sandbox"* ]]
  [ ! -e "$TM" ]
}

@test "--roles: a session of that name already open is refused, naming how to return to it and how to end it" {
  run_engine TMUX_DUMP="$TM" TMUX_HAS=1 -- asb --roles a b
  [ "$status" -eq 1 ]
  [[ "$output" == *"a tmux session named 'proj' is already open. To return to it: tmux attach -t proj"* ]]
  [[ "$output" == *"to end it, and every launch in it: tmux kill-session -t proj"* ]]
  [ ! -e "$TM" ] # nothing created
}

@test "--roles: no tmux on PATH nor in the tools env is refused, naming install.sh; the tools env's is used when the host has none" {
  no_tmux_path
  run_engine TMUX_DUMP="$TM" PATH="$NOTMUX" -- asb --roles a
  [ "$status" -eq 1 ]
  [[ "$output" == *"--roles opens its panes with tmux, and there is none: not on PATH, nor in the tools env. install.sh installs it there"* ]]
  [ ! -e "$TM" ]
  local tools="$H/home/.local/share/agent-sandbox/tools"
  stub_tmux "$tools/a/bin/tmux"
  ln -s a "$tools/current"
  run_engine TMUX_DUMP="$TM" PATH="$NOTMUX" -- asb --roles a
  [ "$status" -eq 0 ]
  mapfile -t T <"$TM"
  [ "${T[0]}" = new-session ] && [ "${T[10]}" = "$(window --role a)" ]
}

@test "--roles reviews an unapproved dot-file once, here, before the panes open; a pane's launch then starts without a review" {
  printf '[agent]\ncommand = claude\n[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  # no terminal: refused, nothing opened (every pane would ask)
  run_engine TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 1 ]
  [[ "$output" == *"--roles: .agent-sandbox needs your review, and there is no terminal here to ask at: run asb --trust first"* ]]
  [ ! -e "$TM" ]
  run ! cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
  # no at the terminal: nothing recorded, nothing opened
  run_engine_tty 'n\n' TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 1 ]
  [[ "$output" == *"not approved; --roles opens no panes."* ]]
  [ ! -e "$TM" ]
  run ! cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
  # yes: one review for both panes, recorded as a launch records it
  run_engine_tty 'y\n' TMUX_DUMP="$TM" -- asb --roles a b
  [ "$status" -eq 0 ]
  [ "$(grep -c 'approve this .agent-sandbox' <<<"$output")" -eq 1 ]
  [[ "$output" == *"[allow]"*"pypi.org"*"approved."* ]]
  cmp -s "$REC.approved" "$PROJ/.agent-sandbox"
  [ ! -s "$H/argv" ] # nothing launched from here
  # a pane's command, at a terminal of its own: it launches, and asks nothing
  pane_cmds
  local line="${PC[1]%; exec*}"
  [ "$line" = "$(printf '%q ' "$SELF" --role b | sed 's/ $//')" ]
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

@test "--roles starts the host side that takes resets once the session is made: setsid -f, the engine with __roles-resets, tmux, the session, the project and ROLE<TAB>KEYS per role; stdin /dev/null, its output to <state>/.roles-resets/<slug>.log" {
  stub_setsid
  mkdir -p "$PROJ/.asb/coord/to"
  local log
  log="$H/home/.local/state/agent-sandbox/.roles-resets/$(printf '%s' "$PROJ" | sed 's:[^A-Za-z0-9-]:-:g').log"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b.2 --resume
  [ "$status" -eq 0 ]
  mapfile -t S <"$H/setsid"
  local -a want=(-f "$SELF" __roles-resets "$H/bin/tmux" proj "$PROJ" $'a\t/clear' $'b.2\t/clear')
  [ "$(printf '%s\n' "${S[@]}")" = "$(printf '%s\n' "${want[@]}")" ]
  [ "$(cat "$H/setsid.fds")" = "$(printf '/dev/null\n%s\nmade' "$log")" ]
  [[ "$output" == *"the host takes resets: an empty .asb/coord/to/ROLE.reset types the role's fresh start (/clear) in that role's pane, then goes (log: $log)"* ]]
  [[ "$output" != *"no reset taken"* ]]
  [[ "$output" == *"To attach to it: tmux attach -t proj"* ]]
  # the log's directory is not a profile's: --list reads every profile's stores, and finds none
  [ -d "${log%/*}" ]
  run_engine -- asb --list-all
  [[ "$output" != *"roles-resets"* ]]
  # served roles: their loop takes the marker; a project without the inboxes: nothing to take
  rm -f "$H/setsid"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b --serve
  [ "$status" -eq 0 ]
  [ ! -e "$H/setsid" ] && [[ "$output" != *"takes resets"* ]]
  rm -r "$PROJ/.asb"
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" -- asb --roles a b
  [ "$status" -eq 0 ]
  [ ! -e "$H/setsid" ] && [[ "$output" != *"takes resets"* ]]
}

@test "--roles with mixed agents: each role's keys are its agent's profile's [agent] clear; a role whose profile has none is not watched, and the launch says so (#355)" {
  stub_setsid
  mkdir -p "$PROJ/.asb/coord/to"
  two_profiles
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" "$P2" -- asb --roles a b c --agent b=codex
  [ "$status" -eq 0 ]
  mapfile -t S <"$H/setsid"
  [ "$(printf '%s\n' "${S[@]:5}")" = "$(printf '%s\n' "$PROJ" $'a\t/clear' $'c\t/clear')" ]
  [[ "$output" == *"no reset taken for b: their agent's profile says nothing of a fresh start ([agent] clear); a fresh start there is yours to give"* ]]
  [[ "$output" == *"types the role's fresh start (/clear) in that role's pane"* ]]
  # a profile with keys of its own: per role
  rm -f "$H/setsid"
  CLEAR=/new two_profiles
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" "$P2" -- asb --roles a b --agent b=codex
  [ "$status" -eq 0 ]
  mapfile -t S <"$H/setsid"
  [ "$(printf '%s\n' "${S[@]:5}")" = "$(printf '%s\n' "$PROJ" $'a\t/clear' $'b\t/new')" ]
  [[ "$output" == *"types the role's fresh start (/clear, /new) in that role's pane"* ]]
  [[ "$output" != *"no reset taken"* ]]
  # no role with keys: no watcher, and every role named
  rm -f "$H/setsid"
  CLEAR="" two_profiles
  run_engine TMUX_DUMP="$TM" SETSID_DUMP="$H/setsid" "$P2" -- asb --roles a b --agent codex
  [ "$status" -eq 0 ]
  [ ! -e "$H/setsid" ]
  [[ "$output" == *"no reset taken for a b:"* ]] && [[ "$output" != *"takes resets"* ]]
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

# resets ROLE<TAB>KEYS... -- run the watcher for session `sess` of the project, as --roles starts it
resets() {
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" CALLS="$H/calls" PANES="$H/panes" HAS_N="${HAS_N:-1}" \
    "$ENGINE" __roles-resets "$H/bin/tmux" sess "$PROJ" "$@" </dev/null
}

@test "the host side of --roles: a role's marker types its keys and Enter in its pane and goes, a link removed and never followed; nothing for a role without one, nor for a marker with no pane; it ends when the session has gone" {
  stub_tmux_watched
  local to="$PROJ/.asb/coord/to"
  mkdir -p "$to"
  printf '%%1 a\n%%2 b\n%%3 c\n%%4 \n' >"$H/panes"
  : >"$to/a.reset"
  echo keep >"$H/victim"
  ln -s "$H/victim" "$to/b.reset"
  : >"$to/d.reset" # no pane is role d's
  resets $'a\t/clear' $'b\t/new' $'c\t/clear' $'d\t/clear'
  [ "$status" -eq 0 ]
  local fmt='#{pane_id} #{@role}'
  local -a want=(
    "has-session -t =sess"
    "list-panes -s -t =sess -F $fmt"
    "send-keys -t %1 /clear Enter"
    "list-panes -s -t =sess -F $fmt"
    "send-keys -t %2 /new Enter"
    "list-panes -s -t =sess -F $fmt"
    "has-session -t =sess"
  )
  mapfile -t C <"$H/calls"
  [ "$(printf '%s\n' "${C[@]}")" = "$(printf '%s\n' "${want[@]}")" ]
  [ ! -e "$to/a.reset" ] && [ ! -L "$to/b.reset" ]
  [ "$(cat "$H/victim")" = keep ]
  [ -e "$to/d.reset" ] # nobody took it: the Supervisor sees that
  [[ "$output" == *"role 'a': a reset marker -- typed /clear in pane %1, and removed the marker"* ]]
  [[ "$output" == *"role 'b': a reset marker -- typed /new in pane %2, and removed the marker"* ]]
  [[ "$output" == *"tmux session 'sess' is gone; no more resets taken"* ]]
  # no session at all: one look, and it ends
  rm -f "$H/calls" "$H/calls.n"
  HAS_N=0 resets $'a\t/clear'
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
  HAS_N=3 resets $'a\t/clear'
  chmod 755 "$to"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send-keys' "$H/calls")" -eq 1 ]
  [ "$(grep -c '^has-session' "$H/calls")" -eq 4 ]
  [[ "$output" == *"--roles: could not remove $PROJ/.asb/coord/to/a.reset; no reset"* ]]
}
