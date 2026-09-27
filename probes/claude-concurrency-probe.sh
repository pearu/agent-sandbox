#!/usr/bin/env bash
# claude-concurrency-probe.sh -- how NATIVE Claude Code behaves when two processes share
# one session or one file. Evidence for the instance-storage decision (docs/glossary.md,
# "Instance storage"): what two launches sharing a named store would inherit.
#
#   M1  two concurrent `claude -r U` of one session: how the transcript records both,
#       what a third resume reconstructs, and what the per-session directories do
#   M2  two sessions racing on a memory file, once with Write and once with Edit: does
#       either tool notice the file changed since it was read, and which write survives
#
# Runs the native binary (no sandbox), in a throwaway project directory, with your login.
# Costs a few short Haiku turns. Removes its project directory and its
# ~/.claude/projects/<slug>/ entry at the end; leaves the project entry in ~/.claude.json.
#
#   bash probes/claude-concurrency-probe.sh            # results under $OUT (printed)
#   ONLY=m1 bash probes/claude-concurrency-probe.sh    # M1 alone
#
# THE PROMPT NEVER FOLLOWS --allowedTools. It takes several values, and the first run
# of this probe lost A's prompt to it: A ran with no prompt and wrote nothing, so M1
# measured one resume, not two. M1 now also says INVALID unless A replied A1 and B's
# turn ran inside A's.
set -uo pipefail

native="$(printf '%s\n' "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[[ -x "$native" ]] || {
  echo "no native Claude Code under ~/.local/share/claude/versions" >&2
  exit 2
}
command -v python3 >/dev/null || {
  echo "needs python3" >&2
  exit 2
}
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OUT="${OUT:-$(mktemp -d /tmp/claude-concurrency.XXXXXX)}"
# No dot in the name: Claude Code turns dots into dashes in the transcript directory.
P="$(mktemp -d /tmp/ccprobe-proj-XXXXXX)"
cd "$P" || exit 2
C=("$native" --model haiku)
echo "native: $native ($("$native" --version 2>/dev/null))"
echo "project: $P"
echo "results: $OUT"

# The transcript directory Claude Code derives from the project path. Found rather
# than computed, after the first turn creates it.
slugdir() {
  local d
  for d in "$CFG"/projects/*"$(basename "$P")"; do [[ -d "$d" ]] && printf '%s' "$d" && return 0; done
  return 1
}

# Summarise a transcript: one line per entry -- type, short uuid, short parent, text.
chain() {
  python3 - "$1" <<'PY'
import json, sys
for n, line in enumerate(open(sys.argv[1]), 1):
    try: e = json.loads(line)
    except Exception: print(f"{n:3} <unparsable>"); continue
    t = e.get("type", "?")
    u = (e.get("uuid") or "")[:8]; p = (e.get("parentUuid") or "-")[:8]
    m = e.get("message") or {}
    c = m.get("content") if isinstance(m, dict) else None
    txt = ""
    if isinstance(c, str): txt = c
    elif isinstance(c, list):
        for x in c:
            if isinstance(x, dict):
                txt += x.get("text") or (("tool_use:" + x.get("name", "")) if x.get("type") == "tool_use" else "") \
                       or ("tool_result" if x.get("type") == "tool_result" else "")
    print(f"{n:3} {t:10} uuid={u:8} parent={p:8} {txt[:70]!r}")
PY
}

persession() { # what exists for session $1 in the per-session directories
  local d
  for d in file-history session-env tasks todos plans shell-snapshots; do
    local -a hits=("$CFG/$d/$1"*)
    [[ -e "${hits[0]}" ]] || hits=()
    printf '  %-16s %s\n' "$d/" "${#hits[@]} entries"
  done
}

# ---------------------------------------------------------------------------------
echo
echo "=== M1: two concurrent resumes of one session ==="
U="$(python3 -c 'import uuid; print(uuid.uuid4())')"
"${C[@]}" -p --session-id "$U" "Reply with exactly: A0" >"$OUT/m1-create.txt" 2>&1
echo "create exit=$? reply: $(tr -d '\n' <"$OUT/m1-create.txt")"
SD="$(slugdir)"
T="$SD/$U.jsonl"
[[ -r "$T" ]] || {
  echo "no transcript at $T -- stopping" >&2
  exit 1
}
echo "per-session state after create:"
persession "$U"

# A is resumed first and sleeps inside its turn; B is resumed while A is still running.
(
  date +%s.%N >"$OUT/m1-a.start"
  "${C[@]}" -p --allowedTools 'Bash(python3:*)' -r "$U" \
    "Run this shell command in the foreground and wait for it: python3 -c 'import time; time.sleep(25); print(1)'. Then reply with exactly: A1" >"$OUT/m1-a.txt" 2>&1
  echo "A exit=$?" >>"$OUT/m1-a.txt"
  date +%s.%N >"$OUT/m1-a.end"
) &
pa=$!
sleep 6
bs="$(date +%s.%N)"
"${C[@]}" -p -r "$U" "Reply with exactly: B1" >"$OUT/m1-b.txt" 2>&1
echo "B exit=$? reply: $(head -1 "$OUT/m1-b.txt")"
be="$(date +%s.%N)"
wait "$pa"
echo "A reply: $(head -1 "$OUT/m1-a.txt") ($(tail -1 "$OUT/m1-a.txt"))"
# Verify the verification. What makes this a concurrency measurement is structural: B
# loaded the transcript while A's turn was still being written, so both continue from
# one entry. So: B ran inside A's process lifetime, AND some entry has two children.
# (The first version checked A's reply instead, and Claude Code refused a bare `sleep`
# and backgrounded it -- A replied something else and the check threw away a valid run.)
fork="$(
  python3 - "$T" <<'PY2'
import json, sys, collections
kids = collections.defaultdict(list)
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") in ("user", "assistant", "attachment", "system") and e.get("parentUuid"):
        kids[e["parentUuid"]].append(e.get("uuid", "")[:8])
forks = {p[:8]: c for p, c in kids.items() if len(c) > 1}
print(" ".join(f"{p}->{','.join(c)}" for p, c in forks.items()) or "none")
PY2
)"
echo "entries with two children (forks): $fork"
if ! python3 -c 'import sys; a0, a1, b0, b1 = map(float, sys.argv[1:]); sys.exit(0 if a0 < b0 and b1 < a1 else 1)' \
  "$(cat "$OUT/m1-a.start")" "$(cat "$OUT/m1-a.end")" "$bs" "$be"; then
  echo "M1 INVALID: B did not run inside A's process lifetime"
elif [[ "$fork" == none ]]; then
  echo "M1: B ran inside A's lifetime and the transcript did NOT fork (B continued after A's entries)"
else
  echo "M1 valid: B ran inside A's lifetime, and the conversation forked"
fi
tf=("$SD/$U"*)
echo "transcript files for this session: ${#tf[@]} (${tf[*]##*/})"
echo "--- transcript chain after A and B:"
chain "$T" | tee "$OUT/m1-chain.txt"
cp "$T" "$OUT/m1-transcript.jsonl"

