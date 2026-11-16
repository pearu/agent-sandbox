#!/usr/bin/env bats
# Symbolic links as the declarations they imply (#401), with the REAL bwrap and the claude
# profile: a link P -> T is `P = MODE outside:T`, approved with the dot-file's review (here
# `printf y | asb --trust`, as a launch without a terminal names it), asked again when new
# or changed, never read through before. A stub claude runs ./probe.sh from inside.

# shellcheck disable=SC2016 # the probe scripts and the inner shells expand their own
setup() {
  load "$BATS_TEST_DIRNAME/../../helpers/common"
  load "$BATS_TEST_DIRNAME/../../helpers/integration"
  require_bwrap
  I="$(mkdir -p "$BATS_TEST_TMPDIR/i" && cd "$BATS_TEST_TMPDIR/i" && pwd -P)"
  IHOME="$I/home"
  IWORK="$I/work"
  mkdir -p "$IHOME/.local/share/claude/versions/9.9.9" "$IWORK" "$IHOME/.claude" "$IHOME/dot/claude" "$IHOME/secret"
  cat >"$IHOME/.local/share/claude/versions/9.9.9/claude" <<'PROBE'
#!/usr/bin/env bash
bash "$PWD/probe.sh" >"$PWD/report" 2>&1
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  printf 'DOTFILE\n' >"$IHOME/dot/claude/CLAUDE.md"
  printf 'SECRET\n' >"$IHOME/secret/s"
  ln -s ../dot/claude/CLAUDE.md "$IHOME/.claude/CLAUDE.md"
  # read P, then try to write it
  printf '%s\n' 'p="$HOME/.claude/CLAUDE.md"' 'printf "read=%s\n" "$(cat "$p" 2>&1)"' \
    '(echo ROLE >>"$p") 2>/dev/null && echo write=ok || echo write=refused' >"$IWORK/probe.sh"
  TEST_PRESET=shared
}

# asb ARGS... -- the engine from the project, no terminal (stdin from /dev/null).
asb() {
  rm -f "$IWORK/report"
  engine_cmd
  local -a pre=()
  [[ -n "$TEST_PRESET" ]] && pre=(AGENT_SANDBOX_PRESET="$TEST_PRESET")
  run env -i HOME="$IHOME" PATH="${XPATH:+$XPATH:}/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" "${pre[@]}" ${XENV[@]+"${XENV[@]}"} \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" "$@"
}
claude_() { asb "$@" "$IHOME/.local/share/claude/versions/9.9.9/claude" probe; }
# trust_y [ANSWERS] -- asb --trust, ANSWERS (default: yes to every question) one per line
trust_y() {
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" \
    bash -c 'cd "$1" && printf "%s\n" $3 | "$2" --trust 2>&1' _ "$IWORK" "$REPO_ROOT/agent-sandbox" "${1:-y y y y y y y y}"
}
rpt() { cat "$IWORK/report" 2>/dev/null; }
# claude_tty ANSWER ARGS... -- claude_ at a terminal (script(1)), ANSWER typed at the question.
claude_tty() {
  local a="$1"
  shift
  rm -f "$IWORK/report"
  engine_cmd
  printf '%s\n' "$a" >"$I/answer"
  printf '%q ' env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none AGENT_SANDBOX_SESSION_BASE="$I/base" \
    AGENT_SANDBOX_PRESET="$TEST_PRESET" "${ENGINE_CMD[@]}" "$@" "$IHOME/.local/share/claude/versions/9.9.9/claude" probe >"$I/tty.sh"
  run bash -c 'cd "$1" && script -qec "bash $2" /dev/null <"$3"' _ "$IWORK" "$I/tty.sh" "$I/answer"
}
# no_secret -- nothing of ~/secret/s was read into the state or session directories
no_secret() {
  local -a d=()
  local x
  for x in "$IHOME/.local/state" "$I/base" "$IHOME/.claude"; do [ ! -e "$x" ] || d+=("$x"); done
  run grep -rl SECRET "${d[@]}"
  [ "$status" -eq 1 ] || printf 'secret in: %s\n' "$output" >&3 # 1: nothing found (2: an error)
  [ "$status" -eq 1 ]
}

