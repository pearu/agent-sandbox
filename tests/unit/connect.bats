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
  COPY="$STATE/claude/${PROJ//[^A-Za-z0-9-]/-}/claude.json"
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
fake_live_session() {
  local d="$H/base/session.fake"
  mkdir -p "$d"
  sleep 120 >/dev/null 2>&1 &
  FAKE_SESSION_PID=$!
  printf '%s %s\n' "$FAKE_SESSION_PID" \
    "$(awk '{print $22}' "/proc/$FAKE_SESSION_PID/stat")" >"$d/owner.id"
  printf '%s\n' "$1" >"$d/connect.sandbox"
}

# Record approval of $H/proj/.agent-sandbox the way `--trust` would.
approve_dotfile() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$H/proj/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "no connection asked for: not one bind changes, so the feature is invisible by default" {
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  # The whole state directory, read-write, exactly as before.
  argv_has --bind "$C" "$C"
  # and nothing layered over the instructions channel
  run ! argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "live is spelled out and still changes nothing: it is today's behaviour named" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-write native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "ro rebinds each of the channel's paths read-only, over the read-write state bind" {
  : >"$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- claude --version
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- claude --version
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")" "$C/CLAUDE.md"
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  run ! argv_has --tmpfs "$C/CLAUDE.md"
  [ -d "$SBOX/instructions/own/$(slugify "$C/rules")" ]
}

@test "the slot survives the session: it is state, not scratch" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- claude --version
  printf 'the sandbox wrote this\n' >"$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")"
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/instructions/own/$(slugify "$C/CLAUDE.md")")" = "the sandbox wrote this" ]
}

@test "a mount point the bind creates on the host is cleaned up again" {
  # MEASURED: without this the engine left an empty, unwritable ~/.claude/CLAUDE.md
  # behind, and the next write to it failed. The engine already had this problem
  # with the config file and already had the list that fixes it.
  rm -f "$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$C/CLAUDE.md" ]
}

@test "each form is honoured, and the flag beats the environment" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- \
    claude --connect 'instructions=read-only native' --version
  [ "$status" -eq 0 ]
  : >"$C/CLAUDE.md"
  argv_has --ro-bind "$C/rules" "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "several specs in the environment are separated by semicolons, since a spec has spaces" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native;skills=own native' -- claude --version
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
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_CONNECT='instructions=read-only native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "an UNAPPROVED dot-file grants nothing, so a channel is not closed by an unreviewed file" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[connect]
instructions = own native
EOF
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "--connect is repeatable, and the last spec for a channel wins" {
  : >"$C/CLAUDE.md"
  run_engine -- claude --connect 'skills=own native' \
    --connect 'instructions=own native' --connect 'instructions=read-only native' --version
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- claude --version
  [ "$status" -eq 0 ]
  local connect scratch
  connect="$(argv_index "$SBOX/instructions/own/$(slugify "$C/rules")")"
  scratch="$(argv_index "$C/paste-cache")"
  [ -n "$connect" ]
  [ -n "$scratch" ]
  [ "$connect" -lt "$scratch" ]
}

@test "a wrapped background worker is keyed by ITS project, not by the daemon's directory" {
  # Without this the worker gets a different sandbox from the foreground session
  # on the same project -- one sandbox becoming two -- and every worker of every
  # project shares the daemon's key, which is a cross-project channel. The
  # profile already knew this for the config file; the engine now asks the same
  # function, so the two cannot drift.
  local proj sock="/tmp/cc-daemon-1000/b1952d0c/spare"
  mkdir -p "$sock" /tmp/cc-daemon-1000/b1952d0c/ctl "$H/base"
  proj="$(mkdir -p "$H/bgproj" && cd "$H/bgproj" && pwd -P)"
  printf '%s' "$proj" >"$H/base/bg-project"
  run_engine AGENT_SANDBOX_CONNECT='instructions=own native' -- \
    claude --wrap "$H/bin/claude" --bg-spare "$sock/a.claim.sock"
  [ "$status" -eq 0 ]
  local want="$STATE/claude/${proj//[^A-Za-z0-9-]/-}/default"
  argv_has --bind "$want/instructions/own/$(slugify "$C/rules")" "$C/rules"
  # and NOT keyed by the directory the wrapper happened to run from
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "cow asks bwrap for an overlay on a directory-shaped path" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules" --overlay \
    "$SBOX/instructions/upper/$(slugify "$C/rules")" \
    "$SBOX/instructions/work/$(slugify "$C/rules")" "$C/rules"
}

