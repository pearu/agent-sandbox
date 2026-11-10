#!/usr/bin/env bats
# What installs an agent asb installs, besides `asb --install` (#6, D9, D10), and what a
# launch says of the version it runs (D8):
#   - `--agent AGENT --account NAME --login` installs the pin first, before the account's directory
#     is made, so a failed download leaves nothing; installed, it downloads nothing
#   - a launch at a terminal with nothing installed asks once, y/N, naming the size and
#     host the resolver gives; y installs and launches, anything else refuses with the
#     line that installs it; with no terminal it refuses at once, never asking
#   - the version on the launch line, `running V, pinned W` when it is not the pin; in
#     the role's store (--status, --list) and the keeper's policy (a join, the busy
#     refusal after a switch)
# The claude profile is a copy whose resolver is the fake one of tests/unit/install.bats,
# reading a fake release source, $SRC/VERSION/{asset,sum,size}, from file://; nothing
# here reaches the network.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  ST="$H/home/.local/state/agent-sandbox"
  I="$ST/claude/install"
  ACC="$ST/claude/accounts"
  P="$H/profiles"
  SRC="$H/src"
  mkdir -p "$P" "$SRC"
  cp -a "$REPO_ROOT/profiles/claude" "$P/claude"
  printf '2.1.300\n2.1.321 pinned\n' >"$P/claude/versions"
  cat >"$P/claude/resolve.sh" <<'EOF'
#!/usr/bin/env bash
v="$1" base="${3:?no BASE}"
d="${base#file://}/$v"
[[ -f "$d/sum" ]] || { echo "fake resolve.sh: no release $v" >&2; exit 1; }
: >"$d/resolved"
printf 'file://%s/asset\t%s\t%s\n' "$d" "$(cat "$d/sum")" "$(cat "$d/size" 2>/dev/null)"
EOF
  chmod +x "$P/claude/resolve.sh"
  # the harness's installed stub, as the release's asset; then nothing installed
  cp "$STUB_AGENT_DIR/claude" "$H/stub-agent"
  rm -rf "$I"
  release 2.1.321
  release 2.1.300
  release 9.9.9
  KNOBS=(AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_INSTALL_BASE="$SRC")
  REFUSAL="agent-sandbox: claude is not installed for agent-sandbox: install it, asb --install claude"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

# release VERSION -- the source's VERSION: the stub agent as its asset, its SHA-256, size.
release() {
  mkdir -p "$SRC/$1"
  cp "$H/stub-agent" "$SRC/$1/asset"
  sha256sum "$SRC/$1/asset" | cut -d' ' -f1 >"$SRC/$1/sum"
  stat -c %s "$SRC/$1/asset" >"$SRC/$1/size"
}

# asb_install WORDS... -- asb --install WORDS, from the fake source.
asb_install() {
  run_engine "${KNOBS[@]}" -- asb --install "$@"
  [ "$status" -eq 0 ]
}

# ---- --login installs first ----