refused_for_link() { # what a launch without a terminal says, and that nothing ran
  [ "$status" -ne 0 ] && [[ "$output" == *"is reached through a symbolic link"* ]] || printf '%s\n' "$output" | tail -5 >&3
  [ "$status" -ne 0 ]
  [[ "$output" == *"is reached through a symbolic link"* ]]
  [[ "$output" == *"review it with: "*"--trust"* ]]
  [ ! -e "$IWORK/report" ]
}

@test "the dotfiles case (~/.claude/CLAUDE.md -> ../dot/claude/CLAUDE.md) under shared: refused until approved, then read and written through with the channel's mode" {
  claude_
  refused_for_link
  [[ "$output" == *"= read-write outside:~/dot/claude/CLAUDE.md'"* ]]
  trust_y
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$output" == *"implied by symbolic links"* ]]
  [[ "$output" == *"~/.claude/CLAUDE.md = read-write outside:~/dot/claude/CLAUDE.md"* ]]
  [[ "$output" == *"~/.claude/CLAUDE.md -> ../dot/claude/CLAUDE.md"* ]]
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"*"write=ok"* ]]
  [ "$(tail -1 "$IHOME/dot/claude/CLAUDE.md")" = ROLE ]
  [ "$(readlink "$IHOME/.claude/CLAUDE.md")" = ../dot/claude/CLAUDE.md ] # the user's link stays
}

@test "the dotfiles case under inherit: a copy of the dotfile, written in the copy only" {
  TEST_PRESET=inherit
  claude_
  refused_for_link
  [[ "$output" == *"= copy outside:~/dot/claude/CLAUDE.md'"* ]]
  trust_y
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"*"write=ok"* ]]
  [ "$(cat "$IHOME/dot/claude/CLAUDE.md")" = DOTFILE ]
}

@test "the dotfiles case under isolated: the role's own file, nothing of the dotfile, no question" {
  TEST_PRESET=isolated
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" != *DOTFILE* ]]
  [[ "$(rpt)" == *"write=ok"* ]]
  [ "$(cat "$IHOME/dot/claude/CLAUDE.md")" = DOTFILE ]
}

@test "the dotfiles case under the default preset (inherit): refused until approved, then a copy" {
  TEST_PRESET=""
  claude_
  refused_for_link
  [[ "$output" == *"= copy outside:~/dot/claude/CLAUDE.md'"* ]]
  trust_y
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"* ]]
  [ "$(cat "$IHOME/dot/claude/CLAUDE.md")" = DOTFILE ]
}

@test "the dotfiles case with an account: refused until approved, then read" {
  mkdir -p "$IHOME/.local/state/agent-sandbox/claude/accounts/work"
  claude_ --account work
  refused_for_link
  trust_y
  claude_ --account work
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"* ]]
}

@test "a linked directory (skills), a linked cache with its changelog, and a chain are read once approved (the linked cache/ itself needs a second review: its changelog is all the first one lists)" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/dot/skills" "$IHOME/dot/cache"
  printf 'MY-SKILL\n' >"$IHOME/dot/skills/s.md"
  printf 'CHANGES\n' >"$IHOME/dot/cache/changelog.md"
  ln -s ../dot/skills "$IHOME/.claude/skills"
  ln -s ../dot/cache "$IHOME/.claude/cache"
  ln -s ../dot/a "$IHOME/.claude/CLAUDE.md"
  ln -s claude/CLAUDE.md "$IHOME/dot/a"
  printf '%s\n' 'cat "$HOME/.claude/skills/s.md" "$HOME/.claude/cache/changelog.md" "$HOME/.claude/CLAUDE.md"' >"$IWORK/probe.sh"
  claude_
  refused_for_link
  trust_y
  [[ "$output" == *"~/.claude/skills = read-write outside:~/dot/skills"* ]]
  [[ "$output" == *"~/dot/a -> claude/CLAUDE.md"* ]]
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = $'MY-SKILL\nCHANGES\nDOTFILE' ]
}

@test "a link to what the role already sees asks nothing; a declaration of your own for the path sets the mode" {
  mv "$IHOME/.claude/CLAUDE.md" "$IHOME/CLAUDE.md.lnk"
  mkdir -p "$IWORK/sub"
  printf 'INSIDE\n' >"$IWORK/sub/f"
  ln -s sub/f "$IWORK/l"
  printf '%s\n' 'cat "$PWD/l"' >"$IWORK/probe.sh"
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = INSIDE ]
}

