#!/usr/bin/env bats
# shellcheck disable=SC2016 # the backticks are Markdown, not command substitution
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
  cd "$R" || return
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

@test "a URL with more prose on either side than fits does not exempt the line" {
  url="https://example.com/$(printf 'segment/%.0s' {1..10})"
  printf '\n%s %s %s\n' "$LONG" "$url" "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): $((98 + 1 + ${#url} + 1 + 98)) columns" ]
}

@test "added content that looks like a diff header does not end the file's hunks" {
  # the line `++ b/x.txt` shows in the diff as `+++ b/x.txt`; the long line is a later
  # hunk of the same file
  sed -i '1a ++ b/x.txt' doc.md
  printf '\n%s\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 98 columns" ]
}

@test "an inline tag leading a line is prose; a block tag, or a tag alone on its line, is HTML" {
  printf '\n<kbd>K</kbd> %s\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 111 columns" ]
  git checkout -q doc.md
  printf '\n<div class="x">\n%s\n</div>\n\n<span>\n%s\n</span>\n' "$LONG" "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
}

@test "a path git quotes in the diff header is unquoted; a git error exits 2" {
  printf '%s\n' "$LONG" >'q"x.md'
  git add 'q"x.md'
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = 'q"x.md:1: 98 columns' ]
  run python3 "$PW" --base no-such-ref
  [ "$status" -eq 2 ]
}

@test "a tab advances to the next multiple of 4 columns" {
  # `a`, a tab to column 4, then 84 characters: 88 columns
  printf '\na\t%s\n' "$(printf 'x%.0s' {1..76}) abcdefg" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  printf 'a\t%s\n' "$(printf 'x%.0s' {1..76}) abcdefgh" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 89 columns" ]
}

@test "a fence inside a blockquote is tracked" {
  printf '\n> ```\n> %s\n> ```\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  printf '\n> %s\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
}

@test "continuation prose of an outer list item after a nested one is prose, not code" {
  printf '\n- a\n  - b\n\n  para\n\n    %s\n' "$LONG" >>doc.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "doc.md:$(wc -l <doc.md): 102 columns" ]
}

@test "an untracked Markdown file is judged whole" {
  printf '%s\n' "$LONG" >new.md
  pw_base
  [ "$status" -eq 1 ]
  [ "$output" = "new.md:1: 98 columns" ]
}

@test "a plain unbreakable word too wide for a line passes on a line of its own" {
  hash="$(printf '0123456789abcdef%.0s' {1..6})"
  printf '\nA short line before it.\n%s\n' "${hash:0:95}" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a long URL line passes after a short untouched line, whose words it never asks to move" {
  # the base ends with the short line `The end.`; this line continues its paragraph
  [ "$(tail -1 doc.md)" = "The end." ]
  printf 'See https://example.com/%s now.\n' "$(printf 'segment/%.0s' {1..10})" >>doc.md
  pw_base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
