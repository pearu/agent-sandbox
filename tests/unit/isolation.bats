#!/usr/bin/env bats
# State isolation: the parts of the agent's state directory that are keyed by
# session rather than by project, and so leaked across projects even with
# memory scoping on. Measured on one machine: 40M of verbatim file contents in
# file-history, every prompt ever typed in history.jsonl.
#
# The stub bwrap doubles as the agent here: it writes into the staged
# directories the engine bound, which is exactly what a session would do, so
# the copy-out and append-back paths are exercised for real.

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
}

# an "agent" that writes into whatever the engine staged for it
agent_writes() {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
iso="$(echo "$AGENT_SANDBOX_SESSION_BASE"/session.*/iso)"
[ -d "$iso" ] || exit 0
for d in "$iso"/*file-history "$iso"/*plans; do
  [ -d "$d" ] && mkdir -p "$d/MY-SESSION" && printf 'mine\n' >"$d/MY-SESSION/new@v1"
done
for f in "$iso"/*history.jsonl "$iso"/*responses.log; do
  [ -f "$f" ] && printf 'A NEW LINE\n' >>"$f"
done
exit 0
STUB
  chmod +x "$H/bin/bwrap"
}

@test "the leaky parts are replaced: discarded ones by a tmpfs, the rest by empty staging" {
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  local d
  for d in session-env sessions jobs shell-snapshots debug paste-cache; do
    argv_has --tmpfs "$C/$d"
  done
  # copyout and append are bound from the session dir, never from the host path
  local i
  i="$(argv_index "$C/file-history")"
  [[ "${ARGV[i - 1]}" == "$H/base"/session.*/iso/* ]]
  i="$(argv_index "$C/history.jsonl")"
  [[ "${ARGV[i - 1]}" == "$H/base"/session.*/iso/* ]]
  # nothing binds the host's own copies through
  ! argv_has --bind "$C/file-history" "$C/file-history"
  ! argv_has --bind "$C/history.jsonl" "$C/history.jsonl"
}

@test "canary: another session's file contents and plans are not in what the session gets" {
  agent_writes
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  # what was bound over file-history/ and plans/ is empty of the other session
  local iso
  iso="$(echo "$H/base"/session.*/iso)" # (removed by cleanup; check via the copy-back instead)
  # the canary is still on the host, but nothing of it was ever staged:
  ! grep -rq 'SECRET FROM ANOTHER PROJECT' "$H/base" 2>/dev/null
  ! grep -rq 'another project plan' "$H/base" 2>/dev/null
  # ...and the host's copy is untouched by the session
  grep -q 'SECRET FROM ANOTHER PROJECT' "$C/file-history/OTHER-SESSION/deadbeef@v1"
}

@test "history.jsonl: the session gets its own project's records and no one else's" {
  # freeze the staging so it can be read after the run
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
cp -r "$AGENT_SANDBOX_SESSION_BASE"/session.*/iso "${BWRAP_COPY:?}" 2>/dev/null || true
exit 0
STUB
  chmod +x "$H/bin/bwrap"
  run_engine BWRAP_COPY="$H/staged" -- claude --version
  [ "$status" -eq 0 ]
  local f
  f="$(echo "$H/staged"/*history.jsonl)"
  grep -q '"display":"mine"' "$f" # its own project's record is there
  ! grep -q 'THEIRS' "$f"         # another project's is not
}

@test "append-back: lines the session added reach the host file, the rest is not duplicated" {
  agent_writes
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  # the pre-existing line survives exactly once, the new one is appended
  [ "$(grep -c 'A NEW LINE' "$C/history.jsonl")" -eq 1 ]
  [ "$(grep -c 'THEIRS' "$C/history.jsonl")" -eq 1 ]
  [ "$(grep -c '"display":"mine"' "$C/history.jsonl")" -eq 1 ]
  # the hook log the session appended to is complete on the host
  [ "$(grep -c 'old response from another session' "$C/responses.log")" -eq 1 ]
  [ "$(grep -c 'A NEW LINE' "$C/responses.log")" -eq 1 ]
}