@test "a dot-file declaration for the linked path sets the mode; the approval is of the mode shown, and another mode is asked again" {
  claude_
  refused_for_link
  trust_y
  [[ "$output" == *"~/.claude/CLAUDE.md = read-write outside:~/dot/claude/CLAUDE.md"* ]]
  printf '[connect]\n~/.claude/CLAUDE.md = read-only\n' >"$IWORK/.agent-sandbox"
  printf '%s\n' 'p="$HOME/.claude/CLAUDE.md"' 'printf "read=%s\n" "$(cat "$p" 2>&1)"' \
    '(echo ROLE >>"$p") 2>/dev/null && echo write=ok || echo write=refused' >"$IWORK/probe.sh"
  trust_y # the dot-file's own question
  [[ "$output" == *"approve this .agent-sandbox for"* ]]
  claude_ # the link was approved read-write; read-only is another line
  refused_for_link
  [[ "$output" == *"'~/.claude/CLAUDE.md = read-only outside:~/dot/claude/CLAUDE.md'"* ]]
  claude_tty y
  [[ "$output" == *"~/.claude/CLAUDE.md = read-only outside:~/dot/claude/CLAUDE.md"* ]]
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"*"write=refused"* ]]
}

@test "a path declaration's source through a link is refused until approved, then read" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'REAL\n' >"$IHOME/dot/real.md"
  ln -s dot/real.md "$IHOME/src.md"
  printf '%s\n' 'cat "$PWD/x.md"' >"$IWORK/probe.sh"
  claude_ --connect './x.md = read-only outside:~/src.md'
  refused_for_link
  trust_y
  claude_ --connect './x.md = read-only outside:~/src.md'
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = REAL ]
}

@test "a link in the project to a path outside is found by the --trust scan, not at a launch; approved, it is read" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'ENV\n' >"$IHOME/dot/envrc"
  ln -s "$IHOME/dot/envrc" "$IWORK/.envrc"
  printf '%s\n' 'cat "$PWD/.envrc" 2>/dev/null || echo none' >"$IWORK/probe.sh"
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = none ] # not known to the launch: it leads nowhere inside
  trust_y
  [[ "$output" == *"$(printf '%s' "${IWORK/#$IHOME/\~}")/.envrc = read-write outside:~/dot/envrc"* ]]
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = ENV ]
}

@test "a link the role plants at a missing channel path (shared): the next launch refuses without a terminal, reads nothing through it; --check lists it; at a terminal, no refuses and yes launches" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf '%s\n' 'ln -s ../secret/s "$HOME/.claude/CLAUDE.md"; echo planted' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = planted ]
  [ "$(readlink "$IHOME/.claude/CLAUDE.md")" = ../secret/s ]
  printf '%s\n' 'cat "$HOME/.claude/CLAUDE.md"' >"$IWORK/probe.sh"
  claude_
  refused_for_link
  [[ "$output" == *"'~/.claude/CLAUDE.md = read-write outside:~/secret/s'"* ]]
  [[ "$output" != *SECRET* ]]
  no_secret
  asb --check
  [[ "$output" == *"~/.claude/CLAUDE.md = read-write outside:~/secret/s"* ]]
  [[ "$output" == *"implied declaration(s) new or changed"* ]]
  claude_tty n
  [ "$status" -ne 0 ]
  [[ "$output" == *"approve this link for"* ]]
  [ ! -e "$IWORK/report" ]
  no_secret
  claude_tty y
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = SECRET ] # the user said yes: as declared
}

@test "an approved link retargeted, by anyone, is asked about again" {
  claude_
  refused_for_link
  trust_y
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  rm "$IHOME/.claude/CLAUDE.md"
  ln -s ../secret/s "$IHOME/.claude/CLAUDE.md"
  claude_
  refused_for_link
  no_secret
}

@test "a link the role plants at a missing channel path in the base, the next launch on an account: refused without a terminal, nothing read" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/.local/state/agent-sandbox/claude/accounts/work" "$IHOME/secretdir"
  printf 'SECRET\n' >"$IHOME/secretdir/s"
  printf '%s\n' 'ln -s ../secret/s "$HOME/.claude/CLAUDE.md"; ln -s ../secretdir "$HOME/.claude/agents"; echo planted' >"$IWORK/probe.sh"
  claude_
  [ "$(rpt)" = planted ]
  printf '%s\n' 'cat "$HOME/.claude/CLAUDE.md" "$HOME/.claude/agents/s"' >"$IWORK/probe.sh"
  claude_ --account work
  [ "$status" -ne 0 ]
  [ ! -e "$IWORK/report" ]
  [[ "$output" == *"the agents channel"*"not supported through a symbolic link"*"github.com/pearu/agent-sandbox/issues"* ]] # (C)
  no_secret
  rm "$IHOME/.claude/agents"
  claude_ --account work
  refused_for_link
  [[ "$output" == *"outside:~/secret/s'"* ]]
  no_secret
}

