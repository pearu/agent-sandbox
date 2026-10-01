#!/usr/bin/env bats
# Connections: the three knob forms, what they refuse, and the bwrap argv each
# mode produces. The argv IS the contract -- it is what decides whether a
# channel is open -- so the binds are pinned here token by token.
#
# Every channel is `live` by default, which is exactly what the engine did
# before connections existed, so the first test below is the one that proves
# this feature is invisible until asked for.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  C="$H/home/.claude"
  mkdir -p "$C/rules"
  STATE="$H/home/.local/state/agent-sandbox"
  PROJ="$(cd "$H/proj" && pwd -P)"
  # The engine's own sandbox key: <state>/<profile>/<project slug>/<role>/
  SBOX="$STATE/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
  CFG="$H/home/.config/agent-sandbox"
}

# The name a channel path gets inside a slot directory: the engine's _as_iso_slug,
# which flattens the path and drops the leading separator.
slugify() {
  local s="${1//\//_}"
  printf '%s' "${s#_}"
}

teardown() {
  [[ -n "${FAKE_SESSION_PID:-}" ]] && kill "$FAKE_SESSION_PID" 2>/dev/null
  return 0
}

# A session dir the engine will believe is live: the owner's PID and start-time,
# which is the same pair the janitor uses and is immune to PID reuse, plus the
# sandbox it is holding an overlay for. Detached from stdout, or a live child
# holds bats' pipe open and the run hangs instead of finishing.
# Record approval of $H/proj/.agent-sandbox the way `--trust` would.
approve_dotfile() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$H/proj/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "no connection asked for: not one bind changes, so the feature is invisible by default" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  # The whole state directory, read-write, exactly as before.
  argv_has --bind "$C" "$C"
  # and nothing layered over the instructions channel
  run ! argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "live is spelled out and still changes nothing: it is today's behaviour named" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-write native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "ro rebinds each of the channel's paths read-only, over the read-write state bind" {
  : >"$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
  argv_has --ro-bind "$C/rules" "$C/rules"
  # AFTER the state bind, or it would be shadowed by it and grant read-write.
  [ "$(argv_index "$C/CLAUDE.md")" -gt "$(argv_index "$C")" ]
}

@test "ro over a path the source does not have still binds something read-only" {
  # Otherwise the parent is read-write and the sandbox could CREATE the file,
  # authoring at a channel it was told it may only read.
  rm -f "$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- asb claude --version
  [ "$status" -eq 0 ]
  # Scan for `--ro-bind SRC $C/CLAUDE.md` rather than indexing off the path:
  # with the source absent the path appears as the DESTINATION, not the source,
  # so its first occurrence sits one argument further along than in the case
  # above. Asserting the triple is both clearer and immune to that.
  local i found=0
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    if [[ "${ARGV[i]}" == --ro-bind && "${ARGV[i + 2]}" == "$C/CLAUDE.md" ]]; then
      found=1
      # bound FROM somewhere that is not the source, which has no such file
      [ "${ARGV[i + 1]}" != "$C/CLAUDE.md" ]
      [ ! -e "$C/CLAUDE.md" ] # and the source still does not have one
      break
    fi
  done
  [ "$found" -eq 1 ]
}

@test "none binds a private slot from the engine's state, not a tmpfs" {
  # A tmpfs would forget what the sandbox wrote; `none` promises the sandbox
  # keeps its own (study cell N3).
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")" "$C/CLAUDE.md"
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  run ! argv_has --tmpfs "$C/CLAUDE.md"
  [ -d "$SBOX/instructions/own/$(slugify "$C/rules")" ]
}

@test "the slot survives the session: it is state, not scratch" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- asb claude --version
  printf 'the sandbox wrote this\n' >"$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")"
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")")" = "the sandbox wrote this" ]
}

@test "a mount point the bind creates on the host is cleaned up again" {
  # MEASURED: without this the engine left an empty, unwritable ~/.claude/CLAUDE.md
  # behind, and the next write to it failed. The engine already had this problem
  # with the config file and already had the list that fixes it.
  rm -f "$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- asb claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$C/CLAUDE.md" ]
}

@test "each form is honoured, and the flag beats the environment" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- \
    asb --connect 'instructions=read-only native' claude --version
  [ "$status" -eq 0 ]
  : >"$C/CLAUDE.md"
  argv_has --ro-bind "$C/rules" "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "several specs in the environment are separated by semicolons, since a spec has spaces" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native;skills=own native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
  argv_has --bind "$SBOX/skills/own/$(slugify "$C/skills")" "$C/skills"
}

@test "an approved dot-file is honoured, and the environment beats it" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[connect]
instructions = own native
EOF
  approve_dotfile
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "an UNAPPROVED dot-file grants nothing, so a channel is not closed by an unreviewed file" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[connect]
instructions = own native
EOF
  run_engine -- asb claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"*"--trust"* ]]
  [ ! -s "$H/argv" ]
}

@test "--connect is repeatable, and the last spec for a channel wins" {
  : >"$C/CLAUDE.md"
  run_engine -- asb --connect 'skills=own native' \
    --connect 'instructions=own native' --connect 'instructions=read-only native' claude --version
  [ "$status" -eq 0 ]
  # the other channel is untouched by the repetition
  argv_has --bind "$SBOX/skills/own/$(slugify "$C/skills")" "$C/skills"
  # and the later spec for instructions replaced the earlier one
  argv_has --ro-bind "$C/rules" "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "connection binds come BEFORE the per-session scratch, so the scratch still wins" {
  # Asserted here because nothing would fail today: no channel path overlaps an
  # isolated one. The order is load-bearing all the same -- a channel at `live`
  # must still not hand over another session's paste cache -- and an overlap is
  # exactly the kind of thing a later channel addition introduces quietly.
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- asb claude --version
  [ "$status" -eq 0 ]
  local connect scratch
  connect="$(argv_index "$SBOX/instructions/own/$(slugify "$C/rules")")"
  scratch="$(argv_index "$C/paste-cache")"
  [ -n "$connect" ]
  [ -n "$scratch" ]
  [ "$connect" -lt "$scratch" ]
}

@test "cow asks bwrap for an overlay on a directory-shaped path" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules" --overlay \
    "$SBOX/instructions/upper/$(slugify "$C/rules")" \
    "$SBOX/instructions/work/$(slugify "$C/rules")" "$C/rules"
}

@test "cow on a FILE-shaped path is copy, permanently: overlayfs cannot stack on a file" {
  printf 'YOURS\n' >"$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")"
  argv_has --bind "$slot" "$C/CLAUDE.md"
  [ "$(cat "$slot")" = YOURS ]
  # no overlay was attempted for it
  run ! argv_has --overlay-src "$C/CLAUDE.md"
}

