#!/usr/bin/env bash
# The METHOD for the cross-project leak study (docs/cross-project-channels.md).
# Row scripts source this and stay short enough to read as a specification: what the
# canary is, where it is planted, what the reader does, how the verdict is decided.
#
# Everything the method requires lives here, once, because the alternative -- the
# same setup copy-pasted per row -- means the first methodological fix has to land in
# every copy, and the one that is missed produces results that are silently NOT
# COMPARABLE. That is worse than no result.
#
# Host-only. Needs a real Claude Code install and writes only under probes/results/,
# which is git-ignored. It never touches the real ~/.claude, and every run asserts so.
#
# Isolation is a throwaway HOME, NOT a throwaway CLAUDE_CONFIG_DIR. Measured: the
# engine neither forwards CLAUDE_CONFIG_DIR (it is not in profile_env_pass) nor binds
# it (profile_config_binds hardcodes $HOME/.claude), so a sandboxed session cannot see
# a throwaway config at all -- and a canary planted there reads as "unreachable",
# which is indistinguishable from the sandbox working. A throwaway HOME is bound AND
# scoped by the engine, so T2 measures the real scoping, and it keeps the default
# credential account, which the CLAUDE_CONFIG_DIR route does not.
# shellcheck shell=bash

LEAK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEAK_REPO_ROOT="$(cd -- "$LEAK_LIB_DIR/../.." && pwd)"
LEAK_SNAPSHOT="$LEAK_REPO_ROOT/probes/snapshot.py"
LEAK_WATCH="$LEAK_REPO_ROOT/probes/watch-reads.py"
LEAK_RECORD="$LEAK_LIB_DIR/record.py"

leak_die() {
  printf 'leak: %s\n' "$*" >&2
  exit 1
}

leak_say() { printf 'leak: %s\n' "$*" >&2; }

