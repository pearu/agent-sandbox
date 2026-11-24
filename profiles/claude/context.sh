#!/usr/bin/env bash
# context.sh -- the claude profile's context file (#456): how full a role's context is,
# where the Supervisor reads it. Sourced by statusline.sh and state-hook.sh inside the
# sandbox (copied beside them by profile_briefing_args), and run on the host by
# profile_serve_result after a turn of --serve:
#
#   bash context.sh FILE PLAN RESCUE SERVED KEY=VALUE...
#
# FILE is the context file, one line, e.g.
#
#   level=ok tokens=612000 window=1000000 stop=977000 left=365000 used=63% turn=+18000 maxturn=41000 session=ID at=2026-11-23T10:00:00Z
#
#   tokens   the context's size: the last response's input, cache-creation and
#            cache-read tokens (what Claude Code counts against its limit)
#   window   the model's context window
#   stop     where Claude Code refuses a request with auto-compact off: the window less
#            min(the model's max output tokens, 20000) less 3000 (2.1.311, the binary's
#            UQ, RVe and gHr = 20000; measured by stub bisection, #456: 976500 tokens ran
#            on a 1M window, 976999 were refused). Without the model's max output, 20000.
#   left     stop - tokens
#   used     tokens as a percent of stop, rounded down: of the usable span, not the window
#   turn     the growth over the last turn: tokens at its Stop less tokens at its prompt
#   maxturn  the largest turn of this session
#   session  the session these numbers are of; a new one resets turn and maxturn
#   at       when the line was written (UTC)
#   level    ok; plan (used >= PLAN percent); rescue (left <= RESCUE tokens, and for a
#            served role, SERVED 1, <= 2 x maxturn when that is larger); stopped (left
#            <= 0, or refused=1: a turn the limit refused); ? while stop is unknown
#
# A field whose value is not known is `?`. FILE.level holds the level alone, so a
# watcher on it wakes a few times per Task, not at every turn.
#
# The KEY=VALUEs are what the writer knows: tokens, window, maxout (the model's max
# output tokens), session, base (the tokens at this turn's prompt, of this session:
# turn and maxturn are updated) and refused=1. What it does not give is kept from the
# file's line: the window and stop of any session, turn and maxturn of the same session.
# PLAN is a percent (60) or `-` (no such level), RESCUE a number of tokens or `-`.
#
# Written by a rename from a file made beside it, and only when a value but `at` changes
# (the status line runs every second); FILE.level only when the level changes. Serialized
# by a lock on FILE's directory, when flock is there: the status line and the Stop hook
# may write at once. Every number read back is checked to be digits before any
# arithmetic: on the host the file is what a sandbox wrote.

# ctx_num V -- V is a decimal number (no sign, at most 15 digits).
ctx_num() { [[ "$1" =~ ^[0-9]{1,15}$ ]]; }

