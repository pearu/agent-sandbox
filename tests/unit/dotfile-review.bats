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

# --check: the same review, asking nothing and recording nothing; for an author, CI or a
# pre-commit hook. Stdin is closed in every one: a question would find no answer.
check() { run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"; }

@test "--check with no dot-file says the defaults apply, and exits 0" {
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"no .agent-sandbox in $PROJ; a launch uses the defaults"* ]]
}

@test "--check on a new file shows it and its review notes, asks nothing, records nothing" {
  printf '[net]\nmode = open\n[bogus]\nx\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ] # the text is one a launch accepts once approved
  [[ "$output" == *"mode = open"* ]]
  [[ "$output" == *"network mode 'open'"* ]]
  [[ "$output" == *"unknown section [bogus]"* ]]
  [[ "$output" == *"not approved yet; a launch asks first"*"--trust"* ]]
  [[ "$output" != *"approve this"* ]] # no question
  [ ! -e "$REC" ]                     # and no record
}

@test "--check on an approved file says so; on a changed one it shows the difference and records nothing" {
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved and unchanged since; a launch uses it"* ]]
  local before
  before="$(cat "$REC")"
  printf '[allow]\npypi.org\nexample.com\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"+example.com"* ]]
  [[ "$output" == *"CHANGED since it was approved; a launch asks again"* ]]
  [ "$(cat "$REC")" = "$before" ]
}

@test "--check exits non-zero when a launch would refuse: a control character, or a missing approved file" {
  printf '[allow]\npypi.org\033[2K\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"a launch refuses this file"* ]]
  printf '[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  approve
  rm "$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"one was approved earlier: a launch refuses"* ]]
  [ -f "$REC" ] # nothing forgotten either
}

# --check with a profile (named, or the only one): what the file means for a role, from
# the launch path itself, which stops before anything is started.
@test "--check shows the policy for the role the file names, and the mount plan, creating nothing" {
  printf '[sandbox]\nrole = impl\n[connect]\nartefacts = read-write native\n~/notes/ = read-only\n[connect:reviewer]\nmemory = read-only sandbox:@impl\n[connect:impl]\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Policy: profile claude, role impl ([sandbox] role), preset inherit"* ]]
  [[ "$output" == *"roles in this file: impl, reviewer"* ]]
  [[ "$output" =~ artefacts\ +read-write\ +native\ +\.agent-sandbox\ \[connect\] ]]
  [[ "$output" =~ instructions\ +copy-on-write\ +native\ +preset\ inherit ]]
  [[ "$output" == *"Binds, outer first:"* ]]
  [[ "$output" =~ \~/notes\ +read-only\ +declared\;\ does\ not\ exist ]]
  [[ "$output" =~ \~/.claude/projects/\{slug\}/memory ]]
  [[ "$output" =~ \~/.claude/sessions\ +tmpfs\ +blanked\ every\ launch ]]
  [ ! -e "$REC" ]                                      # nothing approved
  [ ! -d "$H/home/.local/state/agent-sandbox/claude" ] # no role, no record, no keeper
  [ ! -s "$H/argv" ]                                   # bwrap never ran
}

@test "--check --role shows another role's policy, a sandbox: source resolved as a launch would" {
  printf '[connect:reviewer]\nmemory = read-only sandbox:@impl\n./.git/ = own\n[connect:impl]\n' >"$PROJ/.agent-sandbox"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PRESET=inherit "$4" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"role reviewer (--role)"* ]]
  [[ "$output" =~ memory\ +read-only\ +sandbox:@impl\ +\.agent-sandbox\ \[connect:reviewer\] ]]
  [[ "$output" == *"memory: sandbox:@impl: nothing there; skipped"* ]] # impl never ran, nothing native
  [[ "$output" =~ \./\.git\ +own\ +declared\;\ this\ role\'s\ own ]]
}

@test "--check shows the project's mode, in the policy and in the mount plan (#220)" {
  printf '[connect]\nproject = read-only\n./impl/ = read-write\n[connect:supervisor]\nproject = read-write\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  [[ "$output" =~ project\ +read-only\ +the\ working\ tree\ +\.agent-sandbox\ \[connect\] ]]
  [[ "$output" =~ read-only\ +the\ project ]]
  [ ! -e "$PROJ/impl" ] # nothing made
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PRESET=inherit "$4" --check --role supervisor 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ project\ +read-write\ +the\ working\ tree\ +\.agent-sandbox\ \[connect:supervisor\] ]]
  [[ "$output" =~ read-write\ +the\ project ]]
}

