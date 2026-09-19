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
  run_engine AGENT_SANDBOX_CONNECT='instructions=live native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$C" "$C"
  run ! argv_has --ro-bind "$C/CLAUDE.md" "$C/CLAUDE.md"
}

@test "ro rebinds each of the channel's paths read-only, over the read-write state bind" {
  : >"$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=ro native' -- claude --version
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=ro native' -- claude --version
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/none/$(slugify "$C/CLAUDE.md")" "$C/CLAUDE.md"
  argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"
  run ! argv_has --tmpfs "$C/CLAUDE.md"
  [ -d "$SBOX/instructions/none/$(slugify "$C/rules")" ]
}

@test "the slot survives the session: it is state, not scratch" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- claude --version
  printf 'the sandbox wrote this\n' >"$SBOX/instructions/none/$(slugify "$C/CLAUDE.md")"
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- claude --version
  [ "$status" -eq 0 ]
  [ "$(cat "$SBOX/instructions/none/$(slugify "$C/CLAUDE.md")")" = "the sandbox wrote this" ]
}

@test "a mount point the bind creates on the host is cleaned up again" {
  # MEASURED: without this the engine left an empty, unwritable ~/.claude/CLAUDE.md
  # behind, and the next write to it failed. The engine already had this problem
  # with the config file and already had the list that fixes it.
  rm -f "$C/CLAUDE.md"
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- claude --version
  [ "$status" -eq 0 ]
  [ ! -e "$C/CLAUDE.md" ]
}

@test "each form is honoured, and the flag beats the environment" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- \
    claude --connect 'instructions=ro native' --version
  [ "$status" -eq 0 ]
  : >"$C/CLAUDE.md"
  argv_has --ro-bind "$C/rules" "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"
}

@test "several specs in the environment are separated by semicolons, since a spec has spaces" {
  run_engine AGENT_SANDBOX_CONNECT='instructions=ro native;skills=none native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
  argv_has --bind "$SBOX/skills/none/$(slugify "$C/skills")" "$C/skills"
}

@test "an approved dot-file is honoured, and the environment beats it" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[connect]
instructions = none native
EOF
  approve_dotfile
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"

  run_engine AGENT_SANDBOX_CONNECT='instructions=ro native' -- claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$C/rules" "$C/rules"
}

@test "an UNAPPROVED dot-file grants nothing, so a channel is not closed by an unreviewed file" {
  cat >"$H/proj/.agent-sandbox" <<'EOF'
[connect]
instructions = none native
EOF
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  run ! argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"
}

@test "--connect is repeatable, and the last spec for a channel wins" {
  : >"$C/CLAUDE.md"
  run_engine -- claude --connect 'skills=none native' \
    --connect 'instructions=none native' --connect 'instructions=ro native' --version
  [ "$status" -eq 0 ]
  # the other channel is untouched by the repetition
  argv_has --bind "$SBOX/skills/none/$(slugify "$C/skills")" "$C/skills"
  # and the later spec for instructions replaced the earlier one
  argv_has --ro-bind "$C/rules" "$C/rules"
  run ! argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"
}

@test "connection binds come BEFORE the per-session scratch, so the scratch still wins" {
  # Asserted here because nothing would fail today: no channel path overlaps an
  # isolated one. The order is load-bearing all the same -- a channel at `live`
  # must still not hand over another session's paste cache -- and an overlap is
  # exactly the kind of thing a later channel addition introduces quietly.
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- claude --version
  [ "$status" -eq 0 ]
  local connect scratch
  connect="$(argv_index "$SBOX/instructions/none/$(slugify "$C/rules")")"
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
  run_engine AGENT_SANDBOX_CONNECT='instructions=none native' -- \
    claude --wrap "$H/bin/claude" --bg-spare "$sock/a.claim.sock"
  [ "$status" -eq 0 ]
  local want="$STATE/claude/${proj//[^A-Za-z0-9-]/-}/default"
  argv_has --bind "$want/instructions/none/$(slugify "$C/rules")" "$C/rules"
  # and NOT keyed by the directory the wrapper happened to run from
  run ! argv_has --bind "$SBOX/instructions/none/$(slugify "$C/rules")" "$C/rules"
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
  run_engine -- claude --connect 'instructions=ro sandbox:~/other' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not supported yet"* ]]
}

@test "a malformed spec is refused" {
  run_engine -- claude --connect 'instructions' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 'channel = mode [source]'"* ]]
}

@test "a trailing token is refused too: a spec is that shape and nothing more" {
  # Everything else malformed is refused, so silently discarding the tail would
  # be the one place a user could write something meaningless and be told
  # nothing about it.
  run_engine -- claude --connect 'instructions=ro native extra' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"trailing 'extra'"* ]]
}

@test "an unimplemented mode is refused in the WORDING the study probes for" {
  # This phrase is a contract with probes/connections/lib.sh (conn_mode_supported),
  # which tells "not implemented yet" apart from "implemented wrong" by reading it.
  # Reword it and an unimplemented mode starts looking like a broken one.
  # `copy` came off this list when it landed; `cow` is what is left. A mode that
  # stays here after it is implemented would have its study cells skipped, which
  # is the quiet failure this wording exists to prevent.
  run_engine -- claude --connect 'instructions=cow' --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect: mode 'cow' is not implemented"* ]]
  # and an implemented one is NOT refused
  run_engine -- claude --connect 'instructions=copy' --version
  [ "$status" -eq 0 ]
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