@test "cow on a FILE-shaped path is copy, permanently: overlayfs cannot stack on a file" {
  printf 'YOURS\n' >"$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")"
  argv_has --bind "$slot" "$C/CLAUDE.md"
  [ "$(cat "$slot")" = YOURS ]
  # no overlay was attempted for it
  run ! argv_has --overlay-src "$C/CLAUDE.md"
}

@test "--overlay off forces the copy fallback, and the launch SAYS so through --quiet" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine -- claude --connect 'instructions=copy-on-write native' --overlay off --quiet --version
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
  run_engine -- claude --connect 'instructions=copy-on-write native' --version
  [ "$status" -eq 0 ]
  run ! argv_has --overlay-src "$C/rules" # the file turned it off

  run_engine AGENT_SANDBOX_OVERLAY=auto -- claude --connect 'instructions=copy-on-write native' --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules" # the environment overrode the file

  run_engine AGENT_SANDBOX_OVERLAY=auto -- \
    claude --connect 'instructions=copy-on-write native' --overlay off --version
  [ "$status" -eq 0 ]
  run ! argv_has --overlay-src "$C/rules" # and the flag overrode the environment
}

@test "an unknown overlay mode keeps auto rather than guessing" {
  run_engine AGENT_SANDBOX_OVERLAY=sideways -- \
    claude --connect 'instructions=copy-on-write native' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown mode 'sideways'"* ]]
  argv_has --overlay-src "$C/rules"
}

@test "--reset-connection clears an overlay's upper layer, whiteouts and all" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  local upper
  upper="$SBOX/instructions/upper/$(slugify "$C/rules")"
  mkdir -p "$upper"
  printf 'SANDBOX\n' >"$upper/topic.md"
  run_engine -- claude --reset-connection instructions
  [ "$status" -eq 0 ]
  [ ! -e "$upper/topic.md" ]
}

@test "--reset-connection REFUSES while a session of this sandbox is live" {
  # It removes the very layers that session has mounted, and the conflict warning
  # actively tells the user to run it -- reading that in one terminal while the
  # session runs in another is the ordinary case, not an edge one.
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  fake_live_session "$SBOX"
  run_engine -- claude --reset-connection instructions
  [ "$status" -ne 0 ]
  [[ "$output" == *"session of this sandbox is running"* ]]
}

@test "and it goes ahead once that session is gone" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  fake_live_session "$SBOX"
  kill "$FAKE_SESSION_PID" 2>/dev/null
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -d "/proc/$FAKE_SESSION_PID" ]] || break
    sleep 0.05
  done
  run_engine -- claude --reset-connection instructions
  [ "$status" -eq 0 ]
}

@test "a live session of ANOTHER sandbox does not block a reset" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  fake_live_session "$STATE/claude/some-other-project/default"
  run_engine -- claude --reset-connection instructions
  [ "$status" -eq 0 ]
}

@test "WITHOUT a holder, a second live session is called out -- once" {
  # With a holder there is nothing to warn about: every session shares one
  # overlay. Without one, two sessions are two overlays over one layer, which
  # overlayfs calls undefined. The stub bwrap exits immediately, so no holder
  # ever records itself here and this is the fallback path by construction.
  fake_live_session "$SBOX"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --quiet --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"without a shared overlay that is undefined"* ]]
  # once, not once per path in the channel
  [ "$(grep -c 'without a shared overlay' <<<"$output")" -eq 1 ]
}

@test "and says nothing when it is the only session" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"without a shared overlay"* ]]
}