@test "--overlay off forces the copy fallback, and the launch SAYS so even when quiet" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect 'instructions=copy-on-write native' --overlay off claude --version
  [ "$status" -eq 0 ]
  # BEFORE the `run !` below, which replaces $output -- the helper warns about
  # exactly this and it is easy to do anyway.
  [[ "$output" == *"copy-on-write is using copy here"* ]]
  [[ "$output" == *"overlay is turned off"* ]]
  argv_has --bind "$SBOX/instructions/copy/$(slugify "$C/rules")" "$C/rules"
  run ! argv_has --overlay-src "$C/rules"
}

@test "the overlay knob takes all three forms, flag beating environment beating file" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[overlay]
mode = off
EOF
  approve_dotfile
  run_engine -- asb --connect 'instructions=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --overlay-src "$C/rules" # the file turned it off

  run_engine AGENT_SANDBOX_OVERLAY=auto -- asb --connect 'instructions=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules" # the environment overrode the file

  run_engine AGENT_SANDBOX_OVERLAY=auto -- \
    asb --connect 'instructions=copy-on-write native' --overlay off claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --overlay-src "$C/rules" # and the flag overrode the environment
}

@test "an unknown overlay mode keeps auto rather than guessing" {
  run_engine AGENT_SANDBOX_OVERLAY=sideways -- \
    asb --connect 'instructions=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown mode 'sideways'"* ]]
  argv_has --overlay-src "$C/rules"
}

@test "--reset clears an overlay's upper layer, whiteouts and all" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  local upper
  upper="$SBOX/instructions/upper/$(slugify "$C/rules")"
  mkdir -p "$upper"
  printf 'SANDBOX\n' >"$upper/topic.md"
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  [ ! -e "$upper/topic.md" ]
}

@test "--reset REFUSES while something is joined into this role's keeper" {
  # It removes the very layers the keeper has mounted, and the conflict warning
  # actively tells the user to run it -- reading that in one terminal while the
  # role runs in another is the ordinary case, not an edge one.
  engine_bg AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  run_engine -- asb --reset instructions claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"role 'default' is running"* ]]
  release_bg
}

@test "and it goes ahead once that join is gone" {
  engine_bg AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  release_bg
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
}

@test "an IDLE keeper does not block a reset: it is ended first" {
  # Within its grace an idle keeper still has the overlays mounted; the reset ends it
  # rather than refusing, since nothing is using them.
  local upper
  upper="$SBOX/instructions/upper/$(slugify "$C/rules")"
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  release_bg
  [ -e "$SBOX/keeper/id" ] # still there, waiting out its grace
  mkdir -p "$upper"
  printf 'SANDBOX\n' >"$upper/topic.md"
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  [ ! -e "$SBOX/keeper/id" ]
  [ ! -e "$upper/topic.md" ]
}

@test "a running keeper of ANOTHER role does not block a reset" {
  engine_bg AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb --role other claude --version
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  release_bg
}

@test "a second launch of a running role joins it: one keeper, one set of mounts" {
  # Two launches of one role would be two overlays over one upper layer, which
  # overlayfs calls undefined. There is never a second: the second invocation is a
  # join into the first one's keeper, and nothing is mounted for it.
  engine_bg AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  run_engine AGENT_SANDBOX_VERBOSE= AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude -p hi
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ] # no second launch
  join_has "$H/home/.local/share/claude/versions/2.1.300/claude" -p hi
  # both joins name the same process
  local a b
  a="$(grep -B1 -m1 '^--$' "$H/join.bg" | head -1)"
  b="$(grep -B1 -m1 '^--$' "$H/join" | head -1)"
  [ -n "$a" ] && [ "$a" = "$b" ]
  release_bg
}

@test "the overlay's lower layer is the SOURCE, so a directory made later shows up" {
  # An earlier version used an empty placeholder when the source directory was
  # missing, to avoid creating anything in the user's own state. With a launch that
  # outlives its apps -- the holder then, the keeper now -- that is actively wrong:
  # the lower is fixed when the overlay is mounted, so a directory the user creates
  # afterwards would stay invisible for as long as the role runs. The study caught
  # it. An overlay can only track the source if the source IS the lower, which
  # means creating it when it is absent -- one empty directory, in a tree bwrap
  # already creates mount points in.
  rm -rf "$C/rules"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- asb claude --version
  [ "$status" -eq 0 ]
  local i src=""
  for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --overlay-src ]] && src="${ARGV[i + 1]}" && break
  done
  [ -n "$src" ]
  [ "$src" = "$C/rules" ]
  [ -d "$C/rules" ]
}

@test "a channel with TWO directories gets an overlay on each" {
  mkdir -p "$C/skills" "$C/commands"
  run_engine AGENT_SANDBOX_CONNECT='skills=copy-on-write native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/skills"
  argv_has --overlay-src "$C/commands"
}

# ----- presets: one position for every channel at once ----------------------
#
# These pass TEST_PRESET or the knob explicitly. Every other suite is pinned to
# `shared` by the harness, so that a change to the engine's default does not
# quietly change what they measure -- which means the default itself needs a test
# that names it, and that is the first one here.

@test "the engine's own default preset puts every declared channel at cow" {
  TEST_PRESET="" run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules"
  argv_has --overlay-src "$C/skills"
  argv_has --overlay-src "$C/agents"
  # and the whole state directory is still bound underneath, as it always was
  argv_has --bind "$C" "$C"
}

@test "independent gives the sandbox nothing of the native install" {
  run_engine AGENT_SANDBOX_PRESET=isolated -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  argv_has --bind "$SBOX/skills/own/$(slugify "$C/skills")" "$C/skills"
  run ! argv_has --overlay-src "$C/rules"
}

@test "shared is the engine before 0.3: not one channel is layered over" {
  run_engine AGENT_SANDBOX_PRESET=shared -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! argv_has --overlay-src "$C/rules"
  run ! argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "a [connect] line overrides the preset for its own channel and no other" {
  run_engine AGENT_SANDBOX_PRESET=isolated \
    AGENT_SANDBOX_CONNECT='instructions=read-only native' -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"                              # overridden
  argv_has --bind "$SBOX/skills/own/$(slugify "$C/skills")" "$C/skills" # still the preset
}

@test "the preset takes all three forms, flag beating environment beating file" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[sandbox]
preset = isolated
EOF
  approve_dotfile
  TEST_PRESET="" run_engine -- asb claude --version
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_PRESET=shared -- asb claude --version
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_PRESET=shared -- asb --preset isolated claude --version
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "an unknown preset is REFUSED, not defaulted" {
  # Guessing which channels the user meant to move is the one thing a preset
  # must never do: it positions all of them at once.
  run_engine AGENT_SANDBOX_PRESET=paranoid -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown preset 'paranoid'"* ]]
  [ ! -s "$H/argv" ]
}

@test "a preset moves ONLY the channels the engine manages as connections" {
  # The design's table also lists memory, transcripts and the rest. Each still has
  # machinery of its own, and a preset that silently claimed to position them would
  # leave the user believing a channel was shut. The config file is one of the
  # managed ones since #119, so it moves: to its own store under `isolated`.
  run_engine AGENT_SANDBOX_PRESET=isolated -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/config/own/$(slugify "$H/home/.claude/.claude.json")" "$H/home/.claude/.claude.json"
  # memory is still scoped by its own machinery, whatever the preset
  run ! grep -qF "$SBOX/memory" "$H/argv"
}

@test "native is refused from the environment: only the flag can turn isolation off" {
  # Every other preset is takeable from the environment because none of them can
  # widen much. This one switches state isolation off wholesale, and a line in a
  # shell profile would do that for every project, every launch, unnoticed and
  # with no project to approve. Hence a refusal rather than a trust gate.
  run_engine AGENT_SANDBOX_PRESET=native -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"only accepted as the --preset flag"* ]]
  [ ! -s "$H/argv" ]
}

