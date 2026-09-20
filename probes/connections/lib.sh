#!/usr/bin/env bash
# The METHOD for the connections study (docs/connections-study.md), Part 1.
#
# Part 1 asks one question per mode: does a channel behave as its mode promises, in
# both directions, at the stated time? Every assertion here is about the CONTAINER --
# scripted, free, no model -- which is what makes this file an ACCEPTANCE SUITE as much
# as a study: the connections implementation is finished exactly when these pass.
#
# It runs today, against an engine that has none of it. A mode the engine cannot express
# records `not-implemented` rather than a failure, so the suite reports a score
# (pass / fail / not-implemented) and the specification exists as executable text before
# the code does. `live` is the exception: it is today's behaviour, needs no knob, and so
# exercises the harness itself from the first run.
#
# WHAT IT REUSES. probes/leak/lib.sh is the instrument -- one tree per experiment, hexid
# names, pure-hex canaries, the throwaway HOME, the real ~/.claude asserted unchanged,
# the record writer and the validity gate. This file adds only what the connections
# model needs and the leak study had no reason to build:
#
#   a LAUNCH SEQUENCE. `copy` and `cow` promise things that appear only at the NEXT
#   launch of the SAME sandbox -- a refresh that arrives, a change that persists, a
#   conflict that warns. So a cell is several launches with source edits between them,
#   and every record carries the launch index.
#
# WHAT IT DOES NOT ASSERT: where a sandbox keeps its copies or its layer. Those are the
# implementation's to choose. Every assertion below is observable through the mount or
# on the source, so the suite survives a change of layout -- and a cell that can only be
# written by inspecting internals is a cell that would pass for the wrong reason.
# shellcheck shell=bash

CONN_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Results land beside the leak study's, not inside them.
export LEAK_RESULTS_SUBDIR=connections
# shellcheck source=probes/leak/lib.sh
source "$CONN_HERE/../leak/lib.sh"

# ----- the channel map ------------------------------------------------------
# A channel is named by what it carries; these are the paths Claude Code reads it
# from, which is the `claude` profile's business everywhere else. The study needs its
# own copy because it plants and reads directly, and Part 1 uses `instructions` only:
# it is the cheapest channel and it has both shapes, a FILE and a DIRECTORY, which are
# not the same mechanism under an overlay or a copy.
# shellcheck disable=SC2034 # read by the suites that source this file
CONN_CHANNEL_FILE="CLAUDE.md" # instructions, file shape
CONN_CHANNEL_DIR="rules"      # instructions, directory shape

# ----- capability probe, PER MODE -------------------------------------------
# Does this engine implement THIS mode? Asked once per suite, and asked of the
# ENGINE'S BEHAVIOUR rather than of its help text.
#
# It began as one grep of `--engine-help` for the connect variable, which was enough
# while the engine implemented nothing: the only question was whether the feature
# existed. It stopped being enough the moment some modes landed and others had not,
# because then every cell ran, a refused launch produced no reader output, and the
# validity gate threw out the whole run as a broken experiment -- which is the one
# thing this suite must never confuse with a closed channel.
#
# WHY BEHAVIOUR AND NOT THE HELP TEXT. An engine whose help omits `copy` but whose code
# half-handles it without refusing would, under a help-text probe, have its cells
# skipped and its half-implementation hidden. Here those cells run and fail, which is
# what should happen: this study's whole premise is that documentation is not evidence,
# and its own probe has to live by that.
#
# So: ask for the mode and run `true`. Accepted -> the mode is implemented, run the
# cells. Refused with the engine's not-implemented wording -> record the expectation.
# Refused for ANY OTHER reason -> treat it as implemented and let the cells run, so a
# broken engine fails loudly instead of skipping quietly.
conn_mode_supported() {
  local mode="$1" out rc=0
  [[ "$mode" == live ]] && return 0 # no knob at all; today's behaviour
  [[ "${CONN_PROBED_MODE:-}" == "$mode" ]] && return "$CONN_PROBED_RC"
  out="$(
    cd "$LEAK_B" || exit 1
    env HOME="$LEAK_HOME" XDG_STATE_HOME="$LEAK_HOME/.local/state" \
      AGENT_SANDBOX_NET=none AGENT_SANDBOX_CONNECT="instructions=$mode native" \
      claude --quiet --exec true 2>&1
  )" || rc=$?
  CONN_PROBED_MODE="$mode"
  # The phrase is the engine's; agent-sandbox says so beside it. Matched with the
  # mode name in it, so a refusal about some OTHER mode cannot be mistaken for this
  # one's.
  if ((rc != 0)) && grep -qF "connect: mode '$mode' is not implemented" <<<"$out"; then
    CONN_PROBED_RC=1
    leak_say "engine does NOT implement \`$mode\` yet: its cells record the expectation"
  else
    CONN_PROBED_RC=0
    if ((rc == 0)); then
      leak_say "engine implements \`$mode\`: its cells run"
    else
      leak_say "engine refused \`$mode\` for some OTHER reason (exit $rc); its cells run and will fail"
    fi
  fi
  return "$CONN_PROBED_RC"
}

