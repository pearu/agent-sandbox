#!/usr/bin/env bats
# State isolation: the parts of the agent's state directory that are keyed by
# session rather than by project, and so leaked across projects even with
# memory scoping on. Measured on one machine: 40M of verbatim file contents in
# file-history, every prompt ever typed in history.jsonl.
#
# The stub bwrap doubles as the agent here: it writes into what the engine bound at
# file-history/, plans/, history.jsonl and responses.log, which is exactly what a
# session would do. Since #120 those are the role's own stores (`transcripts`,
# `logs`), and nothing is merged back into the native state when the launch ends.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  C="$H/home/.claude"
  mkdir -p "$C/file-history/OTHER-SESSION" "$C/plans" "$C/paste-cache" "$C/session-env"
  # what another project's session left behind
  printf 'SECRET FROM ANOTHER PROJECT\n' >"$C/file-history/OTHER-SESSION/deadbeef@v1"
  printf '# another project plan\n' >"$C/plans/other.md"
  printf '{"display":"mine","project":"%s"}\n' "$PROJ" >"$C/history.jsonl"
  printf '{"display":"THEIRS","project":"/home/someone/other"}\n' >>"$C/history.jsonl"
  printf 'old response from another session\n' >"$C/responses.log"
  for f in history.jsonl responses.log; do cp "$C/$f" "$H/$f.before"; done
}

# the SOURCE bound at DEST, from the recorded argv
bound_at() {
  local i
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    if [[ "${ARGV[i]}" == --bind && "${ARGV[i + 2]}" == "$1" ]]; then
      printf '%s' "${ARGV[i + 1]}"
      return 0
    fi
  done
  return 1
}

# an "agent" that writes into whatever the engine bound at those paths
agent_writes() {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
set +x
if [[ "${1:-}" == --help ]]; then printf '    --overlay RWSRC WORKDIR DEST Mount overlayfs on DEST\n'; exit 0; fi
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
args=("$@")
for ((i = 0; i + 2 < ${#args[@]}; i++)); do
  [[ "${args[i]}" == --bind ]] || continue
  src="${args[i + 1]}" dest="${args[i + 2]}"
  case "$dest" in
    "$HOME/.claude/file-history" | "$HOME/.claude/plans") mkdir -p "$src/MY-SESSION" && printf 'mine\n' >"$src/MY-SESSION/new@v1" ;;
    "$HOME/.claude/history.jsonl" | "$HOME/.claude/responses.log") printf 'A NEW LINE\n' >>"$src" ;;
  esac
done
. "${0%/*}/keeper-tail"
STUB
  chmod +x "$H/bin/bwrap"
}

@test "the per-launch parts are tmpfs; the rest are the role's stores, never the host's own paths" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  local d
  for d in session-env sessions jobs shell-snapshots debug paste-cache; do
    argv_has --tmpfs "$C/$d"
  done
  local p
  for p in file-history plans history.jsonl responses.log alerts.log; do
    [[ "$(bound_at "$C/$p")" == "$H/home/.local/state/agent-sandbox/claude/"*/default/* ]]
    run ! argv_has --bind "$C/$p" "$C/$p"
  done
}

@test "canary: another session's file contents, plans and prompts are not in what the role gets" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run ! grep -rq 'SECRET FROM ANOTHER PROJECT' "$(bound_at "$C/file-history")"
  run ! grep -rq 'another project plan' "$(bound_at "$C/plans")"
  run ! grep -q THEIRS "$(bound_at "$C/history.jsonl")"
  grep -q 'SECRET FROM ANOTHER PROJECT' "$C/file-history/OTHER-SESSION/deadbeef@v1" # the host's is untouched
}

@test "what the session writes stays in the role: nothing is merged back into the native state" {
  agent_writes
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$C/file-history/MY-SESSION" ]
  [ ! -e "$C/plans/MY-SESSION" ]
  cmp "$C/history.jsonl" "$H/history.jsonl.before"
  cmp "$C/responses.log" "$H/responses.log.before"
  # ...and it persists in the role's stores for the next launch
  [ -f "$(bound_at "$C/file-history")/MY-SESSION/new@v1" ]
  grep -q 'A NEW LINE' "$(bound_at "$C/history.jsonl")"
  [ -z "$(ls -A "$H/base")" ] # and the launch directory is gone
}

# ---- [claude] hide, and what is hidden by default -------------------------

trust_proj() { # record approval of $PROJ/.agent-sandbox the way --trust would
  local t="$H/home/.config/agent-sandbox/trust"
  mkdir -p "$t"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$t/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "daemon/ is hidden by default; gh/ and ide/ are not" {
  mkdir -p "$C/daemon" "$C/gh" "$C/ide"
  printf 'control-key\n' >"$C/daemon/control.key"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  # the supervisor's control key and session roster: a cross-session control
  # channel with no in-sandbox use
  argv_has --tmpfs "$C/daemon"
  # both of these exist to make Claude Code work from inside a sandbox, so
  # hiding them by default would break the feature they were created for
  run ! argv_has --tmpfs "$C/gh"
  run ! argv_has --tmpfs "$C/ide"
}

@test "[claude] hide blanks the named paths, but only from an approved dot-file" {
  mkdir -p "$C/gh" "$C/ide"
  printf '[claude]\nhide = gh ide\n' >"$PROJ/.agent-sandbox"

  # unapproved: the section grants nothing
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"present but not approved"* ]]
  run ! argv_has --tmpfs "$C/gh"

  trust_proj
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$C/gh"
  argv_has --tmpfs "$C/ide"
  argv_has --tmpfs "$C/daemon" # the default still applies alongside
}

@test "[claude] hide refuses to escape the state directory, and warns on unknown keys" {
  printf '[claude]\nhide = ../../etc /etc gh\nbogus = 1\n' >"$PROJ/.agent-sandbox"
  trust_proj
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"must be a relative path"* ]]
  [[ "$output" == *"unknown [claude] key"* ]]
  run ! argv_has --tmpfs /etc
  run ! grep -q '\.\./\.\./etc' "$H/argv"
  argv_has --tmpfs "$C/gh" # the valid entry on the same line still applies
}

@test "a section named for another profile is ignored, not applied" {
  mkdir -p "$C/gh"
  printf '[codex]\nhide = gh\n' >"$PROJ/.agent-sandbox"
  trust_proj
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unknown section [codex]"* ]]
  run ! argv_has --tmpfs "$C/gh"
}

@test "the sandbox runs as the invoking user, and identically in every network mode" {
  # strict runs bwrap inside pasta's user namespace, where the caller is already
  # mapped to root; without an explicit --uid the same sandbox would report uid 0
  # there and the real uid in every other mode. Nothing about the network should
  # change who the payload is, so this asserts the invariant across all of them --
  # the cross-mode check whose absence let the two drift apart.
  # strict is covered end to end in tests/integration/strict.bats instead: it
  # needs pasta and nft, so the engine refuses before building any argv when they
  # are absent -- as on the CI runners, where this loop failed while passing on a
  # host that has them.
  local mode
  for mode in none proxy open; do
    run_engine AGENT_SANDBOX_NET="$mode" -- asb claude --version
    [ "$status" -eq 0 ]
    argv_has --uid "$(id -u)" --gid "$(id -g)"
  done
}