@test "the overlay's lower layer is the SOURCE, so a directory made later shows up" {
  # An earlier version used an empty placeholder when the source directory was
  # missing, to avoid creating anything in the user's own state. With a holder
  # that is actively wrong: the lower is fixed when the overlay is mounted, so a
  # directory the user creates afterwards would stay invisible for as long as the
  # holder lives. The study caught it. An overlay can only track the source if
  # the source IS the lower, which means creating it when it is absent -- one
  # empty directory, in a tree bwrap already creates mount points in.
  rm -rf "$C/rules"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy-on-write native' -- claude --version
  [ "$status" -eq 0 ]
  local i src=""
  for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --overlay-src ]] && src="${ARGV[i + 1]}" && break
  done
  [ -n "$src" ]
  [ "$src" = "$C/rules" ]
  [ -d "$C/rules" ]
}

@test "a channel with TWO directories does not report the launch as a second session" {
  # The session records the sandbox it is holding while the binds are still being
  # assembled, so the second path of a channel found the first path's record --
  # owner alive, sandbox matching -- and every launch warned about itself.
  # `skills` is the only channel with two directories, which is why every test
  # using `instructions` missed it.
  mkdir -p "$C/skills" "$C/commands"
  fake_live_session "$STATE/claude/some-other-project/default"
  run_engine AGENT_SANDBOX_CONNECT='skills=copy-on-write native' -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"without a shared overlay"* ]]
  # both paths still got their overlay
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
  TEST_PRESET="" run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --overlay-src "$C/rules"
  argv_has --overlay-src "$C/skills"
  argv_has --overlay-src "$C/agents"
  # and the whole state directory is still bound underneath, as it always was
  argv_has --bind "$C" "$C"
}

@test "independent gives the sandbox nothing of the native install" {
  run_engine AGENT_SANDBOX_PRESET=isolated -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  argv_has --bind "$SBOX/skills/own/$(slugify "$C/skills")" "$C/skills"
  run ! argv_has --overlay-src "$C/rules"
}

@test "shared is the engine before 0.3: not one channel is layered over" {
  run_engine AGENT_SANDBOX_PRESET=shared -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! argv_has --overlay-src "$C/rules"
  run ! argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "a [connect] line overrides the preset for its own channel and no other" {
  run_engine AGENT_SANDBOX_PRESET=isolated \
    AGENT_SANDBOX_CONNECT='instructions=read-only native' -- claude --version
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
  TEST_PRESET="" run_engine -- claude --version
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_PRESET=shared -- claude --version
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_PRESET=shared -- claude --preset isolated --version
  argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
}

@test "an unknown preset is REFUSED, not defaulted" {
  # Guessing which channels the user meant to move is the one thing a preset
  # must never do: it positions all of them at once.
  run_engine AGENT_SANDBOX_PRESET=paranoid -- claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown preset 'paranoid'"* ]]
  [ ! -s "$H/argv" ]
}

@test "a preset moves ONLY the channels the engine manages as connections" {
  # The design's table also lists memory, transcripts, the config file and the
  # rest. Each still has machinery of its own, and a preset that silently claimed
  # to position them would leave the user believing a channel was shut.
  run_engine AGENT_SANDBOX_PRESET=isolated -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$COPY" "$H/home/.claude/.claude.json" # the config file, untouched by presets
}

@test "native is refused from the environment: only the flag can turn isolation off" {
  # Every other preset is takeable from the environment because none of them can
  # widen much. This one switches state isolation off wholesale, and a line in a
  # shell profile would do that for every project, every launch, unnoticed and
  # with no project to approve. Hence a refusal rather than a trust gate.
  run_engine AGENT_SANDBOX_PRESET=native -- claude --version
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
  TEST_PRESET="" run_engine -- claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"only accepted as the --preset flag"* ]]
}

@test "--preset native opens every channel and SAYS SO on every launch" {
  run_engine -- claude --preset native --version
  [ "$status" -eq 0 ]
  # every declared channel live: nothing layered, nothing shadowed, the state
  # directory straight through
  argv_has --bind "$C" "$C"
  run ! argv_has --overlay-src "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/own/$(slugify "$C/rules")" "$C/rules"
  # and the notice is not suppressible: --quiet does not silence it
  run_engine -- claude --preset native --quiet --version
  [[ "$output" == *"state isolation is OFF"* ]]
}

