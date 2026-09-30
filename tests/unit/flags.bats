#!/usr/bin/env bats
# Engine flag parsing, profile selection and refusals, via the stub bwrap.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
}

@test "no command: exit 2 with the calling convention and the profiles" {
  run_engine -- asb
  [ "$status" -eq 2 ]
  [[ "$output" == *"no command"*"asb [ENGINE FLAGS] CMD [AGENT ARGS]"* ]]
  [[ "$output" == *"profiles available"*"claude"* ]]
  [ ! -s "$H/argv" ]
  # an agent option before any command is an option the engine does not have
  run_engine -- asb --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"'--json' is not an option of agent-sandbox"*"asb --role reviewer claude -r"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- asb --role x -r claude
  [ "$status" -eq 2 ]
  [[ "$output" == *"'-r' is not an option"* ]]
}

@test "--help before a command prints engine usage; after one it goes to the agent" {
  run_engine -- agent-sandbox --help
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  run_engine -- asb claude --help
  [ "$status" -eq 0 ]
  # the briefing appends its own --settings after the agent's arguments, so
  # --help is the last argument the USER gave, not the last on the line
  join_has --help
  [ "${JOINV[1]}" = --help ]
  [ "${JOINV[2]}" = --settings ]
  # the agent's help ends with a footer pointing at --engine-help
  [[ "$output" == *"--engine-help"* ]]
  [[ "$output" == *"runs inside a sandbox"* ]]
}

@test "when bwrap itself cannot run, the engine names the unsandboxed way back in" {
  # The agent itself is not affected, and the message names it, resolved. 127 is
  # what a shell returns when the
  # command does not exist; a stub that exits 127 exercises OUR handling of it
  # without depending on PATH resolution (making the stub unexecutable does not
  # work: the lookup then finds the real bwrap further along PATH).
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
set +x
: >"${BWRAP_DUMP:?}"; exit 127
STUB
  chmod +x "$H/bin/bwrap"
  run_engine -- asb claude --version
  [ "$status" -eq 127 ]
  [[ "$output" == *"the sandbox did not start"* ]]
  [[ "$output" == *"without the sandbox"* ]]
  # the actual binary, not just the idea of one
  [[ "$output" == *"claude    ($H/home/.local/share/claude/versions/2.1.300/claude)"* ]]
  [[ "$output" == *"troubleshooting.md"* ]]
}

@test "a normal non-zero exit from the agent is NOT mistaken for a broken sandbox" {
  # Only 126/127 from the launch mean bwrap could not run; anything else is the
  # agent's own status -- the joined command's -- and suggesting the emergency exit
  # there would be noise.
  run_engine JOIN_EXIT=3 -- asb claude --version
  [ "$status" -eq 3 ]
  [[ "$output" != *"the sandbox did not start"* ]]
}

@test "--version before the command prints the engine's version and exits without launching" {
  run_engine -- asb --version
  [ "$status" -eq 0 ]
  # derived from the VERSION file next to the engine, not hardcoded, so a
  # release bump does not need to touch this test; a build marker may follow.
  [[ "$output" == "agent-sandbox $(cat "$REPO_ROOT/VERSION")"* ]]
  [ ! -s "$H/argv" ]
  # after the command it is the agent's, untouched
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  join_has --version
  [[ "$output" != "agent-sandbox $(cat "$REPO_ROOT/VERSION")"* ]]
  # and the old spelling is refused with the new one
  run_engine -- asb --engine-version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--engine-version was renamed: write --version"* ]]
  [ ! -s "$H/argv" ]
}

@test "--engine-help prints the engine usage even with a profile, and does not launch the agent" {
  run_engine -- asb --engine-help claude
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  [[ "$output" == *"--allow"* && "$output" == *"--trust"* && "$output" == *"--engine-help"* ]]
  [ ! -s "$H/argv" ]
  # also reachable without a profile via the engine name
  run_engine -- agent-sandbox --engine-help
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
  [ ! -s "$H/argv" ]
}

