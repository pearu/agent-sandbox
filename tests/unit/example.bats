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
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  # Any unrecognized section or key would produce one of these:
  [[ "$output" != *"ignoring unknown section"* ]]
  [[ "$output" != *"unknown [conda] key"* ]]
  [[ "$output" != *"is not allowed here"* ]]
  [[ "$output" != *"is not supported yet"* ]]
  [[ "$output" != *"before any [section]"* ]]
  [[ "$output" != *"expects 'key = value'"* ]]
}

@test "the example shows every section and [conda] key the engine supports (nothing missing)" {
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
  for k in $(grep -oE '_df_conda_[a-z]+' "$ENGINE" | sort -u | sed 's/_df_conda_//'); do
    grep -qE "^#?$k[[:space:]]*=" "$EX" || {
      echo "[conda] key '$k' is accepted by the engine but absent from the example" >&2
      false
    }
  done
}