# ----- run and cell ---------------------------------------------------------
conn_setup() {
  local name="$1"
  leak_setup "$name"
  CONN_PASS=0 CONN_FAIL=0 CONN_TODO=0 CONN_BLOCKED=0
  CONN_CTRL_OK=0 CONN_CTRL_BAD=0
  CONN_SUITE="$name"
  CONN_PROBED_MODE="" CONN_PROBED_RC=0
  leak_real_config_before
}

# conn_cell ID MODE DESC -- one experiment: a fresh tree, and a launch counter.
#
# The cell is skipped (its assertions recorded as not-implemented) when its mode needs
# a knob the engine does not have. `live` never skips: it is what the engine does with
# no knob at all, which is both today's behaviour and this study's comparison arm.
conn_cell() {
  CONN_ID="$1" CONN_MODE="$2" CONN_DESC="$3"
  CONN_LAUNCH=0
  CONN_SKIP=0
  leak_cell "$CONN_ID"
  # After leak_cell, because the probe is a launch and needs this cell's tree.
  conn_mode_supported "$CONN_MODE" || CONN_SKIP=1
  # The connection this cell's launches run under, in the form the engine's knob takes.
  # Read by leak_read_sandboxed; empty for `live`, which is the default.
  if [[ "$CONN_MODE" == live ]]; then
    LEAK_CONNECT=""
  else
    LEAK_CONNECT="instructions=$CONN_MODE native"
  fi
  # How `cow` is implemented for this cell. Empty leaves the engine's own choice; the
  # suite-wide default comes from CONN_OVERLAY, which the runner sets for its second pass
  # over the cow suite so the two implementations can be compared on one host.
  LEAK_OVERLAY="${CONN_OVERLAY:-}"
  CONN_OVERLAY_EFF="${CONN_OVERLAY:-auto}"
  CONN_SOURCE="$LEAK_CONFIG"
  mkdir -p "$CONN_SOURCE/$CONN_CHANNEL_DIR"
  conn_write_probes
  local _note=""
  # ${CONN_SKIP:+...} would fire on the string "0" as well, which is set and false --
  # the note has to test the VALUE, not whether the variable exists.
  ((CONN_SKIP)) && _note=" (mode not implemented: recording the expectation)"
  leak_say "cell $CONN_ID [$CONN_MODE] $CONN_DESC$_note"
  conn_controls
  # AFTER the controls, and not before: an assertion must never be graded on a verdict,
  # a reader file or a stderr file left behind by the previous cell or by a control.
  # Cleared here, the failure mode is a missing verdict (which fails) rather than a
  # stale one (which can quietly pass).
  CONN_VERDICT="" CONN_READER_OUT="" CONN_LAUNCH_SAID=""
}