@test "--login on an agent not installed: its pin installed first, saying size and host, then the account made and logged in" {
  run_engine "${KNOBS[@]}" -- asb --agent claude --account work --login
  # 1: the stub join logs nothing in, so the account has no login file afterwards
  [ "$status" -eq 1 ]
  [[ "$output" == *"--login: the account 'work' of claude has no login: there is no ~/.local/state/agent-sandbox/claude/accounts/work/.credentials.json" ]]
  [ "$(readlink "$I/current")" = 2.1.321 ]
  [ -x "$I/2.1.321/claude" ]
  [ -f "$SRC/2.1.321/resolved" ]
  [ -d "$ACC/work" ]
  [[ "$output" == *"agent-sandbox: --login: claude is not installed for agent-sandbox; installing its pinned version first
agent-sandbox: --install: downloading claude 2.1.321 for $(uname -m)-gnu, 0 MB, from file://$SRC/2.1.321/asset
agent-sandbox: --install: claude 2.1.321 is installed at ~/.local/state/agent-sandbox/claude/install/2.1.321/claude, and is now claude's current version
agent-sandbox: --login: made ~/.local/state/agent-sandbox/claude/accounts/work, the account 'work' of claude"* ]]
  # the login ran the installed agent
  [ "${JOINV[0]}" = "$I/2.1.321/claude" ]
}

@test "--login: a failed download leaves nothing, no account directory, no install; the login does not run" {
  printf '%064d\n' 0 >"$SRC/2.1.321/sum"
  run_engine "${KNOBS[@]}" -- asb --agent claude --account work --login
  [ "$status" -eq 1 ]
  [[ "$output" == *"--install: the SHA-256 of file://$SRC/2.1.321/asset is "*"; nothing installed"* ]]
  [[ "$output" != *"made "* ]]
  [ ! -e "$ACC" ]
  [ ! -e "$I/current" ]
  [ -z "$(find "$I" -mindepth 1 2>/dev/null)" ]
  [ ! -e "$H/home/.cache/agent-sandbox" ]
  [ ! -s "$H/argv" ]
}

@test "--login on an installed agent downloads nothing; a broken current is not mended: refused (2) with nothing made" {
  asb_install claude@2.1.300
  rm -r "$SRC"
  mkdir -p "$ACC/work"
  printf 'WORK-LOGIN\n' >"$ACC/work/.credentials.json" # a re-login, the stub logging nothing in
  run_engine "${KNOBS[@]}" -- asb --agent claude --account work --login
  [ "$status" -eq 0 ]
  [[ "$output" != *"installing"* ]]
  [[ "$output" != *"--install:"* ]]
  [ "$(readlink "$I/current")" = 2.1.300 ]
  [ "${JOINV[0]}" = "$I/2.1.300/claude" ]
  ln -sfn ../.. "$I/current"
  run_engine "${KNOBS[@]}" -- asb --agent claude --account other --login
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/current points at '../..', which is not a version beside it): install it, asb --install claude" ]
  [ "$(readlink "$I/current")" = ../.. ]
  [ ! -e "$ACC/other" ]
  [ ! -s "$H/argv" ]
}

# ---- a launch with the agent not installed ----

@test "a launch at a terminal, not installed: asked once with size and host; y installs the pin and launches it" {
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: claude is not installed for agent-sandbox; looking up claude 2.1.321, its pinned version..."* ]]
  [[ "$output" == *"agent-sandbox: install claude 2.1.321 (0 MB from file://$SRC/2.1.321/asset)? [y/N] "* ]]
  [ "$(grep -c 'install claude 2.1.321 (' <<<"$output")" -eq 1 ]
  # the launch's own messages, not --install's
  [[ "$output" == *"agent-sandbox: claude 2.1.321 is installed at ~/.local/state/agent-sandbox/claude/install/2.1.321/claude, and is now claude's current version"* ]]
  [[ "$output" != *"--install:"* ]]
  [ "$(readlink "$I/current")" = 2.1.321 ]
  argv_has --ro-bind "$I/2.1.321" "$I/2.1.321"
}

@test "a launch at a terminal, a version there but no current: asked to make it current; y links it and launches, no resolver run; n refuses" {
  mkdir -p "$I/2.1.321"
  cp "$H/stub-agent" "$I/2.1.321/claude"
  run_engine_tty 'n
' "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: make claude 2.1.321, installed already at ~/.local/state/agent-sandbox/claude/install/2.1.321 (no download), claude's current version? [y/N] "* ]]
  [[ "$output" == *"$REFUSAL"* ]]
  [ ! -e "$I/current" ]
  [ ! -s "$H/argv" ]
  run_engine_tty 'y
' "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude 2.1.321 is installed already at ~/.local/state/agent-sandbox/claude/install/2.1.321/claude (no download), and is now claude's current version"* ]]
  [ "$(readlink "$I/current")" = 2.1.321 ]
  [ ! -e "$SRC/2.1.321/resolved" ]
  argv_has --ro-bind "$I/2.1.321" "$I/2.1.321"
}

@test "a launch at a terminal inside a sandbox (AGENT_SANDBOX=1): never asked, the plain refusal" {
  run_engine_tty 'y
' AGENT_SANDBOX=1 "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" == *"$REFUSAL"* ]]
  [ ! -e "$SRC/2.1.321/resolved" ]
  [ ! -e "$I" ]
}

@test "the question comes after the launch's own checks: a dot-file review answered no asks nothing more and installs nothing" {
  printf '[allow]\nexample.org\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'n\ny\n' "${KNOBS[@]}" -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"approve this .agent-sandbox"* ]]
  [[ "$output" != *"install claude"* ]]
  [ ! -e "$SRC/2.1.321/resolved" ]
  [ ! -e "$I" ]
  [ ! -s "$H/argv" ]
}

@test "at a terminal, --summarize and --serve never ask: the plain refusal, not a download before their own refusal" {
  local w
  for w in "--summarize claude" "--role r --serve claude"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine_tty 'y\n' "${KNOBS[@]}" -- asb $w
    [ "$status" -eq 1 ]
    [[ "$output" != *"[y/N]"* ]]
    [[ "$output" == *"$REFUSAL"* ]]
    [ ! -e "$SRC/2.1.321/resolved" ]
    [ ! -e "$I" ]
  done
}

@test "at a terminal, --roles with an agent not installed refuses up front, never asking; nothing opens" {
  # a tmux that must never be reached (and never the default socket)
  printf '#!/bin/sh\necho "tmux called: $*" >>"%s/tmux.log"\nexit 1\n' "$H" >"$H/bin/tmux"
  chmod +x "$H/bin/tmux"
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb --roles a b --agent claude
  [ "$status" -eq 1 ]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" == *"$REFUSAL"* ]]
  [[ "$output" == *"--roles: role 'a' cannot start; nothing was opened"* ]]
  [ ! -e "$H/tmux.log" ]
  [ ! -e "$I" ]
}

@test "a launch at a terminal, not installed: n (or nothing) refuses with the line that installs it; nothing is made" {
  local a
  for a in 'n\n' '\n' ''; do
    run_engine_tty "$a" "${KNOBS[@]}" -- asb claude --version
    [ "$status" -eq 1 ]
    [[ "$output" == *"install claude 2.1.321 (0 MB from file://$SRC/2.1.321/asset)? [y/N] "* ]]
    [[ "$output" == *"$REFUSAL"* ]]
    [ ! -e "$I/current" ]
    [ ! -e "$I/2.1.321" ]
    [ ! -s "$H/argv" ]
  done
}

@test "a launch with no terminal, not installed: refused at once, never asked, nothing resolved or made" {
  run_engine "${KNOBS[@]}" -- asb claude -p hi </dev/null
  [ "$status" -eq 1 ]
  [ "$output" = "$REFUSAL" ]
  [ ! -e "$SRC/2.1.321/resolved" ]
  [ ! -e "$I" ]
  [ ! -s "$H/argv" ]
}

@test "at a terminal, --exec, a verb, --status and --shutdown never ask: they refuse as before" {
  local w
  for w in "--profile claude --exec true" "claude agents" "--status claude" "--shutdown claude"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine_tty 'y\n' "${KNOBS[@]}" -- asb $w
    [ "$status" -eq 1 ]
    [[ "$output" != *"[y/N]"* ]]
    [[ "$output" != *"looking up"* ]]
    [[ "$output" == *"$REFUSAL"* ]]
    [ ! -e "$I/current" ]
    [ ! -e "$SRC/2.1.321/resolved" ]
  done
}

@test "at a terminal, a broken current is never mended by the question: refused, naming it" {
  mkdir -p "$I/2.1.321"
  ln -s 2.1.321 "$I/current" # a version directory without the binary
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" == *"claude is not installed for agent-sandbox (~/.local/state/agent-sandbox/claude/install/2.1.321 has no executable claude): install it, asb --install claude"* ]]
  [ ! -e "$SRC/2.1.321/resolved" ]
}

# ---- the version: launch line, record, --status, --list, join ----

@test "the launch line names the version: the pin with --verbose only; running V, pinned W always; untested for one not in the table" {
  asb_install claude
  run_engine "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 0 ]
  grep -qxF "agent-sandbox: agent: claude 2.1.321" <<<"$output"
  run_engine "${KNOBS[@]}" AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent: claude"* ]]
  asb_install claude@2.1.300
  run_engine "${KNOBS[@]}" AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: agent: claude, running 2.1.300, pinned 2.1.321 (asb --install claude moves to the pin)"* ]]
  asb_install claude@9.9.9
  run_engine "${KNOBS[@]}" AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: agent: claude, running 9.9.9 (untested with asb), pinned 2.1.321 (asb --install claude moves to the pin)"* ]]
  # an agent named by its path has no version said
  run_engine "${KNOBS[@]}" -- asb --profile claude "$H/stub-agent" --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent: claude"* ]]
}

@test "the version is recorded in the role's store per launch: --status says it, stopped and running; --list shows it" {
  asb_install claude@2.1.300
  run_engine "${KNOBS[@]}" -- asb claude --version
  [ "$status" -eq 0 ]
  local sb="$ST/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
  [ "$(cat "$sb/version")" = "claude"$'\t'"2.1.300" ]
  run_engine "${KNOBS[@]}" -- asb --status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"  version: claude, running 2.1.300, pinned 2.1.321"* ]]
  run_engine "${KNOBS[@]}" -- asb --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude 2.1.300, base"* ]]
  asb_install claude
  engine_bg "${KNOBS[@]}" -- asb claude --version
  run_engine "${KNOBS[@]}" -- asb --status claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"running since"*"  version: claude 2.1.321"* ]]
  release_bg
  [ "$(cat "$sb/version")" = "claude"$'\t'"2.1.321" ]
  # a launch by path records no version
  run_engine "${KNOBS[@]}" -- asb --profile claude "$H/stub-agent" --version
  [ "$(cat "$sb/version")" = "claude"$'\t' ]
  run_engine "${KNOBS[@]}" -- asb --status claude
  [[ "$output" != *"version:"* ]]
}