# leak_setup ROW -- run directory, throwaway config, and two SEPARATE repositories.
# Sets LEAK_RUN, LEAK_CONFIG, LEAK_A, LEAK_B.
#
# A and B are `git init`ed even though they sit inside this repository: memory is
# keyed to the innermost repository, so initialising them is what makes them
# different projects rather than two directories of one, which would share memory by
# construction and make any result meaningless.
leak_setup() {
  local row="$1"
  # readable, not executable: both are invoked as `python3 <path>`, and snapshot.py
  # is not marked executable in the repo
  [[ -r "$LEAK_SNAPSHOT" && -r "$LEAK_WATCH" ]] \
    || leak_die "instruments missing: expected $LEAK_SNAPSHOT and $LEAK_WATCH"
  command -v claude >/dev/null || leak_die "no 'claude' on PATH"
  [[ -z "${CLAUDE_CODE_PROJECT_DIR_NAME:-}" ]] \
    || leak_die "CLAUDE_CODE_PROJECT_DIR_NAME is set; it would store every session's
      transcripts AND memory under one name, collapsing the variable under test"
  [[ -z "${CLAUDE_CONFIG_DIR:-}" ]] \
    || leak_die "CLAUDE_CONFIG_DIR is set; isolation here is a throwaway HOME, and a
      config dir would send native and sandboxed cells to different configs"

  LEAK_RUN="$LEAK_REPO_ROOT/probes/results/leak/$row-$(date +%Y%m%dT%H%M%S)"
  LEAK_HOME="$LEAK_RUN/home"
  LEAK_CONFIG="$LEAK_HOME/.claude"
  LEAK_A="$LEAK_RUN/a"
  LEAK_B="$LEAK_RUN/b"
  mkdir -p "$LEAK_CONFIG" "$LEAK_A" "$LEAK_B" "$LEAK_RUN/records" "$LEAK_HOME/.local/share"
  # Version discovery walks $HOME/.local/share/claude/versions, and the seccomp filter
  # lives under $HOME/.local/share/agent-sandbox. Symlink the PARENTS: `find` does not
  # descend a start point that is itself a symlink, and a missing filter would leave
  # T2 running without seccomp -- silently not the default deployment.
  ln -sfn "$HOME/.local/share/claude" "$LEAK_HOME/.local/share/claude"
  ln -sfn "$HOME/.local/share/agent-sandbox" "$LEAK_HOME/.local/share/agent-sandbox"
  printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false}' >"$LEAK_HOME/.claude.json"
  local gc=(-c user.email=leak@example.invalid -c user.name=leak -c init.defaultBranch=main)
  git "${gc[@]}" -C "$LEAK_A" init -q
  git "${gc[@]}" -C "$LEAK_B" init -q

  # Slug truncation past 200 converted characters would move a canary planted by
  # path somewhere else; fail loudly rather than measure the wrong directory.
  local p
  for p in "$LEAK_A" "$LEAK_B"; do
    ((${#p} <= 200)) || leak_die "project path is ${#p} characters; past 200 the
      project slug is truncated and hashed, so a canary planted by path lands elsewhere"
  done
  leak_say "run $LEAK_RUN"
}

# leak_slug PATH -- Claude Code's project slug for PATH.
leak_slug() { printf '%s' "${1//[^A-Za-z0-9-]/-}"; }

# leak_precheck ROOT... -- FATAL if any symlink under ROOT resolves outside it.
#
# watch-reads.py watches directories, so a read through a symlink leaving the tree
# raises nothing at all -- under neither the link path nor the target path. A null
# result would then be uninterpretable, and an uninterpretable run is worse than no
# run, so this stops the batch rather than recording a warning nobody reads.
leak_precheck() {
  local root real target out="$LEAK_RUN/precheck.txt"
  : >"$out"
  for root in "$@"; do
    real="$(cd -- "$root" 2>/dev/null && pwd -P)" || leak_die "precheck: no such root: $root"
    while IFS= read -r l; do
      target="$(readlink -f -- "$l" 2>/dev/null || true)"
      if [[ -z "$target" ]]; then
        printf 'BROKEN\t%s\n' "$l" >>"$out"
      elif [[ "$target" != "$real" && "$target" != "$real"/* ]]; then
        printf 'OUTWARD\t%s\t%s\n' "$l" "$target" >>"$out"
      fi
    done < <(find "$real" -type l 2>/dev/null)
  done
  if grep -q '^OUTWARD' "$out" 2>/dev/null; then
    sed 's/^/  /' "$out" >&2
    leak_die "symlinks leave the watched tree: reads through them are invisible, so a
      negative result here would mean nothing. Watch the targets' trees too, or remove them."
  fi
  leak_say "precheck: no outward symlinks ($(wc -l <"$out") note(s))"
}

# leak_real_config_before / _after -- the real ~/.claude must be untouched, measured
# against a NOISE FLOOR rather than in the absolute.
#
# The host normally has another Claude Code session running -- the one driving this
# study, for one -- writing its own job state and transcripts. A bare before/after
# would flag that on every run, and a warning that always fires is a warning nobody
# reads. So an idle control window is measured first; whatever moves during it is
# ambient, and is subtracted. What remains is attributable to the experiment.
LEAK_CONTROL_SECONDS="${LEAK_CONTROL_SECONDS:-15}"

leak_real_config_before() {
  python3 "$LEAK_SNAPSHOT" manifest "$HOME/.claude" "$HOME/.claude.json" >"$LEAK_RUN/real-m0"
  leak_say "noise floor: ${LEAK_CONTROL_SECONDS}s idle control window"
  sleep "$LEAK_CONTROL_SECONDS"
  python3 "$LEAK_SNAPSHOT" manifest "$HOME/.claude" "$HOME/.claude.json" >"$LEAK_RUN/real-before"
  python3 "$LEAK_SNAPSHOT" diff "$LEAK_RUN/real-m0" "$LEAK_RUN/real-before" >"$LEAK_RUN/real-ambient"
  leak_say "noise floor: $(wc -l <"$LEAK_RUN/real-ambient") ambient change(s)"
}

leak_real_config_after() {
  python3 "$LEAK_SNAPSHOT" manifest "$HOME/.claude" "$HOME/.claude.json" >"$LEAK_RUN/real-after"
  python3 "$LEAK_SNAPSHOT" diff "$LEAK_RUN/real-before" "$LEAK_RUN/real-after" >"$LEAK_RUN/real-diff"
  cut -f2 "$LEAK_RUN/real-ambient" | sort -u >"$LEAK_RUN/real-ambient-paths"
  awk -F'\t' 'NR==FNR { a[$0] = 1; next } !($2 in a)' \
    "$LEAK_RUN/real-ambient-paths" "$LEAK_RUN/real-diff" >"$LEAK_RUN/real-attributable"
  if [[ -s "$LEAK_RUN/real-attributable" ]]; then
    leak_say "WARNING: the real ~/.claude changed in ways the noise floor does not explain:"
    sed 's/^/  /' "$LEAK_RUN/real-attributable" >&2
  else
    leak_say "real ~/.claude untouched (beyond the measured noise floor)"
  fi
}

# leak_watch_start ROOT -- start watch-reads.py and block until it is READY.
# A read before the watches exist raises nothing and is indistinguishable from a
# clean result, so failing to reach READY is fatal.
leak_watch_start() {
  local root="$1"
  LEAK_WATCH_OUT="$LEAK_RUN/watch.out"
  python3 "$LEAK_WATCH" "$root" >"$LEAK_WATCH_OUT" 2>"$LEAK_RUN/watch.err" &
  LEAK_WATCH_PID=$!
  local _
  for _ in $(seq 1 200); do
    grep -q '^READY' "$LEAK_WATCH_OUT" && return 0
    sleep 0.05
  done
  leak_die "watch-reads.py never became READY: $(cat "$LEAK_RUN/watch.err")"
}

leak_watch_stop() {
  [[ -n "${LEAK_WATCH_PID:-}" ]] || return 0
  kill -INT "$LEAK_WATCH_PID" 2>/dev/null || true
  wait "$LEAK_WATCH_PID" 2>/dev/null || true
  LEAK_WATCH_PID=""
}

# leak_read_sandboxed NET CWD SCRIPT OUT -- run SCRIPT inside the sandbox.
# `claude --exec` gives the identical sandbox an agent session would get, with the
# command swapped in, so this measures the container rather than an imitation of it.
leak_read_sandboxed() {
  local net="$1" cwd="$2" script="$3" out="$4"
  shift 4
  # Arguments, never environment: the sandbox does --clearenv and re-exports an
  # allowlist, so an exported variable does not cross -- and forwarding one would
  # change the environment under test to measure it.
  (
    cd "$cwd" || exit 1
    env HOME="$LEAK_HOME" AGENT_SANDBOX_NET="$net" \
      claude --quiet --exec python3 "$script" "$@"
  ) >"$out" 2>"$out.err" || true
}

# leak_read_native CWD SCRIPT OUT -- the same reader with no sandbox (T1).
leak_read_native() {
  local cwd="$1" script="$2" out="$3"
  shift 3
  (
    cd "$cwd" || exit 1
    env HOME="$LEAK_HOME" python3 "$script" "$@"
  ) >"$out" 2>"$out.err" || true
}

# Paths the OBSERVING session owns. The interactive Claude Code session driving the
# study writes these, and the idle noise floor cannot capture them: they are
# EVENT-driven -- a turn ending fires the Stop hook -- so they never happen during a
# quiet control window. Classified once here, with the reason, rather than re-decided
# per run; anything NOT matched still fails the gate, which is the point.
#
#   responses.log, alerts.log  written by the user's Stop/Notification hooks
#   history.jsonl              prompt history, read by the interactive session
#   jobs/                      background job state of the session running this
LEAK_KNOWN_AMBIENT="${LEAK_KNOWN_AMBIENT:-/\.claude/(responses\.log|alerts\.log|history\.jsonl|jobs/)}"

# leak_validate -- the per-run VALIDITY gate. Does this data mean what it claims?
# Interpretation waits for every row, but a run whose controls did not fire is not a
# result, and that must be caught while re-running is still cheap.
leak_validate() {
  leak_say "validity gate:"
  python3 "$LEAK_RECORD" validate "$LEAK_RUN" --known-ambient "$LEAK_KNOWN_AMBIENT"
}

# leak_trust DIR -- approve DIR/.agent-sandbox exactly as `--trust` would, by
# recording its SHA-256 in the throwaway HOME's trust store. The real --trust is
# interactive, and the trust gate is not what any row is measuring: a dot-file that
# is silently ignored would make a share look like isolation.
leak_trust() {
  local d="$1" t="$LEAK_HOME/.config/agent-sandbox/trust"
  mkdir -p "$t"
  sha256sum -- "$d/.agent-sandbox" | cut -d' ' -f1 \
    >"$t/$(printf '%s' "$d" | sha256sum | cut -d' ' -f1)"
}

# leak_isolation_canary -- plant a canary in A's TRANSCRIPT; sets LEAK_ISO_PATH and
# LEAK_ISO_TOKEN.
#
# For a row EXPECTED TO LEAK, the control rows 1-4 used does not work. "B reads its own
# data -> obtained" proves nothing when the channel is shared: it is obtained whether or
# not the sandbox applied at all, so a positive in the test cell could equally mean the
# sandbox never ran. The control has to be something KNOWN ISOLATED read from the SAME
# sandbox -- row 2 measured A's transcript as ENOENT under the default scoping. If A's
# shared data comes through while A's transcript does not, the sandbox demonstrably
# applied and the leak is the channel's, not the harness's.
#
# It also keeps the verdict set non-degenerate, which the validity gate requires for
# exactly this reason.
leak_isolation_canary() {
  local slug
  slug="$(leak_slug "$LEAK_A")"
  LEAK_ISO_TOKEN="LEAK-ISO-$(date +%s)-$RANDOM"
  LEAK_ISO_PATH="$LEAK_CONFIG/projects/$slug/00000000-0000-0000-0000-0000000000ff.jsonl"
  mkdir -p "$(dirname "$LEAK_ISO_PATH")"
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' \
    "$LEAK_ISO_TOKEN" >"$LEAK_ISO_PATH"
}

# leak_untrust DIR -- forget DIR's approval; the counterpart to leak_trust.
#
# Removing a dot-file while its approval still stands makes the engine REFUSE to
# launch -- deliberately, since a policy that vanished must not silently fall back to
# the defaults. So a row with any sandboxed cell AFTER a share cell must forget the
# approval as well as delete the file, or every later cell dies at launch. Found by
# the validity gate rather than by reading the code, which is what it is for.
leak_untrust() {
  local d="$1" t="$LEAK_HOME/.config/agent-sandbox/trust"
  rm -f "$t/$(printf '%s' "$d" | sha256sum | cut -d' ' -f1)"
}

# leak_record NAME --set k=v ... -- one record per cell, under records/.
leak_record() {
  local name="$1"
  shift
  python3 "$LEAK_RECORD" write --out "$LEAK_RUN/records/$name.json" \
    --set "row=${LEAK_ROW:-unknown}" \
    --set "claude_version=$(claude --version 2>/dev/null | head -1)" \
    --set "run=$LEAK_RUN" \
    "$@"
}
