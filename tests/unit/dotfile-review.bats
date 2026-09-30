#!/usr/bin/env bats
# The dot-file review is part of the launch (#143): with someone at a terminal a new,
# changed or missing .agent-sandbox is shown -- the difference, against the approved
# content the store keeps -- and asked about; without one the launch refuses. Inside
# the sandbox the file is read-only unless a declaration says otherwise. Stub bwrap;
# run_engine_tty gives the engine a pty and types the answers.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  REC="$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

approve() { # approve the project's dot-file the way --trust does, content kept
  (cd "$PROJ" && printf 'y\nn\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "$ENGINE" --trust >/dev/null 2>&1)
  [ -f "$REC" ] && [ -f "$REC.approved" ]
}

@test "a new dot-file at a terminal is shown whole and asked about; yes approves it, keeps its content, and launches" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'y\n' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[allow]"*"pypi.org"*"approve this .agent-sandbox"* ]]
  [[ "$output" == *"approved."* ]]
  [[ "$output" == *"session allowlist: pypi.org"* ]] # and the launch runs under it
  [ -s "$H/argv" ]
  cmp -s "$REC.approved" "$PROJ/.agent-sandbox" # the content is kept, for the next diff
}

@test "no at the terminal records nothing and launches nothing" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'n\n' -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"not approved."* ]]
  [ ! -e "$REC" ] && [ ! -e "$REC.approved" ]
  [ ! -s "$H/argv" ]
}

@test "a changed dot-file shows the difference against what was approved" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  printf '[allow]\npypi.org\nevil.example\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'n\n' -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has changed since you approved it"* ]]
  [[ "$output" == *"+evil.example"* ]] # the added line, as a diff shows it
  [[ "$output" != *"+pypi.org"* ]]     # and not the line that was already approved
  run_engine_tty 'y\n' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: pypi.org evil.example "* ]] # approved: now it applies
}

@test "without a terminal a changed file refuses, and --trust (answers on stdin) approves it" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  printf '[allow]\nfiles.example\n' >"$PROJ/.agent-sandbox"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has changed since you approved it"*"launch from a terminal to be asked"*"--trust"* ]]
  [ ! -s "$H/argv" ]
  approve
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: files.example"* ]]
}

@test "the review says what a path under HOME gives, before the question; the launch does not repeat it" {
  mkdir -p "$H/home/.local/bin" "$PROJ/data"
  printf '[connect]\n~/.local/bin = read-only\n~/notes/ = own\n./data/ = own\n' >"$PROJ/.agent-sandbox"
  run bash -c "cd '$PROJ' && printf 'y\nn\n' | env -i HOME='$H/home' PATH='$H/bin:/usr/bin:/bin' '$ENGINE' --trust 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'~/.local/bin' is under your home directory"*"puts your real '$H/home/.local/bin' there, at read-only."*"approve this .agent-sandbox"* ]]
  [[ "$output" == *"'~/notes/' is under your home directory"*"sandbox-only storage at '$H/home/notes'"* ]]
  [[ "$output" != *"'./data/' is under"* ]] # inside the project
  run_engine AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"under your home directory"* ]]
}

@test "the review says a declared file is bound over, and that copy-on-write on one is copy; the launch does not" {
  printf 'x\n' >"$PROJ/AGENT.md"
  printf 'y\n' >"$PROJ/NOTES.md"
  mkdir -p "$PROJ/data"
  printf '[connect]\n./AGENT.md = read-only\n./NOTES.md = copy-on-write\n./data/ = own\n' >"$PROJ/.agent-sandbox"
  run bash -c "cd '$PROJ' && printf 'y\nn\n' | env -i HOME='$H/home' PATH='$H/bin:/usr/bin:/bin' '$ENGINE' --trust 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'./AGENT.md' is a file. It is bound over, so it cannot be deleted or renamed from inside the sandbox."*"approve this .agent-sandbox"* ]]
  [[ "$output" == *"'./NOTES.md' is a file."*"copy-on-write on a file is copy"* ]]
  [[ "$output" != *"'./data/' is a file"* ]]
  run_engine AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"is a file"* ]]
}

@test "a missing approved dot-file at a terminal offers to forget the approval; no refuses, yes launches with the defaults" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  rm "$PROJ/.agent-sandbox"
  run_engine_tty 'n\n' -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no .agent-sandbox, but one was approved earlier"*"pypi.org"* ]] # what was approved
  [ -f "$REC" ]
  [ ! -s "$H/argv" ]
  run_engine_tty 'y\n' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"approval forgotten"* ]]
  [ ! -e "$REC" ] && [ ! -e "$REC.approved" ]
  [[ "$output" != *"pypi.org"*"session allowlist"* ]]
}

@test "a join under a changed file is asked too, and joins under the keeper's policy either way" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  engine_bg -- asb claude --version
  printf '[allow]\nfiles.example\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'n\n' -- asb --role default claude --version
  [ "$status" -eq 0 ] # joined
  [[ "$output" == *"has changed since you approved it"* ]]
  [ ! -s "$H/argv" ] # no second launch
  [[ "$output" != *"agent-sandbox: approved."* ]]
  run_engine_tty 'y\n' -- asb --role default claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* ]]
  [[ "$output" == *"the change applies at the next keeper"* ]] # the running role keeps its policy
  release_bg
  run_engine -- asb claude --version # the next keeper follows the answer
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: files.example"* ]]
}

@test "AGENT_SANDBOX=1 on the host does not switch the gate off: only a real sandbox has no gate" {
  # A project's own shell setup (a direnv .envrc) could set the marker; the file that
  # project ships must still be reviewed.
  printf '[allow]\nevil.example\n' >"$PROJ/.agent-sandbox"
  run_engine AGENT_SANDBOX=1 -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"* ]]
  [ ! -s "$H/argv" ]
}

@test "a verb is not asked, and not refused, over a file never approved" {
  printf '[allow]\nevil.example\n' >"$PROJ/.agent-sandbox"
  run_engine_tty 'y\n' -- asb --status claude
  [ "$status" -eq 0 ]
  [[ "$output" != *"approve this"* ]]
  [[ "$output" == *"not running"* ]]
}

# ---- inside the sandbox the file is read-only (#143) ------------------------------

@test "inside the sandbox the dot-file is bound read-only by default" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/.agent-sandbox" "$PROJ/.agent-sandbox"
  [[ "$output" != *"connect: ./.agent-sandbox"* ]]    # built in, so not reported at every launch
  [[ "$output" != *"'./.agent-sandbox' is a file"* ]] # nor its bind explained: nobody declared it
}

@test "not under --preset native, whose claim is that it differs from none in nothing" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --ro-bind "$PROJ/.agent-sandbox" "$PROJ/.agent-sandbox"
}

@test "a declaration may give the sandbox a copy of its own; read-write is refused" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  run_engine -- asb --connect './.agent-sandbox = copy' claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --ro-bind "$PROJ/.agent-sandbox" "$PROJ/.agent-sandbox"
  local i found=0
  for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --bind && "${ARGV[i + 2]:-}" == "$PROJ/.agent-sandbox" && "${ARGV[i + 1]}" != "$PROJ/.agent-sandbox" ]] && found=1
  done
  ((found)) # the role's copy, not the project's file
  run_engine -- asb --connect './.agent-sandbox = read-write' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-write' is refused"*"#143"* ]]
  [ ! -s "$H/argv" ]
}

@test "with no dot-file nothing is bound for it: no mount point is left in the project" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --ro-bind "$PROJ/.agent-sandbox" "$PROJ/.agent-sandbox"
  [ ! -e "$PROJ/.agent-sandbox" ]
}