# check_role ROLE [VAR=value ...] -- `--check --role ROLE` from the project, in a clean environment.
check_role() {
  local role="$1"
  shift
  run bash -c 'r="$1" proj="$2" home="$3" path="$4" eng="$5"; shift 5; cd "$proj" && env -i HOME="$home" PATH="$path" "$@" "$eng" --check --role "$r" 2>&1 </dev/null' \
    _ "$role" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE" "$@"
}

@test "--check says where the role can act as you: none, a gh login, read only, git refused, ssh (#226)" {
  mkdir -p "$H/home/.claude/gh" "$H/home/.config/agent-sandbox"
  : >"$H/home/.claude/gh/hosts.yml"
  printf 'github.com\napi.github.com\n' >"$H/home/.config/agent-sandbox/allowlist.txt"
  printf '[env]\nMY_API_KEY\n[connect:writer]\ngh = read-only\n[connect:reader]\ngh = read-only\n[net:reader]\nretrieve-only = on\ngit = refuse\n[connect:plain]\n' >"$PROJ/.agent-sandbox"
  check_role plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Can act as you at"* ]]
  [[ "$output" =~ GitHub\ +no\ --\ no\ GitHub\ credential\ here ]]
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh ]]
  [[ "$output" =~ MY_API_KEY\ +forwarded\ from\ your\ shell ]]
  check_role writer
  [[ "$output" =~ GitHub\ +YES\ --\ a\ gh\ login\ \(~/.claude/gh,\ read-only\),\ writes\ included\;\ git\ transport\ allowed ]]
  check_role reader
  [[ "$output" =~ GitHub\ +read\ only\ --\ a\ gh\ login.*retrieve-only\ refuses\ every\ write.*git\ transport\ refused ]]
  [[ "$output" =~ SSH\ +no\ --\ --ssh\ is\ refused\ for\ this\ role ]]
  # a forwarded GH_TOKEN is a credential when your shell has it, not when it does not
  check_role plain AGENT_SANDBOX_FORWARD=GH_TOKEN GH_TOKEN=x
  [[ "$output" =~ GitHub\ +YES\ --\ GH_TOKEN,\ forwarded ]]
  check_role plain AGENT_SANDBOX_FORWARD=GH_TOKEN
  [[ "$output" =~ GitHub\ +no\ -- ]]
  # a credential with no GitHub host reachable
  printf '[deny]\ngithub.com\napi.github.com\n' >>"$PROJ/.agent-sandbox"
  check_role writer
  [[ "$output" =~ GitHub\ +no\ --\ a\ credential.*but\ no\ GitHub\ host\ is\ reachable ]]
}

@test "--check exits non-zero when the policy is one a launch refuses" {
  printf '[connect]\ninstructions = readonly\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown mode 'readonly'"* ]]
  [[ "$output" != *"Binds, outer first"* ]]
}