@test "under native the config file is neither copied nor relocated" {
  # The parity that first justified the preset: natively the file is the user's
  # own at ~/.claude.json, and CLAUDE_CONFIG_DIR -- which exists only because a
  # read-only $HOME loses the writes beside it -- has nothing left to work around.
  run_engine -- claude --preset native --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$COPY" "$H/home/.claude/.claude.json"
  run ! grep -q 'CLAUDE_CONFIG_DIR' "$H/argv"
}

# ----- refusals: every one of these would otherwise leave a channel wide open -

@test "an unknown channel is REFUSED, not ignored: a typo must not read as 'closed'" {
  # The worst outcome this code can produce is a user reading their own dot-file,
  # believing a channel is shut, and it being open. So a name the profile does
  # not carry stops the launch and lists the ones it does.
  run_engine -- claude --connect 'instrctions=none' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'instrctions'"* ]]
  [[ "$output" == *instructions* ]] # it names what the profile does carry
}

@test "an unknown mode is refused" {
  run_engine -- claude --connect 'instructions=readonly' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown mode 'readonly'"* ]]
}

@test "a source other than native is refused while only native is supported" {
  run_engine -- claude --connect 'instructions=read-only sandbox:~/other' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not supported yet"* ]]
}

@test "a malformed spec is refused" {
  run_engine -- claude --connect 'instructions' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 'channel = mode [source] [scope]'"* ]]
}

@test "a trailing token is refused too: a spec is that shape and nothing more" {
  # Everything else malformed is refused, so silently discarding the tail would
  # be the one place a user could write something meaningless and be told
  # nothing about it. A fourth token cannot be anything, so it is the tail.
  run_engine -- claude --connect 'instructions=read-only native run-scoped extra' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"trailing 'extra'"* ]]
}

@test "a second SOURCE is named as such, not reported as a vague tail" {
  # `read-only native extra` is three legal-looking tokens; `extra` has no
  # `-scoped` suffix so it can only be a source, and there is already one.
  run_engine -- claude --connect 'instructions=read-only native extra' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"two sources"* ]]
  [[ "$output" == *"'native' and 'extra'"* ]]
}

# ----- the scope axis ---------------------------------------------------------
#
# A scope says WHICH STORAGE a channel's sandbox side uses. Only the default is
# built; the rest parse and are refused, because a scope that is accepted and
# never applied reads as isolation that is not there.

@test "the scope is optional: writing none means the role, today's behaviour" {
  run_engine -- claude --connect 'instructions=read-only native' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "source and scope are told apart by shape, so either order parses" {
  # Both orders reach the scope check and get the same refusal: the scope was
  # recognised as a scope whichever side of the source it stood.
  local a b
  run_engine -- claude --connect 'instructions=copy native run-scoped' --version
  a="$output"
  run_engine -- claude --connect 'instructions=copy run-scoped native' --version
  b="$output"
  [[ "$a" == *"scope 'run-scoped' is not implemented"* ]]
  [[ "$b" == *"scope 'run-scoped' is not implemented"* ]]
}

@test "read-write plus a scope is refused: there is nothing left to scope" {
  # PERMANENT, not a statement about what is built. At read-write the sandbox
  # writes the source itself, so no sandbox-side storage exists for a scope to
  # apply to -- the spec cannot mean what its author thinks. Checked before
  # implementation status, so it stays true once the scopes land.
  local sc
  for sc in run-scoped process-scoped; do
    run_engine -- claude --connect "instructions=read-write $sc" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not mean anything"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "a scope that is not implemented is REFUSED, never quietly ignored" {
  local sc
  for sc in run-scoped process-scoped; do
    run_engine -- claude --connect "instructions=copy native $sc" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"scope '$sc' is not implemented"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "the withdrawn scopes are refused, each saying what to write instead" {
  # #125: storage belongs to the role, so the default has no name, sharing across
  # roles is a source, and a per-conversation store is a role of its own.
  run_engine -- claude --connect 'instructions=copy native sandbox-scoped' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'sandbox-scoped' was withdrawn"*"write no scope"* ]]
  [ ! -s "$H/argv" ]
  run_engine -- claude --connect 'instructions=copy native project-scoped' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'project-scoped' was withdrawn"*"sandbox:<project>/<role>"* ]]
  run_engine -- claude --connect 'instructions=copy native session-scoped' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"'session-scoped' was withdrawn"*"--role"* ]]
}

