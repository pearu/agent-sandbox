#!/usr/bin/env bats
# The README's "Knobs and flags" table against the engine, both directions:
# nothing the engine offers is undocumented, and nothing documented has gone.
# Stale documentation has bitten this project more than once (a "there is no
# seccomp filter" line outliving seccomp, resolved items left under "open design
# questions"), and this table is the one place that claims to list every setting.
#
# The engine is the source of truth. A knob counts as user-facing when the engine
# READS it as `${AGENT_SANDBOX_...}`; variables the engine SETS for profiles
# (AGENT_SANDBOX_ENGINE, AGENT_SANDBOX_PROFILE) are not settings and never match.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  README="$REPO_ROOT/README.md"
  # the section, and just its table rows (prose mentions --help, which is the
  # agent's flag, not an engine flag)
  SECTION="$(awk '/^## Knobs and flags$/,/^## Documentation$/' "$README")"
  TABLE="$(grep '^|' <<<"$SECTION")"
}

# ---- the engine's side ----
code_flags() { # engine flags, from the argument parser only
  awk '/---- engine flags \(must precede/,/^      \*\) break ;;/' "$ENGINE" \
    | grep -oE '^      --[a-z-]+( \| --[a-z-]+)*\)' | tr -d ' )' | tr '|' '\n' | sort -u
}
code_env() { # variables the engine reads from the environment
  grep -oE '\$\{AGENT_SANDBOX_[A-Z_]+' "$ENGINE" | sed 's/.*{//' | sort -u
}
code_sections() { # supported .agent-sandbox sections
  # The sections the parser ACTS on: arms of the section dispatch (6-space
  # indent, inside _as_dotfile_parse) that have a body. `ssh) ;;` and `*) ;;`
  # have none -- [ssh] is recognised and refused at the header, and the header
  # case also names knob-only sections -- so a bare `;;` arm is not a setting.
  # Read this way the list survives renames and reordering.
  #
  # The profile-named section is invisible here on purpose: its arm is
  # `"$profile")`, whose name is a runtime value, so there is no static list to
  # read. Its keys are checked against the shipping profile instead, in the
  # `[claude]` test below.
  awk '/^_as_dotfile_parse\(\) \{/,/^\}$/' "$ENGINE" \
    | awk '/^      [a-z-]+\)/ {
        arm = $0; sub(/^ +/, "", arm)
        name = arm; sub(/\).*/, "", name)
        rest = arm; sub(/^[a-z-]+\)/, "", rest); gsub(/[ \t]/, "", rest)
        if (rest != ";;") print name
      }' | sort -u
}
code_keys() { # key = value names inside section $1 (minus the section's own arm)
  awk "/^      $1\)\$/,/^        ;;\$/" "$ENGINE" \
    | grep -oE '^\s+[a-z-]+\)' | tr -d ' )' | grep -vxF "$1" | sort -u
}

# Every extraction must find a plausible number of items. Without this a regex
# that stops matching (a reformat, a rename) makes the comparisons run over an
# empty list and the tests pass while checking nothing.
enough() { # enough NAME MIN < items
  local name="$1" min="$2" n
  n=$(grep -c . || true)
  [ "$n" -ge "$min" ] || {
    echo "extraction '$name' found only $n items (expected >= $min): the engine's shape changed and this test is no longer reading it"
    false
  }
}

# ---- the README's side ----
readme_flags() { grep -oE '`--[a-z-]+' <<<"$TABLE" | tr -d '`' | sort -u; }
readme_env() { grep -oE 'AGENT_SANDBOX_[A-Z_]+' <<<"$SECTION" | sort -u; }
# The dot-file column (the third of four) only. Searching a whole row for
# "[section]" gives false passes: the last column carries markdown links, and a
# link label like ([seccomp](components/seccomp/README.md)) satisfies a search
# for [seccomp] while the dot-file column says "no such setting".
readme_dotfile_col() {
  awk -F'|' 'NF >= 6 { print $4 }' <<<"$TABLE"
}

# fail_missing LABEL WHERE < list-of-items-not-found
fail_missing() {
  local label="$1" where="$2" items
  items="$(cat)"
  [ -z "$items" ] || {
    echo "$label not $where:"
    printf '  %s\n' "${items//$'\n'/$'\n'  }"
    false
  }
}

@test "README knobs: every engine flag is in the table, and the table invents none" {
  code_flags | enough code_flags 8
  fail_missing "engine flags" "documented in README's table" < <(
    for f in $(code_flags); do grep -qF -- "\`$f" <<<"$TABLE" || echo "$f"; done
  )
  fail_missing "flags the table documents" "engine flags any more" < <(
    comm -23 <(readme_flags) <(code_flags)
  )
}