# conn_overlay auto|off -- force this cell's `cow` implementation, whatever the host
# could do. W8 is the cell that needs it: the fallback is the path two of the three
# supported releases take, and a path exercised only on old machines is a path that rots.
conn_overlay() {
  LEAK_OVERLAY="$1"
  CONN_OVERLAY_EFF="$1"
}

# conn_controls -- the two controls docs/connections-study.md requires of every cell,
# run once per cell before its sequence begins.
#
# A POSITIVE CONTROL, because a cell that expects a CLOSED channel cannot tell "the mode
# closed it" from "nothing ran": a launch that died, a reader that never started and a
# path that is simply absent all read as not-obtained. This reads a canary in the working
# directory, which every mode binds read-write, so `obtained` means the launch happened
# and the reader works. It deliberately does not read the channel under test -- a control
# that shares the subject's failure mode is not a control.
#
# AN ISOLATION CHECK, because the converse is just as silent: if a cell were somehow not
# sandboxed, every `obtained` in the suite would be true and meaningless. Another
# project's transcript is scoped by the engine independently of any connection, so it
# must stay closed in every mode.
#
# Controls are recorded but kept OUT of the acceptance score: they say the measurement is
# valid, not that the engine keeps a promise. A control that does not hold invalidates
# the run -- validate.py enforces that, which is what makes these more than decoration.
conn_controls() {
  ((CONN_SKIP)) && return 0
  local out tok
  tok="$(leak_token OWN)"
  printf '%s\n' "$tok" >"$LEAK_B/own-canary.txt"
  out="$LEAK_RUN/$CONN_ID-c1-positive.json"
  leak_read_sandboxed none "$LEAK_B" "$CONN_READER" "$out" "$LEAK_B/own-canary.txt" "$tok"
  conn_control "$out" obtained \
    "positive control: the launch ran and read a file that is certainly present"

  # AND THE PATHS AGREE. The control above proves a launch happened and the reader works.
  # It does not prove the sandbox sees the tree this harness plants into -- and if HOME
  # inside ever differed from the throwaway HOME, every subject read would miss for a
  # reason that has nothing to do with the mode. The `none` suite would then pass
  # COMPLETELY: nothing found, the source untouched, and the sandbox's own write read
  # back from the same wrong prefix. Cheap, and it needs no extra launch.
  local inside_home
  inside_home="$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("home", ""))
except Exception:
    print("")' "$out")"
  conn_control_host "$LEAK_HOME" "$inside_home" \
    "positive control: the sandbox sees the HOME this harness plants into"

  leak_isolation_canary
  out="$LEAK_RUN/$CONN_ID-c2-isolation.json"
  leak_read_sandboxed none "$LEAK_B" "$CONN_READER" "$out" "$LEAK_ISO_PATH" "$LEAK_ISO_TOKEN"
  conn_control "$out" "not-obtained-absent|not-obtained-unreachable" \
    "isolation check: another project's transcript stays closed from this sandbox"
}

# conn_control OUT WANT DESC -- a control whose evidence is a reader result.
conn_control() {
  local out="$1" want="$2" desc="$3" got
  got="$(python3 "$LEAK_RECORD" write --out "$out.rec" --reader "$out" \
    --set "cell=$CONN_ID" 2>/dev/null || echo invalid-reader-output)"
  conn_control_host "$want" "$got" "$desc" --reader "$out"
}

# conn_control_host WANT GOT DESC [--reader F] -- a control the harness decides on the
# host. WANT takes the same `|`-separated form as conn_expect, so a single value is an
# exact comparison.
conn_control_host() {
  local want="$1" got="$2" desc="$3" status=control-fail
  shift 3
  [[ "|$want|" == *"|$got|"* ]] && status=control-pass
  conn_record "$status" "$want" "$got" "$desc" "$@"
}