@test "a join says the running role's version; a busy role refuses a launch after --install moved current, naming both versions" {
  asb_install claude
  engine_bg "${KNOBS[@]}" -- asb claude --version
  run_engine "${KNOBS[@]}" -- asb claude -p again
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-sandbox: agent: claude 2.1.321, the running role's"* ]]
  asb_install claude@2.1.300
  run_engine "${KNOBS[@]}" -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'default' is running with agent = $I/2.1.321/claude (claude 2.1.321), and this launch's agent asks for '$I/2.1.300/claude' (claude 2.1.300). A running role's policy cannot change"* ]]
  [ ! -s "$H/join" ]
  release_bg
}

@test "a join whose keeper's version row is not a version says no version line, and joins" {
  asb_install claude
  engine_bg "${KNOBS[@]}" -- asb claude --version
  local pol="$ST/claude/${PROJ//[^A-Za-z0-9-]/-}/default/keeper/policy"
  # shellcheck disable=SC2016 # the row's text, literally
  sed -i 's|^version\t[^\t]*\t|version\t../evil $(x)\t|' "$pol"
  grep -q '^version	\.\./evil' "$pol"
  run_engine "${KNOBS[@]}" -- asb claude -p again
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent: claude"* ]]
  [[ "$output" != *evil* ]]
  [ -s "$H/join" ]
  release_bg
}

