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
  engine_cmd
  (cd "$PROJ" && printf 'y\nn\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
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
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'~/.local/bin' is under your home directory"*"puts your real '$H/home/.local/bin' there, at read-only."*"approve this .agent-sandbox"* ]]
  [[ "$output" == *"'~/notes/' is under your home directory"*"sandbox-only storage at '$H/home/notes'"* ]]
  [[ "$output" != *"'./data/' is under"* ]] # inside the project
  run_engine AGENT_SANDBOX_VERBOSE= -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"under your home directory"* ]]
}

@test "the review says of a declared file reached through a symbolic link that the file it leads to is bound over, the link not (#401)" {
  mkdir -p "$PROJ/real"
  printf 'x\n' >"$PROJ/real/cfg"
  ln -s real/cfg "$PROJ/cfg"
  printf '[connect]\n./cfg = read-only\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'./cfg' is a file reached through a symbolic link. The file it leads to is bound over, so that file cannot be deleted or renamed from inside the sandbox; a link on its way, in a directory the role can write, can be."* ]]
  [[ "$output" != *"'./cfg' is a file. It is bound over"* ]]
}

@test "the review says a declared file is bound over, and that copy-on-write on one is copy; the launch does not" {
  printf 'x\n' >"$PROJ/AGENT.md"
  printf 'y\n' >"$PROJ/NOTES.md"
  mkdir -p "$PROJ/data"
  printf '[connect]\n./AGENT.md = read-only\n./NOTES.md = copy-on-write\n./data/ = own\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
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
  require_host "AGENT_SANDBOX=1 with pid 1 not bubblewrap is the host's case; inside a sandbox pid 1 is bwrap"
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
check() {
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}

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
  [ ! -e "$REC" ] # nothing approved
  # no role, no record, no keeper: only the agent the harness installed (#6)
  [ "$(ls "$H/home/.local/state/agent-sandbox/claude")" = install ]
  [ ! -s "$H/argv" ] # bwrap never ran
}

@test "--check --role shows another role's policy, a sandbox: source resolved as a launch would" {
  printf '[connect:reviewer]\nmemory = read-only sandbox:@impl\n./.git/ = own\n[connect:impl]\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PRESET=inherit "${@:4}" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
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
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PRESET=inherit "${@:4}" --check --role supervisor 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ project\ +read-write\ +the\ working\ tree\ +\.agent-sandbox\ \[connect:supervisor\] ]]
  [[ "$output" =~ read-write\ +the\ project ]]
}

# check_role ROLE [VAR=value ...] -- `--check --role ROLE` from the project, in a clean environment.
check_role() {
  local role="$1"
  shift
  engine_cmd
  run bash -c 'r="$1" proj="$2" home="$3" path="$4" n="$5"; shift 5; eng=("${@:1:n}"); shift "$n"; cd "$proj" && env -i HOME="$home" PATH="$path" "$@" "${eng[@]}" --check --role "$r" 2>&1 </dev/null' \
    _ "$role" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

@test "--check says where the role can act as you: none, a gh login, read only, git refused, ssh (#226)" {
  mkdir -p "$H/home/.config/gh" "$H/home/.config/agent-sandbox"
  : >"$H/home/.config/gh/hosts.yml"
  printf 'github.com\napi.github.com\n' >"$H/home/.config/agent-sandbox/allowlist.txt"
  printf '[env]\nMY_API_KEY\n[connect:writer]\ngh = read-only\n[connect:reader]\ngh = read-only\n[net:reader]\nretrieve-only = on\ngit = refuse\n[connect:plain]\n' >"$PROJ/.agent-sandbox"
  check_role plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Can act as you at"* ]]
  [[ "$output" =~ GitHub\ +no\ --\ no\ GitHub\ credential\ here ]]
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh ]]
  [[ "$output" =~ MY_API_KEY\ +forwarded\ from\ your\ shell ]]
  check_role writer
  [[ "$output" =~ GitHub\ +YES\ --\ a\ gh\ login\ \(~/.config/gh,\ read-only\),\ writes\ included\;\ git\ transport\ allowed ]]
  check_role reader
  [[ "$output" =~ GitHub\ +read\ only\ --\ a\ gh\ login.*retrieve-only\ refuses\ every\ write.*git\ transport\ refused ]]
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh,\ through\ the\ broker ]] # git = refuse does not close SSH (#293)
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

