#!/usr/bin/env bats
# Roles (#129 step 7): a role is a named, persistent instance of a project under a policy.
# The name is the sandbox key's second half; the policy comes from the dot-file's
# role-suffixed sections, `[<section>:<glob>]`, applied after the unsuffixed ones, in file
# order, later overriding earlier PER KEY. [sandbox:...], [connect:...] and (#221)
# [allow:...], [deny:...], [env:...], [conda:...] and [net:...] take the suffix. There is
# no [role:...] section.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  C="$H/home/.claude"
  mkdir -p "$C/rules" "$C/skills"
  STATE="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}"
}

slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}
trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}
dotfile() { # dotfile TEXT -- write and approve the project's dot-file
  printf '%s' "$1" >"$PROJ/.agent-sandbox"
  trust
}
own_bind() { argv_has --bind "$STATE/$1/$2/own/$(slugify "$3")" "$3"; }

@test "--role names the sandbox: two roles are two sandbox directories" {
  run_engine -- asb --role impl-1 --connect 'skills=own native' claude --version
  [ "$status" -eq 0 ]
  own_bind impl-1 skills "$C/skills"
  run_engine -- asb --role reviewer --connect 'skills=own native' claude --version
  own_bind reviewer skills "$C/skills"
  [ -d "$STATE/impl-1" ] && [ -d "$STATE/reviewer" ]
}

@test "no --role is the default role, and --role default is the same" {
  run_engine -- asb --connect 'skills=own native' claude --version
  own_bind default skills "$C/skills"
  run_engine -- asb --role default --connect 'skills=own native' claude --version
  own_bind default skills "$C/skills"
}

@test "the role takes three forms: flag over environment over [sandbox] role" {
  dotfile $'[sandbox]\nrole = from-file\n'
  run_engine -- asb --connect 'skills=own native' claude --version
  [ "$status" -eq 0 ]
  own_bind from-file skills "$C/skills"
  run_engine AGENT_SANDBOX_ROLE=from-env -- asb --connect 'skills=own native' claude --version
  own_bind from-env skills "$C/skills"
  run_engine AGENT_SANDBOX_ROLE=from-env -- asb --role from-flag --connect 'skills=own native' claude --version
  own_bind from-flag skills "$C/skills"
  run_engine -- asb --role=eq-form --connect 'skills=own native' claude --version
  own_bind eq-form skills "$C/skills"
}

@test "a role-suffixed [connect] applies to the roles its glob matches, and not to others" {
  dotfile $'[connect:impl-*]\nskills = own native\n\n[connect:*]\n'
  run_engine -- asb --role impl-7 claude --version
  [ "$status" -eq 0 ]
  own_bind impl-7 skills "$C/skills"
  run_engine -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "/reviewer/skills/own/" "$H/argv"
}

@test "later sections override earlier ones per key, and an unrelated key survives" {
  dotfile $'[connect]\nskills = own native\ninstructions = own native\n\n[connect:impl-*]\nskills = read-only native\n\n[connect:*]\n'
  run_engine -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/skills" "$C/skills"      # the later, suffixed line won
  own_bind impl-1 instructions "$C/rules"         # the earlier key it did not name stays
  run_engine -- asb --role other claude --version # a role the suffix does not match
  own_bind other skills "$C/skills"
}

@test "[sandbox:<glob>] preset applies per role, after the unsuffixed one" {
  dotfile $'[sandbox]\npreset = shared\n\n[sandbox:iso-*]\npreset = isolated\n\n[sandbox:*]\n'
  TEST_PRESET='' run_engine -- asb --role iso-1 claude --version
  [ "$status" -eq 0 ]
  own_bind iso-1 skills "$C/skills"
  TEST_PRESET='' run_engine -- asb --role plain claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "/plain/skills/own/" "$H/argv"
}

@test "a name matching no suffixed section is refused, naming the sections that exist" {
  dotfile $'[connect:impl-*]\nskills = own native\n[sandbox:reviewer]\npreset = isolated\n'
  run_engine -- asb --role revewer claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'revewer' matches no role section"*"impl-*"*"reviewer"* ]]
  [ ! -s "$H/argv" ]
}

@test "without any suffixed section, any role name is the one policy, a separate instance" {
  dotfile $'[connect]\nskills = own native\n'
  run_engine -- asb --role scratch-42 claude --version
  [ "$status" -eq 0 ]
  own_bind scratch-42 skills "$C/skills"
}