@test "an unknown scope names the set" {
  run_engine -- claude --connect 'instructions=copy native world-scoped' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown scope 'world-scoped'"* ]]
  [[ "$output" == *"run-scoped|process-scoped"* ]]
  [[ "$output" == *"nothing written means the role"* ]]
}

@test "two scopes in one spec are refused" {
  run_engine -- claude --connect 'instructions=copy run-scoped process-scoped' --version
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
    run_engine -- claude --connect "instructions=$mode" --version
    [ "$status" -eq 0 ]
  done
}

@test "every PRE-0.3 mode name is refused, and the refusal says what to write" {
  # Renamed, not aliased. `none` is why: it was the most-closed mode and becomes
  # the preset meaning no sandbox at all, so honouring it here would make one
  # word mean opposite ends of one model -- someone asking for maximum isolation
  # would get none of it. Once `none` cannot be carried, carrying the other three
  # would leave a single special case nobody remembers.
  local old new
  for pair in "none own" "cow copy-on-write" "ro read-only" "live read-write"; do
    read -r old new <<<"$pair"
    run_engine -- claude --connect "instructions=$old" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"mode '$old' was renamed"* ]]
    [[ "$output" == *"write '$new'"* ]]
    [ ! -s "$H/argv" ] # and nothing launched
  done
}

@test "both renamed presets are refused by name too, not silently defaulted" {
  local old new
  for pair in "independent isolated" "default inherit"; do
    read -r old new <<<"$pair"
    run_engine "AGENT_SANDBOX_PRESET=$old" -- claude --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"'$old' was renamed"* ]]
    [[ "$output" == *"write '$new'"* ]]
  done
}

@test "copy seeds from the source and binds the sandbox's own copy, not the source" {
  printf 'YOURS\n' >"$C/CLAUDE.md"
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/CLAUDE.md")"
  argv_has --bind "$slot" "$C/CLAUDE.md"
  [ "$(cat "$slot")" = YOURS ]
  # the source itself is never the bind source, or a write inside would reach it
  run ! argv_has --bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "copy warns, naming the file, when both sides changed it -- and --quiet does not hide it" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --version
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/rules")"
  printf 'SANDBOX\n' >"$slot/topic.md"    # as if the session edited it
  printf 'CHANGED\n' >"$C/rules/topic.md" # and the user changed theirs
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --quiet --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"topic.md"* ]]
  [[ "$output" == *"reset-connection instructions"* ]] # it says how to resolve it
  [ "$(cat "$slot/topic.md")" = SANDBOX ]              # and kept the sandbox's
}

@test "--reset-connection takes the source's version back, and does NOT launch" {
  printf 'YOURS\n' >"$C/rules/topic.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=copy native' -- claude --version
  local slot
  slot="$SBOX/instructions/copy/$(slugify "$C/rules")"
  printf 'SANDBOX\n' >"$slot/topic.md"
  run_engine -- claude --reset-connection instructions
  [ "$status" -eq 0 ]
  [ "$(cat "$slot/topic.md")" = YOURS ]
  [ ! -s "$H/argv" ] # bwrap was never reached: it resets and exits
}

@test "--reset-connection on a channel the profile does not carry is refused" {
  run_engine -- claude --reset-connection nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no channel 'nosuch'"* ]]
}

@test "a refusal stops the launch: bwrap is never reached" {
  run_engine -- claude --connect 'instructions=nonsense' --version
  [ "$status" -ne 0 ]
  [ ! -s "$H/argv" ]
}

# ----- path declarations (#106 piece 2) -----------------------------------------
# A [connect] key containing `/` names a PATH rather than a channel. The key is the
# path inside the sandbox; with no source given, the source is the same path
# outside. Relative keys resolve against the project, `~` against $HOME.