# The reader and the writer, written into B's own directory: the sandbox binds the
# working directory and nothing above it, so a probe anywhere else is not there.
conn_write_probes() {
  CONN_READER="$LEAK_B/read.py"
  cat >"$CONN_READER" <<'PY'
# Report whether TOKEN is in the channel at PATH, for a file or a directory, in the
# shape record.py classifies: open=ok plus token_found, or an errno.
import errno, json, os, sys

path, token = sys.argv[1], sys.argv[2]
# `home` is not for the verdict: it is what lets a control check that the sandbox sees
# the tree this harness plants into, rather than agreeing with itself at another prefix.
out = {"path": path, "token": token, "home": os.environ.get("HOME", "")}
try:
    if os.path.isdir(path):
        found, entries = False, []
        for root, _dirs, files in os.walk(path):
            for name in sorted(files):
                full = os.path.join(root, name)
                entries.append(os.path.relpath(full, path))
                try:
                    with open(full, encoding="utf-8", errors="surrogateescape") as fh:
                        if token in fh.read():
                            found = True
                except OSError:
                    pass
        out["open"] = "ok"
        out["entries"] = entries
        out["token_found"] = found
    else:
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            out["token_found"] = token in fh.read()
        out["open"] = "ok"
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY
  CONN_WRITER="$LEAK_B/write.py"
  cat >"$CONN_WRITER" <<'PY'
# Write TEXT to the channel file at PATH from inside, or delete it (TEXT == "").
# Reports in the reader's shape so one classifier covers both: token_found means the
# write (or the delete) did what it said.
import errno, json, os, sys

path, text = sys.argv[1], sys.argv[2]
out = {"path": path, "token": text}
try:
    if text == "":
        os.unlink(path)
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    out["open"] = "ok"
    out["token_found"] = True
except OSError as e:
    out["open"] = errno.errorcode.get(e.errno, str(e.errno))
    out["token_found"] = False
print(json.dumps(out))
PY
}