@test "the command names the profile; --profile NAME, --profile=NAME and a path give identical argv" {
  # Session-scoped paths are normalised away: the briefing and state isolation
  # both bind files out of a per-launch session directory whose name is random,
  # so two identical invocations legitimately differ in exactly those paths.
  # How the profile was selected is what this test is about -- and normalising
  # beats switching those features off, since then the argv compared is the one
  # a real launch produces.
  norm() { sed 's/session\.[A-Za-z0-9]\{6\}/session.NORMALISED/g' "$1"; }
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  norm "$H/argv" >"$H/argv.a"
  run_engine -- agent-sandbox --profile claude claude --version
  [ "$status" -eq 0 ]
  norm "$H/argv" >"$H/argv.b" && cmp -s "$H/argv.b" "$H/argv.a"
  run_engine -- agent-sandbox --profile=claude claude --version
  norm "$H/argv" >"$H/argv.b" && cmp -s "$H/argv.b" "$H/argv.a"
  # a path whose basename is the profile's name, here the link on PATH itself
  run_engine -- asb "$H/bin/claude" --version
  norm "$H/argv" >"$H/argv.b" && cmp -s "$H/argv.b" "$H/argv.a"
  # the normalisation must actually have had something to normalise, or this
  # test would be comparing raw argvs and passing for the wrong reason
  grep -q 'session\.NORMALISED' "$H/argv.a"
}

@test "the agent is what the command resolves to, through its symlinks, and the agent's options are its own" {
  run_engine -- asb claude --role x --version
  [ "$status" -eq 0 ]
  # $H/bin/claude links into versions/, as the native installer's launcher does
  [ "${JOINV[0]}" = "$H/home/.local/share/claude/versions/2.1.300/claude" ]
  # everything after the command is the agent's, engine-looking words included
  join_has --role x --version
  [[ "$output" != *"role: x"* ]]
}

@test "a versioned binary runs with --profile; without it its basename names no profile" {
  mkdir -p "$H/opt"
  cp "$H/home/.local/share/claude/versions/2.1.300/claude" "$H/opt/2.1.284"
  run_engine -- asb "$H/opt/2.1.284" --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"'$H/opt/2.1.284' names no profile"*"--profile NAME $H/opt/2.1.284"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- asb --profile claude "$H/opt/2.1.284" --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/opt/2.1.284" ]
  # bound read-only at its host path, so the sandbox sees it wherever it lives
  argv_has --ro-bind "$H/opt/2.1.284" "$H/opt/2.1.284"
  # relative to where the command is typed, as a shell would take it
  RUN_CWD="$H/opt" run_engine -- asb --profile claude ./2.1.284 --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/opt/2.1.284" ]
  run_engine -- asb --profile claude "$H/opt/nosuch" --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'$H/opt/nosuch' is not an executable file"* ]]
}

@test "no agent on PATH: refused, naming the path form" {
  rm "$H/bin/claude"
  run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"no 'claude' on PATH to run"*"asb --profile claude /path/to/claude"* ]]
  [ ! -s "$H/argv" ]
}

@test "a verb needs a profile, not a command: both spellings name the same role" {
  run_engine -- asb --status claude
  [ "$status" -eq 0 ]
  local a="$output"
  run_engine -- asb --profile claude --status
  [ "$status" -eq 0 ]
  [ "$output" = "$a" ]
  [[ "$output" == *"role 'default' of $H/proj"* ]]
}

@test "--exec needs --profile: the words after it are another command's" {
  run_engine -- asb --exec true
  [ "$status" -eq 2 ]
  [[ "$output" == *"--exec needs the profile whose sandbox it runs in: asb --profile NAME --exec true"* ]]
  [ ! -s "$H/argv" ]
}

@test "the engine run through a launcher named after a profile is refused, naming asb and install.sh (#151)" {
  mkdir -p "$H/old"
  ln -s "$ENGINE" "$H/old/claude"
  run_engine -- "$H/old/claude" --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"no longer run as 'claude'"*"asb claude"* ]]
  [[ "$output" == *"$H/old/claude is a launcher an earlier install.sh left"*"install.sh"* ]]
  [ ! -s "$H/argv" ]
  [[ "$output" != "agent-sandbox $(cat "$REPO_ROOT/VERSION")"* ]] # no engine flag answers as the agent
  # except --wrap, from a daemon an earlier engine started: its own message says what to do
  run_engine -- "$H/old/claude" --wrap
  [ "$status" -eq 2 ]
  [[ "$output" == *"--wrap was removed"*"claude daemon stop"* ]]
}

@test "any other name for the engine is the engine: only a profile's name is refused" {
  mkdir -p "$H/mine"
  ln -s "$ENGINE" "$H/mine/sb"
  run_engine -- "$H/mine/sb" claude --version
  [ "$status" -eq 0 ]
  [ "${JOINV[0]}" = "$H/home/.local/share/claude/versions/2.1.300/claude" ]
}

@test "a launcher to ANOTHER copy of the engine is passed over too: an installed copy, run from a checkout" {
  mkdir -p "$H/old" "$H/app"
  cp "$ENGINE" "$H/app/agent-sandbox"
  ln -s "$H/app/agent-sandbox" "$H/old/claude"
  run_engine PATH="$H/old:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: $H/old/claude is a launcher an earlier install.sh left"* ]]
  [ "${JOINV[0]}" = "$H/home/.local/share/claude/versions/2.1.300/claude" ]
}