@test "[ssh]: the review names the widening per section, and --check's SSH row the hosts with their source" {
  printf '[ssh:gh-fix-*]\ngithub.com\n[connect:gh-review-*]\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[ssh:gh-fix-*] github.com: SSH to it as you, signed with your key through the broker, for the roles gh-fix-*; [net] git and retrieve-only do not reach into it: a push over SSH to a remote on it is possible where the account allows"*"approve this"* ]]
  check_role gh-fix-215
  [ "$status" -eq 0 ]
  [[ "$output" =~ SSH\ +github\.com\ \(\.agent-sandbox\ \[ssh:gh-fix-\*\]\)\ --\ through\ the\ broker\;\ plus\ any\ host\ a\ launch\ names\ with\ --ssh\;\ \[net\]\ git\ and\ retrieve-only\ do\ not\ reach\ into\ them:\ a\ push\ over\ SSH\ to\ a\ remote\ on\ them\ is\ possible\ where\ the\ account\ allows ]]
  [[ "$output" == *"roles in this file: "*"gh-fix-*"* ]]
  check_role gh-review-1
  [[ "$output" =~ SSH\ +only\ the\ hosts\ a\ launch\ names\ with\ --ssh ]]
  [[ "$output" != *"github.com (.agent-sandbox"* ]]
}

@test "[permissions]: the review names each rule as a widening, per section; --check lists the role's with their section" {
  printf '%s\n' '[permissions]' 'Bash(tail:*)' '[permissions:gate]' 'Bash(git push:*)' 'Bash(rm -rf' \
    '[connect:planner-*]' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[permissions] Bash(tail:*): a permission rule the agent gets without asking you, for every role"*"approve this"* ]]
  [[ "$output" == *"[permissions:gate] Bash(git push:*): a permission rule the agent gets without asking you, for the roles gate"* ]]
  [[ "$output" == *"[permissions:gate] bad rule 'Bash(rm -rf' (a tool name, or Tool(specifier), as the agent's settings take it); ignoring"* ]]
  check_role gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission rules the agent gets without asking: Bash(tail:*) ([permissions]), Bash(git push:*) ([permissions:gate])"* ]]
  [[ "$output" == *"roles in this file: "*"gate"* ]]
  check_role planner-1
  [[ "$output" == *"permission rules the agent gets without asking: Bash(tail:*) ([permissions])"$'\n'* ]]
  [[ "$output" != *"Bash(git push:*) ([permissions:gate])"* ]]
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
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:4}" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
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
  mkdir -p "$c/gh" "$c/debug" "$c/cache" "$c/newdir" "$c/partdir/inner" "$c/telemetry"
  : >"$c/settings.json"
  : >"$c/unknown.json"
  : >"$c/cache/other"
  : >"$c/.hidden-state"
  local f
  for f in policy-limits.json.signature.json policy-limits.json.signature-iat.json \
    remote-settings.json.signature.json remote-settings.json.signature-iat.json \
    remote-settings.json.synced-at; do : >"$c/$f"; done
  : >"$c/stats-cache.json"
  printf '[claude]\nhide = newdir partdir/inner\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  local u
  u="$(sed -n '/^Unclassified in/,/^$/p' <<<"$output")"
  [[ "$u" == *"unknown.json"* ]]
  [[ "$u" == *".hidden-state"* ]]
  [[ "$u" == *"partdir/ -- only inner is classified"* ]]
  [[ "$u" != *"cache"* ]]         # visible: native on purpose, changelog.md its channel (#109)
  [[ "$u" != *"telemetry"* ]]     # visible
  [[ "$u" != *"gh/"* ]]           # hidden: a login left there by the first gh channel
  [[ "$u" != *"debug/"* ]]        # hidden by the profile
  [[ "$u" != *"settings.json"* ]] # a channel
  [[ "$u" != *"newdir"* ]]        # hidden by the project's [claude] hide
  [[ "$u" != *"signature"* ]]     # the policy channel's, with the bodies (#355)
  [[ "$u" != *"synced-at"* ]]
}