@test "[connect:*] matches every role, so nothing is refused" {
  dotfile $'[connect:*]\nskills = own native\n'
  run_engine -- asb --role anything claude --version
  [ "$status" -eq 0 ]
}

@test "role names: letters, digits, . _ - after a letter or digit; nothing else" {
  local bad
  for bad in -lead 'a/b' 'a@b' 'a*b' 'a?b' '' '.dot'; do
    run_engine -- asb --role "$bad" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"role"* ]]
    [ ! -s "$H/argv" ]
  done
  run_engine -- asb --role "$(printf 'r%.0s' {1..201})" claude --version
  [ "$status" -ne 0 ]
  run_engine -- asb --role "A.b_c-9" claude --version
  [ "$status" -eq 0 ]
}

@test "role is a key of the unsuffixed [sandbox] only" {
  dotfile $'[sandbox:x]\nrole = y\n'
  run_engine -- asb --role x claude --version
  [[ "$output" != *"[sandbox:x] role"* ]] # ignored quietly: the review said it
  run_review
  [[ "$output" == *"[sandbox:x] role"* ]]
}

@test "a suffix on a section that does not take one is said, not silently honoured" {
  dotfile $'[seccomp:impl-*]\nmode = off\n[connect:*]\n'
  run_engine -- asb --role impl-1 claude --version
  [[ "$output" != *"seccomp mode 'off'"* ]] # the skipped section applied to nobody
  run_review
  [[ "$output" == *"[seccomp:impl-*]"*"role suffix"* ]]
}

@test "[net:<role>] and [env:<role>] apply to the roles they match, over the unsuffixed section, per key (#221)" {
  dotfile $'[net]\nmode = proxy\n[env]\nMY_TOOL\n[net:impl-*]\nmode = none\n[env:impl-*]\nIMPL_ONLY\n[connect:reviewer]\n'
  run_engine MY_TOOL=a IMPL_ONLY=b -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --share-net
  [ "$(setenv_value MY_TOOL)" = a ]
  [ "$(setenv_value IMPL_ONLY)" = b ]
  run_engine MY_TOOL=a IMPL_ONLY=b -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  argv_has --share-net
  [ "$(setenv_value MY_TOOL)" = a ]
  run ! setenv_value IMPL_ONLY
}

@test "a role-suffixed [env], [net], [allow], [deny] or [conda] defines a role: a name none matches is refused (#221)" {
  dotfile $'[env:impl-*]\nIMPL_ONLY\n'
  run_engine -- asb --role reviewer claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"matches no role section"* ]]
}

@test "the review reads every role's lines, whatever role launches (#221)" {
  dotfile $'[env:impl-*]\nPINNED = yes\n[net:reviewer]\nmode = bogus\n'
  run_review
  [[ "$output" == *"[env] PINNED = ...: a project's file only forwards"* ]]
  [[ "$output" == *"[net] mode 'bogus' unknown"* ]]
}

@test "[allow:<role>] and [deny:<role>]: the session's grant and its denial, for that role only; never the profile's own hosts (#221)" {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"; for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/*.txt; do printf '== %s\n' "${f##*/}"; cat "$f"; done >"${BWRAP_PROBE:?}" 2>&1
. "${0%/*}/keeper-tail"
STUB
  dotfile $'[deny]\npypi.org\n[allow:impl-*]\nfiles.example.org\n[deny:reviewer]\ngithub.com\n.anthropic.com\n'
  run_engine BWRAP_PROBE="$H/probe" -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  sed -n '/^== allow.txt$/,/^== /p' "$H/probe" | grep -qx 'files.example.org'
  [ "$(sed -n '/^== deny.txt$/,$p' "$H/probe" | sed 1d)" = pypi.org ]
  run_engine BWRAP_PROBE="$H/probe" -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"[deny] .anthropic.com would take the profile's own host"* ]]
  run ! grep -qx 'files.example.org' "$H/probe"
  [ "$(sed -n '/^== deny.txt$/,$p' "$H/probe" | sed 1d | paste -sd' ')" = "pypi.org github.com" ]
}