# ctx_update FILE PLAN RESCUE SERVED KEY=VALUE... -- write FILE (and FILE.level) from
# the KEY=VALUEs and FILE's line, as above, and set CTX_LEVEL and CTX_LEFT to the level
# and the tokens left it computed (left empty when not known). Status 0 always.
ctx_update() {
  local file="$1" plan="$2" rescue="$3" served="$4" kv k v dir name line="" old lev oldlev="" tmp fd=""
  shift 4
  [[ -n "$file" && "$file" != */ ]] || return 0
  local tokens="" window="" maxout="" session="" base="" refused=0
  for kv in "$@"; do
    k="${kv%%=*}" v="${kv#*=}"
    case "$k" in
      tokens | window | maxout | base) ctx_num "$v" && printf -v "$k" '%s' "$((10#$v))" ;;
      session) [[ "$v" =~ ^[A-Za-z0-9_-]{1,64}$ ]] && session="$v" ;;
      refused) [[ "$v" == 1 ]] && refused=1 ;;
    esac
  done
  dir="${file%/*}" name="${file##*/}"
  [[ "$file" == */* ]] || dir=.
  # One writer at a time: a lock on the directory, which the file's writers share.
  if command -v flock >/dev/null 2>&1 && exec {fd}<"$dir"; then
    flock -w 2 "$fd" || :
  fi 2>/dev/null
  # The line as it is: a regular file only, never through a link, one line of at most 4 KiB.
  # (A FIFO renamed in between the test and the read would hold the read open: on the host
  # that stalls only the role's own --serve loop, its caller; R1's N2, left as it is.)
  if [[ -f "$file" && ! -L "$file" ]]; then
    { IFS= read -r -n 4096 line <"$file"; } 2>/dev/null || :
  fi
  local p_tokens="" p_window="" p_stop="" p_turn="" p_maxturn="" p_session="" p_level=""
  local -a words=()
  read -r -a words <<<"$line" || :
  for kv in ${words[@]+"${words[@]}"}; do
    k="${kv%%=*}" v="${kv#*=}"
    case "$k" in
      tokens | window | stop | maxturn) ctx_num "$v" && printf -v "p_$k" '%s' "$((10#$v))" ;;
      turn) [[ "$v" =~ ^[+-][0-9]{1,15}$ ]] && p_turn="$v" ;;
      session) [[ "$v" =~ ^[A-Za-z0-9_-]{1,64}$ ]] && p_session="$v" ;;
      level) [[ "$v" =~ ^(ok|plan|rescue|stopped)$ ]] && p_level="$v" ;;
    esac
  done
  [[ -n "$session" ]] || session="$p_session"
  local same=0
  [[ -n "$session" && "$session" == "$p_session" ]] && same=1
  # The window and the stop: given, or the line's. Without the model's max output, a stop
  # for the line's own window is kept (it may have come with one).
  local stop=""
  if [[ -n "$window" ]]; then
    if [[ -n "$maxout" ]]; then
      ((maxout < 20000)) || maxout=20000
      stop=$((window - maxout - 3000))
    elif [[ "$window" == "$p_window" && -n "$p_stop" ]]; then
      stop="$p_stop"
    else
      stop=$((window - 23000))
    fi
  else
    window="$p_window" stop="$p_stop"
  fi
  ((${stop:-1} > 0)) || stop=""
  [[ -n "$tokens" ]] || { ((same)) && tokens="$p_tokens"; }
  # turn and maxturn: of this session only.
  local turn="" maxturn=""
  if ((same)); then turn="$p_turn" maxturn="$p_maxturn"; fi
  if [[ -n "$base" && -n "$tokens" ]]; then
    turn=$((tokens - base))
    if ((turn >= 0)); then turn="+$turn"; fi
    if ((${turn#+} >= 0)) && [[ -z "$maxturn" ]] || ((${turn#+} > ${maxturn:-0})); then maxturn="${turn#+}"; fi
  fi
  local left="" used="" eff
  if [[ -n "$tokens" && -n "$stop" ]]; then
    left=$((stop - tokens))
    used=$((tokens * 100 / stop))
  fi
  if ((refused)); then
    lev=stopped
  elif [[ -z "$left" ]]; then
    # A refusal recorded for this session stays until a response says otherwise.
    if ((same)) && [[ "$p_level" == stopped && -z "$tokens" ]]; then lev=stopped; else lev="?"; fi
  elif ((left <= 0)); then
    lev=stopped
  else
    lev=ok
    if [[ "$rescue" =~ ^[0-9]{1,15}$ ]]; then
      eff=$((10#$rescue))
      [[ "$served" == 1 && -n "$maxturn" ]] && ((2 * maxturn > eff)) && eff=$((2 * maxturn))
      ((left <= eff)) && lev=rescue
    fi
    if [[ "$lev" == ok && "$plan" =~ ^[0-9]{1,3}$ ]] && ((tokens * 100 >= 10#$plan * stop)); then
      lev=plan
    fi
  fi
  line="level=$lev tokens=${tokens:-?} window=${window:-?} stop=${stop:-?} left=${left:-?} used=${used:+$used%}"
  [[ -n "$used" ]] || line+="?"
  line+=" turn=${turn:-?} maxturn=${maxturn:-?} session=${session:-?}"
  old=""
  if [[ -f "$file" && ! -L "$file" ]]; then
    { IFS= read -r -n 4096 old <"$file"; } 2>/dev/null || :
  fi
  if [[ "${old% at=*}" != "$line" ]]; then
    local at
    TZ=UTC printf -v at '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    ctx_put "$dir" "$name" "$line at=$at"
  fi
  if [[ -f "$file.level" && ! -L "$file.level" ]]; then
    { IFS= read -r -n 64 oldlev <"$file.level"; } 2>/dev/null || :
  fi
  [[ "$oldlev" == "$lev" && -f "$file.level" && ! -L "$file.level" ]] || ctx_put "$dir" "$name.level" "$lev"
  [[ -z "$fd" ]] || exec {fd}<&-
  # What this update made of it, for the Stop hook's save prompt (state-hook.sh).
  # shellcheck disable=SC2034 # read by the caller that sourced this file
  CTX_LEVEL="$lev" CTX_LEFT="$left"
  return 0
}

# ctx_put DIR NAME TEXT -- DIR/NAME holds the line TEXT, by a rename from a new file in
# DIR: whatever is at DIR/NAME, a link included, is replaced, never written through. The
# new file is made and written in one open, O_EXCL (noclobber, under a name no one knows
# before it exists), never opened again by its name: on the host DIR is the sandbox's to
# write, and a process left running there could put a link at a temp file's name the
# moment it appears (inotify), before a second open -- `mktemp`, then `>"$tmp"` -- wrote
# through it to any file of yours.
ctx_put() {
  local - tmp
  set -C
  tmp="$(mktemp -u -- "$1/.$2.XXXXXXXXXX" 2>/dev/null)" || return 0
  { printf '%s\n' "$3" >"$tmp" && mv -f -- "$tmp" "$1/$2"; } 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  (($# >= 4)) || {
    echo "usage: context.sh FILE PLAN RESCUE SERVED KEY=VALUE..." >&2
    exit 2
  }
  ctx_update "$@"
fi