@test "[ssh] under [net] git = refuse, fetch or retrieve-only: the review, --check's git line and SSH row say a push over SSH to the host is possible (#293)" {
  local g
  for g in refuse fetch allow; do
    printf '[ssh:impl-*]\ntob-ex\n[net:impl-*]\ngit = %s\nretrieve-only = on\n[connect:supervisor]\n' "$g" >"$PROJ/.agent-sandbox"
    run_review
    [[ "$output" == *"[ssh:impl-*] tob-ex: SSH to it as you, signed with your key through the broker, for the roles impl-*; [net] git and retrieve-only do not reach into it: a push over SSH to a remote on it is possible where the account allows"* ]]
    check_role impl-1
    [ "$status" -eq 0 ]
    [[ "$output" != *"and --ssh"* ]]
    [[ "$output" != *"--ssh is refused"* ]]
    case "$g" in
      refuse) [[ "$output" == *"  git transport: refused -- git over HTTPS to any host"$'\n'* ]] ;;
      fetch) [[ "$output" == *"  git transport: fetch only -- a push over HTTPS is refused"$'\n'* ]] ;;
      allow) [[ "$output" != *"git transport:"* ]] ;;
    esac
    [[ "$output" =~ SSH\ +tob-ex\ \(\.agent-sandbox\ \[ssh:impl-\*\]\)\ --\ through\ the\ broker\;\ plus\ any\ host\ a\ launch\ names\ with\ --ssh\;\ \[net\]\ git\ and\ retrieve-only\ do\ not\ reach\ into\ them:\ a\ push\ over\ SSH\ to\ a\ remote\ on\ them\ is\ possible\ where\ the\ account\ allows ]]
  done
}

@test "[net] agent-port: the review and --check say each token and where it is published, an address loudly (#335)" {
  printf '[net]\nmode = strict\nagent-port = 8000\nagent-port = 0.0.0.0:2222\nagent-port = 192.168.1.153:2223\n[net:other]\nagent-port = host:9000\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [net] agent-port = 8000: (strict) published at the host's 127.0.0.1:8000"* ]]
  [[ "$output" == *".agent-sandbox: [net] agent-port = 0.0.0.0:2222: (strict) published at 0.0.0.0:2222 -- every address of this host, reachable from the network (the host's firewall is yours)"* ]]
  [[ "$output" == *".agent-sandbox: [net] agent-port = 192.168.1.153:2223: (strict) published at 192.168.1.153:2223 -- that address of this host, reachable from wherever it is (the host's firewall is yours)"* ]]
  [[ "$output" == *"[net] agent-port: bad port 'host:9000'"* ]]
  [[ "$output" == *".agent-sandbox: [net] agent-port = host:9000: a launch refuses it"* ]]
  printf '[net]\nmode = strict\nagent-port = 8000\nagent-port = 0.0.0.0:2222\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"  network: agent port 8000 published at the host's 127.0.0.1:8000"* ]]
  [[ "$output" == *"  network: agent port 2222 published at 0.0.0.0:2222 -- every address of this host, reachable from the network (the host's firewall is yours)"* ]]
}

# ---- the review against the approval (#491): what is new to be trusted, the rest counted ----

