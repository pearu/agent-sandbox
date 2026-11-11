#!/usr/bin/env bats
# scripts/prose-width.py, the check scripts/check.sh runs on the Markdown a branch adds:
# a prose line over 88 columns fails as FILE:LINE: N columns; code, tables, headings,
# link definitions, HTML and a one-token overflow (a URL or an inline code span too wide
# for the line on its own) are exempt; a line the diff did not add is never judged; and
# columns are characters, not bytes. Each test is a throwaway git repo: a commit on main,
# then the branch's edit, checked with --base main as check.sh does.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  PW="$REPO_ROOT/scripts/prose-width.py"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  cd "$R"
  git init -q -b main
  git config user.name tester
  git config user.email tester@example.invalid
  # 98 columns of prose, eleven words: breakable anywhere
  LONG="$(printf 'abcdefgh %.0s' {1..10})abcdefgh"
  {
    echo "# Title"
    echo
    echo "$LONG"
    echo
    echo '```'
    echo 'a fence opened far above the hunk the branch adds to'
  } >doc.md
  for i in {1..20}; do echo "code line $i" >>doc.md; done
  printf '```\n\nThe end.\n' >>doc.md
  git add doc.md
  git commit -q -m base
  git checkout -q -b topic
}

pw_base() { run python3 "$PW" --base main; }

@test "a long prose line the branch adds fails, as FILE:LINE: N columns" {
  printf '\n%s\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  n="$(wc -l <doc.md)"
  [ "$output" = "doc.md:$n: 98 columns" ]
}

@test "a line of 88 columns passes, 89 fails" {
  printf '\n%s\n' "$(printf 'x%.0s' {1..80}) abcdefg" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  printf '%s\n' "$(printf 'x%.0s' {1..80}) abcdefgh" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 89 columns" ]
}

@test "the long line is exempt in a fence, an indented block, a table, a heading, HTML, a link definition" {
  {
    printf '\n```sh\n%s\n```\n' "$LONG"
    printf '\n~~~\n%s\n~~~\n' "$LONG"
    printf '\n    %s\n' "$LONG"
    printf '\n| a | b |\n|---|---|\n| %s | x |\n' "$LONG"
    printf '\n## %s\n' "$LONG"
    printf '\n<!--\n%s\n-->\n' "$LONG"
    printf '\n<details>\n%s\n</details>\n' "$LONG"
    printf '\n[ref]: https://example.com/%s\n' "${LONG// /-}"
  } >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a line added inside a fence opened above the hunk is exempt" {
  # line 8 is inside the base's fence; -U0 shows the branch's hunk without the opener
  sed -i "8a $LONG" doc.md
  run git diff -U0 main -- doc.md
  [[ "$output" != *'```'* ]]
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a URL or an inline code span too wide for the line on its own is exempt" {
  url="https://example.com/$(printf 'segment/%.0s' {1..10})end"
  code="\`asb --role x --account y --login $(printf 'arg %.0s' {1..14})\`"
  {
    printf '\nSee %s for it.\n' "$url"
    printf '\nRun %s once.\n' "$code"
    printf '\n- the list item says [this](docs/x.md#%s).\n' "$(printf 'anchor-%.0s' {1..10})"
  } >>doc.md
  [ "${#url}" -gt 88 ]
  [ "${#code}" -gt 88 ]
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a URL or a code span that would fit on a line of its own does not exempt the line" {
  {
    printf '\n%s https://example.com/short and more\n' "$LONG"
    printf '\n%s `short code` and more\n' "$LONG"
  } >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$(wc -l <<<"$output")" -eq 2 ]
}

@test "an old long line the diff does not add passes; the whole-file mode reports it" {
  printf '\nA new short line.\n' >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run python3 "$PW" doc.md
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:3: 98 columns" ]
}

@test "columns are characters, not bytes" {
  # 88 characters, 98 bytes: passes; one more character fails, counted as 89
  line="$(printf 'é%.0s' {1..10}) $(printf 'x%.0s' {1..77})"
  [ "$(printf '%s' "$line" | wc -c)" -eq 98 ]
  printf '\n%s\n' "$line" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  printf '%s\n' "${line}ü" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 89 columns" ]
}

@test "only Markdown is judged" {
  printf '%s\n' "$LONG" >notes.txt
  git add notes.txt
  pw_base
  [ "$status" -eq 0 ]
}