# A third resume: which of A1 and B1 does it see as the conversation?
"${C[@]}" -p -r "$U" \
  "Without using any tools: list, in order, every reply earlier in this conversation that was exactly A0, A1 or B1. Answer with just those tokens separated by spaces." \
  >"$OUT/m1-c.txt" 2>&1
echo "third resume sees: $(head -1 "$OUT/m1-c.txt")"
echo "per-session state at the end:"
persession "$U"

# ---------------------------------------------------------------------------------
if [[ "${ONLY:-}" != m1 ]]; then
  echo
  echo "=== M2: two sessions racing on one memory file ==="
  M="$SD/memory"
  mkdir -p "$M"
  F="$M/MEMORY.md"

  race() { # race TOOL -- two fresh sessions read F, wait, then change it with TOOL
    local tool="$1" who instr
    printf '# index\n- seed\n' >"$F"
    for who in P Q; do
      if [[ "$tool" == Write ]]; then
        instr="use the Write tool to write $F with exactly the content you read, plus one final line: - $who"
      else
        instr="use the Edit tool on $F to replace the line '- seed' with two lines: '- seed' and '- $who'"
      fi
      ("${C[@]}" -p --allowedTools "Read,$tool,Bash(sleep:*)" --output-format stream-json --verbose \
        "Use the Read tool to read $F. Then run the shell command: sleep 20. Then $instr. Do not read the file again before changing it. Finally reply with DONE, or with the exact error text if the tool refused." \
        >"$OUT/m2-$tool-$who.jsonl" 2>&1) &
      sleep 3
    done
    wait
    echo "--- $tool race: file afterwards"
    sed 's/^/    /' "$F"
    for who in P Q; do
      echo "    $who: $(
        python3 - "$OUT/m2-$tool-$who.jsonl" <<'PY'
import json, sys
errs, result = [], ""
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") == "user":
        for x in (e.get("message") or {}).get("content") or []:
            if isinstance(x, dict) and x.get("type") == "tool_result" and x.get("is_error"):
                c = x.get("content"); errs.append(c if isinstance(c, str) else json.dumps(c)[:200])
    if e.get("type") == "result": result = (e.get("result") or "")[:120]
print(f"tool errors: {errs or 'none'} | reply: {result!r}")
PY
      )"
    done
  }
  race Write
  race Edit
fi

# ---------------------------------------------------------------------------------
echo
echo "=== cleanup ==="
# Only ever a directory this run created: named after its own throwaway project.
[[ -n "$SD" && "$SD" == "$CFG/projects/"*"$(basename "$P")" ]] && rm -rf -- "$SD"
rm -rf -- "$P"
echo "removed $P and $SD (results kept in $OUT)"