@test "a link the role puts in place of a source it sees: refused, the path is fixed (EBUSY)" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'MINE\n' >"$IHOME/.claude/CLAUDE.md"
  printf '%s\n' '{ rm -f "$HOME/.claude/CLAUDE.md" && ln -s ../secret/s "$HOME/.claude/CLAUDE.md"; } 2>&1; echo done' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"Device or resource busy"* ]]
  [ "$(cat "$IHOME/.claude/CLAUDE.md")" = MINE ]
}

@test "a link the role plants at a missing source (a copy outside: in the project): the next launch refuses, nothing copied through it" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf '%s\n' 'ln -s "$HOME/secret/s" src.md; echo planted' >"$IWORK/probe.sh"
  claude_ --connect "./n.md = copy outside:$IWORK/src.md"
  [ "$(rpt)" = planted ]
  printf '%s\n' 'cat n.md' >"$IWORK/probe.sh"
  claude_ --connect "./n.md = copy outside:$IWORK/src.md"
  refused_for_link
  [[ "$output" == *"= copy outside:~/secret/s'"* ]]
  no_secret
}

@test "a link the role plants inside a read-write directory (skills): it leads nowhere at the next launch; the --trust scan lists it" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/.claude/skills"
  printf '%s\n' 'ln -s "$HOME/secret" "$HOME/.claude/skills/x"; echo planted' >"$IWORK/probe.sh"
  claude_
  [ "$(rpt)" = planted ]
  printf '%s\n' 'cat "$HOME/.claude/skills/x/s" 2>&1 || echo none' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *none* ]]
  [[ "$(rpt)" != *SECRET* ]]
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" \
    bash -c 'cd "$1" && printf "n\n" | "$2" --trust 2>&1' _ "$IWORK" "$REPO_ROOT/agent-sandbox"
  [[ "$output" == *"~/.claude/skills/x = read-write outside:~/secret"* ]]
}

@test "the approval is where no role sees it: the record is on the host, and neither readable nor writable from inside" {
  claude_
  refused_for_link
  trust_y
  local rec
  rec="$(ls "$IHOME/.config/agent-sandbox/trust/"*.links)"
  [ -s "$rec" ]
  printf '%s\n' "cat '$rec' >/dev/null 2>&1 && echo read=yes || echo read=no" \
    "(echo X >>'$rec') 2>/dev/null && echo write=yes || echo write=no" >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = $'read=no\nwrite=no' ]
  run grep -c X "$rec"
  [ "$output" = 0 ]
}

@test "native is unchanged: the link is followed as without a sandbox, nothing asked, nothing recorded" {
  TEST_PRESET=""
  asb --preset native "$IHOME/.local/share/claude/versions/9.9.9/claude" probe
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [[ "$(rpt)" == *"read=DOTFILE"*"write=ok"* ]]
  [[ "$output" != *"symbolic link"* ]]
  run bash -c 'find "$1" -name "*.links*" 2>/dev/null' _ "$IHOME/.config"
  [ -z "$output" ]
}

@test "a link to what the role already sees, read-only included, implies nothing: not listed, no extra bind, the role has the target's access (A)" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IWORK/ro"
  printf 'P\n' >"$IWORK/ro/p.md"
  printf '[connect]\nproject = read-write\n./ro/p.md = read-only\n' >"$IWORK/.agent-sandbox"
  trust_y
  printf '%s\n' 'ln -s .agent-sandbox x; ln -s ro/p.md y; ln -s /usr/bin/env py; echo planted' >"$IWORK/probe.sh"
  claude_
  [ "$(rpt)" = planted ]
  trust_y
  [[ "$output" != *"implied by symbolic links"* ]]
  [[ "$output" != *"approve this link"* ]]
  printf '%s\n' '(echo HACK >>x) 2>/dev/null && echo x=written || echo x=refused' \
    '(echo HACK >>y) 2>/dev/null && echo y=written || echo y=refused' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ]
  [ "$(rpt)" = $'x=refused\ny=refused' ]
  [ "$(cat "$IWORK/ro/p.md")" = P ]
  run grep -c HACK "$IWORK/.agent-sandbox"
  [ "$output" = 0 ]
}