# ----- the source (native ~/.claude of the throwaway HOME) -------------------
# conn_source_write REL -- plant a fresh token in the source's REL; echo the token.
conn_source_write() {
  local rel="$1" tok
  tok="$(leak_token "${rel//\//_}")"
  mkdir -p "$(dirname -- "$CONN_SOURCE/$rel")"
  printf '# instructions\n\n%s\n' "$tok" >"$CONN_SOURCE/$rel"
  printf '%s' "$tok"
}
conn_source_delete() { rm -f -- "$CONN_SOURCE/$1"; }
conn_source_sha() { sha256sum -- "$CONN_SOURCE/$1" 2>/dev/null | cut -d' ' -f1; }
conn_source_exists() { [[ -e "$CONN_SOURCE/$1" ]] && echo yes || echo no; }

# ----- launches -------------------------------------------------------------
# conn_read REL TOKEN -- one launch: read the channel at REL from inside, for TOKEN.
# Sets CONN_VERDICT. A skipped cell performs no launch and leaves the verdict unset,
# which conn_expect turns into `not-implemented` rather than a false negative.
conn_read() {
  local rel="$1" tok="$2"
  ((CONN_SKIP)) && {
    CONN_VERDICT=""
    return 0
  }
  CONN_LAUNCH=$((CONN_LAUNCH + 1))
  local out="$LEAK_RUN/$CONN_ID-l$CONN_LAUNCH-read.json"
  leak_read_sandboxed none "$LEAK_B" "$CONN_READER" "$out" "$LEAK_CONFIG/$rel" "$tok"
  CONN_VERDICT="$(conn_verdict_of "$out")"
  CONN_READER_OUT="$out"
  # What the LAUNCH said is an assertion target of its own (a conflict must be named),
  # so the engine's stderr is kept per launch rather than discarded.
  CONN_LAUNCH_SAID="$out.err"
}

# conn_write_inside REL TEXT -- one launch that writes (or, with TEXT empty, deletes)
# the channel file at REL from inside. Sets CONN_VERDICT for the write itself.
conn_write_inside() {
  local rel="$1" text="$2"
  ((CONN_SKIP)) && {
    CONN_VERDICT=""
    return 0
  }
  CONN_LAUNCH=$((CONN_LAUNCH + 1))
  local out="$LEAK_RUN/$CONN_ID-l$CONN_LAUNCH-write.json"
  leak_read_sandboxed none "$LEAK_B" "$CONN_WRITER" "$out" "$LEAK_CONFIG/$rel" "$text"
  CONN_VERDICT="$(conn_verdict_of "$out")"
  CONN_READER_OUT="$out"
  CONN_LAUNCH_SAID="$out.err"
}

# conn_verdict_of READER.json -- the classifier's verdict for one launch's reader result.
# A reader that produced nothing parseable is a FAILED EXPERIMENT, never a negative, so it
# gets its own verdict and the validity gate refuses the run rather than reading it as a
# closed channel.
conn_verdict_of() {
  python3 "$LEAK_RECORD" write --out "$1.rec" --reader "$1" --set "cell=$CONN_ID" \
    2>/dev/null || echo invalid-reader-output
}

# conn_write_pair RELA TEXTA RELB TEXTB -- two launches of THIS sandbox at the SAME TIME.
#
# W9 is the only cell that needs this, and it needs it because concurrency is the ordinary
# case: a sandbox is keyed by project and role, so two terminals open on one project are
# two sessions of one sandbox. Every other cell is a sequence precisely because the
# promises it tests are about what the NEXT launch sees.
#
# Both verdicts are kept and conn_pick chooses which one the next assertion grades, so a
# session that failed is reported as its own failed assertion instead of disappearing into
# a single "it worked".
conn_write_pair() {
  local relA="$1" txtA="$2" relB="$3" txtB="$4" pa pb
  CONN_PAIR_A="" CONN_PAIR_B="" CONN_PAIR_AOUT="" CONN_PAIR_BOUT=""
  ((CONN_SKIP)) && return 0
  CONN_LAUNCH=$((CONN_LAUNCH + 1))
  local oa="$LEAK_RUN/$CONN_ID-l$CONN_LAUNCH-A.json"
  local ob="$LEAK_RUN/$CONN_ID-l$CONN_LAUNCH-B.json"
  leak_read_sandboxed none "$LEAK_B" "$CONN_WRITER" "$oa" "$LEAK_CONFIG/$relA" "$txtA" &
  pa=$!
  leak_read_sandboxed none "$LEAK_B" "$CONN_WRITER" "$ob" "$LEAK_CONFIG/$relB" "$txtB" &
  pb=$!
  wait "$pa" 2>/dev/null || true
  wait "$pb" 2>/dev/null || true
  CONN_PAIR_A="$(conn_verdict_of "$oa")"
  CONN_PAIR_B="$(conn_verdict_of "$ob")"
  CONN_PAIR_AOUT="$oa" CONN_PAIR_BOUT="$ob"
}

# conn_pick A|B -- grade the next assertion against that session's launch.
conn_pick() {
  case "$1" in
    A) CONN_VERDICT="$CONN_PAIR_A" CONN_READER_OUT="$CONN_PAIR_AOUT" ;;
    B) CONN_VERDICT="$CONN_PAIR_B" CONN_READER_OUT="$CONN_PAIR_BOUT" ;;
    *) leak_die "conn_pick takes A or B, not $1" ;;
  esac
  # Neither launch's stderr is "the launch" for a said-assertion when two ran at once.
  CONN_LAUNCH_SAID=""
}

# ----- assertions -----------------------------------------------------------
# conn_expect EXPECTED DESC -- EXPECTED is one verdict or several, `|`-separated (a
# closed channel is `absent` when the path is there and empty, `unreachable` when it is
# not there at all; both are closed, and which one is the implementation's choice).
conn_expect() {
  local expected="$1" desc="$2" status actual="${CONN_VERDICT:-}"
  if ((CONN_SKIP)); then
    status=not-implemented
  elif [[ "|$expected|" == *"|$actual|"* ]]; then
    status=pass
  else
    status=fail
  fi
  # The reader's raw output is evidence produced by a LAUNCH. A skipped cell launched
  # nothing, so attaching a reader file here stamped every recorded expectation with
  # `invalid-reader-output` -- a verdict about a launch that never ran, and one the gate
  # would otherwise have to learn to ignore.
  if [[ -n "${CONN_READER_OUT:-}" ]]; then
    conn_record "$status" "$expected" "$actual" "$desc" --reader "$CONN_READER_OUT"
  else
    conn_record "$status" "$expected" "$actual" "$desc"
  fi
}

