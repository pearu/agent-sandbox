#!/usr/bin/env bats
# Symbolic links as the declarations they imply (#401), with the REAL bwrap and the claude
# profile: a link P -> T is `P = MODE outside:T`, approved with the dot-file's review (here
# `printf y | asb --trust`, as a launch without a terminal names it), asked again when new
# or changed, never read through before. A stub claude runs ./probe.sh from inside.

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
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" "${pre[@]}" \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" "$@"
}
claude_() { asb "$IHOME/.local/share/claude/versions/9.9.9/claude" probe "$@"; }
trust_y() {
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" \
    bash -c 'cd "$1" && printf "y\n" | "$2" --trust 2>&1' _ "$IWORK" "$REPO_ROOT/agent-sandbox"
}
rpt() { cat "$IWORK/report" 2>/dev/null; }

refused_for_link() { # what a launch without a terminal says, and that nothing ran
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
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [[ "$output" == *"implied by symbolic links"* ]]
  [[ "$output" == *"~/.claude/CLAUDE.md = read-write outside:~/dot/claude/CLAUDE.md"* ]]
  [[ "$output" == *"~/.claude/CLAUDE.md -> ../dot/claude/CLAUDE.md"* ]]
  claude_
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
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
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [[ "$(rpt)" == *"read=DOTFILE"*"write=ok"* ]]
  [ "$(cat "$IHOME/dot/claude/CLAUDE.md")" = DOTFILE ]
}

@test "the dotfiles case under isolated and the default preset: the role's own file, nothing of the dotfile, no question" {
  local p
  for p in isolated ""; do
    TEST_PRESET="$p"
    claude_
    [ "$status" -eq 0 ]
    [[ "$(rpt)" != *DOTFILE* ]]
    [ "$(cat "$IHOME/dot/claude/CLAUDE.md")" = DOTFILE ]
  done
}

@test "the dotfiles case with an account: refused until approved, then read" {
  mkdir -p "$IHOME/.local/state/agent-sandbox/claude/accounts/work"
  claude_ --account work
  refused_for_link
  trust_y
  claude_ --account work
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [[ "$(rpt)" == *"read=DOTFILE"* ]]
}

@test "a linked directory (skills), a linked cache with its changelog, and a chain are read after one approval" {
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
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = $'MY-SKILL\nCHANGES\nDOTFILE' ]
}

@test "a link to what the role already sees asks nothing; a declaration of your own for the path sets the mode" {
  mkdir -p "$IWORK/sub"
  printf 'INSIDE\n' >"$IWORK/sub/f"
  ln -s sub/f "$IWORK/l"
  printf '%s\n' 'cat "$PWD/l"' >"$IWORK/probe.sh"
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = INSIDE ]
  printf '[connect]\n~/.claude/CLAUDE.md = read-only\n' >"$IWORK/.agent-sandbox"
  printf '%s\n' 'p="$HOME/.claude/CLAUDE.md"' 'printf "read=%s\n" "$(cat "$p" 2>&1)"' \
    '(echo ROLE >>"$p") 2>/dev/null && echo write=ok || echo write=refused' >"$IWORK/probe.sh"
  trust_y
  [[ "$output" == *"~/.claude/CLAUDE.md = read-only outside:~/dot/claude/CLAUDE.md"* ]]
  claude_
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
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
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = REAL ]
}

@test "a link in the project to a path outside is found by the --trust scan, not at a launch; approved, it is read" {
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'ENV\n' >"$IHOME/dot/envrc"
  ln -s "$IHOME/dot/envrc" "$IWORK/.envrc"
  printf '%s\n' 'cat "$PWD/.envrc" 2>/dev/null || echo none' >"$IWORK/probe.sh"
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = none ] # not known to the launch: it leads nowhere inside
  trust_y
  [[ "$output" == *"$(printf '%s' "${IWORK/#$IHOME/\~}")/.envrc = read-write outside:~/dot/envrc"* ]]
  claude_ --connect 'project = read-write'
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = ENV ]
}

@test "a link the role plants, or retargets, in the base is refused at the next launch without a terminal, nothing read through it; --check lists it" {
  printf '%s\n' 'rm -f "$HOME/.claude/CLAUDE.md"; ln -s ../secret/s "$HOME/.claude/CLAUDE.md"; echo planted' >"$IWORK/probe.sh"
  rm "$IHOME/.claude/CLAUDE.md"
  printf 'MINE\n' >"$IHOME/.claude/CLAUDE.md"
  claude_
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = planted ]
  [ "$(readlink "$IHOME/.claude/CLAUDE.md")" = ../secret/s ]
  printf '%s\n' 'cat "$HOME/.claude/CLAUDE.md"' >"$IWORK/probe.sh"
  claude_
  refused_for_link
  [[ "$output" == *"outside:~/secret/s'"* ]]
  [[ "$output" != *SECRET* ]]
  asb --check
  [[ "$output" == *"~/.claude/CLAUDE.md = read-write outside:~/secret/s"* ]]
  # approved, then retargeted: asked again
  trust_y
  ln -sfn ../dot/claude/CLAUDE.md "$IHOME/.claude/CLAUDE.md"
  ln -sfn ../secret/s "$IHOME/.claude/CLAUDE.md"
  rm "$IHOME/.claude/CLAUDE.md"
  ln -s ../secret/../secret/s "$IHOME/.claude/CLAUDE.md"
  claude_
  refused_for_link
}

@test "the approval is where no role sees it: the trust store is not in the sandbox" {
  claude_
  refused_for_link
  trust_y
  printf '%s\n' 'ls -A "$HOME/.config/agent-sandbox" 2>/dev/null | head -1; echo end' >"$IWORK/probe.sh"
  claude_
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [ "$(rpt)" = end ]
}

@test "native is unchanged: the link is followed as without a sandbox, nothing asked" {
  TEST_PRESET=""
  asb --preset native "$IHOME/.local/share/claude/versions/9.9.9/claude" probe
  [ "$status" -eq 0 ] || { printf "%s\n" "$output" | tail -5 >&3; false; }
  [[ "$(rpt)" == *"read=DOTFILE"* ]]
}