@test "one question per link: the dot-file approved and the link declined -- the dot-file holds, the link is not approved; each question names the declaration that skips it (B)" {
  claude_ # the link: refused without a terminal, kept for --trust to ask
  refused_for_link
  printf '[allow]\nexample.org\n' >"$IWORK/.agent-sandbox"
  trust_y 'y n'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'approve this .agent-sandbox for' <<<"$output")" -eq 1 ]
  [ "$(grep -c 'approve this link for' <<<"$output")" -eq 1 ] || {
    printf "%s\n" "$output" >&3
    false
  }
  [[ "$output" == *"to be asked no more, declare it yourself in .agent-sandbox under [connect]: ~/.claude/CLAUDE.md = read-write outside:~/dot/claude/CLAUDE.md"* ]]
  claude_
  refused_for_link # the link only: the dot-file is approved
  [[ "$output" != *"never been approved"* ]]
  # the declaration the question names: written, it asks nothing
  printf '[allow]\nexample.org\n[connect]\n~/.claude/CLAUDE.md = read-write outside:~/dot/claude/CLAUDE.md\n' >"$IWORK/.agent-sandbox"
  trust_y 'y n'
  printf '%s\n' 'cat "$HOME/.claude/CLAUDE.md"' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = DOTFILE ]
  trust_y n # nothing pending any more: that launch found no implied declaration there
  [[ "$output" != *"approve this link"* ]]
}

@test "a declaration you wrote whose source is the link's target asks nothing, under shared, inherit and isolated (B)" {
  printf '%s\n' 'cat "$HOME/.claude/CLAUDE.md"' >"$IWORK/probe.sh"
  local p
  for p in shared inherit isolated; do
    TEST_PRESET=$p
    # shellcheck disable=SC2088 # the declaration's own ~
    claude_ --connect '~/.claude/CLAUDE.md = read-only outside:~/dot/claude/CLAUDE.md'
    [ "$status" -eq 0 ] || {
      printf "%s: %s\n" "$p" "$output" | tail -5 >&3
      false
    }
    [ "$(rpt)" = DOTFILE ]
  done
  run bash -c 'find "$1" -name "*.links" 2>/dev/null' _ "$IHOME/.config"
  [ -z "$output" ] # nothing approved: nothing needed it
}

@test "a link that stands for what a written outside: may not name is refused as that declaration is: a secret store, the trust store, the home (G)" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/.ssh" "$IHOME/.config/agent-sandbox"
  printf 'KEY\n' >"$IHOME/.ssh/id"
  printf '%s\n' 'cat "$HOME/.claude/skills/id" "$HOME/.claude/skills/.ssh/id" 2>&1; echo ran' >"$IWORK/probe.sh"
  local t
  for t in ../.ssh ../.config/agent-sandbox ..; do
    rm -f "$IHOME/.claude/skills"
    ln -s "$t" "$IHOME/.claude/skills"
    claude_
    [ "$status" -ne 0 ]
    [ ! -e "$IWORK/report" ]
    [[ "$output" == *"~/.claude/skills is reached through a symbolic link"*"as written that is refused, so the link is: refusing 'outside:"* ]]
    trust_y
    [[ "$output" != *"approve this link"* ]]
    run find "$IHOME/.config/agent-sandbox" -name '*.links'
    [ -z "$output" ]
  done
}

@test "the bind source is the target the check resolved, never the link: a retarget between the check and the mount changes nothing (H)" {
  mkdir -p "$I/wbin"
  # a bwrap that keeps its argument file (fd 11, --args) and runs the real one
  printf '%s\n' '#!/bin/bash' \
    "if [ -e /proc/self/fd/11 ]; then /usr/bin/cat <&11 >'$I/args'; exec /usr/bin/bwrap \"\$@\" 11<'$I/args'; fi" \
    'exec /usr/bin/bwrap "$@"' >"$I/wbin/bwrap"
  chmod +x "$I/wbin/bwrap"
  local p
  for p in shared inherit; do
    TEST_PRESET=$p
    claude_
    trust_y
    rm -f "$I/args"
    XPATH="$I/wbin" claude_
    [ "$status" -eq 0 ] || {
      printf "%s\n" "$output" | tail -5 >&3
      false
    }
    [ -s "$I/args" ]
    run grep -zxcF "$IHOME/.claude/CLAUDE.md" "$I/args"
    [ "$output" = 0 ] # the link path is no argument at all: not a source, not a destination
    [[ "$(rpt)" == *"read=DOTFILE"* ]]
  done
}

