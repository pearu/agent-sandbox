#!/usr/bin/env bash
# Derive Claude Code's project-directory naming rule empirically.
#
#   bash probes/slug-probe.sh        RUN ON THE HOST (not in a sandbox)
#
# profiles/claude.sh maps a project path to ~/.claude/projects/<slug> by replacing
# "/" with "-". A probe showed it also rewrites "." , so the profile is wrong for
# any path containing one -- scoping then binds a directory that does not exist and
# the project's own memory and transcripts vanish silently. One data point is not a
# rule, so this runs ONE cheap Haiku turn in a directory whose name carries many
# characters at once and reports what each became.
set -uo pipefail
die() {
  echo "slug-probe: $*" >&2
  exit 2
}
[[ -r /proc/1/cmdline ]] && [[ "$(tr '\0' ' ' </proc/1/cmdline)" == bwrap* ]] \
  && die "run this on the host, not in a sandbox"
MODEL="${MODEL:-claude-haiku-4-5-20251001}"
CB="$(ls -d "$HOME"/.local/share/claude/versions/*/claude 2>/dev/null | sort -V | tail -1)"
[[ -x "$CB" ]] || CB="$(ls -d "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1)"
[[ -x "$CB" ]] || die "no Claude Code binary found"
C="$HOME/.claude"

# One name, many characters: dot underscore plus at tilde colon equals comma,
# mixed case, digits, and an existing dash to see whether dashes survive.
NAME='Ab.c_d+e@f~g:h=i,j-k9'
BASE="$(mktemp -d)"
WORK="$BASE/$NAME"
mkdir -p "$WORK"
STAMP="$C/projects/.slug-probe-stamp"
mkdir -p "$C/projects"
: >"$STAMP"

echo "slug-probe: project path: $WORK"
if ! (cd "$WORK" && timeout 120 "$CB" -p 'Reply with the single word ok' --model "$MODEL" </dev/null >/dev/null 2>&1); then
  rm -f "$STAMP"
  die "the agent did not complete a turn in that directory; cannot observe a slug"
fi
ACTUAL="$(find "$C/projects" -maxdepth 1 -mindepth 1 -type d -newer "$STAMP" -printf '%f\n' 2>/dev/null | head -1)"
rm -f "$STAMP"
[[ -n "$ACTUAL" ]] || die "no new project directory appeared"

PROFILE="${WORK//\//-}"
echo
echo "  profile computes : $PROFILE"
echo "  Claude Code uses : $ACTUAL"
echo
if [[ "$PROFILE" == "$ACTUAL" ]]; then
  echo "  the profile's rule (replace / only) MATCHES for this name"
else
  echo "  MISMATCH. Per-character comparison of the tail:"
  printf '    %-24s %s\n' "input tail" "$NAME"
  printf '    %-24s %s\n' "slug tail" "${ACTUAL##*-9}"
  echo
  echo "  Which characters survived, from the whole slug:"
  echo "    slug alphabet: $(printf '%s' "$ACTUAL" | fold -w1 | sort -u | tr -d '\n')"
  echo "    (any of . _ + @ ~ : = , absent above was rewritten)"
fi
echo
echo "slug-probe: delete when done: $BASE  and  $C/projects/$ACTUAL"