@test "native is refused from a project file too, even an APPROVED one" {
  # Approval says the project is trusted, which is a different question: the file
  # travels with the repository and would take isolation off for anyone who
  # cloned it and said yes once.
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[sandbox]
preset = native
EOF
  approve_dotfile
  TEST_PRESET="" run_engine -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"only accepted as the --preset flag"* ]]
}

@test "--preset native opens every channel and SAYS SO on every launch" {
  run_engine -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  # every declared channel live: nothing layered, nothing shadowed, the state
  # directory straight through
  argv_has --bind "$C" "$C"
  run ! argv_has --overlay-src "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  # and the notice is not suppressible: the quiet default does not silence it
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --preset native claude --version
  [[ "$output" == *"state isolation is OFF"* ]]
}

@test "under native the config file is neither copied nor relocated" {
  # The parity that first justified the preset: natively the file is the user's
  # own at ~/.claude.json, and CLAUDE_CONFIG_DIR -- which exists only because a
  # read-only $HOME loses the writes beside it -- has nothing left to work around.
  run_engine -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  run ! grep -qF "$H/home/.claude/.claude.json" "$H/argv" # nothing bound where the config file would go
  run ! grep -q 'CLAUDE_CONFIG_DIR' "$H/argv"
}

# ----- refusals: every one of these would otherwise leave a channel wide open -

@test "an unknown channel is REFUSED, not ignored: a typo must not read as 'closed'" {
  # The worst outcome this code can produce is a user reading their own dot-file,
  # believing a channel is shut, and it being open. So a name the profile does
  # not carry stops the launch and lists the ones it does.
  run_engine -- asb --connect 'instrctions=none' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'instrctions'"* ]]
  [[ "$output" == *instructions* ]] # it names what the profile does carry
}

@test "an unknown mode is refused" {
  run_engine -- asb --connect 'instructions=readonly' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown mode 'readonly'"* ]]
}

@test "a source other than native is refused while only native is supported" {
  run_engine -- asb --connect 'instructions=read-only sandbox:~/other' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not supported yet"* ]]
}

@test "a malformed spec is refused" {
  run_engine -- asb --connect 'instructions' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 'channel = mode [source] [scope]'"* ]]
}

@test "a trailing token is refused too: a spec is that shape and nothing more" {
  # Everything else malformed is refused, so silently discarding the tail would
  # be the one place a user could write something meaningless and be told
  # nothing about it. A fourth token cannot be anything, so it is the tail.
  run_engine -- asb --connect 'instructions=read-only native run-scoped extra' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"trailing 'extra'"* ]]
}

@test "a second SOURCE is named as such, not reported as a vague tail" {
  # `read-only native extra` is three legal-looking tokens; `extra` has no
  # `-scoped` suffix so it can only be a source, and there is already one.
  run_engine -- asb --connect 'instructions=read-only native extra' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"two sources"* ]]
  [[ "$output" == *"'native' and 'extra'"* ]]
}

# ----- the scope axis ---------------------------------------------------------
#
# A scope says WHICH STORAGE a channel's sandbox side uses: nothing written is the
# role's, `run-scoped` is one run of the role's launch (#105), `join-scoped` one join
# (#147). A combination that is not built is refused, because a scope that is accepted
# and never applied reads as isolation that is not there.

