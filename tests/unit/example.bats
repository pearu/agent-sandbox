#!/usr/bin/env bats
# The shipped template docs/agent-sandbox.example must stay in lockstep with the
# parser: it must use only sections/keys the engine recognizes (nothing stale),
# and it must show every one the engine supports (nothing missing).

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  CFG="$H/home/.config/agent-sandbox"
  EX="$REPO_ROOT/docs/agent-sandbox.example"
}

trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "every section/key in the example is one the engine recognizes (nothing stale)" {
  # Uncomment the config lines ('#' immediately followed by a non-space);
  # leave the prose comments ('# ...') as comments.
  sed -E 's/^#([^[:space:]].*)$/\1/' "$EX" >"$PROJ/.agent-sandbox"
  trust
  # The example's [net] mode is strict and its [seccomp] mode is on; pin both
  # from the shell (which wins) so this stays a parser check and never needs
  # pasta or a compiled filter.
  run_engine AGENT_SANDBOX_NET=proxy AGENT_SANDBOX_SECCOMP=off -- claude --version
  [ "$status" -eq 0 ]
  # Any unrecognized section or key would produce one of these:
  [[ "$output" != *"ignoring unknown section"* ]]
  [[ "$output" != *"unknown [conda] key"* ]]
  [[ "$output" != *"unknown [net] key"* ]]
  [[ "$output" != *"unknown [seccomp] key"* ]]
  [[ "$output" != *"is not allowed here"* ]]
  [[ "$output" != *"is not supported yet"* ]]
  [[ "$output" != *"before any [section]"* ]]
  [[ "$output" != *"expects 'key = value'"* ]]
}

@test "the example shows every section and every [conda]/[net]/[seccomp] key the engine supports (nothing missing)" {
  # The parser's list of accepted sections is the source of truth.
  local accepted
  accepted=$(grep -E 'allow \| share-memory \| ro' "$ENGINE" | head -1 | sed -E 's/\).*//' | tr -d ' ' | tr '|' ' ')
  [ -n "$accepted" ]
  local s
  for s in $accepted; do
    grep -qE "^#?\[$s\]" "$EX" || {
      echo "section [$s] is accepted by the engine but absent from the example" >&2
      false
    }
  done
  # and its [conda] keys
  local k
  # shellcheck disable=SC2013 # identifiers, one per line, no whitespace
  for k in $(grep -oE '_df_conda_[a-z]+' "$ENGINE" | sort -u | sed 's/_df_conda_//'); do
    grep -qE "^#?${k}[[:space:]]*=" "$EX" || {
      echo "[conda] key '$k' is accepted by the engine but absent from the example" >&2
      false
    }
  done
  # and its [net] keys (_df_net_<key>, with _ for -)
  # shellcheck disable=SC2013
  for k in $(grep -oE '_df_net_[a-z_]+' "$ENGINE" | sort -u | sed 's/_df_net_//; s/_/-/g'); do
    grep -qE "^#?${k}[[:space:]]*=" "$EX" || {
      echo "[net] key '$k' is accepted by the engine but absent from the example" >&2
      false
    }
  done
  # and its [seccomp] keys
  # shellcheck disable=SC2013
  for k in $(grep -oE '_df_seccomp_[a-z_]+' "$ENGINE" | sort -u | sed 's/_df_seccomp_//; s/_/-/g'); do
    grep -qE "^#?${k}[[:space:]]*=" "$EX" || {
      echo "[seccomp] key '$k' is accepted by the engine but absent from the example" >&2
      false
    }
  done
}