# check_flags FLAG... -- `--check FLAG...`, as check does.
check_flags() {
  engine_cmd
  run bash -c 'n="$4"; cd "$1" && env -i HOME="$2" PATH="$3" "${@:5:n}" --check "${@:5+n}" 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

# tty_check [VAR=value ...] -- `--check` at a terminal (script(1)): stderr is a tty. CRs gone.
tty_check() {
  engine_cmd
  run bash -c 'n="$4"; cd "$1" && env -i HOME="$2" PATH="$3" "${@:5+n}" script -qec "$(printf "%q " "${@:5:n}") --check" /dev/null | tr -d "\r"' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

# held OUTPUT -- the count OUTPUT's summary line gives, or nothing when there is none.
held() { sed -n 's/^agent-sandbox: \(\x1b\[2m\)\{0,1\}\([0-9][0-9]*\) notes\{0,1\} as in your approval, not shown; .*/\2/p' <<<"$1"; }

# approve_as TEXT -- TEXT recorded as approved, content kept, as --trust does; then the
# file is what it was.
approve_as() {
  local now
  now="$(cat "$PROJ/.agent-sandbox" 2>/dev/null || true)"
  printf '%s' "$1" >"$PROJ/.agent-sandbox"
  approve
  printf '%s\n' "$now" >"$PROJ/.agent-sandbox"
}

PERM_NOTE="a permission rule the agent gets without asking you, for every role"

@test "a one-line change to an approved roles-model file: the added line's note, not an untouched line's, and the rest counted exactly (#491)" {
  git -C "$PROJ" init -q
  git -C "$PROJ" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init
  engine_cmd
  (cd "$PROJ" && env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --init roles </dev/null >/dev/null 2>&1)
  approve
  printf '\n[ssh]\ngithub.com\n' >>"$PROJ/.agent-sandbox"
  # the whole review counts the notes the file now gives: every line it prints but the question
  run_review "$PROJ" --all
  [[ "$output" != *"warning — "* ]]
  [[ "$output" != *"refused — "* ]]
  local all
  all="$(grep -c '^agent-sandbox: ' <<<"$output")"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [ssh] github.com: SSH to it as you"* ]]
  [[ "$output" != *"[agent:gate] effort = low"* ]]
  [ "$(held "$output")" -eq "$((all - 2))" ] # all but the question and the new note
  [ "$(grep -c '^agent-sandbox: new — ' <<<"$output")" -eq 1 ]
}

@test "a change that alters another line's note shows that note, and what it said before as no longer in force (#491)" {
  approve_as $'[ssh]\nbox\n'
  printf '[ssh]\nbox\n[remote:box]\nhost = box.example\nport = 2222\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [ssh] box: SSH to it as you"*"; box is the remote box of this file, [remote:box]"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: no longer in force (approved before, not in the file now):"$'\n'"agent-sandbox: no longer — .agent-sandbox: [ssh] box: SSH to it as you"*"where the account allows"$'\n'* ]]
}

@test "a removed line's note is under no longer in force, a removed [deny] line's too (#491)" {
  approve_as $'[permissions]\nRead\nEdit\n[deny]\nevil.example\n'
  printf '[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: no longer in force (approved before, not in the file now):"$'\n'"agent-sandbox: no longer — .agent-sandbox: [deny] evil.example: refused for every role, whatever the allowlist and hosts = public"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: no longer — .agent-sandbox: [permissions] Edit: $PERM_NOTE"$'\n'* ]]
  [[ "$output" == *$'\n'"-evil.example"$'\n'* ]]
  [ "$(held "$output")" -eq 1 ] # Read
  [[ "$output" != *"new — "* ]]
}

@test "[allow] and [deny] lines each make a note, for their roles: an added host reads new, a suffixed section names its roles (#491)" {
  approve_as $'[allow]\npypi.org\n'
  printf '[allow]\npypi.org\nfiles.example\n[deny:reviewer]\nx.example\n[allow:impl-*]\ny.example\n[connect:*]\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [allow] files.example: reachable for every role (this project's allowlist)"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [deny:reviewer] x.example: refused for the roles reviewer, whatever the allowlist and hosts = public"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [allow:impl-*] y.example: reachable for the roles impl-* (this project's allowlist)"$'\n'* ]]
  [ "$(held "$output")" -eq 1 ] # pypi.org
}

@test "a [deny] line that would take a profile's own host says the launch leaves it out under that profile; a bad host is a warning (#491)" {
  printf '[deny]\n.anthropic.com\nbad!host\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [deny] .anthropic.com: refused for every role, whatever the allowlist and hosts = public; not under the profile claude, whose own host"*" .anthropic.com"*" it would take: a launch there leaves it out"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: warning — .agent-sandbox: [deny] bad host 'bad!host'; ignoring"$'\n'* ]]
}

@test "what reaches stderr outside a note is shown as it came, once, and not compared (#491)" {
  local real
  real="$(PATH=/usr/bin:/bin command -v realpath)"
  printf '#!/usr/bin/env bash\ncase "$*" in *RAWPROBE*) echo "realpath-stub: its own line" >&2 ;; esac\nexec %q "$@"\n' "$real" >"$H/bin/realpath"
  chmod +x "$H/bin/realpath"
  approve_as $'[connect]\n./RAWPROBE/ = own\n'
  printf '[connect]\n./RAWPROBE/ = own\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "$(grep -c '^realpath-stub: its own line$' <<<"$output")" -eq 1 ] # the file now's run; the approved copy's is not shown
  [[ "$output" != *"new — realpath-stub"* ]]
}

@test "a refusal approved under an older rule, in both: printed, and the review's status is the file's (#491)" {
  printf '[agent]\neffort = bogus\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$CFG/trust"
  cp "$PROJ/.agent-sandbox" "$REC.approved"
  sha256sum "$PROJ/.agent-sandbox" | cut -d' ' -f1 | tr -d '\n' >"$REC" # approved before the effort check
  printf '[agent]\neffort = bogus\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *$'\n'"agent-sandbox: refused — .agent-sandbox: [agent] effort = bogus: not an effort level -- one of "*"; a launch refuses it"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: check: a launch refuses this file"* ]]
  [ -z "$(held "$output")" ]       # the refusal is shown, not counted
  [[ "$output" != *"no longer"* ]] # and, in both, it is not gone
}

@test "a warning approved before, in both: printed; it is not counted (#491)" {
  approve_as $'[net]\nmode = weird\n[permissions]\nRead\n[remote:box]\nhost = box.example\n'
  printf '[net]\nmode = weird\n[permissions]\nRead\nEdit\n[remote:box]\nhost = box.example\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: warning — .agent-sandbox: [net] mode 'weird' unknown (proxy|strict|open|none); ignoring"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: warning — .agent-sandbox: [remote:box] has no port line"*"; unusable as written"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: refused — .agent-sandbox: [remote:box]: unusable as written, for the reasons above; "* ]]
  [ "$(held "$output")" -eq 3 ]    # Read, and the remote's two info notes; the warnings and the refusal shown
  [[ "$output" != *"no longer"* ]] # and, in both, it is not gone
}

@test "the same note text twice in the file, one added: printed once, the other counted (#491)" {
  approve_as $'[permissions]\nRead\n'
  printf '[permissions]\nRead\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "$(grep -c "^agent-sandbox: new — .agent-sandbox: \[permissions\] Read: $PERM_NOTE\$" <<<"$output")" -eq 1 ]
  [ "$(held "$output")" -eq 1 ]
  [[ "$output" != *"no longer in force"* ]]
  # twice approved, twice now: both counted, neither new
  approve_as $'[permissions]\nRead\n[permissions]\nRead\n'
  printf '[permissions]\nRead\n[permissions]\nRead\nEdit\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "$(held "$output")" -eq 2 ]
  [[ "$output" != *"new — .agent-sandbox: [permissions] Read:"* ]]
  # twice approved, once now: one is gone, one counted
  printf '[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "$(grep -c "^agent-sandbox: no longer — .agent-sandbox: \[permissions\] Read: $PERM_NOTE\$" <<<"$output")" -eq 1 ]
  [ "$(held "$output")" -eq 1 ]
}

@test "one note held back is said as one note (#491)" {
  approve_as $'[permissions]\nRead\n'
  printf '[permissions]\nRead\nEdit\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: 1 note as in your approval, not shown; "*" --trust --all shows the whole review."$'\n'* ]]
}

@test "--all: every note, no summary line and no reason line (#491)" {
  approve_as $'[permissions]\nRead\nGrep\n'
  printf '[permissions]\nRead\nGrep\nEdit\n' >"$PROJ/.agent-sandbox"
  run_review "$PROJ" --all
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Grep: $PERM_NOTE"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Edit: $PERM_NOTE"$'\n'* ]]
  [ -z "$(held "$output")" ]
  [[ "$output" != *"new — "* ]]
  [[ "$output" != *"the whole review"* ]]
  [[ "$output" == *"+Edit"* ]] # the diff, as today
  check_flags --all
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
  [ -z "$(held "$output")" ]
}