@test "such a launcher earlier on PATH is passed over, with a note: the agent is the next claude" {
  mkdir -p "$H/old"
  ln -s "$ENGINE" "$H/old/claude"
  run_engine PATH="$H/old:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: $H/old/claude is a launcher an earlier install.sh left"* ]]
  [ "${JOINV[0]}" = "$H/home/.local/share/claude/versions/2.1.300/claude" ]
}

@test "unknown, path-like or missing profile names are refused with exit 2" {
  run_engine -- agent-sandbox --profile codex claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"no profile 'codex'"* ]]
  run_engine -- agent-sandbox --profile ../profiles/claude claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad profile name"* ]]
  run_engine -- agent-sandbox --profile
  [ "$status" -eq 2 ]
  printf '#!/bin/sh\n' >"$H/bin/nosuch"
  chmod +x "$H/bin/nosuch"
  run_engine -- asb nosuch --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"'nosuch' names no profile"* ]]
}

@test "AGENT_SANDBOX_PROFILE_DIR overrides where profiles live" {
  mkdir -p "$H/profiles2"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"names no profile"*"profiles available in $H/profiles2: (none)"* ]]
  # a profile's own command is what a verb or --exec runs, looked up on PATH
  printf 'profile_command=x\n' >"$H/profiles2/other.sh"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- agent-sandbox --profile other --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"no 'x' on PATH to run"* ]]
}

@test "sourced mode: agent_sandbox() takes the command as run, and never infers a profile from \$0" {
  pushd "$H/proj" >/dev/null
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm BWRAP_DUMP="$H/argv" \
    JOIN_DUMP="$H/join" AGENT_SANDBOX_JOIN="$H/bin/join-stub.py" AGENT_SANDBOX_KEEPER_GRACE=0 \
    bash -c "source '$ENGINE'; agent_sandbox claude --version"
  popd >/dev/null
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ]
  pushd "$H/proj" >/dev/null
  run env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" USER=tester TERM=xterm BWRAP_DUMP="$H/argv" \
    bash -c "source '$ENGINE'; agent_sandbox"
  popd >/dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"no command"* ]]
}

@test "--ssh flags: values required, mutual exclusion, lifetime syntax, key readability" {
  run_engine -- asb --ssh
  [ "$status" -eq 2 ] && [[ "$output" == *"--ssh needs a host"* ]]
  run_engine -- asb --ssh-unrestricted --ssh example.test claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"mutually exclusive"* ]]
  run_engine -- asb --ssh-timeout 5m claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"need --ssh HOST"* ]]
  run_engine -- asb --ssh example.test --ssh-timeout 5x claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"bad lifetime"* ]]
  run_engine -- asb --ssh example.test --ssh-key /nope claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"cannot read"* ]]
  [ ! -s "$H/argv" ]
}

@test "--allow: hostnames and .domains accepted, junk refused, ignored without a proxy" {
  run_engine -- asb --allow 'bad host' claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"--allow: bad host"* ]]
  run_engine -- asb --allow 'host/path' claude --version
  [ "$status" -eq 2 ]
  run_engine -- asb --allow
  [ "$status" -eq 2 ]
  run_engine AGENT_SANDBOX_NET=none -- asb --allow pypi.org claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"--allow is ignored"* ]]
  [ -z "$(ls -A "$H/base" 2>/dev/null)" ]
}

@test "--host-port/--agent-port: a port 1024-65535 or none; junk and system ports refused; noted and ignored outside strict" {
  run_engine -- asb --host-port
  [ "$status" -eq 2 ] && [[ "$output" == *"--host-port needs a port"* ]]
  run_engine -- asb --agent-port 80 claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"--agent-port: port 80 refused (below 1024"* ]]
  run_engine -- asb --host-port 70000 claude --version
  [ "$status" -eq 2 ] && [[ "$output" == *"--host-port: bad port '70000'"* ]]
  run_engine -- asb --host-port 8x claude --version
  [ "$status" -eq 2 ]
  [ ! -s "$H/argv" ]
  run_engine -- asb --host-port 5432 --agent-port=8000 claude --version # proxy mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"--host-port/--agent-port are ignored with AGENT_SANDBOX_NET=proxy"* ]]
  run_engine AGENT_SANDBOX_NET=none -- asb --agent-port none claude --version
  [ "$status" -eq 0 ] && [[ "$output" == *"are ignored with AGENT_SANDBOX_NET=none"* ]]
  run_engine AGENT_SANDBOX_HOST_PORTS=80 -- asb claude --version # a bad knob value is a config error
  [ "$status" -eq 1 ] && [[ "$output" == *"below 1024"* ]]
}

