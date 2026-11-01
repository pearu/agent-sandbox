#!/usr/bin/env bats
# The [remote:ALIAS] section of a project's .agent-sandbox (#344, step 1): parsed,
# reviewed and approved like every section, listed by --check, acted on by nothing yet.
# Stub bwrap; these assert on the review's lines, --check's and the trust gate.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  REC="$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

# check [ARGS...] -- `--check ARGS...` in the project, answered nothing.
check() {
  engine_cmd
  run bash -c 'cd "$1" && n="$4" && env -i HOME="$2" PATH="$3" "${@:5:n}" --check "${@:5+n}" 2>&1 </dev/null' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "$@"
}

# A section with every key, valid, and the [ssh] line that reaches it.
full_section() {
  cat >"$PROJ/.agent-sandbox" <<'F'
[remote:bench-ex]
host = ex.example.org
account = tob
port = 0.0.0.0:2222
scratch = /home/tob/bench
gpu = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1
allow = pypi.org files.pythonhosted.org
allow = .githubusercontent.com
env = TMPDIR=/home/tob/bench/tmp

[ssh:implementer-1]
bench-ex
F
}

# bad_section LINE... -- a section with host and port, plus the lines given.
bad_section() {
  {
    printf '[remote:r1]\n'
    printf '%s\n' "$@"
  } >"$PROJ/.agent-sandbox"
}

unusable='.agent-sandbox: [remote:r1]: unusable as written, for the reasons above; agent-sandbox --setup-remote r1 (not in this version yet) will refuse it'

@test "[remote:ALIAS]: the review says every line as written, the [ssh] line that names it, and one line for the whole (#344)" {
  full_section
  run_review
  local p='agent-sandbox: .agent-sandbox: [remote:bench-ex]'
  [[ "$output" == *"$p host = ex.example.org: the host the login runs on, reached over ssh as you reach it from here"* ]]
  [[ "$output" == *"$p account = tob: the account that runs the login there"* ]]
  [[ "$output" == *"$p port = 0.0.0.0:2222: the login listens at every address of that host, port 2222: reachable from the network (that host's firewall is its own)"* ]]
  [[ "$output" == *"$p scratch = /home/tob/bench: the project directory there, the login's one writable place ('~' is the account's home there)"* ]]
  [[ "$output" == *"$p gpu = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1: only these GPU device nodes of that host are passed into the login's sandbox"* ]]
  [[ "$output" == *"$p allow = pypi.org files.pythonhosted.org: the login's sandbox reaches these hosts through its allowlist proxy there"* ]]
  [[ "$output" == *"$p allow = .githubusercontent.com: the login's sandbox reaches these hosts"* ]]
  [[ "$output" == *"$p env = TMPDIR=/home/tob/bench/tmp: sets TMPDIR to '/home/tob/bench/tmp' inside the login's sandbox"* ]]
  [[ "$output" == *"[ssh:implementer-1] bench-ex: SSH to it as you"*"; bench-ex is the remote bench-ex of this file, [remote:bench-ex]"* ]]
  # The whole, last of the section's lines; reached, so no note that nothing reaches it.
  [[ "$output" == *"$p env = "*"$p: a sandboxed login on ex.example.org as tob, set up by agent-sandbox --setup-remote bench-ex (not in this version yet)"* ]]
  [[ "$output" != *"no role reaches"* ]]
  [[ "$output" != *unusable* ]]
}

@test "[remote:ALIAS]: no [ssh] line naming it is said, an [ssh] line naming another host is not cross-referenced, and no account is the ssh user (#344)" {
  printf '[remote:r1]\nhost = pearu@qgpu3\nport = 2222\n[ssh]\nother-host\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] port = 2222: the login listens at 127.0.0.1:2222 of that host only: for roles that run on that host"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1]: no [ssh] line names r1, so no role reaches it yet"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1]: a sandboxed login on pearu@qgpu3 as the ssh user, set up by agent-sandbox --setup-remote r1 (not in this version yet)"* ]]
  [[ "$output" == *"[ssh] other-host: SSH to it as you"* ]]
  [[ "$output" != *"is the remote"* ]]
}