@test "no approval: the whole review, its first line says why (#491)" {
  printf '[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "${lines[0]}" = "agent-sandbox: nothing approved to compare with: the whole review" ]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
  [ -z "$(held "$output")" ]
}

@test "an approval whose content was not kept: the whole review, its first line says why (#491)" {
  printf '[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$CFG/trust"
  printf '%064d' 0 >"$REC" # an earlier engine's record: a digest, no content
  run_review
  [ "${lines[0]}" = "agent-sandbox: the approved content was not kept (an earlier engine approved it), so there is nothing to compare with: the whole review" ]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
  [ -z "$(held "$output")" ]
}

@test "approved and unchanged: one line and the count, no file and no notes; --check's own line follows (#491)" {
  printf '[permissions]\nRead\nEdit\n' >"$PROJ/.agent-sandbox"
  approve
  run_review
  [ "${lines[0]}" = "agent-sandbox: this exact content is already approved." ]
  [ "$(held "$output")" -eq 2 ]
  [[ "$output" != *"[permissions] Read"* ]]
  [[ "$output" != *"----"* ]]
  [[ "$output" != *"sha256"* ]]
  [ "$(grep -c 'this exact content is already approved' <<<"$output")" -eq 1 ]
  [[ "$output" == *"agent-sandbox: approve this .agent-sandbox for $PROJ? [y/N] agent-sandbox: left as it was: this exact content stays approved." ]] # the question, as T38 left it
  check
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "agent-sandbox: this exact content is already approved." ]
  [[ "${lines[1]}" == "agent-sandbox: 2 notes as in your approval, not shown; "*" --trust --all shows the whole review." ]]
  [ "${lines[2]}" = "agent-sandbox: check: approved and unchanged since; a launch uses it" ]
}

