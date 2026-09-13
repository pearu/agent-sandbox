#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Run the e2e installer suite (tests/e2e/install.bats) UNCHANGED, twice on this
# host -- once with the fake agent (tests/helpers/fake-claude.sh, the committed
# fixture) and once with the REAL claude swapped in -- and diff the two, per test.
# Only the agent is swapped; install.bats is never edited.
#
# Two questions, both answered by the diff:
#   1. REPRESENTATIVENESS: where fake and real agree, the fake stands in for real.
#      A test that passes fake but fails real is a representativeness gap.
#   2. BUGS in agent-sandbox: a real-run failure that is NOT just the fake's
#      scripted behaviour (its env/fetch/update probes) may be a real bug the
#      fake was hiding -- worth a look, not just noted as "diverges".
#
# Per-test verdicts:
#   match          fake ok, real ok           -> fake representative here
#   DIVERGES       fake ok, real not ok       -> real differs from the fake
#                                                 (expected for the env/fetch/
#                                                 update probes; a surprise
#                                                 elsewhere = investigate a bug)
#   host-noise     fake not ok, real not ok   -> both fail => environment, not the
#                                                 agent (e.g. agent-sandbox already
#                                                 installed perturbs a launcher test)
#   real-only-pass fake not ok, real ok       -> the fake may under-represent
#   skipped        skipped in either run      -> not compared (see the port note)
#
# HOST only. Needs bwrap + curl; each run installs mitmproxy into a throwaway HOME
# (~1 min) unless AGENT_SANDBOX_E2E_MITMDUMP names an existing mitmdump (set it to
# reuse one and halve the time). The proxy tests need port 8888 free -- stop your
# own service first (systemctl --user stop agent-sandbox-mitmproxy.service) or
# they skip in BOTH runs. The fixture is restored (via git) on exit.
#     ./probes/e2e-real-claude.sh
set -uo pipefail

REPO="$(cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$REPO/tests/helpers/fake-claude.sh"
[ -f "$FIXTURE" ] || {
  echo "fixture not found: $FIXTURE"
  exit 1
}
cd "$REPO" || exit 1

_pick_nat() {
  local d="$HOME/.local/share/claude/versions" v c
  while IFS= read -r v; do
    if [ -x "$d/$v" ] && [ ! -d "$d/$v" ]; then
      echo "$d/$v"
      return 0
    fi
    for c in "$d/$v/claude" "$d/$v/bin/claude"; do
      [ -x "$c" ] && {
        echo "$c"
        return 0
      }
    done
  done < <(find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -rV)
  return 1
}
nat="$(_pick_nat)" || {
  echo "no runnable claude under $HOME/.local/share/claude/versions"
  exit 1
}
command -v bats >/dev/null || {
  echo "bats not found (mamba env update -n agent-sandbox -f environment.yml)"
  exit 1
}
{ command -v bwrap && command -v curl; } >/dev/null || {
  echo "need bwrap and curl on PATH"
  exit 1
}

echo "== fake-vs-real e2e diff =="
echo "   suite:       tests/e2e/install.bats (unchanged, run twice)"
echo "   real claude: $nat"
[ -n "${AGENT_SANDBOX_E2E_MITMDUMP:-}" ] && echo "   reusing mitmdump: $AGENT_SANDBOX_E2E_MITMDUMP"

FAKE_TAP="$(mktemp)"
REAL_TAP="$(mktemp)"
cleanup() {
  git -C "$REPO" checkout -- tests/helpers/fake-claude.sh 2>/dev/null && echo "   restored fake-claude.sh"
  rm -f "$FAKE_TAP" "$REAL_TAP"
}
trap cleanup EXIT INT TERM

echo
echo "== run 1/2: FAKE agent (baseline) =="
AGENT_SANDBOX_E2E=1 bats tests/e2e/install.bats >"$FAKE_TAP" 2>&1
grep -E '^(ok|not ok) ' "$FAKE_TAP" | sed 's/^/   /'

# Swap the agent: replace the fixture with a shim that execs the real binary.
# A timeout guards against real claude blocking on auth/first-run in the
# throwaway HOME (a bounded failure is still a divergence, not a hang).
tmo=""
command -v timeout >/dev/null && tmo="timeout 90"
{
  printf '#!/bin/sh\n'
  printf '# TEMPORARY: swapped in by probes/e2e-real-claude.sh to run the REAL claude.\n'
  printf '# Restore with: git checkout -- tests/helpers/fake-claude.sh\n'
  printf 'exec %s "%s" "$@"\n' "$tmo" "$nat"
} >"$FIXTURE"
chmod +x "$FIXTURE"

echo
echo "== run 2/2: REAL claude (agent swapped) =="
AGENT_SANDBOX_E2E=1 bats tests/e2e/install.bats >"$REAL_TAP" 2>&1
grep -E '^(ok|not ok) ' "$REAL_TAP" | sed 's/^/   /'

echo
echo "== diff (fake vs real, same host) =="
python3 - "$FAKE_TAP" "$REAL_TAP" <<'PY'
import re, sys
def parse(f):
    r = {}
    for line in open(f):
        m = re.match(r'(ok|not ok) (\d+)(.*)', line)
        if not m:
            continue
        st, n, rest = m.group(1), int(m.group(2)), m.group(3)
        skip = '# skip' in rest
        desc = rest.split(' # ')[0].strip()
        r[n] = ('skip' if skip else ('pass' if st == 'ok' else 'fail'), desc)
    return r
fake, real = parse(sys.argv[1]), parse(sys.argv[2])
nums = sorted(set(fake) | set(real))
if not nums:
    print("   no test results parsed -- both runs may have errored; see the TAP above.")
    sys.exit(0)
print("   %-2s %-5s %-5s %-14s %s" % ("#", "fake", "real", "verdict", "test"))
counts = {}
for n in nums:
    fs = fake.get(n, ('none', ''))[0]
    rs = real.get(n, ('none', ''))[0]
    desc = (fake.get(n) or real.get(n))[1]
    if fs == 'skip' or rs == 'skip':
        v = 'skipped'
    elif fs == 'pass' and rs == 'pass':
        v = 'match'
    elif fs == 'pass' and rs == 'fail':
        v = 'DIVERGES'
    elif fs == 'fail' and rs == 'fail':
        v = 'host-noise'
    elif fs == 'fail' and rs == 'pass':
        v = 'real-only-pass'
    else:
        v = '%s/%s' % (fs, rs)
    counts[v] = counts.get(v, 0) + 1
    print("   %-2d %-5s %-5s %-14s %s" % (n, fs, rs, v, desc[:58]))
print()
order = ['match', 'DIVERGES', 'host-noise', 'real-only-pass', 'skipped']
print("   " + "  ".join("%s=%d" % (k, counts[k]) for k in order if counts.get(k))
      + "".join("  %s=%d" % (k, v) for k, v in counts.items() if k not in order))
print()
print("   match       = fake represents real here.")
print("   DIVERGES    = real != fake. Expected for the fake's scripted probes")
print("                 (launcher env/fetch, host-routed update). A DIVERGES on")
print("                 any OTHER test is a representativeness gap AND a candidate")
print("                 agent-sandbox bug the fake was hiding -- investigate it.")
print("   host-noise  = both fail => environment (e.g. agent-sandbox installed),")
print("                 not the agent; ignore for representativeness.")
print("   skipped     = not compared; free port 8888 to run the proxy tests.")
PY
