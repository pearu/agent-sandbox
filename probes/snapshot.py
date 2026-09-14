#!/usr/bin/env python3
"""State-snapshot instrument for the cross-project leak study.

Subcommands:
  manifest ROOT [ROOT...]   emit a sorted manifest of every path at/under each ROOT
  diff BEFORE AFTER         classify what changed between two manifest files

The manifest is built so a before/after diff detects writes (content-changed),
touches (mtime-only), and reads (atime-changed) WITHOUT the tool perturbing what it
measures: mtime/atime come from lstat (which never changes them) and file content is
hashed through an O_NOATIME descriptor, so hashing does not bump the file's access
time. See docs/cross-project-channels.md (Method -> State snapshots).

Manifest line, TAB-separated, sorted by path:

    TYPE  SIZE  MTIME_NS  ATIME_NS  SHA256  PATH

TYPE is file|link|dir|fifo|sock|dev|other|unreadable. SHA256 is "-" for anything but
a regular file or a symlink; for a symlink it is the hash of the link *target string*
(the link is recorded, never followed), for a file the hash of its content. ATIME_NS
is recorded only for regular files (lstat reads it, O_NOATIME hashing preserves it);
it is 0 for everything else, whose atime the tool would itself perturb by scanning a
directory or reading a symlink.
"""
import hashlib
import os
import stat
import sys

_CHUNK = 1 << 16


def _sha_file(path):
    """sha256 of a regular file's content, read through O_NOATIME so hashing does
    not bump the file's access time. Falls back to a plain read if O_NOATIME is not
    permitted (only the owner may use it). Returns None if the file cannot be read."""
    noatime = getattr(os, "O_NOATIME", 0)
    modes = [os.O_RDONLY | noatime, os.O_RDONLY] if noatime else [os.O_RDONLY]
    for flags in modes:
        try:
            fd = os.open(path, flags)
        except OSError:
            continue  # e.g. O_NOATIME EPERM -> try plain; or unreadable -> give up
        try:
            h = hashlib.sha256()
            while True:
                chunk = os.read(fd, _CHUNK)
                if not chunk:
                    break
                h.update(chunk)
            return h.hexdigest()
        except OSError:
            return None
        finally:
            os.close(fd)
    return None


def _entry(path):
    """One manifest tuple for a path. Uses lstat, so it neither follows a symlink
    nor changes any timestamp."""
    try:
        st = os.lstat(path)
    except OSError:
        return ("unreadable", 0, 0, 0, "-", path)
    mode, mt = st.st_mode, st.st_mtime_ns
    # atime is recorded only for regular files; for dirs/symlinks the tool's own
    # scandir/readlink would bump it, so it is not a trustworthy signal there.
    if stat.S_ISLNK(mode):
        try:
            target = os.readlink(path)  # reads the link value; does not resolve it
        except OSError:
            return ("unreadable", 0, mt, 0, "-", path)
        sha = hashlib.sha256(target.encode("utf-8", "surrogateescape")).hexdigest()
        return ("link", len(target), mt, 0, sha, path)
    if stat.S_ISDIR(mode):
        return ("dir", 0, mt, 0, "-", path)
    if stat.S_ISREG(mode):
        sha = _sha_file(path)
        if sha is None:
            return ("unreadable", st.st_size, mt, 0, "-", path)
        return ("file", st.st_size, mt, st.st_atime_ns, sha, path)
    if stat.S_ISFIFO(mode):
        kind = "fifo"
    elif stat.S_ISSOCK(mode):
        kind = "sock"
    elif stat.S_ISBLK(mode) or stat.S_ISCHR(mode):
        kind = "dev"
    else:
        kind = "other"
    return (kind, 0, mt, 0, "-", path)


def _walk(root):
    """Yield root and every path beneath it, never descending through a symlink.
    Directories are yielded too, so created/deleted dirs show up in a diff."""
    yield root
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                entries = list(it)
        except OSError:
            continue  # unreadable/not-a-dir; already yielded as a path
        for e in entries:
            yield e.path
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
            except OSError:
                pass


def cmd_manifest(roots):
    seen = set()
    rows = []
    for root in roots:
        for p in _walk(root):
            if p in seen:
                continue
            seen.add(p)
            rows.append(_entry(p))
    rows.sort(key=lambda r: r[5])
    w = sys.stdout.write
    for kind, size, mt, at, sha, path in rows:
        w("%s\t%d\t%d\t%d\t%s\t%s\n" % (kind, size, mt, at, sha, path))
    return 0


def _load(path):
    d = {}
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            kind, size, mt, at, sha, p = line.split("\t", 5)
            d[p] = (kind, size, mt, at, sha)
    return d


def cmd_diff(before, after):
    b, a = _load(before), _load(after)
    changes = []
    for p in a.keys() - b.keys():
        changes.append(("created", p))
    for p in b.keys() - a.keys():
        changes.append(("deleted", p))
    for p in a.keys() & b.keys():
        bkind, bsize, bmt, bat, bsha = b[p]
        akind, asize, amt, aat, asha = a[p]
        if (akind, asize, asha) != (bkind, bsize, bsha):
            changes.append(("content", p))
        elif amt != bmt:
            changes.append(("touched", p))
        elif aat != bat:
            changes.append(("atime", p))
    changes.sort(key=lambda c: (c[1], c[0]))
    for status, p in changes:
        sys.stdout.write("%s\t%s\n" % (status, p))
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "manifest":
        return cmd_manifest(argv[2:])
    if len(argv) == 4 and argv[1] == "diff":
        return cmd_diff(argv[2], argv[3])
    sys.stderr.write(
        "usage: snapshot.py manifest ROOT [ROOT...]\n"
        "       snapshot.py diff BEFORE AFTER\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
