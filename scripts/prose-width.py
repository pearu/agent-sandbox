#!/usr/bin/env python3
"""Markdown prose width check: no prose line wider than 88 columns (#395).

    scripts/prose-width.py FILE...              every line of each file
    scripts/prose-width.py --base REF [FILE...] only the lines added since REF
                                                (`git diff REF`, the working tree
                                                against REF; tracked *.md files, or
                                                the FILEs named)

Each offending line is printed as `FILE:LINE: N columns`, and the exit status is 1 if
there is one (2 on a usage or git error). Columns are characters, not bytes. The whole
file is always parsed, so a fence opened above a hunk still counts.

Exempt, as the re-flow was: lines inside fenced code blocks (``` or ~~~) and indented
code blocks, table rows (`|`-led), headings (`#`), link reference definitions, HTML
blocks and comments, and a line whose overflow is one unbreakable token: a URL or an
inline code span whose word (the run between breakable spaces, spaces inside a code
span not breakable) is wider than the room after the line's text indent -- the line
would still be over the width if broken at every space outside that token. Stdlib only.
"""

import re
import subprocess
import sys

WIDTH = 88

FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
HEADING = re.compile(r"^ {0,3}#{1,6}(\s|$)")
LINK_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*\S")
HTML_COMMENT = re.compile(r"^ {0,3}<!--")
HTML_START = re.compile(r"^ {0,3}(</?[A-Za-z][A-Za-z0-9-]*(\s|/?>|$)|<![A-Za-z]|<\?)")
# the text indent: blockquote markers, then a list marker, then the text
PREFIX = re.compile(r"^((?:\s*>)*)(\s*)((?:[-*+]|\d{1,9}[.)])\s+)?")
LIST_ITEM = re.compile(r"^(\s*)([-*+]|\d{1,9}[.)])(\s+)\S")
# a URL: an absolute one, an autolink, or a Markdown link's target (`](path#anchor)`)
URL = re.compile(r"(?:https?|ftp)://|<[A-Za-z][A-Za-z0-9+.-]*:|\]\(")


def indent_of(line):
    return len(line.expandtabs(4)) - len(line.expandtabs(4).lstrip(" "))


def words(text):
    """Split at spaces outside inline code spans: [(word, has_code_span)]."""
    out, cur, code, i = [], [], False, 0
    while i < len(text):
        c = text[i]
        if c == "`":
            j = i
            while j < len(text) and text[j] == "`":
                j += 1
            ticks = text[i:j]
            k = j
            close = -1
            while True:
                k = text.find(ticks, k)
                if k < 0:
                    break
                end = k + len(ticks)
                if (end >= len(text) or text[end] != "`") and text[k - 1] != "`":
                    close = k
                    break
                k = end
                while k < len(text) and text[k] == "`":
                    k += 1
            if close >= 0:
                cur.append(text[i : close + len(ticks)])
                code = True
                i = close + len(ticks)
            else:
                cur.append(ticks)
                i = j
            continue
        if c.isspace():
            if cur:
                out.append(("".join(cur), code))
            cur, code = [], False
        else:
            cur.append(c)
        i += 1
    if cur:
        out.append(("".join(cur), code))
    return out


def one_token_overflow(line):
    """True if a URL or code-span word alone is wider than the room it has."""
    m = PREFIX.match(line)
    room = WIDTH - len(m.group(0).expandtabs(4))
    for word, code in words(line[m.end() :]):
        if (code or URL.search(word)) and len(word) > room:
            return True
    return False


def prose_lines(lines):
    """Yield (lineno, line) for each line that is prose, not an exempt construct."""
    fence = None  # (char, length) of the open fence
    html = None  # "comment" or "block"
    list_indent = 0  # text indent of the innermost list item still open
    prev_blank = True
    prev_code = False  # previous line was an indented code line
    for n, raw in enumerate(lines, 1):
        line = raw.rstrip("\n").rstrip("\r")
        blank = not line.strip()
        if fence:
            m = FENCE.match(line)
            if (
                m
                and m.group(1)[0] == fence[0]
                and len(m.group(1)) >= fence[1]
                and not m.group(2).strip()
            ):
                fence = None
            prev_blank, prev_code = False, False
            continue
        if html:
            if html == "comment":
                if "-->" in line:
                    html = None
            elif blank:
                html = None
            prev_blank, prev_code = blank, False
            continue
        if blank:
            prev_blank = True
            continue
        ind = indent_of(line)
        if ind >= list_indent + 4 and (prev_blank or prev_code):
            prev_blank, prev_code = False, True
            continue
        prev_code = False
        was_blank, prev_blank = prev_blank, False
        m = LIST_ITEM.match(line)
        if m:
            list_indent = len(m.group(1)) + len(m.group(2)) + len(m.group(3))
        elif was_blank and ind < list_indent:
            list_indent = 0
        m = FENCE.match(line)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = (m.group(1)[0], len(m.group(1)))
            continue
        if HTML_COMMENT.match(line):
            html = None if "-->" in line[line.index("<!--") + 4 :] else "comment"
            continue
        if HTML_START.match(line):
            html = "block"
            continue
        stripped = line.lstrip()
        if stripped.startswith("|") or HEADING.match(line) or LINK_DEF.match(line):
            continue
        yield n, line


def too_wide(path, lines, only=None):
    """Print and count the prose lines over WIDTH, restricted to the `only` set."""
    bad = 0
    for n, line in prose_lines(lines):
        if only is not None and n not in only:
            continue
        cols = len(line)
        if cols > WIDTH and not one_token_overflow(line):
            print(f"{path}:{n}: {cols} columns")
            bad += 1
    return bad


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()


def added_lines(base, files):
    """{path: {line numbers added since base}} from `git diff -U0 base`."""
    cmd = ["git", "-c", "core.quotePath=false", "diff", "--relative", "--no-color"]
    cmd += ["--no-ext-diff"]
    cmd += ["-U0", base, "--"] + (files or ["*.md"])
    diff = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if diff.returncode != 0:
        sys.stderr.write(diff.stderr)
        sys.exit(2)
    added, path = {}, None
    for line in diff.stdout.splitlines():
        if line.startswith("+++ "):
            name = line[4:].rstrip("\t")
            path = name[2:] if name.startswith("b/") else None
            if path is not None and not path.endswith(".md"):
                path = None
        elif path and line.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
            start, count = int(m.group(1)), int(m.group(2) or "1")
            added.setdefault(path, set()).update(range(start, start + count))
    return added


def main(argv):
    if argv[:1] == ["--base"]:
        if len(argv) < 2:
            sys.stderr.write(__doc__)
            return 2
        bad = 0
        for path, nums in sorted(added_lines(argv[1], argv[2:]).items()):
            if nums:
                bad += too_wide(path, read(path), nums)
        return 1 if bad else 0
    if not argv or argv[0].startswith("-"):
        sys.stderr.write(__doc__)
        return 2
    bad = sum(too_wide(path, read(path)) for path in argv)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