@test "the scope is optional: writing none means the role, today's behaviour" {
  run_engine -- asb --connect 'instructions=read-only native' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "source and scope are told apart by shape, so either order parses" {
  # Both orders bind the same run-scoped store: the scope was recognised as a scope
  # whichever side of the source it stood.
  run_engine -- asb --connect 'instructions=copy native run-scoped' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@run/instructions/copy/$(slugify "$C/rules")" "$C/rules"
  run_engine -- asb --connect 'instructions=copy run-scoped native' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@run/instructions/copy/$(slugify "$C/rules")" "$C/rules"
}

@test "read-write plus a scope is refused: there is nothing left to scope" {
  # PERMANENT, not a statement about what is built. At read-write the sandbox
  # writes the source itself, so no sandbox-side storage exists for a scope to
  # apply to -- the spec cannot mean what its author thinks. Checked before
  # implementation status, so it stays true once the scopes land.
  local sc
  for sc in run-scoped join-scoped; do
    run_engine -- asb --connect "instructions=read-write $sc" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not mean anything"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "join-scoped is built for own, copy, seed-only and read-only; an overlay per join is refused, naming #153" {
  run_engine -- asb --connect "instructions=copy-on-write native join-scoped" claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'copy-on-write join-scoped' is not implemented"*"'own', 'copy', 'seed-only' and 'read-only'"*"#153"* ]]
  [ ! -s "$H/argv" ]
  local m
  for m in copy seed-only; do
    run_engine -- asb --connect "instructions=$m native join-scoped" claude --version
    [ "$status" -eq 0 ]
  done
  run_engine -- asb --connect 'instructions=read-only native join-scoped' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules" # nothing is written, so it is the plain bind
  run ! grep -q -- '--private' "$H/join"
}

@test "own join-scoped: the launch shows an empty read-only mount point and binds the staging directory" {
  mkdir -p "$PROJ/scratch"
  run_engine -- asb --connect './scratch/=own join-scoped' claude --version
  [ "$status" -eq 0 ]
  local i
  i="$(argv_index "$PROJ/scratch")"
  [ "${ARGV[i - 2]}" = --ro-bind ]
  [[ "${ARGV[i - 1]}" == "$H/base/session."*/connect/@join/* ]]
  argv_has --bind "$SBOX/@join-stage" /run/agent-sandbox-stage
}

@test "own join-scoped: each join is given its own store to bind, and it is removed when the join ends" {
  mkdir -p "$PROJ/scratch"
  run_engine -- asb --connect './scratch/=own join-scoped' claude --version
  [ "$status" -eq 0 ]
  local i jid=""
  for ((i = 0; i + 4 < ${#JOIN[@]}; i++)); do
    if [[ "${JOIN[i]}" == --private ]]; then
      [ "${JOIN[i + 1]}" = "$SBOX/@join-stage" ]
      [ "${JOIN[i + 2]}" = /run/agent-sandbox-stage ]
      [ "${JOIN[i + 3]}" = "$SBOX/@join" ]
      jid="${JOIN[i + 4]}"
    fi
  done
  [[ "$jid" == j[0-9]* ]]
  grep -A2 -x -- --private-path "$H/join" | grep -qx "$PROJ/scratch"
  [ ! -e "$SBOX/@join-stage/$jid" ] # gone with the join
  [ ! -e "$SBOX/@join/$jid" ]
}

# The seeded modes per join (#153): each join's store starts as a copy of the source as
# it is at that join. The stub join does not move the store out of staging, so while a
# join is held it can be looked at there.
join_store() { # PATH -> the held join's store for PATH
  local s="${1//\//_}" d
  for d in "$SBOX/@join-stage"/j*; do
    [[ -e "$d/${s#_}" ]] && printf '%s' "$d/${s#_}"
  done
}

@test "copy join-scoped: each join's store is seeded from the source as it is at that join" {
  mkdir -p "$PROJ/data"
  printf 'FIRST\n' >"$PROJ/data/a"
  engine_bg -- asb --connect './data/ = copy join-scoped' claude --version
  local st
  st="$(join_store "$PROJ/data")"
  [ -n "$st" ]
  [ "$(cat "$st/a")" = FIRST ]
  printf 'THE JOIN\n' >"$st/a" # what this join writes is its own
  release_bg
  [ "$(cat "$PROJ/data/a")" = FIRST ]
  printf 'SECOND\n' >"$PROJ/data/a"
  engine_bg -- asb --connect './data/ = copy join-scoped' claude --version
  st="$(join_store "$PROJ/data")"
  [ "$(cat "$st/a")" = SECOND ] # the next join starts from the source again
  release_bg
}

@test "seed-only join-scoped on a channel: seeded per join from your files" {
  mkdir -p "$C/skills" "$C/commands"
  printf 'NATIVE\n' >"$C/skills/s.md"
  engine_bg -- asb --connect 'skills=seed-only native join-scoped' claude --version
  local st
  st="$(join_store "$C/skills")"
  [ -n "$st" ]
  [ "$(cat "$st/s.md")" = NATIVE ]
  release_bg
}

@test "a channel whose seed is a filtered view refuses the seeded modes per join" {
  local ch
  for ch in config transcripts; do
    run_engine -- asb --connect "$ch=copy native join-scoped" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"'copy join-scoped' is refused for '$ch'"*"filtered view"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "a channel can be own join-scoped too" {
  mkdir -p "$C/skills" "$C/commands"
  run_engine -- asb --connect 'skills=own native join-scoped' claude --version
  [ "$status" -eq 0 ]
  grep -A2 -x -- --private-path "$H/join" | grep -qx "$C/skills"
  grep -A2 -x -- --private-path "$H/join" | grep -qx "$C/commands"
}

@test "run-scoped stores live apart from the role's, under @run" {
  run_engine -- asb --connect 'skills=own native run-scoped' --connect 'instructions=own native' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@run/skills/own/$(slugify "$C/skills")" "$C/skills"
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "a run-scoped store is gone when the run ends, and the role's own store stays" {
  run_engine -- asb --connect 'skills=own native run-scoped' --connect 'instructions=own native' claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$SBOX/@run" ]                                 # the supervisor cleared it at exit
  [ -d "$SBOX/instructions/own/$(slugify "$C/rules")" ] # the role's store is kept
}

@test "a run-scoped store left by a run that did not end cleanly is cleared at the next cold start" {
  # A keeper killed with -9 runs no exit step; the next launch is what clears.
  local st
  st="$SBOX/@run/skills/own/$(slugify "$C/skills")"
  mkdir -p "$st"
  printf 'LEFT\n' >"$st/stale.md"
  engine_bg -- asb --connect 'skills=own native run-scoped' claude --version
  [ -d "$st" ]
  [ ! -e "$st/stale.md" ]
  release_bg
}

@test "a join into a running launch shares its run-scoped store: one run is one installation" {
  engine_bg -- asb --connect 'skills=own native run-scoped' claude --version
  local st
  st="$SBOX/@run/skills/own/$(slugify "$C/skills")"
  printf 'THIS RUN\n' >"$st/x.md"
  run_engine -- asb --connect 'skills=own native run-scoped' claude --version
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ]                   # joined, not rebuilt
  [ "$(cat "$st/x.md")" = "THIS RUN" ] # and not cleared
  release_bg
  [ ! -e "$SBOX/@run" ]
}

# The seeding modes run-scoped: seeded from the source when the run starts, the run's own
# while it lasts, gone at its end -- and the next run seeds afresh rather than finding the
# last one's writes.
seeded_run_scoped() { # MODE
  local m="$1" st
  st="$SBOX/@run/instructions/$m/$(slugify "$C/rules")"
  printf 'NATIVE\n' >"$C/rules/topic.md"
  engine_bg -- asb --connect "instructions=$m native run-scoped" claude --version
  grep -qxF -- "$st" "$H/argv.bg"      # the run's store is what is bound
  [ "$(cat "$st/topic.md")" = NATIVE ] # seeded
  printf 'THIS RUN\n' >"$st/topic.md"  # what the run writes
  release_bg
  [ ! -e "$SBOX/@run" ]
  engine_bg -- asb --connect "instructions=$m native run-scoped" claude --version
  [ "$(cat "$st/topic.md")" = NATIVE ] # the next run starts from the source
  release_bg
  [ "$(cat "$C/rules/topic.md")" = NATIVE ] # which was never written
  [ ! -e "$SBOX/instructions/$m" ]          # and nothing went to the role's own store
}

@test "copy run-scoped: seeded when the run starts, its own while it lasts, afresh at the next run" {
  seeded_run_scoped copy
}

@test "seed-only run-scoped: seeded when the run starts, its own while it lasts, afresh at the next run" {
  seeded_run_scoped seed-only
}

@test "read-only run-scoped is accepted, and is the plain read-only bind: nothing is ever written" {
  run_engine -- asb --connect 'instructions=read-only native run-scoped' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "outside: a declaration's source is another path outside, bound or seeded at the key (#174)" {
  mkdir -p "$H/data/tpl"
  printf 'OUT\n' >"$H/data/out.txt"
  printf 'T\n' >"$H/data/tpl/t.md"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect "~/in.txt = read-only outside:$H/data/out.txt" \
    --connect "./cfg/ = seed-only outside:$H/data/tpl" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/data/out.txt" "$H/home/in.txt"
  local slot
  slot="$SBOX/@paths/seed-only/$(slugify "$PROJ/cfg")"
  argv_has --bind "$slot" "$PROJ/cfg"
  [ "$(cat "$slot/t.md")" = T ] # seeded from the outside source
  [ ! -e "$PROJ/cfg" ]          # the key needs no path of its own outside
  # `~` in the source is expanded
  mkdir -p "$H/home/dot"
  run_engine -- asb --connect "/srv/x/ = read-only outside:~/dot" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/dot" /srv/x
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "outside: refused for own, relative, over / or HOME, or protected; another source token is not a path's" {
  mkdir -p "$H/home/.ssh" "$H/data"
  local spec
  for spec in "./a/ = own outside:$H/data" './a = read-only outside:data' "./a/ = read-only outside:/" \
    './a/ = read-only outside:~' './a/ = read-only outside:~/.ssh' './a = read-only native'; do
    run_engine -- asb --connect "$spec" claude --version
    [ "$status" -ne 0 ]
    [ ! -s "$H/argv" ]
  done
  run_engine -- asb --connect './a/ = read-only outside:~/.ssh' claude --version
  [[ "$output" == *"secret store"* ]]
}

@test "outside: an absent source is skipped this launch, naming it; under --preset native nothing is relocated" {
  run_engine -- asb --connect "./a.txt = read-only outside:$H/nope.txt" claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"'./a.txt' (outside:$H/nope.txt) does not exist"* ]]
  run ! grep -qx "$PROJ/a.txt" "$H/argv"
  printf 'x\n' >"$H/there.txt"
  run_engine -- asb --preset native --connect "./a.txt = read-only outside:$H/there.txt" claude --version
  [ "$status" -eq 0 ]
  run ! grep -qx "$H/there.txt" "$H/argv"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "outside: the review names the source, and says a file is bound over" {
  printf 'x\n' >"$H/home/real.json"
  printf '[connect]\n~/.agent/config.json = seed-only outside:~/real.json\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"'~/.agent/config.json' follows '$H/home/real.json' outside"* ]]
  [[ "$output" == *"this puts your real '$H/home/real.json' there, at seed-only"* ]]
  [[ "$output" == *"'~/.agent/config.json' is a file"* ]]
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "{slug}: this project's name in the agent's own scheme, in a declaration's key and its outside: source (#176)" {
  local slug="${PROJ//[^A-Za-z0-9-]/-}"
  mkdir -p "$H/home/.claude/projects/$slug/notes" "$H/data/$slug"
  run_engine -- asb --connect '~/.claude/projects/{slug}/notes/ = read-only' \
    --connect "/srv/p/ = read-only outside:$H/data/{slug}" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.claude/projects/$slug/notes" "$H/home/.claude/projects/$slug/notes"
  argv_has --ro-bind "$H/data/$slug" /srv/p
  # and in the channel table: the transcripts channel's per-project directory
  TEST_PRESET=isolated run_engine -- asb claude --version
  grep -qx "$H/home/.claude/projects/$slug" "$H/argv"
}

@test "{slug}: any other placeholder is refused, and so is {slug} for a profile without profile_slug" {
  run_engine -- asb --connect './{project}/ = own' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown placeholder {project}"* ]]
  mkdir -p "$H/profiles2/other"
  printf 'profile_command=true\n' >"$H/profiles2/other/profile.sh"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- agent-sandbox --profile other --connect './{slug}/ = own' --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a profile that defines profile_slug"* ]]
}

@test "[channel:<name>]: a profile's channel table, with {base}, kinds by the slash, outside:/filter:/vendor: (#190)" {
  mkdir -p "$H/profiles2/other" "$H/home/.other/stuff" "$H/home/src"
  printf 'profile_command=true\nprofile_slug() { printf slug; }\n' >"$H/profiles2/other/profile.sh"
  printf 'x\n' >"$H/home/src/conf.json"
  cat >"$H/profiles2/other/agent-sandbox" <<'DF'
[agent]
base = ~/.other
[channel:stuff]
{base}/stuff/ = vendor:cache/
{base}/conf.json = outside:~/src/conf.json
{base}/by/{slug}/
DF
  run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- agent-sandbox --profile other --connect 'stuff = read-only' --exec true
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.other/stuff" "$H/home/.other/stuff"
  argv_has --ro-bind "$H/home/src/conf.json" "$H/home/.other/conf.json" # its outside: source
  # an unknown token, or a path not under {base}, ~ or /, refuses the launch
  local bad
  for bad in '{base}/a = sideways:x' 'relative/path'; do
    printf '[agent]\nbase = ~/.other\n[channel:stuff]\n%s\n' "$bad" >"$H/profiles2/other/agent-sandbox"
    run_engine AGENT_SANDBOX_PROFILE_DIR="$H/profiles2" -- agent-sandbox --profile other --exec true
    [ "$status" -ne 0 ]
    [[ "$output" == *"[channel:stuff]"* ]]
  done
  # a project's [channel:...] is not a project's to declare
  printf '[channel:mine]\n~/x/\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"[channel:mine] is a profile's channel table, not a project's"* ]]
}

@test "the base follows CLAUDE_CONFIG_DIR: bound there, pinned there, its channels there, the config file its own (#190)" {
  local alt="$H/home/alt"
  mkdir -p "$alt"
  printf '{"alt":1}' >"$alt/.claude.json"
  TEST_PRESET=isolated run_engine CLAUDE_CONFIG_DIR="$alt" -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$alt" "$alt"
  [ "$(setenv_value CLAUDE_CONFIG_DIR)" = "$alt" ]
  grep -qx "$alt/CLAUDE.md" "$H/argv" # a channel path, under the moved base
  run ! grep -qx "$H/home/.claude" "$H/argv"
  # the config file: with CLAUDE_CONFIG_DIR set, Claude Code keeps it in the base, so its
  # seed comes from there, not from ~/.claude.json
  printf '{"home":1}' >"$H/home/.claude.json"
  TEST_PRESET=inherit run_engine CLAUDE_CONFIG_DIR="$alt" -- asb claude --version
  [ "$status" -eq 0 ]
  local store
  store="$(grep -B1 -x "$alt/.claude.json" "$H/argv" | head -1)"
  grep -q '"alt"' "$store"
  run ! grep -q '"home"' "$store"
}

@test "a running role keeps its base: a join whose CLAUDE_CONFIG_DIR moves it is refused; one that names none joins (#190)" {
  mkdir -p "$H/home/alt"
  engine_bg -- asb claude --version # the role, running on ~/.claude
  run_engine CLAUDE_CONFIG_DIR="$H/home/alt" -- asb claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"running with base = $H/home/.claude"*"CLAUDE_CONFIG_DIR asks for '$H/home/alt'"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- asb claude --version # names no base: joins the running one
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ]
  release_bg
}

@test "the config store is valid JSON even with no config file to seed from, in every preset and base (#190)" {
  # Measured on Claude Code 2.1.285: a 0-byte .claude.json is "corrupted" and the session
  # fails; {} and no file at all both run. The seeding modes' filter turns an absent
  # source into JSON, and `own` starts from {}.
  local alt="$H/home/alt" preset store
  mkdir -p "$alt"
  rm -f "$H/home/.claude.json"
  for preset in inherit isolated shared; do
    TEST_PRESET=$preset run_engine CLAUDE_CONFIG_DIR="$alt" -- asb claude --version
    [ "$status" -eq 0 ]
    store="$(grep -B1 -x "$alt/.claude.json" "$H/argv" | head -1)"
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$store"
    TEST_PRESET=$preset run_engine -- asb claude --version
    [ "$status" -eq 0 ]
    store="$(grep -B1 -x "$H/home/.claude/.claude.json" "$H/argv" | head -1)"
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$store"
  done
}

@test "a declared path can be run-scoped too" {
  mkdir -p "$PROJ/scratch"
  run_engine -- asb --connect './scratch/=own run-scoped' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@run/@paths/own/$(slugify "$PROJ/scratch")" "$PROJ/scratch"
  [ ! -e "$SBOX/@run" ]
}

@test "an unknown scope names the set" {
  run_engine -- asb --connect 'instructions=copy native world-scoped' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown scope 'world-scoped'"* ]]
  [[ "$output" == *"run-scoped|join-scoped"* ]]
  [[ "$output" == *"nothing written means the role"* ]]
}

@test "two scopes in one spec are refused" {
  run_engine -- asb --connect 'instructions=copy run-scoped join-scoped' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"two scopes"* ]]
}

@test "an unimplemented mode is refused in the WORDING the study probes for" {
  # This phrase is a contract with probes/connections/lib.sh (conn_mode_supported),
  # which tells "not implemented yet" apart from "implemented wrong" by reading it.
  # Reword it and an unimplemented mode starts looking like a broken one.
  # Every mode on the scale is implemented now, so nothing triggers this any
  # more and it cannot be asserted through a launch. The wording stays, and is
  # pinned here, because the study's probe still reads it: the next mode added
  # before it works needs this exact phrase, or its cells are reported as broken
  # rather than as not built yet.
  grep -q "connect: mode '\$mode' is not implemented" "$ENGINE"
  for mode in own copy copy-on-write read-only read-write; do
    run_engine -- asb --connect "instructions=$mode" claude --version
    [ "$status" -eq 0 ]
  done
}

@test "copy seeds from the source and binds the sandbox's own copy, not the source" {
  printf 'YOURS\n' >"$C/CLAUDE.md"
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")"
  argv_has --bind "$slot" "$C/CLAUDE.md"
  [ "$(cat "$slot")" = YOURS ]
  # the source itself is never the bind source, or a write inside would reach it
  run ! argv_has --bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "copy warns, naming the file, when both sides changed it -- and quiet does not hide it" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/rules")"
  printf 'SANDBOX\n' >"$slot/topic.md"    # as if the session edited it
  printf 'CHANGED\n' >"$C/rules/topic.md" # and the user changed theirs
  run_engine AGENT_SANDBOX_VERBOSE= AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"topic.md"* ]]
  [[ "$output" == *"--reset instructions"* ]] # it says how to resolve it
  [ "$(cat "$slot/topic.md")" = SANDBOX ]     # and kept the sandbox's
}

@test "--reset takes the source's version back, and does NOT launch" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- asb claude --version
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/rules")"
  printf 'SANDBOX\n' >"$slot/topic.md"
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  [ "$(cat "$slot/topic.md")" = YOURS ]
  [ ! -s "$H/argv" ] # bwrap was never reached: it resets and exits
}

@test "--reset on a channel the profile does not carry is refused" {
  run_engine -- asb --reset nosuch claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'nosuch'"* ]]
}

@test "a refusal stops the launch: bwrap is never reached" {
  run_engine -- asb --connect 'instructions=nonsense' claude --version
  [ "$status" -ne 0 ]
  [ ! -s "$H/argv" ]
}

# ----- path declarations (#106 piece 2) -----------------------------------------
# A [connect] key containing `/` names a PATH rather than a channel. The key is the
# path inside the sandbox; with no source given, the source is the same path
# outside. Relative keys resolve against the project, `~` against $HOME.

@test "a key with a slash is a path: ./data = read-only binds the project's data read-only" {
  mkdir -p "$PROJ/data"
  run_engine -- asb --connect './data = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a relative key resolves against the project, and ~ against HOME" {
  mkdir -p "$PROJ/sub/dir" "$H/home/notes"
  run_engine -- asb --connect 'sub/dir = read-only' --connect '~/notes = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/sub/dir" "$PROJ/sub/dir"
  argv_has --ro-bind "$H/home/notes" "$H/home/notes"
}

@test "a path key keeps its spaces" {
  mkdir -p "$PROJ/my data"
  run_engine -- asb --connect './my data = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/my data" "$PROJ/my data"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "read-write on a path binds the outside path through" {
  mkdir -p "$H/home/shared"
  run_engine -- asb --connect '~/shared = read-write' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/shared" "$H/home/shared"
}

@test "own on a path binds a private slot from the sandbox's state, and it persists" {
  mkdir -p "$PROJ/scratch"
  printf 'the real one\n' >"$PROJ/scratch/f"
  run_engine -- asb --connect './scratch/ = own' claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/own/$(slugify "$PROJ/scratch")"
  argv_has --bind "$slot" "$PROJ/scratch"
  [ -d "$slot" ]
  [ ! -e "$slot/f" ] # never seeded from outside
  : >"$slot/kept"
  run_engine -- asb --connect './scratch/ = own' claude --version
  [ -e "$slot/kept" ]
}

@test "own with a trailing slash on a directory that does not exist creates it, inside only" {
  run_engine -- asb --connect './scratch/ = own' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@paths/own/$(slugify "$PROJ/scratch")" "$PROJ/scratch"
}

@test "own without a trailing slash on a path that does not exist creates a file of its own, kept by the role (#189)" {
  run_engine -- asb --connect './notes.md = own' claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/own/$(slugify "$PROJ/notes.md")"
  [ -f "$slot" ] && [ ! -s "$slot" ] # an empty file, not a directory
  argv_has --bind "$slot" "$PROJ/notes.md"
  [ ! -e "$PROJ/notes.md" ] # nothing outside: the stub made no mount point, and none is left
  printf 'MINE\n' >"$slot"
  run_engine -- asb --connect './notes.md = own' claude --version
  [ "$(cat "$slot")" = MINE ] # the role's, across launches
  # one join's own: an empty file per join
  run_engine -- asb --connect './j.md = own join-scoped' claude --version
  [ "$status" -eq 0 ]
  grep -A2 -x -- --private-path "$H/join" | grep -qx "$PROJ/j.md"
}

@test "a path that does not exist is skipped with a notice, in every other case" {
  local spec
  for spec in './gone/ = read-only' './gone = copy' './gone = read-write' './gone/ = copy-on-write' './gone = seed-only'; do
    run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect "$spec" claude --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"'./gone"*"does not exist"*"skipped"* ]]
    run ! argv_has "$PROJ/gone"
  done
}

@test "a trailing slash on something that is not a directory is refused" {
  : >"$PROJ/AGENT.md"
  run_engine -- asb --connect './AGENT.md/ = read-only' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
  [ ! -s "$H/argv" ]
}

@test "copy on a path seeds the sandbox's own copy from the source" {
  mkdir -p "$PROJ/tools"
  printf 'v1\n' >"$PROJ/tools/t"
  run_engine -- asb --connect './tools/ = copy' claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/copy/$(slugify "$PROJ/tools")"
  argv_has --bind "$slot" "$PROJ/tools"
  [ "$(cat "$slot/t")" = v1 ]
}

@test "a file declaration is bound over, and the launch does not say so: the dot-file's review does, once" {
  printf 'x\n' >"$PROJ/AGENT.md"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect './AGENT.md = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/AGENT.md" "$PROJ/AGENT.md"
  [[ "$output" != *"is a file"* ]]
}

@test "copy-on-write on a file is copy" {
  printf 'x\n' >"$PROJ/AGENT.md"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect './AGENT.md = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@paths/copy/$(slugify "$PROJ/AGENT.md")" "$PROJ/AGENT.md"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "the root, HOME, and parents of HOME are refused as path keys, in every mode" {
  local spec
  for spec in '/ = own' '~/ = own' '~/.. = read-only'; do
    run_engine -- asb --connect "$spec" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"HOME or a parent of it"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "the project and its parents are refused: binding one would cover the project" {
  # One level down, so the project's parent is not also a parent of HOME, which
  # has a refusal of its own.
  mkdir -p "$PROJ/sub"
  local spec
  for spec in './ = own' '../ = read-only' "$PROJ/ = own"; do
    RUN_CWD="$PROJ/sub" run_engine -- asb --connect "$spec" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"project"* ]]
    [ ! -s "$H/argv" ]
  done
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "secret stores are refused whatever the mode, own included" {
  mkdir -p "$H/home/.ssh"
  local spec
  for spec in '~/.ssh = read-only' '~/.ssh/ = own' '~/.ssh/keys/ = own' '~/.config/ = own'; do
    run_engine -- asb --connect "$spec" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"secret store"* ]]
    [ ! -s "$H/argv" ]
  done
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "~/.local/bin is the one control path declarable read-only; every other mode is refused" {
  mkdir -p "$H/home/.local/bin"
  run_engine -- asb --connect '~/.local/bin = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$H/home/.local/bin" "$H/home/.local/bin"
  local spec
  for spec in '~/.local/bin/ = own' '~/.local/bin = copy' '~/.local/bin = read-write'; do
    run_engine -- asb --connect "$spec" claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"control plane"*"in every mode but read-only"* ]]
    [ ! -s "$H/argv" ]
  done
  # what contains it contains other protected paths too
  run_engine -- asb --connect '~/.local = read-only' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains the"*"in every mode."* ]]
}

@test "a key that is a symlink into a secret store is refused" {
  mkdir -p "$H/home/.ssh"
  ln -s "$H/home/.ssh" "$PROJ/keys"
  run_engine -- asb --connect './keys = read-only' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"secret store"* ]]
}

@test "a key that is a symlink binds its resolved target, at the declared name" {
  # Binding the link would let bwrap resolve it again at mount time, and a link
  # repointed after the check could mount a refused target; the bind is of the target
  # just validated, mounted at the key.
  local d
  d="$(readlink -f "$H")"
  mkdir -p "$d/realdir"
  ln -s "$d/realdir" "$d/link"
  run_engine -- asb --connect "$d/link = read-only" claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$d/realdir" "$d/link"
}

@test "two path declarations nested inside each other are refused" {
  mkdir -p "$PROJ/a/b"
  run_engine -- asb --connect './a/ = own' --connect './a/b/ = read-only' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"inside"* ]]
  [ ! -s "$H/argv" ]
}

@test "the same path declared twice: the later one wins, as for a channel" {
  mkdir -p "$PROJ/data"
  run_engine AGENT_SANDBOX_CONNECT='./data = own' -- asb --connect './data = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
  run ! argv_has --bind "$SBOX/@paths/own/$(slugify "$PROJ/data")" "$PROJ/data"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a path inside a channel is allowed, wins there, and the review says so" {
  mkdir -p "$C/rules/team"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect 'instructions = read-only native' --connect '~/.claude/rules/team/ = own' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"overlaps"* ]] # the launch does not repeat it
  local slot
  slot="$SBOX/@paths/own/$(slugify "$C/rules/team")"
  argv_has --bind "$slot" "$C/rules/team"
  # after the channel's own bind, or the channel would cover it
  [ "$(argv_index "$slot")" -gt "$(argv_index "$C/rules")" ]
  # the review knows the channels without a profile loaded: it reads every profile
  printf '[connect]\n~/.claude/rules/team/ = own\n' >"$PROJ/.agent-sandbox"
  run_review
  [[ "$output" == *"'~/.claude/rules/team/' overlaps the claude profile's channel 'instructions'"* ]]
  [[ "$output" != *"under your home directory"* ]] # a channel's path, not an empty $HOME
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a path under HOME is not noted at launch: the dot-file's review says it, once" {
  mkdir -p "$H/home/notes"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect '~/notes/ = own' --connect '~/fresh/ = own' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"under your home directory"* ]]
}

@test "a preset never moves a path declaration" {
  mkdir -p "$PROJ/data"
  TEST_PRESET=isolated run_engine -- asb --connect './data = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

@test "copy-on-write on a directory path is an overlay at that path, the path itself its lower layer" {
  mkdir -p "$PROJ/data"
  run_engine -- asb --connect './data/ = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$PROJ/data" --overlay "$SBOX/@paths/upper/$(slugify "$PROJ/data")" \
    "$SBOX/@paths/work/$(slugify "$PROJ/data")" "$PROJ/data"
  # after the project bind, or the project would cover it
  [ "$(argv_index --overlay-src)" -gt "$(argv_index "$PROJ")" ]
}

@test "with the overlay off, a copy-on-write path is copy, and the launch says so" {
  mkdir -p "$PROJ/data"
  run_engine AGENT_SANDBOX_OVERLAY=off -- asb --connect './data/ = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"'./data/': copy-on-write is using copy here -- the overlay is turned off"* ]]
  argv_has --bind "$SBOX/@paths/copy/$(slugify "$PROJ/data")" "$PROJ/data"
  run ! argv_has --overlay-src "$PROJ/data"
}

@test "on a bubblewrap too old for overlays, a copy-on-write path is copy, and the launch says so" {
  mkdir -p "$PROJ/data"
  run_engine AGENT_SANDBOX_TEST_NO_OVERLAY=1 -- asb --connect './data/ = copy-on-write' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"copy-on-write is using copy here -- this bubblewrap cannot mount an overlay"* ]]
  argv_has --bind "$SBOX/@paths/copy/$(slugify "$PROJ/data")" "$PROJ/data"
}

@test "a run-scoped copy-on-write path keeps its layers under @run" {
  mkdir -p "$PROJ/data"
  run_engine -- asb --connect './data/ = copy-on-write run-scoped' claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$PROJ/data" --overlay "$SBOX/@run/@paths/upper/$(slugify "$PROJ/data")"
}

@test "--reset of a copy-on-write path discards its upper layer, whiteouts and all" {
  mkdir -p "$PROJ/data"
  run_engine -- asb --connect './data/ = copy-on-write' claude --version
  local up
  up="$SBOX/@paths/upper/$(slugify "$PROJ/data")"
  printf 'MINE\n' >"$up/x"
  run_engine -- asb --reset ./data/ claude
  [ "$status" -eq 0 ]
  [ ! -e "$up" ]
}

@test "a path declaration from an approved dot-file is honoured" {
  mkdir -p "$PROJ/data"
  printf '[connect]\n./data = read-only\n' >"$PROJ/.agent-sandbox"
  approve_dotfile
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

@test "path declarations are bound AFTER the working tree, or the project would cover them" {
  # Measured under the real bwrap (tests/integration/connect-paths.bats): bound
  # before it, `./data = read-only` was writable and `./scratch/ = own` showed the
  # project's files.
  mkdir -p "$PROJ/data"
  run_engine -- asb --connect './data = read-only' claude --version
  [ "$status" -eq 0 ]
  local i tree=-1 decl=-1
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --bind && "${ARGV[i + 1]}" == "$PROJ" && "${ARGV[i + 2]}" == "$PROJ" ]] && tree=$i
    [[ "${ARGV[i]}" == --ro-bind && "${ARGV[i + 2]}" == "$PROJ/data" ]] && decl=$i
  done
  [ "$tree" -ge 0 ]
  [ "$decl" -gt "$tree" ]
}

# ----- seed-only (#120) ------------------------------------------------------------
# Copied from the source once, when the store is first created, and the role's own
# from then on: never refreshed, so never a conflict warning.

@test "seed-only seeds the store from the source at the first launch and binds it" {
  printf 'NATIVE\n' >"$C/CLAUDE.md"
  mkdir -p "$C/rules" && printf 'R1\n' >"$C/rules/a.md"
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  [ "$status" -eq 0 ]
  local fslot dslot
  fslot="$SBOX/instructions/seed-only/$(slugify "$C/CLAUDE.md")"
  dslot="$SBOX/instructions/seed-only/$(slugify "$C/rules")"
  argv_has --bind "$fslot" "$C/CLAUDE.md"
  argv_has --bind "$dslot" "$C/rules"
  [ "$(cat "$fslot")" = NATIVE ]
  [ "$(cat "$dslot/a.md")" = R1 ]
}

@test "seed-only never refreshes, and never warns, when the source changes later" {
  printf 'V1\n' >"$C/CLAUDE.md"
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  local fslot
  fslot="$SBOX/instructions/seed-only/$(slugify "$C/CLAUDE.md")"
  printf 'SANDBOX\n' >"$fslot"  # the role changed its own
  printf 'V2\n' >"$C/CLAUDE.md" # and so did the source
  mkdir -p "$C/rules" && printf 'NEW\n' >"$C/rules/new.md"
  run_engine AGENT_SANDBOX_VERBOSE= -- asb --connect 'instructions=seed-only native' claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$fslot")" = SANDBOX ]
  [ ! -e "$SBOX/instructions/seed-only/$(slugify "$C/rules")/new.md" ]
  [[ "$output" != *"kept this sandbox"* ]]
  [[ "$output" != *"has changed since"* ]]
}

# A conflict names a file of yours, never the agent's own sync bookkeeping: the profile
# lists what it rewrites on both sides (profile_channel_vendor; skills/synced/ here).
# Measured: a server skill sync's .last-complete-round otherwise warned at every launch.
both_sides() { # STORE -- change synced/ bookkeeping and a skill, in the store and at home
  local st="$1"
  printf 'r2\n' >"$C/skills/synced/x/.last-complete-round"
  printf 'MINE\n' >"$C/skills/s.md"
  mkdir -p "$st/synced/x"
  printf 'r3\n' >"$st/synced/x/.last-complete-round"
  printf 'SANDBOX\n' >"$st/s.md"
}

@test "copy: a conflict warning names your file, not the agent's synced/ bookkeeping" {
  mkdir -p "$C/skills/synced/x" "$C/commands"
  printf 'r1\n' >"$C/skills/synced/x/.last-complete-round"
  printf 'V1\n' >"$C/skills/s.md"
  run_engine -- asb --connect 'skills=copy native' claude --version
  [ "$status" -eq 0 ]
  both_sides "$SBOX/skills/copy/$(slugify "$C/skills")"
  run_engine -- asb --connect 'skills=copy native' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept this sandbox's 's.md'"* ]]
  [[ "$output" != *"synced/"* ]]
}

@test "copy-on-write: a shadow warning names your file, not the agent's synced/ bookkeeping" {
  mkdir -p "$C/skills/synced/x" "$C/commands"
  printf 'r1\n' >"$C/skills/synced/x/.last-complete-round"
  printf 'V1\n' >"$C/skills/s.md"
  run_engine -- asb --connect 'skills=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  both_sides "$SBOX/skills/upper/$(slugify "$C/skills")"
  run_engine -- asb --connect 'skills=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"this sandbox has its own 's.md'"* ]]
  [[ "$output" != *"synced/"* ]]
}

@test "seed-only over a source that does not exist binds an empty store" {
  # The mount point bwrap would leave on the host is only created by a real bwrap, so
  # its cleanup is asserted in tests/integration/connect-seed-only.bats, not here.
  rm -f "$C/CLAUDE.md"
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  [ "$status" -eq 0 ]
  local fslot
  fslot="$SBOX/instructions/seed-only/$(slugify "$C/CLAUDE.md")"
  argv_has --bind "$fslot" "$C/CLAUDE.md"
  [ -f "$fslot" ] && [ ! -s "$fslot" ]
}

@test "seed-only keeps its own store, apart from copy's" {
  printf 'V1\n' >"$C/CLAUDE.md"
  run_engine -- asb --connect 'instructions=copy native' claude --version
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  [ "$status" -eq 0 ]
  [ -e "$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")" ]
  [ -e "$SBOX/instructions/seed-only/$(slugify "$C/CLAUDE.md")" ]
  run ! argv_has --bind "$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")" "$C/CLAUDE.md"
}

@test "--reset discards a seed-only store, so the next launch seeds again" {
  printf 'V1\n' >"$C/CLAUDE.md"
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  local fslot
  fslot="$SBOX/instructions/seed-only/$(slugify "$C/CLAUDE.md")"
  printf 'V2\n' >"$C/CLAUDE.md"
  run_engine -- asb --reset instructions claude
  [ "$status" -eq 0 ]
  [ ! -e "$fslot" ]
  run_engine -- asb --connect 'instructions=seed-only native' claude --version
  [ "$(cat "$fslot")" = V2 ]
}

@test "a path declaration at seed-only is seeded once from the same path outside" {
  mkdir -p "$PROJ/tools" && printf 'T1\n' >"$PROJ/tools/t"
  run_engine -- asb --connect './tools/ = seed-only' claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/seed-only/$(slugify "$PROJ/tools")"
  argv_has --bind "$slot" "$PROJ/tools"
  [ "$(cat "$slot/t")" = T1 ]
  printf 'T2\n' >"$PROJ/tools/t"
  run_engine -- asb --connect './tools/ = seed-only' claude --version
  [ "$(cat "$slot/t")" = T1 ]
}

@test "seed-only sits between own and copy in every message that lists the scale" {
  run_engine -- asb --connect 'instructions=nonsense native' claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"own|seed-only|copy|copy-on-write|read-only|read-write"* ]]
}