@test "a channel the profile does not support through a link is refused, naming the link and inviting a feature request: settings.json, plugins, agents, projects, the base's .claude.json, and the project's .agent-sandbox (C)" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/dot2"
  printf 'echo ran\n' >"$IWORK/probe.sh"
  local n
  for n in settings.json plugins agents projects; do
    if [[ "$n" == *.json ]]; then printf '{}\n' >"$IHOME/dot2/$n"; else mkdir -p "$IHOME/dot2/$n"; fi
    rm -rf "${IHOME:?}/.claude/$n" # (an earlier refused launch may have made projects/)
    ln -s "../dot2/$n" "$IHOME/.claude/$n"
    claude_
    [ "$status" -ne 0 ] || {
      printf '%s launched: %s\n' "$n" "$output" >&3
      false
    }
    [ ! -e "$IWORK/report" ]
    [[ "$output" == *"channel) is reached through the symbolic link ~/.claude/$n -> ../dot2/$n, and this location is not supported through a symbolic link"*"https://github.com/pearu/agent-sandbox/issues"* ]] || {
      printf '%s: %s\n' "$n" "$output" | tail -3 >&3
      false
    }
    [ "$(readlink "$IHOME/.claude/$n")" = "../dot2/$n" ] # the user's link left as it is
    rm "$IHOME/.claude/$n"
  done
  printf '{}\n' >"$IHOME/dot2/cj"
  ln -s dot2/cj "$IHOME/.claude.json"
  claude_
  [ "$status" -ne 0 ]
  [[ "$output" == *"(the config channel) is reached through the symbolic link ~/.claude.json -> dot2/cj, and this location is not supported"* ]]
  rm "$IHOME/.claude.json"
  printf '[allow]\nexample.org\n' >"$IHOME/dot2/as"
  ln -s "$IHOME/dot2/as" "$IWORK/.agent-sandbox"
  trust_y
  claude_
  [ "$status" -ne 0 ]
  [ ! -e "$IWORK/report" ]
  [[ "$output" == *"(the project's dot-file) is reached through the symbolic link"*"not supported through a symbolic link"* ]]
}

@test "a linked agent base (~/.claude -> dot/claude-base) is refused, naming CLAUDE_CONFIG_DIR for a base that lives elsewhere; set, it launches on that base (O)" {
  rm "$IHOME/.claude/CLAUDE.md"
  mv "$IHOME/.claude" "$IHOME/dot/claude-base"
  printf 'BASEMD\n' >"$IHOME/dot/claude-base/CLAUDE.md"
  ln -s dot/claude-base "$IHOME/.claude"
  printf '%s\n' 'cat "$CLAUDE_CONFIG_DIR/CLAUDE.md"' >"$IWORK/probe.sh"
  local p
  for p in shared inherit isolated; do
    TEST_PRESET=$p
    claude_
    [ "$status" -ne 0 ]
    [ ! -e "$IWORK/report" ]
    [[ "$output" == *"its base ~/.claude is reached through a symbolic link (~/.claude -> dot/claude-base), and a linked base is not supported. For a base that lives elsewhere, set CLAUDE_CONFIG_DIR to it"*"https://github.com/pearu/agent-sandbox/issues"* ]] || {
      printf '%s: %s\n' "$p" "$output" >&3
      false
    }
  done
  rm "$IHOME/.claude"
  TEST_PRESET=shared
  XENV=(CLAUDE_CONFIG_DIR="$IHOME/dot/claude-base")
  claude_
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = BASEMD ]
}