@test "unknown network mode is refused" {
  run_engine AGENT_SANDBOX_NET=bogus -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown AGENT_SANDBOX_NET"* ]]
}

@test "--exec runs the given command in the sandbox instead of the agent" {
  run_engine -- asb --profile claude --exec /bin/echo hello world
  [ "$status" -eq 0 ]
  # the sandbox is still built; only the command at the end differs
  argv_has --ro-bind "$H/home/.local/share/claude/versions/2.1.300/claude" \
    "$H/home/.local/share/claude/versions/2.1.300/claude"
  # the command is what is joined into the keeper, exactly as given
  [ "${JOINV[*]}" = "/bin/echo hello world" ]
  # the agent binary is NOT the thing being executed
  run ! join_has "$H/home/.local/share/claude/versions/2.1.300/claude"
}

@test "--exec passes flags of its own through untouched, and needs a command" {
  # the command's flags must reach the command, not be eaten by the engine
  run_engine -- asb --profile claude --exec python3 -c 'print(1)'
  [ "$status" -eq 0 ]
  [ "${#JOINV[@]}" -eq 3 ] && join_has python3 -c 'print(1)'
  run_engine -- asb --profile claude --exec
  [ "$status" -eq 2 ]
  [[ "$output" == *"--exec needs a command"* ]]
}

@test "engine flags before --exec still apply; everything after belongs to the command" {
  run_engine -- asb --allow pypi.org --profile claude --exec bash -l --allow evil.example
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  [[ "$output" != *evil.example* ]] # the second --allow is the command's argument
  [ "${JOINV[*]}" = "bash -l --allow evil.example" ]
}

@test "--exec never routes to a host-side subcommand or a native verb" {
  # `claude update` runs on the host unsandboxed, and `claude agents` runs
  # natively; under --exec both name a program to run INSIDE the sandbox, and
  # matching them here would run the agent outside the sandbox instead
  run_engine -- asb --profile claude --exec update --foo
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # bwrap WAS invoked; it did not take the host-side path
  [ "${JOINV[*]}" = "update --foo" ]
  [[ "$output" != *"on the host"* ]]
  run_engine -- asb --profile claude --exec agents
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ]
  [ "${JOINV[*]}" = agents ]
  [[ "$output" != *"runs natively"* ]]
}

@test "quiet by default: the routine status lines appear only with --verbose" {
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --allow pypi.org claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"session allowlist"* ]] # quiet by default
  argv_has --ro-bind "$H/home/.local/share/claude/versions/2.1.300/claude" \
    "$H/home/.local/share/claude/versions/2.1.300/claude" # and the launch is unchanged
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --verbose --allow pypi.org claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: pypi.org"* ]]
}

@test "AGENT_SANDBOX_VERBOSE does the same, and rejects a value it does not understand" {
  run_engine AGENT_SANDBOX_VERBOSE=on -- asb --allow pypi.org claude --version
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  run_engine AGENT_SANDBOX_VERBOSE=off -- asb --allow pypi.org claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"session allowlist"* ]]
  run_engine AGENT_SANDBOX_VERBOSE=maybe -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"AGENT_SANDBOX_VERBOSE='maybe' is not recognised"* ]]
}

@test "--quiet and AGENT_SANDBOX_QUIET are refused: quiet is the default, --verbose the way back" {
  run_engine -- asb --quiet claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--quiet was removed: quiet is the default now"*"--verbose"* ]]
  [ ! -s "$H/argv" ]
  run_engine AGENT_SANDBOX_QUIET=on -- asb claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"AGENT_SANDBOX_QUIET was removed"*"AGENT_SANDBOX_VERBOSE=on"* ]]
  [ ! -s "$H/argv" ]
}

@test "quiet never hides a refusal, a warning, or an unsandboxed notice" {
  # a refusal: the launch must still explain itself, and still fail
  mkdir -p "$H/home/.aws"
  run_engine AGENT_SANDBOX_VERBOSE= AGENT_SANDBOX_RW="$H/home/.aws" -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *refusing* ]]
  [ ! -s "$H/argv" ]
  # a warning about a path that is not there
  run_engine AGENT_SANDBOX_VERBOSE= AGENT_SANDBOX_RO="$H/home/no-such-dir" -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping missing path"* ]]
  # and a notice that something runs OUTSIDE the sandbox
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --preset none claude -p hi
  [[ "$output" == *"preset none: running claude with no sandbox"* ]]
}