# conn_expect_host EXPECTED ACTUAL DESC -- an assertion the harness makes on the HOST:
# the source unchanged, a file still gone, a warning named. These hold whether or not
# the mode is implemented, but recording them as passes in a skipped cell would inflate
# the score, so a skipped cell records them as not-implemented too.
conn_expect_host() {
  local expected="$1" actual="$2" desc="$3" status
  if ((CONN_SKIP)); then
    status=not-implemented
  elif [[ "$expected" == "$actual" ]]; then
    status=pass
  else
    status=fail
  fi
  conn_record "$status" "$expected" "$actual" "$desc"
}

# conn_expect_said REGEX DESC / conn_expect_said_not REGEX DESC -- what the LAST launch
# said. C5 and W4 promise that a conflict is named, and a promise nobody can see is not
# kept; C8 promises that a reset clears it, and a warning that outlives its cause trains
# the reader to ignore warnings.
#
# ALWAYS ASSERTED ON THE FIRST LAUNCH AFTER THE CONFLICT, never a later one: the design
# says "the launch says so" without settling once versus every time, so a cell that reads
# the second launch's stderr silently requires the stronger of the two readings and fails
# an engine that warns once, correctly.
# NOTHING TO READ IS NOT A PASS. `said_not` once held whenever no launch had spoken at
# all, which made it strongest-looking in exactly the case where it established least --
# the same shape as an assertion that cannot go red. A missing stderr is now its own
# answer, `no launch`, which satisfies neither direction.
conn_said_state() {
  [[ -r "${CONN_LAUNCH_SAID:-/nonexistent}" ]] || {
    printf 'no launch'
    return 0
  }
  if grep -Eq -- "$1" "$CONN_LAUNCH_SAID"; then printf 'said'; else printf 'absent'; fi
}
conn_expect_said() {
  conn_expect_host said "$(conn_said_state "$1")" "$2"
}
conn_expect_said_not() {
  conn_expect_host absent "$(conn_said_state "$1")" "$2"
}

conn_record() {
  local status="$1" expected="$2" actual="$3" desc="$4"
  shift 4
  local n=$((CONN_PASS + CONN_FAIL + CONN_TODO + CONN_BLOCKED + \
    CONN_CTRL_OK + CONN_CTRL_BAD + 1))
  python3 "$LEAK_RECORD" write --out "$LEAK_RUN/records/$CONN_ID-$n.json" \
    --set "suite=$CONN_SUITE" --set "cell=$CONN_ID" --set "channel=instructions" \
    --set "mode=$CONN_MODE" --set "source=native" --set "role=default" \
    --set "preset=n/a" --set "launch=$CONN_LAUNCH" \
    --set "assertion=$desc" --set "expected=$expected" --set "actual=$actual" \
    --set "status=$status" --set "cell_desc=$CONN_DESC" \
    --set "overlay=${CONN_OVERLAY_EFF:-auto}" \
    --set "claude_version=$(claude --version 2>/dev/null | head -1)" \
    --set "engine_version=$(claude --engine-version 2>/dev/null | head -1)" \
    "$@" >/dev/null
  case "$status" in
    pass) CONN_PASS=$((CONN_PASS + 1)) ;;
    fail) CONN_FAIL=$((CONN_FAIL + 1)) ;;
    # `blocked` is not `not-implemented`: one is a promise the engine does not make yet,
    # the other a promise nobody has measured here. Counting them together would let a
    # blocked cell disappear as the not-implemented count falls.
    blocked) CONN_BLOCKED=$((CONN_BLOCKED + 1)) ;;
    control-pass) CONN_CTRL_OK=$((CONN_CTRL_OK + 1)) ;;
    control-fail) CONN_CTRL_BAD=$((CONN_CTRL_BAD + 1)) ;;
    *) CONN_TODO=$((CONN_TODO + 1)) ;;
  esac
  printf '  %-16s %-18s %s\n' "$CONN_ID" "$status" "$desc"
}