@test "a scan-approved project link retargeted is left unbound and pending for the next review: the launch goes on without a terminal; a new channel link under --serve at a terminal refuses, asking nothing" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'ENV\n' >"$IHOME/dot/envrc"
  ln -s "$IHOME/dot/envrc" "$IWORK/.envrc"
  printf '%s\n' 'cat "$PWD/.envrc" 2>/dev/null || echo none' >"$IWORK/probe.sh"
  printf '[serve:r]\nwatch = ./inbox\nprompt = ./p.md\n' >"$IWORK/.agent-sandbox"
  mkdir -p "$IWORK/inbox"
  printf 'go\n' >"$IWORK/p.md"
  trust_y
  claude_ --role r --connect 'project = read-write'
  trust_y
  claude_ --role r --connect 'project = read-write'
  [ "$(rpt)" = ENV ]
  rm "$IWORK/.envrc"
  ln -s ../secret/s "$IHOME/dot/s2" # a chain, to the secret
  ln -s "$IHOME/dot/s2" "$IWORK/.envrc"
  claude_ --role r --connect 'project = read-write'
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = none ] # it leads nowhere inside
  no_secret
  trust_y n
  [[ "$output" == *"/.envrc = read-write outside:~/secret/s"* ]]
  # a new link on a channel path still refuses; --serve at a terminal does not ask
  ln -s ../secret/s "$IHOME/.claude/CLAUDE.md"
  claude_tty y --role r --serve --connect 'project = read-write'
  [ ! -e "$IWORK/report" ] # (--serve itself ends with its launch, exit 0)
  [[ "$output" != *"approve this link"* ]]
  [[ "$output" == *"review it with: "*"--trust"* ]] || {
    printf '%s\n' "$output" >&3
    false
  }
  no_secret
}

@test "a link with a newline in its target cannot be shown for approval: refused" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/dot/a"$'\n'"b"
  printf 'X\n' >"$IHOME/dot/a"$'\n'"b/CLAUDE.md"
  ln -s "../dot/a"$'\n'"b/CLAUDE.md" "$IHOME/.claude/CLAUDE.md"
  claude_
  [ "$status" -ne 0 ]
  [[ "$output" == *"has a tab or a newline in its name or target, which cannot be shown for approval"* ]]
  [ ! -e "$IWORK/report" ]
}

@test "under an account, a missing channel source in the base behind a link is not made through it" {
  rm "$IHOME/.claude/CLAUDE.md"
  mkdir -p "$IHOME/.local/state/agent-sandbox/claude/accounts/work" "$IHOME/elsewhere"
  ln -s ../elsewhere "$IHOME/.claude/cache" # the changelog channel's cache/changelog.md, read-write under shared
  printf 'echo ran\n' >"$IWORK/probe.sh"
  claude_ --account work
  [ ! -e "$IHOME/elsewhere/changelog.md" ] # not made through the link (_as_base_rw_sources)
}

@test "an approved scan-found link is resolved again at every launch: a directory on its way that another role replaced by a link leaves it unbound, nothing read or written through it" {
  rm "$IHOME/.claude/CLAUDE.md"
  TEST_PRESET=inherit
  mkdir -p "$IHOME/data/sub"
  printf 'DATA\n' >"$IHOME/data/sub/f"
  printf 'SECRET\n' >"$IHOME/secret/f"
  printf '[connect:b]\n~/data/ = read-write\n[connect:a]\n' >"$IWORK/.agent-sandbox"
  ln -s "$IHOME/data/sub/f" "$IWORK/x"
  printf '%s\n' 'cat x 2>/dev/null || echo none' >"$IWORK/probe.sh"
  trust_y
  claude_ --role a
  claude_ --role b
  trust_y
  [[ "$output" == *"/x = read-write outside:~/data/sub/f"* ]]
  claude_ --role a
  [ "$status" -eq 0 ]
  [ "$(rpt)" = DATA ]
  # role b, which has ~/data read-write, puts a link to the secret on x's way
  printf '%s\n' 'mv ~/data/sub ~/data/sub.old && ln -s ~/secret ~/data/sub && echo swapped' >"$IWORK/probe.sh"
  claude_ --role b
  [ "$(rpt)" = swapped ]
  printf '%s\n' 'cat x 2>/dev/null || echo none' '(echo ROLE-A >>x) 2>/dev/null && echo write=ok || echo write=refused' >"$IWORK/probe.sh"
  claude_ --role a
  [ "$status" -eq 0 ] || {
    printf "%s\n" "$output" | tail -5 >&3
    false
  }
  [ "$(rpt)" = "none"$'\n'"write=refused" ] || {
    rpt >&3
    false
  }
  [ "$(cat "$IHOME/secret/f")" = SECRET ]
  # pending for the next review, as it now resolves
  trust_y n
  [[ "$output" == *"/x = read-write outside:~/secret/f"* ]]
  [[ "$output" == *"~/data/sub -> ~/secret"* ]] || [[ "$output" == *"/data/sub -> "*"/secret"* ]]
}