@test "--check orders what can reach a session by how it arrives, and says UNMEASURED where nothing is measured" {
  local other="$H/other"
  mkdir -p "$other"
  other="$(cd "$other" && pwd -P)"
  mkdir -p "$H/home/.claude/projects/$(printf '%s' "$other" | sed 's:[^A-Za-z0-9-]:-:g')/memory"
  printf '[connect]\nartefacts = read-write native\n[share-memory]\n%s\n' "$other" >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  local reach
  reach="$(sed -n '/^Reaches this session/,/^Leaves this session/p' <<<"$output" | sed '1d')" # past the header
  [[ "$reach" =~ context\ +instructions ]]
  [[ "$reach" =~ context\ +skills\ +.*their\ descriptions\ are\ in\ every\ session ]]
  [[ "$reach" =~ searched\ +artefacts ]]
  [[ "$reach" =~ searched\ +memory\ of\ .*/other\ +read-only,\ from\ sandbox: ]]
  [[ "$reach" =~ --\ +workflows\ .*reach\ UNMEASURED ]]
  # context first, then searched, then the unmeasured
  [ "$(grep -n 'context ' <<<"$reach" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'searched ' <<<"$reach" | head -1 | cut -d: -f1)" ]
  [ "$(grep -n 'searched ' <<<"$reach" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'UNMEASURED' <<<"$reach" | head -1 | cut -d: -f1)" ]
  # what leaves: the read-write channel; the rest is this role's own, in one sentence
  [[ "$(sed -n '/^Leaves this session/,/^$/p' <<<"$output")" =~ searched\ +artefacts\ +read-write ]]
  [[ "$output" == *"This role's own, reaching no other session: "*"memory"* ]]
}

@test "every channel of the claude profile either has a measured reach or prints UNMEASURED" {
  local f="$REPO_ROOT/profiles/claude/agent-sandbox" ch
  # a reach value is one of the four words, with an optional note
  [ "$(grep -E '^reach' "$f" | grep -cvE '^reach *= *(context|searched|pointed|never)( -- .*)?$')" -eq 0 ]
  for ch in instructions settings skills agents memory artefacts projects; do
    sed -n "/^\[channel:$ch\]/,/^\[/p" "$f" | grep -qE '^reach *= *(context|searched|pointed|never)'
  done
}

@test "--check names the lines that change nothing for the role, and not an override that does" {
  local nomem="$H/nomem"
  mkdir -p "$nomem"
  printf '[sandbox]\npreset = inherit\n[connect]\ninstructions = copy-on-write\nartefacts = own\nartefacts = read-write native\nmemory = read-write\n[connect:reviewer]\nmemory = own\n[connect:*]\n[share-memory]\n%s\n' "$nomem" >"$PROJ/.agent-sandbox"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [ "$status" -eq 0 ] # advice, not a refusal
  local ne
  ne="$(sed -n '/^Lines with no effect/,/^$/p' <<<"$output")"
  [[ "$ne" == *"[connect] artefacts: set twice; the earlier 'artefacts = own' never applies"* ]]
  [[ "$ne" == *"[connect] instructions = copy-on-write: already preset inherit's rung"* ]]
  [[ "$ne" == *"[share-memory] "*"nomem: nothing to share yet"* ]]
  # reviewer's memory = own restates the rung but overrides [connect]'s read-write: it acts
  [[ "$ne" != *"memory = own"* ]]
}

@test "--check says nothing about no-effect lines when there are none" {
  printf '[connect]\nartefacts = read-write native\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Lines with no effect"* ]]
}

@test "--check lists what in the agent's base no channel, hide or visible line covers (#82)" {
  local c="$H/home/.claude"
  mkdir -p "$c/gh" "$c/debug" "$c/cache" "$c/newdir"
  : >"$c/settings.json"
  : >"$c/unknown.json"
  : >"$c/cache/other"
  : >"$c/.hidden-state"
  printf '[claude]\nhide = newdir\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  local u
  u="$(sed -n '/^Unclassified in/,/^$/p' <<<"$output")"
  [[ "$u" == *"unknown.json"* ]]
  [[ "$u" == *".hidden-state"* ]]
  [[ "$u" == *"cache/ -- only changelog.md is classified"* ]]
  [[ "$u" != *"gh/"* ]]           # visible
  [[ "$u" != *"debug/"* ]]        # hidden by the profile
  [[ "$u" != *"settings.json"* ]] # a channel
  [[ "$u" != *"newdir"* ]]        # hidden by the project's [claude] hide
}
