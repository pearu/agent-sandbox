#!/usr/bin/env bats
# _as_placeholders_in_use on canned mount tables: which placeholder mount points another
# live session or keeper holds. No bwrap and no real keeper: the liveness helpers are
# stubbed, and `cat` serves the host's /proc/self/mountinfo and each keeper's
# /proc/<pid>/mountinfo from files written here, so the verdicts do not depend on what a
# given bwrap version leaves in a mount table (#355, P7: before #368, one launch shape got
# a verdict that differed between CI (bwrap 0.9.0) and this host (0.12) and was never
# explained).
#
# The layout every test shares: the test directory T is a mount of its own on the host
# (device 0:50, root /), and the placeholders are files below it. A role's keeper binds a
# directory of T -- an account, accounts/work -- at /home/u/.claude, and has a mount on
# /home/u/.claude/.claude.json: on the host that is $T/accounts/work/.claude.json, found
# through the parent bind's device and root, not through the inside path.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  source_engine
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/t"
  MI="$BATS_TEST_TMPDIR/mountinfo"
  ST="$BATS_TEST_TMPDIR/state"
  export AGENT_SANDBOX_SESSION_BASE="$BATS_TEST_TMPDIR/sessions"
  mkdir -p "$T/accounts/work" "$T/accounts/personal" "$MI" "$ST" "$AGENT_SANDBOX_SESSION_BASE"
  : >"$T/accounts/work/.claude.json"
  : >"$T/accounts/work/settings.json"
  : >"$T/accounts/personal/.claude.json"
  printf '%s\n' \
    "21 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw" \
    "40 21 0:50 / $(esc "$T") rw,relatime shared:9 - tmpfs tmpfs rw" >"$MI/host"
  # A process is live when its recorded start time is `live`; a keeper is live when its
  # keeper/id names a payload that is not `dead*`. A payload's mount table is
  # $MI/<payload>, absent for one that cannot be read.
  # shellcheck disable=SC2329 # called by _as_placeholders_in_use
  _as_state_dir() { printf '%s' "$ST"; }
  # shellcheck disable=SC2329 # called by _as_placeholders_in_use
  _as_proc_is() { [[ "$2" == live ]]; }
  # shellcheck disable=SC2329 # called by _as_placeholders_in_use
  _as_keeper_live() {
    read -r _keeper_target _ <"$1/keeper/id" || return 1
    [[ "$_keeper_target" != dead* ]]
  }
  # shellcheck disable=SC2329 # called by _as_placeholders_in_use
  cat() {
    case "$*" in
      /proc/self/mountinfo) command cat "$MI/host" ;;
      "-- /proc/"*/mountinfo)
        local p="${2#/proc/}"
        command cat -- "$MI/${p%/mountinfo}"
        ;;
      *) command cat "$@" ;;
    esac
  }
}

# esc PATH -- PATH in mountinfo's escaped form.
esc() {
  local e="$1"
  e="${e//\\/\\134}" e="${e// /\\040}" e="${e//$'\t'/\\011}"
  printf '%s' "$e"
}

# keeper NAME ROLE -- a live keeper of ROLE under the state directory whose payload is
# NAME: its mount table is $MI/NAME (a `dead*` NAME is not live).
keeper() {
  mkdir -p "$ST/claude/-proj/$2/keeper"
  printf '%s live\n' "$1" >"$ST/claude/-proj/$2/keeper/id"
}

# role_table NAME ACCOUNT -- NAME's mount table: the account directory $T/ACCOUNT bound at
# /home/u/.claude, and a file bound on /home/u/.claude/.claude.json.
role_table() {
  printf '%s\n' \
    "100 99 0:70 / / rw - tmpfs tmpfs rw" \
    "101 100 0:50 /$(esc "$2") /home/u/.claude rw - tmpfs tmpfs rw" \
    "102 101 0:50 /accounts/other.json /home/u/.claude/.claude.json rw - tmpfs tmpfs rw" >"$MI/$1"
}

# in_use PATH... -- the indexes _as_placeholders_in_use prints, sorted, one per line.
in_use() {
  _as_placeholders_in_use "$@" | sort -nu
}

@test "_as_placeholders_in_use: a path another role's keeper has a mount on, through a parent bind of its directory, is in use" {
  keeper kA one
  role_table kA accounts/work
  run in_use "$T/accounts/work/settings.json" "$T/accounts/work/.claude.json"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
}

@test "_as_placeholders_in_use: a path no live keeper has a mount on is not in use, a keeper with the same inside path from another account included" {
  keeper kB one
  role_table kB accounts/personal # its /home/u/.claude/.claude.json is personal's
  run in_use "$T/accounts/work/.claude.json" "$T/accounts/work/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # and the account it does bind is in use
  run in_use "$T/accounts/personal/.claude.json"
  [ "$output" = 1 ]
}

@test "_as_placeholders_in_use: a live keeper's mount table that cannot be read keeps every path" {
  keeper kA one
  role_table kA accounts/personal
  keeper kGone two # no $MI/kGone
  run in_use "$T/accounts/work/settings.json" "$T/accounts/work/.claude.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1\n2')" ]
}

@test "_as_placeholders_in_use: a dead keeper's table is not read, and a keeper the session base records is" {
  keeper deadK one # its table would be unreadable: not read at all
  run in_use "$T/accounts/work/.claude.json"
  [ "$output" = "" ]
  mkdir -p "$AGENT_SANDBOX_SESSION_BASE/session.x"
  printf 'kS live\n' >"$AGENT_SANDBOX_SESSION_BASE/session.x/keeper"
  role_table kS accounts/work
  run in_use "$T/accounts/work/settings.json" "$T/accounts/work/.claude.json"
  [ "$output" = 2 ]
}

@test "_as_placeholders_in_use: a path a live session records is in use, one a dead session records is not" {
  local s="$AGENT_SANDBOX_SESSION_BASE"
  mkdir -p "$s/session.live" "$s/session.dead"
  printf '1 live\n' >"$s/session.live/owner.id"
  printf '%s\n' "$T/accounts/work/.claude.json" >"$s/session.live/placeholders"
  printf '2 gone\n' >"$s/session.dead/owner.id"
  printf '%s\n' "$T/accounts/work/settings.json" >"$s/session.dead/placeholders"
  run in_use "$T/accounts/work/settings.json" "$T/accounts/work/.claude.json"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
}

@test "_as_placeholders_in_use: names with a space match in mountinfo's escaped form" {
  mkdir -p "$T/my acct"
  : >"$T/my acct/.claude.json"
  keeper kA one
  role_table kA "my acct"
  grep -qF 'my\040acct' "$MI/kA"
  run in_use "$T/accounts/work/.claude.json" "$T/my acct/.claude.json"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
}