@test "[remote:ALIAS] without a host line is said and unusable (#344)" {
  bad_section 'port = 2222'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] has no host line (an ssh destination); unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
  [[ "$output" != *"a sandboxed login on"* ]]
}

@test "[remote:ALIAS] without a port line is said and unusable (#344)" {
  bad_section 'host = ex.example.org'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] has no port line (where the login listens there, as --agent-port takes it); unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
}

@test "[remote:ALIAS] port: a token --agent-port refuses is unusable, as is none (#344)" {
  local t
  for t in host:2222 80 0.0.0.0:80 70000 none ::1:2222; do
    bad_section 'host = ex.example.org' "port = $t"
    run_review
    [[ "$output" == *".agent-sandbox: [remote:r1] port = $t: not a port --agent-port takes (PORT, or ADDR:PORT with ADDR an IPv4 address of that host or 0.0.0.0 for every one; the port 1024-65535); unusable as written"* ]]
    [[ "$output" == *"$unusable"* ]]
  done
}

@test "[remote:ALIAS] host: a port or an option is not an ssh destination (#344)" {
  local t
  for t in ex.example.org:22 -oProxyCommand=x 'a b'; do
    bad_section "host = $t" 'port = 2222'
    run_review
    [[ "$output" == *".agent-sandbox: [remote:r1] host = $t: not an ssh destination (a hostname, user@host, or a ~/.ssh/config alias; a port is the alias's); unusable as written"* ]]
    [[ "$output" == *"$unusable"* ]]
  done
}

@test "[remote:ALIAS] gpu: an entry outside /dev/ or with '..' is unusable (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'gpu = /dev/nvidiactl /home/x/card'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] gpu = /dev/nvidiactl /home/x/card: '/home/x/card' is not a node under /dev/; unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
  bad_section 'host = ex.example.org' 'port = 2222' 'gpu = /dev/../etc/shadow'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] gpu = /dev/../etc/shadow: '/dev/../etc/shadow' has a '..' component; unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
}

@test "[remote:ALIAS] account: a name adduser would refuse is unusable (#344)" {
  local t
  for t in Tob 1tob 'tob;id' -tob abcdefghijabcdefghijabcdefghijabc; do
    bad_section 'host = ex.example.org' 'port = 2222' "account = $t"
    run_review
    [[ "$output" == *".agent-sandbox: [remote:r1] account = $t: not an account name adduser takes (lowercase letters, digits, '-' and '_', starting with a letter or '_', at most 32); unusable as written"* ]]
    [[ "$output" == *"$unusable"* ]]
  done
  bad_section 'host = ex.example.org' 'port = 2222' 'account = _tob-2'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] account = _tob-2: the account that runs the login there"* ]]
  [[ "$output" != *unusable* ]]
}

@test "[remote:ALIAS] scratch: a relative path is unusable; ~ is the account's home there (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'scratch = bench'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] scratch = bench: relative; it is absolute or under '~' (the account's home there); unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
  bad_section 'host = ex.example.org' 'port = 2222' 'scratch = ~/bench'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] scratch = ~/bench: the project directory there"* ]]
  [[ "$output" != *unusable* ]]
}

@test "[remote:ALIAS] env: a line without = or with a bad name is unusable (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'env = TMPDIR'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] env = TMPDIR: not NAME=VALUE; unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
  bad_section 'host = ex.example.org' 'port = 2222' 'env = 1X=y'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] env = 1X=y: '1X' is not a variable name; unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
}

@test "[remote:ALIAS] allow: a bad host is unusable (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'allow = pypi.org http://x.org'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] allow = pypi.org http://x.org: bad host 'http://x.org' (a hostname, or .domain); unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
}

@test "[remote:ALIAS]: a second host line is unusable (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'host = ey.example.org'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] host = ey.example.org: a second host line, where the section takes one; unusable as written"* ]]
  [[ "$output" == *"$unusable"* ]]
}