@test "a key with a slash is a path: ./data = read-only binds the project's data read-only" {
  mkdir -p "$PROJ/data"
  run_engine -- claude --connect './data = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a relative key resolves against the project, and ~ against HOME" {
  mkdir -p "$PROJ/sub/dir" "$H/home/notes"
  run_engine -- claude --connect 'sub/dir = read-only' --connect '~/notes = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/sub/dir" "$PROJ/sub/dir"
  argv_has --ro-bind "$H/home/notes" "$H/home/notes"
}

@test "a path key keeps its spaces" {
  mkdir -p "$PROJ/my data"
  run_engine -- claude --connect './my data = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/my data" "$PROJ/my data"
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "read-write on a path binds the outside path through, as [rw] does" {
  mkdir -p "$H/home/shared"
  run_engine -- claude --connect '~/shared = read-write' --version
  [ "$status" -eq 0 ]
  argv_has --bind "$H/home/shared" "$H/home/shared"
}

@test "own on a path binds a private slot from the sandbox's state, and it persists" {
  mkdir -p "$PROJ/scratch"
  printf 'the real one\n' >"$PROJ/scratch/f"
  run_engine -- claude --connect './scratch/ = own' --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/own/$(slugify "$PROJ/scratch")"
  argv_has --bind "$slot" "$PROJ/scratch"
  [ -d "$slot" ]
  [ ! -e "$slot/f" ] # never seeded from outside
  : >"$slot/kept"
  run_engine -- claude --connect './scratch/ = own' --version
  [ -e "$slot/kept" ]
}

@test "own with a trailing slash on a directory that does not exist creates it, inside only" {
  run_engine -- claude --connect './scratch/ = own' --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@paths/own/$(slugify "$PROJ/scratch")" "$PROJ/scratch"
}

@test "a path that does not exist is skipped with a notice, in every other case" {
  local spec
  for spec in './gone/ = read-only' './gone = own' './gone = copy' './gone = read-write' './gone/ = copy-on-write'; do
    run_engine -- claude --quiet --connect "$spec" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"'./gone"*"does not exist"*"skipped"* ]]
    run ! argv_has "$PROJ/gone"
  done
}

@test "a trailing slash on something that is not a directory is refused" {
  : >"$PROJ/AGENT.md"
  run_engine -- claude --connect './AGENT.md/ = read-only' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
  [ ! -s "$H/argv" ]
}

@test "copy on a path seeds the sandbox's own copy from the source" {
  mkdir -p "$PROJ/tools"
  printf 'v1\n' >"$PROJ/tools/t"
  run_engine -- claude --connect './tools/ = copy' --version
  [ "$status" -eq 0 ]
  local slot
  slot="$SBOX/@paths/copy/$(slugify "$PROJ/tools")"
  argv_has --bind "$slot" "$PROJ/tools"
  [ "$(cat "$slot/t")" = v1 ]
}

@test "a file declaration says at launch that it cannot be deleted from inside" {
  printf 'x\n' >"$PROJ/AGENT.md"
  run_engine -- claude --quiet --connect './AGENT.md = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/AGENT.md" "$PROJ/AGENT.md"
  [[ "$output" == *"'./AGENT.md' is a file"*"cannot be deleted"* ]]
}

@test "copy-on-write on a file is copy, and the launch says so" {
  printf 'x\n' >"$PROJ/AGENT.md"
  run_engine -- claude --quiet --connect './AGENT.md = copy-on-write' --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/@paths/copy/$(slugify "$PROJ/AGENT.md")" "$PROJ/AGENT.md"
  [[ "$output" == *"copy-on-write on a file is copy"* ]]
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "the root, HOME, and parents of HOME are refused as path keys, in every mode" {
  local spec
  for spec in '/ = own' '~/ = own' '~/.. = read-only'; do
    run_engine -- claude --connect "$spec" --version
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
    RUN_CWD="$PROJ/sub" run_engine -- claude --connect "$spec" --version
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
    run_engine -- claude --connect "$spec" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"secret store"* ]]
    [ ! -s "$H/argv" ]
  done
}

@test "a key that is a symlink into a secret store is refused" {
  mkdir -p "$H/home/.ssh"
  ln -s "$H/home/.ssh" "$PROJ/keys"
  run_engine -- claude --connect './keys = read-only' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"secret store"* ]]
}

