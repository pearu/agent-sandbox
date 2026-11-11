#!/usr/bin/env python3
"""Markdown prose width check: no prose line wider than 88 columns (#395).

    scripts/prose-width.py FILE...              every line of each file
    scripts/prose-width.py --base REF [FILE...] only the lines added since REF
                                                (`git diff REF`, the working tree
                                                against REF, plus untracked files
                                                whole; *.md files, or the FILEs named)

Each offending line is printed as `FILE:LINE: N columns`, and the exit status is 1 if
there is one (2 on a usage or git error). Columns are characters, not bytes; a tab
advances to the next multiple of 4. The whole file is always parsed, so a fence opened
above a hunk still counts.

Exempt, as the re-flow was: lines inside fenced code blocks (``` or ~~~, also inside a
blockquote) and indented code blocks, table rows (`|`-led), headings (`#`), link
reference definitions, HTML blocks and comments (CommonMark's start conditions: a
block-level tag anywhere, another tag only alone on its line), and a line whose overflow
is one unbreakable word: a run with no space outside inline code spans (so a URL, a link
target or a code span with its inner spaces), wider than the room after the line's text
indent, with the text before it and the text after it each fitting in the width and the
text before it not fitting on the paragraph's previous line, so no wrapping would make
the line fit. Stdlib only.
"""

import re
import subprocess
import sys

WIDTH = 88
TAB = 4

# the blockquote markers in front of a line's block structure
QUOTE = re.compile(r"^(?: {0,3}>(?: |\t)?)+")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
HEADING = re.compile(r"^ {0,3}#{1,6}(\s|$)")
LINK_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*\S")
# CommonMark's HTML block starts 1-6, each with its end condition (None: a blank line)
BLOCK_TAGS = (
    "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|"
    "dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|"
    "frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|"
    "menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|"
    "tbody|td|tfoot|th|thead|title|tr|track|ul"
)
HTML_STARTS = [
    (re.compile(r"^ {0,3}<(?:pre|script|style|textarea)(?:\s|>|$)", re.I),
     re.compile(r"</(?:pre|script|style|textarea)>", re.I)),
    (re.compile(r"^ {0,3}<!--"), re.compile(r"-->")),
    (re.compile(r"^ {0,3}<\?"), re.compile(r"\?>")),
    (re.compile(r"^ {0,3}<![A-Za-z]"), re.compile(r">")),
    (re.compile(r"^ {0,3}<!\[CDATA\["), re.compile(r"\]\]>")),
    (re.compile(r"^ {0,3}</?(?:" + BLOCK_TAGS + r")(?:\s|/?>|$)", re.I), None),
]
# start 7: one complete open or closing tag, alone on its line, not inside a paragraph
ATTR = r"""\s+[A-Za-z_:][\w.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?"""
HTML_TAG_LINE = re.compile(
    r"^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*(?:" + ATTR + r")*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)\s*$"
)
# the text indent: blockquote markers, then a list marker, then the text
PREFIX = re.compile(r"^((?:\s*>)*)(\s*)((?:[-*+]|\d{1,9}[.)])\s+)?")
LIST_ITEM = re.compile(r"^(\s*)([-*+]|\d{1,9}[.)])(\s+)\S")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def words(text):
    """Split at spaces outside inline code spans: [(start, end, has_code_span)]."""
    out, start, code, i = [], None, False, 0
    while i < len(text):
        c = text[i]
        if c == "`":
            j = i
            while j < len(text) and text[j] == "`":
                j += 1
            ticks = text[i:j]
            k, close = j, -1
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
            if start is None:
                start = i
            if close >= 0:
                code = True
                i = close + len(ticks)
            else:
                i = j
            continue
        if c.isspace():
            if start is not None:
                out.append((start, i, code))
            start, code = None, False
        elif start is None:
            start = i
        i += 1
    if start is not None:
        out.append((start, len(text), code))
    return out


def one_token_overflow(line, prev=None):
    """True if the line's overflow is one unbreakable word -- a run with no space
    outside code spans, so a URL, a link target or a code span is one too: the word is
    wider than its room, the text before it and the text after it each fit in the
    width, and the text before it would not fit on the previous line of the paragraph
    (`prev`): wrapping cannot make the line fit any better."""
    m = PREFIX.match(line)
    indent = len(m.group(0))
    room = WIDTH - indent
    for start, end, _ in words(line[indent:]):
        if end - start <= room:
            continue
        before = line[: indent + start].rstrip()
        after = line[indent + end :].strip()
        if len(before) > WIDTH or (after and indent + len(after) > WIDTH):
            continue
        lead = line[indent : indent + start].split()
        if lead and prev is not None and len(prev.rstrip()) + 1 + len(lead[0]) <= WIDTH:
            continue  # its first word would have gone on the line above
        return True
    return False


