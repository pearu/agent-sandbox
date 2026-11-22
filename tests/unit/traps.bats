#!/usr/bin/env bats
# The engine's signal handlers and bash 5.2 (#423). A handler that runs while bash 5.2
# parses a command substitution fails ("trap: line 2: unexpected EOF while looking for
# matching `)'") and abandons the rest of the script. It runs there deterministically when
# the signal arrived during an earlier substitution of the same simple command, so the
# engine runs one substitution per simple command (tests/helpers/sibling_comsubs.py says
# which commands hold more). What a signal can still hit is the parse of a single `$(`,
# microseconds; docs/design.md ("Signals") says what that does.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  SCAN="$BATS_TEST_DIRNAME/../helpers/sibling_comsubs.py"
}

# siblings FILE -- the scanner's lines for FILE: FIRSTLINE LASTLINE FUNCTION COUNT TEXT.
siblings() { python3 "$SCAN" "$1"; }

# The engine spells a handler one way only: `trap 'ACTION' SIGNALS`, on a line of its own,
# with nothing after the signals. handlers FILE prints those lines as ACTION|SIGNALS.
handlers() { sed -nE "s/^ *trap '([^']+)' ([A-Z0-9 ]+)\$/\\1|\\2/p" "$1"; }

# other_traps FILE -- LINE: TEXT for each other `trap` at a command position (after a line's
# start, ; & | ( { ! or a keyword) on a non-comment line, unless it is a reset (`trap -`) or
# an ignore (`trap ''`): a handler spelled any other way, which handlers would not see.
# Exempt, by name, as text that is not the engine's own trap:
# - _as_remote_account's remote command string (`ssh … 'set -e; …; trap … EXIT; …'`),
#   which runs on the remote host.
# - _as_keeper_tie's watcher, the `bash -c '…'` body of strict's parent-death watcher
#   (#430): a bash of its own, outside the engine's shell, whose handler `end` runs no
#   command substitution (its body has none, so bash 5.2 has nothing to meet).
# What it cannot see, none of which the engine writes: `builtin trap …`, `command trap …`,
# `eval "trap …"`, and a `trap` inside backticks.
other_traps() {
  python3 - "$1" <<'PY'
import re, sys

EXEMPT = [
    """trap '"'"'rm -rf "$t"'"'"' EXIT""",  # _as_remote_account's remote command
    "trap end TERM URG",  # _as_keeper_tie's watcher: its handler
    'trap "" TERM URG',  # _as_keeper_tie's watcher: its handler ignores both from its start
]
CMD = re.compile(r"(?:^|[;&|({!]|\b(?:then|do|else|elif|if)\b)\s*trap(?=\s|$)")
ONE = re.compile(r"^ *trap '[^']+' [A-Z0-9 ]+$")
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.rstrip("\n")
    if line.lstrip().startswith("#") or ONE.match(line):
        continue
    for m in CMD.finditer(line):
        rest = line[m.end():]
        if any(rest.startswith(e[len("trap"):]) for e in EXEMPT):
            continue
        if (rest.split() or [""])[0] not in ("-", "''"):
            print(f"{n}: {line.strip()}")
PY
}