@test "at a terminal, a launch whose account is refused is refused for that first: no question, no not-installed line" {
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb --account nosuch claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"the account 'nosuch' (--account): there is no "*"log it in with asb --agent claude --account nosuch --login"* ]]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" != *"is not installed"* ]]
  [ ! -e "$SRC/2.1.321/resolved" ]
  [ ! -e "$I" ]
}

@test "at a terminal, a launch that would join a live keeper asks nothing: the plain refusal" {
  asb_install claude@2.1.300
  engine_bg "${KNOBS[@]}" -- asb claude --version
  rm "$I/current"
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb claude -p again
  [ "$status" -eq 1 ]
  [[ "$output" != *"[y/N]"* ]]
  [[ "$output" == *"$REFUSAL"* ]]
  [ ! -e "$SRC/2.1.321/resolved" ]
  [ ! -e "$I/current" ]
  release_bg
}

@test "--preset none at a terminal is asked even while the default role's keeper is live (none has no keeper)" {
  asb_install claude@2.1.300
  engine_bg "${KNOBS[@]}" -- asb claude --version
  rm "$I/current"
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb --preset none claude --version
  [ "$status" -eq 0 ]
  [ "$(grep -c 'install claude 2.1.321 (' <<<"$output")" -eq 1 ]
  [ "$(readlink "$I/current")" = 2.1.321 ]
  release_bg
}

@test "--preset none at a terminal, not installed: asked once; y installs and runs it with no sandbox" {
  run_engine_tty 'y\n' "${KNOBS[@]}" -- asb --preset none claude --version
  [ "$status" -eq 0 ]
  [ "$(grep -c 'install claude 2.1.321 (' <<<"$output")" -eq 1 ]
  [[ "$output" == *"stub-agent argv: --version"* ]]
  [ "$(readlink "$I/current")" = 2.1.321 ]
}