@test "two path declarations nested inside each other are refused" {
  mkdir -p "$PROJ/a/b"
  run_engine -- claude --connect './a/ = own' --connect './a/b/ = read-only' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"inside"* ]]
  [ ! -s "$H/argv" ]
}

@test "the same path declared twice: the later one wins, as for a channel" {
  mkdir -p "$PROJ/data"
  run_engine AGENT_SANDBOX_CONNECT='./data = own' -- claude --connect './data = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
  run ! argv_has --bind "$SBOX/@paths/own/$(slugify "$PROJ/data")" "$PROJ/data"
}

@test "a path declaration takes no source yet: outside: is a follow-up" {
  mkdir -p "$PROJ/data"
  run_engine -- claude --connect './data = read-only native' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"source"* ]]
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a path inside a channel is allowed, warned about, and wins there" {
  mkdir -p "$C/rules/team"
  run_engine -- claude --quiet --connect 'instructions = read-only native' --connect '~/.claude/rules/team/ = own' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlaps the channel 'instructions'"* ]]
  local slot
  slot="$SBOX/@paths/own/$(slugify "$C/rules/team")"
  argv_has --bind "$slot" "$C/rules/team"
  # after the channel's own bind, or the channel would cover it
  [ "$(argv_index "$slot")" -gt "$(argv_index "$C/rules")" ]
}

# shellcheck disable=SC2088 # a literal ~ is what a user writes; the engine expands it
@test "a path under HOME, outside the project and every channel, is warned about" {
  mkdir -p "$H/home/notes"
  run_engine -- claude --quiet --connect '~/notes/ = own' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"'~/notes/' is under your home directory"* ]]
  # including when the directory does not exist yet and the launch creates it,
  # which is the case the warning is chiefly for
  run_engine -- claude --quiet --connect '~/fresh/ = own' --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"'~/fresh/' is under your home directory"* ]]
  # and a path inside the project is not, even when the project is under HOME
  mkdir -p "$H/home/work"
  mkdir -p "$H/home/work/data"
  RUN_CWD="$H/home/work" run_engine -- claude --quiet --connect './data/ = own' --version
  [ "$status" -eq 0 ]
  argv_has --bind "$STATE/claude/${H//[^A-Za-z0-9-]/-}-home-work/default/@paths/own/$(slugify "$H/home/work/data")" "$H/home/work/data"
  [[ "$output" != *"under your home directory"* ]]
}

@test "a preset never moves a path declaration" {
  mkdir -p "$PROJ/data"
  TEST_PRESET=isolated run_engine -- claude --connect './data = read-only' --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

@test "copy-on-write on a directory path is not implemented yet, and says so in the probed wording" {
  mkdir -p "$PROJ/data"
  run_engine -- claude --connect './data/ = copy-on-write' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not implemented in this engine"* ]]
}

@test "a path declaration from an approved dot-file is honoured" {
  mkdir -p "$PROJ/data"
  printf '[connect]\n./data = read-only\n' >"$PROJ/.agent-sandbox"
  approve_dotfile
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$PROJ/data" "$PROJ/data"
}

@test "path declarations are bound AFTER the working tree, or the project would cover them" {
  # Measured under the real bwrap (tests/integration/connect-paths.bats): bound
  # before it, `./data = read-only` was writable and `./scratch/ = own` showed the
  # project's files.
  mkdir -p "$PROJ/data"
  run_engine -- claude --connect './data = read-only' --version
  [ "$status" -eq 0 ]
  local i tree=-1 decl=-1
  for ((i = 0; i + 2 < ${#ARGV[@]}; i++)); do
    [[ "${ARGV[i]}" == --bind && "${ARGV[i + 1]}" == "$PROJ" && "${ARGV[i + 2]}" == "$PROJ" ]] && tree=$i
    [[ "${ARGV[i]}" == --ro-bind && "${ARGV[i + 2]}" == "$PROJ/data" ]] && decl=$i
  done
  [ "$tree" -ge 0 ]
  [ "$decl" -gt "$tree" ]
}