# conn_reset -- the supported way back to the source, for one channel of this sandbox.
# C8 and W6 assert that it works; the verb does not exist yet, so on an engine without
# it the cell is already skipped and this is a no-op. When it lands, this is the single
# place the suite learns its spelling.
conn_reset() {
  CONN_RESET_RC=0
  ((CONN_SKIP)) && return 0
  local out="$LEAK_RUN/$CONN_ID-reset.out"
  # </dev/null and a timeout, because the verb's shape is a guess until it lands: if a
  # future engine treats --reset-connection as a pre-launch flag and then starts a
  # session, an unguarded call would block forever on a terminal that is not there --
  # hanging the suite instead of failing it. The exit code is KEPT, not swallowed, and
  # C8 and W6 assert on it, so the placeholder cannot rot into a no-op that always looks
  # fine.
  (
    cd "$LEAK_B" || exit 1
    env HOME="$LEAK_HOME" XDG_STATE_HOME="$LEAK_HOME/.local/state" \
      timeout 60 claude --reset-connection instructions
  ) >"$out" 2>&1 </dev/null || CONN_RESET_RC=$?
  ((CONN_RESET_RC == 0)) || leak_say "reset exited $CONN_RESET_RC (see $(basename "$out"))"
  return 0
}

# conn_cell_blocked ID MODE DESC REASON -- a cell that cannot run here at all.
#
# No tree, no controls, no launches: a control exists to say a MEASUREMENT is sound, and
# there is no measurement here. Spending two launches per blocked cell to control an
# experiment that never happens is pure cost, and it grows once the modes land.
conn_cell_blocked() {
  CONN_ID="$1" CONN_MODE="$2" CONN_DESC="$3"
  CONN_LAUNCH=0
  CONN_SKIP=0
  leak_say "cell $CONN_ID [$CONN_MODE] $CONN_DESC (blocked, nothing runs)"
  conn_blocked "$4"
}

# conn_blocked REASON -- recorded with its reason so the suite's score never hides it,
# and so nobody re-derives the blockage later.
conn_blocked() {
  conn_record blocked "a result" "cannot run here" "$1"
}

# ----- the end of a suite ---------------------------------------------------
# The score IS the result: an acceptance suite reports how much of the model the engine
# expresses, and "0 fail" is only good news beside "0 not-implemented".
conn_summary() {
  leak_cell_finish
  leak_real_config_after
  # THE GATE RUNS BEFORE THE SCORE IS BELIEVED. A `fail` is a result -- the engine broke
  # a promise -- so it does not invalidate anything; a control that did not hold, a
  # version that changed mid-run or a write into the real config does, and then no number
  # below is safe to read.
  local valid=1
  python3 "$CONN_HERE/validate.py" "$LEAK_RUN" \
    --known-ambient "$LEAK_KNOWN_AMBIENT" || valid=0
  printf '\n%s: %d pass, %d fail, %d not-implemented, %d blocked (controls: %d ok, %d bad)\n' \
    "$CONN_SUITE" "$CONN_PASS" "$CONN_FAIL" "$CONN_TODO" "$CONN_BLOCKED" \
    "$CONN_CTRL_OK" "$CONN_CTRL_BAD"
  printf 'records: %s/records/\n' "$LEAK_RUN"
  ((valid)) || {
    printf 'THIS RUN IS NOT A RESULT -- see the validity gate above.\n' >&2
    return 1
  }
  ((CONN_FAIL == 0))
}