@test "[remote:ALIAS]: an unknown key and a line without = are said and ignored; the section stays usable (#344)" {
  bad_section 'host = ex.example.org' 'port = 2222' 'colour = blue' 'bench-ex'
  run_review
  [[ "$output" == *".agent-sandbox: [remote:r1] key 'colour' is not one a remote takes (host, account, port, scratch, gpu, allow, env); ignoring"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1] expects 'key = value', ignoring: bench-ex"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1]: a sandboxed login on ex.example.org as the ssh user"* ]]
  [[ "$output" != *unusable* ]]
}

@test "[remote:ALIAS] written twice: the review says the file is unusable, --trust refuses to approve it and --check exits 1 (#344)" {
  printf '[remote:r1]\nhost = a.example.org\nport = 2222\n[remote:r1]\nhost = b.example.org\nport = 2223\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ \
    "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [[ "$output" == *".agent-sandbox: [remote:r1] is written more than once: the file is unusable, and cannot be approved, until one is renamed or removed"* ]]
  [[ "$output" == *"a launch refuses this file as it is, so it cannot be approved."* ]]
  [[ "$output" != *"approve this .agent-sandbox"* ]] # never asked
  [ ! -e "$REC" ]
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"is written more than once"*"check: a launch refuses this file"* ]]
}

@test "[remote:<bad name>] and a bare [remote] are said and skipped, never read (#344)" {
  printf '[remote:a/b]\nhost = x\nport = 2222\n[remote]\nhost = y\nport = 2223\n[remote:r1:impl]\nhost = z\nport = 2224\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *".agent-sandbox: [remote:a/b] -- a remote's name is letters, digits, '-', '_' and '.' (it takes no role suffix); ignoring the section"* ]]
  [[ "$output" == *".agent-sandbox: [remote] needs a name, [remote:<name>]; ignoring the section"* ]]
  [[ "$output" == *".agent-sandbox: [remote:r1:impl] -- a remote's name is"* ]]
  [[ "$output" != *"sandboxed login"* ]]
}

@test "[remote:ALIAS]: an edit of one of its lines changes the trust digest, and the launch says the file changed (#344)" {
  printf '[remote:r1]\nhost = ex.example.org\nport = 0.0.0.0:2222\n' >"$PROJ/.agent-sandbox"
  engine_cmd
  (cd "$PROJ" && printf 'y\nn\n' | env -i HOME="$H/home" PATH="$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}" --trust >/dev/null 2>&1)
  [ -f "$REC" ]
  local before
  before="$(cat "$REC")"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # approved: the launch runs, the section changing nothing in it
  sed -i 's/^port = 0.0.0.0:2222$/port = 0.0.0.0:2223/' "$PROJ/.agent-sandbox"
  grep -qx 'port = 0.0.0.0:2223' "$PROJ/.agent-sandbox"
  : >"$H/argv"
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has changed since you approved it"* ]]
  [ ! -s "$H/argv" ]
  [ "$(cat "$REC")" = "$before" ] # nothing re-recorded
}

@test "--check lists each [remote:ALIAS] after the role's plan, one line each (#344)" {
  full_section
  printf '[remote:r2]\nhost = qgpu3\nport = 2222\n[remote:r3]\nhost = q\n' >>"$PROJ/.agent-sandbox"
  check --role implementer-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"check: a launch would apply the above"*"remote bench-ex: ex.example.org as tob, port 0.0.0.0:2222"$'\n'"remote r2: qgpu3 as the ssh user, port 2222"$'\n'"remote r3: unusable as written (the review above says why)"* ]]
}

@test "a dot-file without [remote:ALIAS] gets no remote line at the review or at --check (#344)" {
  printf '[ssh]\nbench-ex\n[allow]\npypi.org\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[ssh] bench-ex: SSH to it as you"* ]]
  [[ "$output" != *"[remote"* ]]
  [[ "$output" != *"is the remote"* ]]
  [[ "$output" != *"no role reaches"* ]]
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"check: a launch would apply the above"* ]]
  [[ "$output" != *$'\n'"remote "* ]]
  [[ "$output" != *setup-remote* ]]
}
