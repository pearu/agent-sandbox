#!/usr/bin/env bash
# Step 4 of the session-isolation plan: find out which parts of ~/.claude Claude
# Code actually NEEDS, before we hide any of them.
#
#   bash probes/claude-state-probe.sh          RUN ON THE HOST (not in a sandbox)
#
# Method: run the real agent inside a throwaway bubblewrap that inherits the host
# filesystem and network (--bind / /) and differs only in which ~/.claude paths
# are blanked -- a tmpfs over a directory, an empty writable file over
# history.jsonl. If the agent still completes a turn, that path is not needed.
# A control run with nothing blanked comes first: if the control fails, the
# harness is wrong and every later result would be meaningless.
#
# It makes a handful of short Haiku calls, and creates one throwaway project
# under ~/.claude/projects (printed at the end so you can remove it). It never
# deletes or writes anything else in ~/.claude: the blanking is mount-only and
# lives and dies with each bwrap.
set -uo pipefail

die() {
  echo "claude-state-probe: $*" >&2
  exit 2
}
[[ -r /proc/1/cmdline ]] && [[ "$(tr '\0' ' ' </proc/1/cmdline)" == bwrap* ]] \
  && die "this is inside a sandbox; run it on the host (nested namespaces are blocked, and with AGENT_SANDBOX_SECCOMP=on unshare is denied)"
command -v bwrap >/dev/null || die "bwrap not found"
MODEL="${MODEL:-claude-haiku-4-5-20251001}"
CB="$(ls -d "$HOME"/.local/share/claude/versions/*/claude 2>/dev/null | sort -V | tail -1)"
[[ -x "$CB" ]] || CB="$(ls -d "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1)"
[[ -x "$CB" ]] || die "no Claude Code binary under ~/.claude... (~/.local/share/claude/versions)"
C="$HOME/.claude"
DIRS=(paste-cache file-history session-env sessions jobs shell-snapshots plans)
EMPTY="$(mktemp)"
trap 'rm -f "$EMPTY"' EXIT

# blank_args NAME...: bwrap arguments that blank the named paths
blank_args() {
  local n
  for n in "$@"; do
    if [[ "$n" == history.jsonl ]]; then
      printf '%s\0%s\0%s\0' --bind "$EMPTY" "$C/history.jsonl"
    elif [[ -d "$C/$n" ]]; then
      printf '%s\0%s\0' --tmpfs "$C/$n"
    fi
  done
}

# try LABEL CWD -- NAMES...: one agent turn with NAMES blanked; prints PASS/FAIL
try() {
  local label="$1" cwd="$2"
  shift 3
  local -a b=()
  mapfile -d '' -t b < <(blank_args "$@")
  local out rc
  out=$(cd "$cwd" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
    "${b[@]}" "$CB" -p 'Reply with the single word ok' --model "$MODEL" </dev/null 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "${out,,}" == *ok* ]]; then
    printf '  %-46s PASS\n' "$label"
    return 0
  fi
  printf '  %-46s FAIL (rc=%s) %s\n' "$label" "$rc" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  return 1
}

echo "claude-state-probe: agent $CB, model $MODEL"
echo
echo "== control: nothing blanked (must PASS, or the rest is meaningless) =="
try "control" "$PWD" -- || die "control failed: the harness itself is wrong, not the blanking"

echo
echo "== the whole target set blanked at once =="
ALL=(history.jsonl "${DIRS[@]}")
if try "history.jsonl + ${#DIRS[@]} directories" "$PWD" -- "${ALL[@]}"; then
  echo "  -> nothing in the target set is needed to start a session"
else
  echo
  echo "== bisecting: one path at a time =="
  for n in "${ALL[@]}"; do try "$n blanked" "$PWD" -- "$n"; done
fi

echo
echo "== how Claude Code names a project directory (the profile must match it) =="
# The claude profile computes the slug by replacing "/" with "-" only. If Claude
# Code also rewrites other characters, memory scoping would bind a directory that
# does not exist -- silently, for any project path containing one. Test with a
# path that has both a dot and a dash.
SLUGWORK="$(mktemp -d)/probe.a-b"
mkdir -p "$SLUGWORK"
EXPECT="${SLUGWORK//\//-}"
STAMP="$C/projects/.probe-stamp"
: >"$STAMP"
if try "create a session in '$(basename "$SLUGWORK")'" "$SLUGWORK" --; then
  ACTUAL="$(find "$C/projects" -maxdepth 1 -mindepth 1 -type d -newer "$STAMP" -printf '%f\n' 2>/dev/null | head -1)"
  if [[ -z "$ACTUAL" ]]; then
    echo "  no new project directory appeared at all (print mode may not persist a session)"
  elif [[ "$ACTUAL" == "${EXPECT#-}" || "$ACTUAL" == "$EXPECT" ]]; then
    printf '  %-46s MATCH (%s)\n' "slug scheme: replace / only" "$ACTUAL"
  else
    printf '  %-46s MISMATCH\n' "slug scheme"
    echo "    profile would compute: $EXPECT"
    echo "    Claude Code actually used: $ACTUAL"
    echo "    -> profiles/claude.sh _claude_project_slug is wrong for such paths"
  fi
fi
rm -f "$STAMP"

echo
echo "== resume: does replaying a transcript survive the blanking? =="
# Deterministic: create with a known --session-id, then resume that id.
RWORK="$(mktemp -d)"
SID="$(cat /proc/sys/kernel/random/uuid)"
if (cd "$RWORK" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
  "$CB" -p 'Reply with the single word ok' --model "$MODEL" --session-id "$SID" </dev/null >/dev/null 2>&1); then
  printf '  %-46s PASS\n' "create a session with a known id"
  rb=()
  mapfile -d '' -t rb < <(blank_args "${ALL[@]}")
  out=$(cd "$RWORK" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
    "${rb[@]}" "$CB" -p --resume "$SID" 'Reply with the single word ok' --model "$MODEL" </dev/null 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "${out,,}" == *ok* ]]; then
    printf '  %-46s PASS\n' "resume that id with the target set blanked"
  else
    printf '  %-46s FAIL (rc=%s) %s\n' "resume with the target set blanked" "$rc" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  fi
else
  printf '  %-46s FAIL -- cannot test resume\n' "create a session with a known id"
fi

echo
echo "claude-state-probe: done."
echo "  throwaway dirs to delete: $SLUGWORK, $RWORK"
echo "  and any new dir under $C/projects for those paths"
