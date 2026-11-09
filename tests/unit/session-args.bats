#!/usr/bin/env bats
# profile_session_args (#6): the arguments a profile adds to every invocation that runs
# the agent as a session, the briefing on or off, first on the line, with the sandbox's
# preset in scope -- and never for --exec or a verb. A scratch profile whose hook writes
# the preset it was given into its argument.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  P="$H/profiles"
  mkdir -p "$P/sess"
  ln -s "$REPO_ROOT/profiles/claude" "$P/claude"
  cat >"$P/sess/profile.sh" <<'SH'
profile_command=sess
profile_session_args() { profile_session_argv=(--sess "preset=${_preset:-unset}"); }
profile_briefing_args() { profile_briefing_argv=(--brief); }
SH
  printf '[agent]\nbase = ~/.sess\nverbs = vb\n' >"$P/sess/agent-sandbox"
  printf '#!/bin/sh\nexit 0\n' >"$H/bin/sess"
  chmod +x "$H/bin/sess"
}

teardown() {
  [[ -n "${BG_PID:-}" ]] && release_bg
  return 0
}

@test "session args: first, before the briefing's and the agent's own, with the sandbox's preset" {
  local p
  for p in shared isolated inherit; do
    TEST_PRESET=$p run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb sess a b
    [ "$status" -eq 0 ]
    [ "${JOINV[*]}" = "$H/bin/sess --sess preset=$p --brief a b" ]
  done
  TEST_PRESET="" run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb --preset native sess a b
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$H/bin/sess --sess preset=native --brief a b" ]
}

@test "session args: there with the briefing off, which takes only the briefing's away" {
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_BRIEFING=off -- asb sess a b
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$H/bin/sess --sess preset=shared a b" ]
}

@test "session args: not for --exec, the caller's own command" {
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb --profile sess --exec sess a b
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "sess a b" ]
}

@test "session args: a join gets the running keeper's preset; a verb joined into it gets none" {
  TEST_PRESET=isolated engine_bg AGENT_SANDBOX_PROFILE_DIR="$P" -- asb sess first
  mapfile -t J <"$H/join.bg"
  [[ " ${J[*]} " == *" --sess preset=isolated --brief first "* ]]
  # a second session with no preset of its own joins the isolated keeper, and is told so
  TEST_PRESET="" run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb sess second
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$H/bin/sess --sess preset=isolated --brief second" ]
  # a verb is not a session
  TEST_PRESET="" run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb sess vb x
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$H/bin/sess vb x" ]
}

@test "session args: a join into a keeper started with the briefing off still gets them" {
  engine_bg AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_BRIEFING=off -- asb sess first
  mapfile -t J <"$H/join.bg"
  [[ " ${J[*]} " == *" $H/bin/sess --sess preset=shared first "* ]]
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_BRIEFING=off -- asb sess second
  [ "$status" -eq 0 ]
  [ "${JOINV[*]}" = "$H/bin/sess --sess preset=shared second" ]
}