@test "copy-out: entries the session created are merged back, existing ones never overwritten" {
  agent_writes
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ -f "$C/file-history/MY-SESSION/new@v1" ] # the session's own survives
  grep -q 'SECRET FROM ANOTHER PROJECT' "$C/file-history/OTHER-SESSION/deadbeef@v1"
  grep -q 'another project plan' "$C/plans/other.md" # untouched
  [ -z "$(ls -A "$H/base")" ]                        # and the session dir is gone
}

@test "a rewritten file is not appended back, and says why" {
  # two of this project's records, so the filtered view has a baseline of 2 and
  # a truncation to one line is detectable as "shorter than it started"
  printf '{"display":"mine2","project":"%s"}\n' "$PROJ" >>"$C/history.jsonl"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/iso/*history.jsonl; do
  [ -f "$f" ] && printf 'REPLACED\n' >"$f"   # truncate: which lines are new is unknowable
done
exit 0
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- claude --version
  [[ "$output" == *"was rewritten inside the sandbox"* ]]
  ! grep -q 'REPLACED' "$C/history.jsonl"
  [ "$(grep -c 'THEIRS' "$C/history.jsonl")" -eq 1 ] # host file intact
  [ "$(grep -c 'mine2' "$C/history.jsonl")" -eq 1 ]
}

@test "the janitor flushes an orphan's pending appends before removing it" {
  # A session killed with SIGKILL runs no trap, so its new lines sit unflushed
  # in a dir the next launch's sweep will reap. Reap must not mean lose.
  local d="$H/base/session.orphan" staged
  mkdir -p "$d/iso"
  staged="$d/iso/history"
  printf 'ORPHANED LINE\n' >"$staged"
  printf 'append\t%s\t%s\t0\n' "$C/history.jsonl" "$staged" >"$d/iso.manifest"
  printf '999999 1\n' >"$d/owner.id" # a PID that is not us and not alive
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ ! -d "$d" ]                              # reaped
  grep -q 'ORPHANED LINE' "$C/history.jsonl" # ...but not lost
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
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  # the supervisor's control key and session roster: a cross-session control
  # channel with no in-sandbox use
  argv_has --tmpfs "$C/daemon"
  # both of these exist to make Claude Code work from inside a sandbox, so
  # hiding them by default would break the feature they were created for
  ! argv_has --tmpfs "$C/gh"
  ! argv_has --tmpfs "$C/ide"
}

@test "[claude] hide blanks the named paths, but only from an approved dot-file" {
  mkdir -p "$C/gh" "$C/ide"
  printf '[claude]\nhide = gh ide\n' >"$PROJ/.agent-sandbox"

  # unapproved: the section grants nothing
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"present but not approved"* ]]
  ! argv_has --tmpfs "$C/gh"

  trust_proj
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --tmpfs "$C/gh"
  argv_has --tmpfs "$C/ide"
  argv_has --tmpfs "$C/daemon" # the default still applies alongside
}

@test "[claude] hide refuses to escape the state directory, and warns on unknown keys" {
  printf '[claude]\nhide = ../../etc /etc gh\nbogus = 1\n' >"$PROJ/.agent-sandbox"
  trust_proj
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"must be a relative path"* ]]
  [[ "$output" == *"unknown [claude] key"* ]]
  ! argv_has --tmpfs /etc
  ! grep -q '\.\./\.\./etc' "$H/argv"
  argv_has --tmpfs "$C/gh" # the valid entry on the same line still applies
}

@test "a section named for another profile is ignored, not applied" {
  mkdir -p "$C/gh"
  printf '[codex]\nhide = gh\n' >"$PROJ/.agent-sandbox"
  trust_proj
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unknown section [codex]"* ]]
  ! argv_has --tmpfs "$C/gh"
}