@test "README knobs: every environment variable the engine reads is documented, and none is stale" {
  code_env | enough code_env 10
  fail_missing "AGENT_SANDBOX_* the engine reads" "documented in README's knobs section" < <(
    comm -23 <(code_env) <(readme_env)
  )
  fail_missing "AGENT_SANDBOX_* the README documents" "read by the engine" < <(
    comm -13 <(code_env) <(readme_env)
  )
}

@test "README knobs: every .agent-sandbox section and key is in the table" {
  code_sections | enough code_sections 5
  code_keys conda | enough "code_keys conda" 2
  code_keys net | enough "code_keys net" 2
  local col
  col="$(readme_dotfile_col)"
  enough readme_dotfile_col 5 <<<"$col"
  fail_missing ".agent-sandbox sections" "documented in README's dot-file column" < <(
    for s in $(code_sections); do grep -qF -- "[$s]" <<<"$col" || echo "[$s]"; done
  )
  # Every section that takes `key = value` lines, derived rather than listed, so
  # a new one is not silently exempt from the key check.
  local sec key
  fail_missing ".agent-sandbox keys" "documented in README's dot-file column" < <(
    for sec in $(code_sections); do
      for key in $(code_keys "$sec"); do
        grep -qF -- "[$sec] $key" <<<"$col" || echo "[$sec] $key"
      done
    done
  )
}

# The keys of the profile-named section, from the profile that defines them.
# The engine hands the pairs over uninterpreted, so the profile is the source of
# truth for this one section the way the engine is for all the others.
profile_dotfile_keys() {
  awk '/^profile_isolate\(\) \{/,/^\}$/' "$REPO_ROOT/profiles/claude.sh" \
    | grep -oE '^      [a-z-]+\)' | tr -d ' )' | sort -u
}

@test "README knobs: every [claude] key the profile reads is in the table" {
  # This section cannot be derived from the engine (see code_sections), so
  # without this test a new [claude] key would be exempt from the drift check
  # that covers every other setting.
  profile_dotfile_keys | enough profile_dotfile_keys 1
  local col key
  col="$(readme_dotfile_col)"
  fail_missing "[claude] keys" "documented in README's dot-file column" < <(
    for key in $(profile_dotfile_keys); do
      grep -qF -- "[claude] $key" <<<"$col" || echo "[claude] $key"
    done
  )
  # and in the two places that explain a section rather than list it: config.md
  # writes a key as `key = ...` in prose, the example file as a commented line.
  fail_missing "[claude] keys" "explained in docs/config.md" < <(
    for key in $(profile_dotfile_keys); do
      grep -qF -- "\`$key = " "$REPO_ROOT/docs/config.md" || echo "$key"
    done
  )
  fail_missing "[claude] keys" "shown in docs/agent-sandbox.example" < <(
    for key in $(profile_dotfile_keys); do
      grep -qE "^#$key = " "$REPO_ROOT/docs/agent-sandbox.example" || echo "$key"
    done
  )
}

@test "README knobs: the table is well formed (four columns, a row per setting)" {
  local rows body
  rows=$(wc -l <<<"$TABLE")
  [ "$rows" -ge 10 ] # header + separator + the settings
  # every row has exactly four cells; an escaped \| inside a cell is not a divider
  body=$(awk -F'|' 'NF != 6 {print NR": "$0}' <<<"${TABLE//\\|/}")
  [ -z "$body" ] || {
    echo "rows without four cells:"
    echo "$body"
    false
  }
}

@test "seccomp default: the engine, its --help, and every shipped doc agree it is on" {
  # F3: five docs (plus two install.sh messages the reviewer missed) had drifted
  # to "opt-in / off by default" after #28 flipped it on. This pins all three
  # sources to each other so they cannot part again silently.

  # the code default, from the parameter expansion the engine actually uses
  local code_default
  code_default="$(grep -oE '_knob_seccomp:-[a-z]+' "$ENGINE" | head -1 | sed 's/.*:-//')"
  [ "$code_default" = on ]

  # the engine's own --help must state the same default
  grep -qE 'AGENT_SANDBOX_SECCOMP=on\|off .*default: on\)' "$ENGINE"
  run ! grep -qE 'AGENT_SANDBOX_SECCOMP.*default: off' "$ENGINE"

  # no shipped doc may call it opt-in or off-by-default (unrelated "port opt-ins"
  # is fine; these patterns are seccomp-scoped)
  local f
  for f in "$REPO_ROOT/README.md" "$REPO_ROOT/docs/design.md" \
    "$REPO_ROOT/components/seccomp/README.md" "$REPO_ROOT/install.sh"; do
    run ! grep -qiE 'seccomp[^.]{0,40}(opt-in|off by default)' "$f"
    run ! grep -qiE '(opt-in|off by default)[^.]{0,40}seccomp' "$f"
  done
  # the component README title specifically (it said "(opt-in)")
  run ! grep -qi 'default-deny syscall filter (opt-in)' "$REPO_ROOT/components/seccomp/README.md"
}