@test "a path declaration's copy, seed-only and copy-on-write read the source as the check resolved it: a link flipped around the bind-time readlink -f copies, seeds and hashes nothing of its other target" {
  rm "$IHOME/.claude/CLAUDE.md"
  TEST_PRESET=inherit
  mkdir -p "$IHOME/data" "$I/rl"
  printf 'DATA\n' >"$IHOME/data/f"
  printf 'SECRET\n' >"$IHOME/secret/f"
  ln -s "$IHOME/data" "$IWORK/lnk"
  # a readlink that, for every `readlink -f` of the link, points it at the secret for that
  # call and back: only a resolution other than the check's sees the secret
  printf '%s\n' '#!/bin/bash' \
    'if [[ -z "$RL_PERSIST" && " $* " == *" -f "* && "${@: -1}" == "$RL_LNK" ]]; then' \
    '  good="$(/usr/bin/readlink -- "$RL_LNK")"; ln -sfn "$RL_EVIL" "$RL_LNK"; /usr/bin/readlink "$@"; rc=$?' \
    '  ln -sfn "$good" "$RL_LNK"; : >"$RL_LNK.flipped"; exit $rc' \
    'fi' \
    'if [[ -n "$RL_PERSIST" && " $* " != *" -f "* && " $* " == *" $RL_LNK "* && ! -e "$RL_LNK.flipped" ]]; then' \
    '  /usr/bin/readlink "$@"; rc=$?; ln -sfn "$RL_EVIL" "$RL_LNK"; : >"$RL_LNK.flipped"; exit $rc' \
    'fi' 'exec /usr/bin/readlink "$@"' >"$I/rl/readlink"
  chmod +x "$I/rl/readlink"
  printf '%s\n' 'cat view/f' >"$IWORK/probe.sh"
  local m
  for m in copy seed-only copy-on-write; do
    rm -rf "${IHOME:?}/.local/state" "$IWORK/lnk.flipped"
    printf '[connect]\n./view/ = %s outside:%s\n' "$m" "$IWORK/lnk" >"$IWORK/.agent-sandbox"
    XPATH="" XENV=()
    trust_y
    claude_
    trust_y
    XPATH="$I/rl" XENV=(RL_LNK="$IWORK/lnk" RL_EVIL="$IHOME/secret")
    claude_
    [ "$status" -eq 0 ] || {
      printf "%s: %s\n" "$m" "$output" | tail -5 >&3
      false
    }
    [ -e "$IWORK/lnk.flipped" ] # the wrapper did flip it
    [ "$(rpt)" = DATA ] || {
      printf '%s: %s\n' "$m" "$(rpt)" >&3
      false
    }
    # (the overlay's work directories are unreadable: grep says 2 for them, and still
    # prints every file it found)
    [ -d "$IHOME/.local/state/agent-sandbox" ]
    run grep -rls SECRET "$IHOME/.local/state" "$I/base"
    [ -z "$output" ] || {
      printf '%s: secret in %s\n' "$m" "$output" >&3
      false
    }
    # the copy-on-write record of what it shadows names the data's file, not the secret's
    if [[ "$m" == copy-on-write ]]; then
      run grep -rls --include='*.json' '"f"' "$IHOME/.local/state"
      [ -n "$output" ]
      run grep -rls --include='*.json' '"s"' "$IHOME/.local/state"
      [ -z "$output" ]
    fi
    # the link left pointing at the secret right after the check read it: the read
    # still uses what the check resolved (the later full pass sees the change and
    # refuses the launch, which is not what this checks)
    rm -rf "${IHOME:?}/.local/state" "$IWORK/lnk.flipped"
    XPATH="$I/rl" XENV=(RL_LNK="$IWORK/lnk" RL_EVIL="$IHOME/secret" RL_PERSIST=1)
    claude_
    [ -e "$IWORK/lnk.flipped" ]
    [ "$(readlink "$IWORK/lnk")" = "$IHOME/secret" ]
    [ -d "$IHOME/.local/state/agent-sandbox" ]
    run grep -rls SECRET "$IHOME/.local/state" "$I/base"
    [ -z "$output" ] || {
      printf '%s (persist): secret in %s\n' "$m" "$output" >&3
      false
    }
    ln -sfn "$IHOME/data" "$IWORK/lnk"
  done
}
