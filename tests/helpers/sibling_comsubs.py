#!/usr/bin/env python3
"""sibling_comsubs.py FILE -- the simple commands of a bash FILE that hold two or more
command or process substitutions ($(...), <(...), >(...)) side by side (#423).

Bash 5.2 runs a signal's trap handler that arrived during one substitution when it starts
to parse the next substitution of the same simple command, and the handler then fails
("trap: line 2: unexpected EOF while looking for matching `)'"), abandoning the rest of
the script: `v="$(a)$(b)"`, `cmd "$(a)" "$(b)"`, `v="$(a)" w="$(b)"`,
`[[ "$(a)" == "$(b)" ]]`, an array literal with two. Separate commands (`;`, `&&`, `||`,
`|`, a newline) are safe, so is one substitution, and so is a substitution nested in
another (it is parsed in the child, where the handler is not installed).

Prints one line per such command: FIRSTLINE<TAB>LASTLINE<TAB>FUNCTION<TAB>COUNT<TAB>TEXT,
FUNCTION being the enclosing `name() {` or `name() (` definition (`-` at the top level).

What it reads as one command: a line, with backslash continuations joined, a multi-line
array literal (`name=(` or `name+=(` ending a line, up to the line that starts with `)`),
and a `[[ ... ]]` left open at a line's end, up to its `]]`. Split into simple commands
at ; & && || and newlines outside quotes, substitutions and `[[ ... ]]` (where && || and
| are the test's own). Not counted, as the child's: what is inside a substitution, inside
a ( ... ) subshell (`v="$(_as_one "$(a)$(b)")"`, `( cmd "$(a)" "$(b)" )`: #423's forms),
and the elements of a pipeline of two or more. Skipped: single-quoted text, comments,
here-document bodies, `$((...))` and `((...))` (its substitutions are counted).

What it does not see: a double-quoted string, or a substitution, that runs over a
line break without a backslash (the line is read alone); a command built by `eval`.
"""
import re
import sys

FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) *[({]")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
ARRAY_OPEN = re.compile(r"[A-Za-z0-9_\]]\+?=\($")


def strip_comment(text):
    """TEXT without a trailing ` # comment` outside quotes (a rough cut, enough to see
    whether a line ends in an array's open parenthesis)."""
    q = None
    for j, c in enumerate(text):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (j == 0 or text[j - 1] in " \t"):
            return text[:j]
    return text


def count(line):
    """The most substitutions side by side at the top level of one simple command of
    LINE that the shell itself runs: not one inside a ( ... ) subshell or a substitution
    (the child's), nor an element of a pipeline of two or more (each element runs in a
    child: the engine never sets lastpipe)."""
    cmds = [[0, False]]  # per simple command: [count, in a pipeline]
    stack = []  # open substitutions, subshells, arithmetic: [kind, parens]
    q = None  # the quote open at the top level: ' or "
    test = False  # inside [[ ... ]]: ( ) group, they are no subshell
    j = 0
    n = len(line)

    def at_command_start(k):
        """Whether position K starts a command: after nothing, ; & | ( ! or a keyword."""
        before = line[:k].rstrip()
        if not before or before[-1] in ";&|(!{":
            return True
        word = re.split(r"[\s;&|(]", before)[-1]
        return word in ("if", "then", "else", "elif", "do", "while", "until", "time")

    while j < n:
        c = line[j]
        if q == "'":
            if c == "'":
                q = None
            j += 1
            continue
        if c == "\\":
            j += 2
            continue
        if not stack and q is None and c == "#" and (j == 0 or line[j - 1] in " \t;"):
            break
        if not stack and c == "'" and q is None:
            q = "'"
            j += 1
            continue
        if not stack and c == '"':
            q = None if q == '"' else '"'
            j += 1
            continue
        if not stack and q is None and line.startswith("[[", j) and at_command_start(j):
            test = True
            j += 2
            continue
        if not stack and q is None and test and line.startswith("]]", j):
            test = False
            j += 2
            continue
        if line.startswith("$((", j):
            stack.append(["a", 0])
            j += 3
            continue
        if line.startswith("$(", j) or (q is None and line[j:j + 2] in ("<(", ">(")):
            if all(k == "a" for k, _ in stack):
                cmds[-1][0] += 1
            stack.append(["s", 0])
            j += 2
            continue
        if not stack and q is None and line.startswith("((", j) and at_command_start(j):
            stack.append(["a", 0])
            j += 2
            continue
        if not stack and q is None and c == "(" and not test and at_command_start(j):
            stack.append(["p", 0])  # a subshell: its contents are the child's
            j += 1
            continue
        if stack and c == "(":
            stack[-1][1] += 1
        elif stack and c == ")":
            if stack[-1][1]:
                stack[-1][1] -= 1
            else:
                kind = stack.pop()[0]
                if kind == "a" and line[j + 1:j + 2] == ")":
                    j += 1
        elif not stack and q is None and not test and c == "|" and line[j + 1:j + 2] != "|" and line[j - 1:j] != "|":
            cmds[-1][1] = True
            cmds.append([0, True])
            if line[j + 1:j + 2] == "&":
                j += 1
        elif not stack and q is None and not test and c in ";|&":
            if line.startswith("||", j) or line.startswith("&&", j):
                j += 1
            cmds.append([0, False])
        j += 1
    return max((k for k, piped in cmds if not piped), default=0)


def test_open(line):
    """Whether LINE leaves a [[ open: more [[ than ]] at command positions (a rough count,
    outside quotes and comments, as strip_comment cuts)."""
    t = strip_comment(line)
    t = re.sub(r"'[^']*'", "", t)
    return len(re.findall(r"(?:^|[\s;&|(!])\[\[(?=\s)", t)) > len(re.findall(r"(?<=\s)\]\](?=$|[\s;&|)])", t))


def scan(path):
    src = open(path, encoding="utf-8").read().split("\n")
    func = "-"
    heredoc = None
    i = 0
    while i < len(src):
        first = i
        line = src[i]
        i += 1
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        m = FUNC.match(line)
        if m:
            func = m.group(1)
        while i < len(src) and (line.endswith("\\") or test_open(line)):
            line = (line[:-1] if line.endswith("\\") else line) + " " + src[i].lstrip()
            i += 1
        if ARRAY_OPEN.search(strip_comment(line).rstrip()):
            while i < len(src):
                nxt = src[i].strip()
                i += 1
                if nxt.startswith("#"):
                    continue
                line += " " + strip_comment(nxt)
                if nxt.startswith(")"):
                    break
        h = HEREDOC.search(strip_comment(line))
        if h and not line.lstrip().startswith("#"):
            heredoc = h.group(1)
        k = count(line)
        if k >= 2:
            yield first + 1, i, func, k, " ".join(line.split())


def main():
    for first, last, func, k, text in scan(sys.argv[1]):
        print(f"{first}\t{last}\t{func}\t{k}\t{text}")


if __name__ == "__main__":
    main()