@test "the sibling-substitution scanner: what it counts as one command, and what it skips" {
  local f="$BATS_TEST_TMPDIR/s.sh"
  # shellcheck disable=SC2016 # bash text, not expanded here
  cat >"$f" <<'SH'
f() {
  v="$(a)$(b)"
  cmd "$(a)" "$(b)"
  v="$(a)" w="$(b)"
  [[ "$(a)" == "$(b)" ]]
  diff <(a) <(b)
  args+=(
    --x "$(a)"
    # a comment with $(c)
    --y "$(b)"
  )
  long "$(a)" \
    "$(b)"
}
g() (
  v="$(a)"; w="$(b)"
  v="$(a)" && w="$(b)" || u="$(c)"
  v="$(a "$(b)")"
  v=$(($(a) + 1)) w=$((1 + 2))
  v='$(a) $(b)'
  # $(a) $(b)
  printf '%s\n' "$x" | cat "$(a)"
  cat <<EOF
$(a) $(b)
EOF
  v="$(a)"
  v="$(_as_one "$(a)/x/$(b)")"
  (mkdir -p -- "$(a)" "$(b)") || return 1
  if [[ -L x ]] && ! ([[ "$(a)" == "$(b)" ]]); then :; fi
  printf '%s %s\n' "$(a)" "$(b)" | cat -v
  for d in "$(_as_one "$(a)/$(b)")"/*/id; do :; done
  ((n += $(a) + $(b)))
)
h() {
  [[ "$(a)" == x && -n "$(b)" ]] || continue
  if [[ -z "$(a)" ||
  -z "$(b)" ]]; then :; fi
  ([[ "$(a)" == x && -n "$(b)" ]]) || continue
  [[ "$(a)" =~ ^(x|y)$ && -n "$(b)" ]] || :
}
SH
  run siblings "$f"
  [ "$status" -eq 0 ]
  # the flagged ones, by first line, function and count: in g only the arithmetic command,
  # whose substitutions the shell expands itself
  # and in h, && and || inside [[ ]] (one command), a [[ ]] over two lines, and a | in a
  # [[ ]] regex (no pipeline)
  [ "$(cut -f1,3,4 <<<"$output" | tr '\t' ' ' | tr '\n' ';')" = "2 f 2;3 f 2;4 f 2;5 f 2;6 f 2;7 f 2;12 f 2;32 g 2;35 h 2;36 h 2;39 h 2;" ]
  # an array literal is one command, from its line to the closing one
  [ "$(awk -F'\t' '$1 == 7 { print $2 }' <<<"$output")" = 11 ]
}

# The rule (#423): a simple command the shell runs itself has at most one top-level
# `$(…)`, `<(…)` or `>(…)`. Three forms comply. `v="$(_as_one "$(a)/x/$(b)")"`: one
# top-level substitution, the inner two expanded in its child, where no handler is armed;
# _as_one returns the status the shell had on entry, the last inner substitution's, so
# the assignment's status is the one `v="$(a)/x/$(b)"` had. `( cmd "$(a)" "$(b)" )`: a
# subshell, whose own expansions are the child's; for a command that leaves the shell's
# state alone. And the parts hoisted into commands of their own. An element of a pipeline
# of two or more runs in a child too (the engine never sets lastpipe), and is not counted.
@test "no simple command in the engine or the profiles' scripts holds two substitutions side by side (#423)" {
  local f
  run siblings "$ENGINE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for f in "$REPO_ROOT"/profiles/*/*.sh; do
    run siblings "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# Every handler the engine installs (a `trap 'ACTION' SIGNALS` line), and why each is
# where it is; a new one fails here until it is added, with its reasoning, and so does a
# handler spelled any other way (other_traps).
@test "the engine's signal handlers are the listed ones (#422, #423)" {
  local expected
  expected="$(
    cat <<'EOF'
_as_session_exit|EXIT
_as_session_signal 2|INT
_as_session_signal 15|TERM
_as_session_signal 1|HUP
_as_handover_sig=2|INT
_as_handover_sig=15|TERM
_as_handover_sig=1|HUP
_as_woke=1|USR1
:|INT QUIT
sig=1|INT TERM HUP
_serve_stop=1|INT TERM HUP
:|INT
chmod -R u+rwX -- "$tmp" 2>/dev/null; rm -rf -- "$tmp"|EXIT
exit 130|INT TERM HUP
EOF
  )"
  # _as_session_exit, _as_session_signal (_as_session_begin): a launch's setup, until the
  #   keeper's supervisor is started, and again after a failed start; one substitution
  #   per simple command there.
  # _as_handover_sig=N (_as_handover_defer): while a keeper starts, the signal recorded
  #   by a builtin assignment, no cleanup; acted on once the start's outcome is known.
  # _as_woke=1 USR1 (_as_keeper_supervise): a builtin assignment, the wake kept for the
  #   next wait (#441); no substitution once a join can signal it (#419).
  # : INT QUIT (_as_keeper_join): around one foreground command.
  # sig=1 (_as_summarize): around the turn and _as_summarize_forget; no substitution.
  # _serve_stop=1 (_as_serve): the loop; single substitutions, and the ending ignores the
  #   three until it returns.
  # : INT (_as_login): around one foreground subshell.
  # the EXIT and exit 130 of _as_install_fetch: single substitutions; a hit ends the fetch,
  #   its temporary directory removed.
  local got
  got="$(handlers "$ENGINE")"
  [ "$(LC_ALL=C sort <<<"$got")" = "$(LC_ALL=C sort <<<"$expected")" ]
  run other_traps "$ENGINE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a handler in another spelling is seen: other_traps flags it, and the inventory's spelling is the one it allows (#423)" {
  local f="$BATS_TEST_TMPDIR/engine" sp
  cp -- "$ENGINE" "$f"
  run other_traps "$f"
  [ -z "$output" ]
  # six spellings handlers would not see, each added to a copy of the engine; the last
  # pins other_traps' keywords (then, do, else, elif, if)
  for sp in 'trap "_x" TERM' "trap -- '_x' TERM" "trap '_x' TERM # why" ": ; trap '_x' TERM" 'trap _x TERM' "if c; then trap '_x' TERM; fi"; do
    {
      cat -- "$ENGINE"
      printf '_x_arm() {\n  %s\n}\n' "$sp"
    } >"$f"
    run other_traps "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *": $sp" ]]
    [ "$(handlers "$f")" = "$(handlers "$ENGINE")" ]
  done
  # the one spelling: not other_traps' but handlers', so the inventory sees it
  {
    cat -- "$ENGINE"
    printf "_x_arm() {\n  trap '_x' TERM\n  trap - TERM\n  trap '' INT\n}\n"
  } >"$f"
  run other_traps "$f"
  [ -z "$output" ]
  [ "$(handlers "$f" | tail -n 1)" = "_x|TERM" ]
}

@test "_as_one keeps the expression's status: its last substitution's, as the plain assignment had (#423)" {
  source_engine
  local v rc
  v="$(_as_one "$(printf A)$(exit 3)")" && rc=0 || rc=$?
  [ "$v" = A ] && [ "$rc" -eq 3 ]
  v="$(_as_one "$(exit 4)$(printf B)")" && rc=0 || rc=$?
  [ "$v" = B ] && [ "$rc" -eq 0 ]
  # the plain assignment, for comparison
  v="$(printf A)$(exit 3)" && rc=0 || rc=$?
  [ "$v" = A ] && [ "$rc" -eq 3 ]
  # under set -e it ends the shell, as the plain assignment would
  run bash -c 'source "$1"; set -e; v="$(_as_one "$(echo A)$(exit 5)")"; echo notreached' _ "$ENGINE"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}