@test "purpose files: all unchanged in one line with their count; one changed shows its diff, the others still one line (#491)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'A.\n' >"$PROJ/.asb/roles/a.md"
  printf 'B.\n' >"$PROJ/.asb/roles/b.md"
  printf 'C.\n' >"$PROJ/.asb/roles/c.md"
  printf '[briefing:a]\n[briefing:b]\n[briefing:c]\n' >"$PROJ/.agent-sandbox"
  approve
  run_review # approved and unchanged: the one line and the count, no purpose line
  [[ "$output" != *"approved, unchanged"* ]]
  printf '[briefing:a]\n[briefing:b]\n[briefing:c]\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: approved, unchanged: $PROJ/.asb/roles/a.md, $PROJ/.asb/roles/b.md, $PROJ/.asb/roles/c.md (3 files)"$'\n'* ]]
  [[ "$output" != *": approved, unchanged."* ]]
  printf 'B, CHANGED.\n' >"$PROJ/.asb/roles/b.md"
  run_review
  [[ "$output" == *$'\n'"purpose file $PROJ/.asb/roles/b.md has changed since you approved it."* ]]
  [[ "$output" == *$'\n'"+B, CHANGED."$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: approved, unchanged: $PROJ/.asb/roles/a.md, $PROJ/.asb/roles/c.md (2 files)"$'\n'* ]]
}

@test "--all goes with --trust, --check and --apply only: with another verb, or a launch, it is refused (#491)" {
  local w
  for w in --status --shutdown "--init roles" claude; do
    # shellcheck disable=SC2086 # a verb and its word
    run_engine -- asb --all $w
    [ "$status" -eq 2 ]
    [[ "$output" == *"--all shows the whole review of the .agent-sandbox; it goes with --trust, --check or --apply"* ]]
  done
  engine_cmd # --apply asks: answered no
  run bash -c 'cd "$1" && printf "n\n" | env -i HOME="$2" PATH="$3" "${@:4}" --all --apply "[permissions]" Read 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" != *"--all shows the whole review"* ]]
  [[ "$output" == *$'\n'"agent-sandbox: .agent-sandbox: [permissions] Read: $PERM_NOTE"$'\n'* ]]
}

@test "a note's text is compared as data: a value with \$(...) and backquotes is never run (#491)" {
  approve_as $'[permissions]\nBash($(touch PWNED1))\nBash(`touch PWNED2`)\n'
  # shellcheck disable=SC2016 # the file's text, not expanded
  printf '[permissions]\nBash($(touch PWNED1))\nBash(`touch PWNED2`)\nRead\n' >"$PROJ/.agent-sandbox"
  run_review
  [ "$(held "$output")" -eq 2 ]
  [ ! -e "$PROJ/PWNED1" ]
  [ ! -e "$PROJ/PWNED2" ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED1" ]
}

# A review with a line of each kind: refused, warning, new, no longer (under its info
# heading), info (the heading) and the summary.
kinds_fixture() {
  approve_as $'[permissions]\nRead\nGrep\n[ssh]\nold.example\n'
  printf '[permissions]\nRead\nGrep\nEdit\n[agent]\neffort = bogus\n[net]\nmode = weird\n' >"$PROJ/.agent-sandbox"
}

@test "at a terminal each line of the review has its kind's word and colour; through a pipe the same words, no escape (#491)" {
  kinds_fixture
  check
  [[ "$output" != *$'\e['* ]]
  [[ "$output" == *$'\n'"agent-sandbox: refused — .agent-sandbox: [agent] effort = bogus: "* ]]
  [[ "$output" == *$'\n'"agent-sandbox: warning — .agent-sandbox: [net] mode 'weird' unknown"* ]]
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [permissions] Edit: "* ]]
  [[ "$output" == *$'\n'"agent-sandbox: no longer — .agent-sandbox: [ssh] old.example: "* ]]
  [[ "$output" == *$'\n'"agent-sandbox: 2 notes as in your approval, not shown; "* ]]
  local piped
  piped="$(held "$output")"
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the colour on"
  local R=$'\e[0m'
  tty_check
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[31m'"refused — .agent-sandbox: [agent] effort = bogus: "*"; a launch refuses it$R"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[33m'"warning — .agent-sandbox: [net] mode 'weird' unknown (proxy|strict|open|none); ignoring$R"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[32m'"new — .agent-sandbox: [permissions] Edit: $PERM_NOTE$R"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: no longer in force (approved before, not in the file now):"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[36m'"no longer — .agent-sandbox: [ssh] old.example: "*"$R"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[2m'"2 notes as in your approval, not shown; "*" --trust --all shows the whole review.$R"$'\n'* ]]
  [ "$(held "$output")" = "$piped" ] # the comparison does not see the terminal
  [[ "$output" != *$'\e[0m'"agent-sandbox: "$'\e['* ]]
  [ "$(grep -c $'\e\\[' <<<"$output")" -eq 5 ] # the five coloured lines, nothing else
}

@test "the colour follows stderr, where the review is: stdout alone a terminal gives none, stderr alone gives it (#491)" {
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the colour on"
  kinds_fixture
  engine_cmd
  # stderr to a file, stdout the terminal
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" script -qec "$(printf "%q " "${@:5}") --check 2>$(printf "%q" "$4")" /dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/err" "${ENGINE_CMD[@]}"
  grep -qF 'new — .agent-sandbox: [permissions] Edit: ' "$H/err"
  run ! grep -qF $'\e[' "$H/err"
  # stdout to a file, stderr the terminal
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" script -qec "$(printf "%q " "${@:5}") --check >$(printf "%q" "$4")" /dev/null | tr -d "\r"' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/out" "${ENGINE_CMD[@]}"
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[32m'"new — .agent-sandbox: [permissions] Edit: "* ]]
}

@test "at a terminal, NO_COLOR set gives no escape; NO_COLOR empty gives colour (#491)" {
  command -v script >/dev/null || skip "script(1) is not on PATH: no terminal to test the colour on"
  kinds_fixture
  tty_check NO_COLOR=1
  [[ "$output" == *$'\n'"agent-sandbox: new — .agent-sandbox: [permissions] Edit: "* ]]
  [[ "$output" != *$'\e['* ]]
  tty_check NO_COLOR=
  [[ "$output" == *$'\n'"agent-sandbox: "$'\e[32m'"new — .agent-sandbox: [permissions] Edit: "* ]]
}

@test "a profile's refusal and warning, approved and in both: printed with their words, not counted (#491)" {
  approve_as "$(printf '[sshd]\nhome = /srv\nauthorized-keys = %s/keys\n[permissions]\nRead\n' "$PROJ")"
  printf '[sshd]\nhome = /srv\nauthorized-keys = %s/keys\n[permissions]\nRead\nEdit\n' "$PROJ" >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *$'\n'"agent-sandbox: refused — .agent-sandbox: [sshd] home = /srv: not a value it takes (project); a launch refuses it"$'\n'* ]]
  [[ "$output" == *$'\n'"agent-sandbox: warning — .agent-sandbox: [sshd] authorized-keys = $PROJ/keys is inside the project directory"* ]]
  [ "$(held "$output")" -eq 2 ] # Read, and the keys file's info note
}

@test "every note the engine words as a refusal or a line ignored is marked with its kind (#491)" {
  # The kind is set at the source, never read from the words at run time; this reads the
  # source, so a new note worded so and left unmarked is caught here. The two lines
  # left: a launch's own (a profile's hide), and --serve's watch-only note, which says
  # what --serve refuses but is itself information.
  run grep -nE '_as_(msg|remote_say) "(\.agent-sandbox|connect)[^"]*(refuses|unusable|cannot be approved|ignoring|Ignoring)' "$ENGINE"
  local left
  # shellcheck disable=SC2016 # the engine's source text, not expanded
  left="$(grep -vF -e 'hide: ignoring \"$name\"' -e 'watch only -- the watcher on $w is enforced' <<<"$output" || true)"
  [ -z "$left" ]
  [ "${#lines[@]}" -eq 2 ]
  # a remote's lines (said with the section's name in front) and a port's reasons
  # (said with the line's label in front): every one so worded is marked
  # shellcheck disable=SC2016 # the engine's source text, not expanded
  run grep -nE '_as_remote_say "[^"]*(refuses|unusable|ignoring)|_as_msg "\$label: [^"]*(bad port|refused)' "$ENGINE"
  [ -z "$output" ]
}

@test "inside a sandbox, --check says why there is nothing to compare with, and never 'approved and unchanged' beside it (#491)" {
  printf '[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  printf '#!/usr/bin/env bash\nsource %q\n_as_pid1_bwrap() { return 0; }\nagent_sandbox "$@"\n' "$ENGINE" >"$H/inside"
  chmod +x "$H/inside"
  engine_cmd "$H/inside"
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" AGENT_SANDBOX=1 "${@:4}" --check 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "${lines[0]}" = "agent-sandbox: inside a sandbox, where no approval is recorded, so there is nothing to compare with: the whole review" ]
  [[ "$output" == *$'\n'"agent-sandbox: check: inside a sandbox there is no gate: a launch here uses it without asking"$'\n'* ]]
  [[ "$output" != *"approved and unchanged"* ]]
}

@test "a purpose file changed, the dot-file as approved: one line for the dot-file, not all of it; the purpose file's diff (#491)" {
  mkdir -p "$PROJ/.asb/roles"
  printf 'A.\n' >"$PROJ/.asb/roles/a.md"
  printf '[briefing:a]\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  approve
  printf 'A, CHANGED.\n' >"$PROJ/.asb/roles/a.md"
  run_review
  [[ "$output" == *$'\n'"$PROJ/.agent-sandbox is as you approved it (sha256 "*"); a purpose file or addendum it names is not."$'\n'* ]]
  [[ "$output" != *$'\n'"[permissions]"$'\n'* ]] # the file is not shown
  [[ "$output" == *$'\n'"+A, CHANGED."$'\n'* ]]
  [ "$(held "$output")" -eq 1 ]
  run_review "$PROJ" --all
  [[ "$output" == *$'\n'"[permissions]"$'\n'* ]] # --all: the whole file
}

@test "approved and unchanged, with a refusal an older rule let through: the refusal is printed, not counted (#491)" {
  printf '[agent]\neffort = bogus\n[permissions]\nRead\n' >"$PROJ/.agent-sandbox"
  mkdir -p "$CFG/trust"
  cp "$PROJ/.agent-sandbox" "$REC.approved"
  sha256sum "$PROJ/.agent-sandbox" | cut -d' ' -f1 | tr -d '\n' >"$REC" # approved before the effort check
  check
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "agent-sandbox: this exact content is already approved." ]
  [[ "$output" == *$'\n'"agent-sandbox: refused — .agent-sandbox: [agent] effort = bogus: not an effort level -- one of "*"; a launch refuses it"$'\n'* ]]
  [ "$(held "$output")" -eq 1 ] # Read
}