@test "[net:<role>] retrieve-only = on: the session's file names only the profile's hosts; other roles have none (#223)" {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"; for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/*.txt; do printf '== %s\n' "${f##*/}"; cat "$f"; done >"${BWRAP_PROBE:?}" 2>&1
. "${0%/*}/keeper-tail"
STUB
  dotfile $'[allow]\nfiles.example.org\n[net:reviewer]\nretrieve-only = on\n[connect:supervisor]\n'
  run_engine BWRAP_PROBE="$H/probe" -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  local ro
  ro="$(sed -n '/^== retrieve-only.txt$/,/^== /p' "$H/probe" | grep -v '^== ')"
  [[ "$ro" == *api.anthropic.com* ]]
  [[ "$ro" != *files.example.org* ]] # a host you allowed is not exempt
  run_engine BWRAP_PROBE="$H/probe" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  run ! grep -q '^== retrieve-only.txt$' "$H/probe"
}

@test "retrieve-only is said: in the briefing, in --check, at the review for a bad value, and ignored without a proxy (#223)" {
  dotfile $'[net:reviewer]\nretrieve-only = on\n[net:other]\nretrieve-only = maybe\n[connect:supervisor]\n'
  run_engine BWRAP_COPY="$H/copied/briefing" -- asb --role reviewer claude --version
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --check --role reviewer 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [[ "$output" == *"network: retrieve-only -- GET and HEAD only"* ]]
  run_review
  [[ "$output" == *"[net] retrieve-only 'maybe' unknown (on|off)"* ]]
  run_engine AGENT_SANDBOX_NET=none -- asb --role reviewer claude --version
  [[ "$output" == *"[net] retrieve-only is ignored with AGENT_SANDBOX_NET=none"* ]]
}

@test "[net:<role>] git = refuse: the session's file, --check's line, and --ssh refused for that role only (#224)" {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
. "${0%/*}/stub-env"
set +x
: >"${BWRAP_DUMP:?}"; for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
for f in "$AGENT_SANDBOX_SESSION_BASE"/session.*/*.txt; do printf '== %s\n' "${f##*/}"; done >"${BWRAP_PROBE:?}" 2>&1
. "${0%/*}/keeper-tail"
STUB
  dotfile $'[net:impl-*]\ngit = refuse\n[net:other]\ngit = maybe\n[connect:supervisor]\n'
  run_engine BWRAP_PROBE="$H/probe" -- asb --role impl-1 claude --version
  [ "$status" -eq 0 ]
  grep -qx '== git-refuse.txt' "$H/probe"
  run_engine BWRAP_PROBE="$H/probe" -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  run ! grep -qx '== git-refuse.txt' "$H/probe"
  run_engine -- asb --role impl-1 --ssh github.com claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ssh is refused for role 'impl-1': its .agent-sandbox [net] says git = refuse"* ]]
  [ ! -s "$H/argv" ]
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "$4" --check --role impl-1 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$ENGINE"
  [[ "$output" == *"git transport: refused"* ]]
  run_review
  [[ "$output" == *"[net] git 'maybe' unknown (allow|refuse)"* ]]
}

@test "[conda:<role>] prefix activates an env by its path, for that role; a path that is no env is ignored, said (#221)" {
  local base="$H/conda" clone="$PROJ/.asb/impl-1/.env"
  mkdir -p "$base/envs/x-dev/conda-meta" "$base/pkgs" "$clone/conda-meta" "$clone/bin"
  dotfile $'[conda]\nname = x-dev\n[conda:implementer-1]\nprefix = .asb/impl-1/.env\n[conda:reviewer]\nprefix = .asb/none\n[connect:supervisor]\n'
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --role implementer-1 claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value CONDA_PREFIX)" = "$clone" ]
  [ "$(setenv_value CONDA_DEFAULT_ENV)" = "$clone" ]
  [[ "$(setenv_value PATH)" == "$clone/bin:"* ]]
  argv_has --ro-bind "$clone" "$clone"
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --role supervisor claude --version
  [ "$(setenv_value CONDA_PREFIX)" = "$base/envs/x-dev" ]
  run_engine MAMBA_ROOT_PREFIX="$base" -- asb --role reviewer claude --version
  [[ "$output" == *"conda prefix '.asb/none' is not a conda env"* ]]
}

@test "a non-default role with --bg runs in that role's launch (#123)" {
  run_engine -- asb --role impl-1 --connect 'skills=own native' claude --bg 'do it'
  [ "$status" -eq 0 ]
  own_bind impl-1 skills "$C/skills"
  join_has "$H/home/.local/share/claude/versions/2.1.300/claude" --bg 'do it'
}