def prose_lines(lines):
    """Yield (lineno, line) for each line that is prose, not an exempt construct; the
    line has its tabs expanded."""
    fence = None  # (char, length) of the open fence
    html_end = False  # the end pattern of the open HTML block (None: a blank line)
    lists = []  # the text indents of the list items still open, innermost last
    prev_blank = True
    prev_code = False  # previous line was an indented code line
    last = None  # (lineno, line) of the last prose line yielded
    for n, raw in enumerate(lines, 1):
        line = raw.rstrip("\n").rstrip("\r").expandtabs(TAB)
        q = QUOTE.match(line)
        body = line[q.end() :] if q else line
        blank = not body.strip()
        if fence:
            m = FENCE.match(body)
            if (
                m
                and m.group(1)[0] == fence[0]
                and len(m.group(1)) >= fence[1]
                and not m.group(2).strip()
            ):
                fence = None
            prev_blank, prev_code = False, False
            continue
        if html_end is not False:
            if html_end is None:
                if blank:
                    html_end = False
            elif html_end.search(body):
                html_end = False
            prev_blank, prev_code = blank, False
            continue
        if blank:
            prev_blank = True
            continue
        ind = indent_of(body)
        list_indent = lists[-1] if lists else 0
        if ind >= list_indent + 4 and (prev_blank or prev_code):
            prev_blank, prev_code = False, True
            continue
        prev_code = False
        was_blank, prev_blank = prev_blank, False
        m = LIST_ITEM.match(body)
        if m:
            while lists and lists[-1] > len(m.group(1)):
                lists.pop()
            lists.append(len(m.group(1)) + len(m.group(2)) + len(m.group(3)))
        elif was_blank:
            while lists and lists[-1] > ind:
                lists.pop()
        m = FENCE.match(body)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = (m.group(1)[0], len(m.group(1)))
            continue
        started = False
        for start, end in HTML_STARTS:
            m = start.match(body)
            if m:
                started = True
                if end is None:
                    html_end = None
                elif not end.search(body, m.end()):
                    html_end = end  # else the block ends on its own first line
                break
        if not started and was_blank and HTML_TAG_LINE.match(body):
            started, html_end = True, None
        if started:
            continue
        stripped = body.lstrip()
        if stripped.startswith("|") or HEADING.match(body) or LINK_DEF.match(body):
            continue
        # the line above, if this one continues its paragraph
        prev = last[1] if last and last[0] == n - 1 and not LIST_ITEM.match(body) else None
        if prev is not None and (prev.endswith("  ") or prev.endswith("\\")):
            prev = None  # a hard break: nothing moves up over it
        last = (n, line)
        yield n, line, prev


def too_wide(path, lines, only=None):
    """Print and count the prose lines over WIDTH, restricted to the `only` set."""
    bad = 0
    for n, line, prev in prose_lines(lines):
        if only is not None and n not in only:
            continue
        cols = len(line)
        if cols > WIDTH and not one_token_overflow(line, prev):
            print(f"{path}:{n}: {cols} columns")
            bad += 1
    return bad


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()


ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def unquote(name):
    """A path as git prints it in a diff header: C-quoted when it has `"`, `\\`, a
    control character (or, without core.quotePath=false, non-ASCII)."""
    if not name.startswith('"'):
        return name
    if len(name) < 2 or not name.endswith('"'):
        raise ValueError(name)
    s, out, i = name[1:-1], bytearray(), 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out += c.encode("utf-8")
            i += 1
        elif s[i + 1 : i + 2] in ESCAPES:
            out.append(ESCAPES[s[i + 1]])
            i += 2
        elif re.match(r"[0-7]{3}", s[i + 1 : i + 4]):
            out.append(int(s[i + 1 : i + 4], 8))
            i += 4
        else:
            raise ValueError(name)
    return out.decode("utf-8")


def git(args):
    r = subprocess.run(["git"] + args, capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(2)
    return r.stdout


def added_lines(base, files):
    """{path: {line numbers added since base}}: `git diff -U0 base`, and every line of
    an untracked file."""
    spec = files or ["*.md"]
    out = git(["-c", "core.quotePath=false", "diff", "--relative", "--no-color",
               "--no-ext-diff", "--no-renames", "-U0", base, "--"] + spec)
    added, path, header = {}, None, False
    for line in out.splitlines():
        if line.startswith("diff --git "):
            path, header = None, True
        elif header and line.startswith("+++ "):
            name = line[4:].rstrip("\t")
            if name != "/dev/null":
                try:
                    name = unquote(name)
                except ValueError:
                    sys.stderr.write(f"prose-width: cannot read the diff header {line!r}\n")
                    sys.exit(2)
                if not name.startswith("b/"):
                    sys.stderr.write(f"prose-width: unexpected diff header {line!r}\n")
                    sys.exit(2)
                path = name[2:] if name.endswith(".md") else None
        elif line.startswith("@@"):
            header = False
            if path:
                m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
                start, count = int(m.group(1)), int(m.group(2) or "1")
                added.setdefault(path, set()).update(range(start, start + count))
    untracked = git(["ls-files", "-z", "--others", "--exclude-standard", "--"] + spec)
    for path in filter(None, untracked.split("\0")):
        if path.endswith(".md"):
            added[path] = set(range(1, len(read(path)) + 1))
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
