#!/usr/bin/env python3
"""State-snapshot instrument for the cross-project leak study.

Subcommands:
  manifest [--arm] ROOT...  emit a sorted manifest of every path at/under each ROOT
  diff BEFORE AFTER         classify what changed between two manifest files

--arm makes reads observable, which they are NOT by default. Linux mounts default to
relatime, where (man mount) "access time is only updated if the previous access time
was earlier than or equal to the current modify or change time" -- so a file already
read since it was last written records nothing when read again, and a quiet 'atime'
column means "not read OR read invisibly". Arming sets such a file's atime to its own
mtime, which satisfies that rule, so the next read is recorded. It is one-shot per
file: after that read, atime leads mtime again.

    snapshot.py manifest --arm ROOT... >before   # baseline AND arm, one walk
    <run the session under test>
    snapshot.py manifest ROOT... >after          # plain: O_NOATIME, perturbs nothing
    snapshot.py diff before after                # 'atime' rows = files it read

Arming writes metadata (atime, and ctime as an unavoidable side effect of utime) to
the tree, so it is opt-in and must NOT be used on a run whose purpose is to prove that
tree was left untouched.

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

Performance (measured 2026-09-14, study host): hashing the whole ~/.claude -- 609 MiB
across 5201 files, dominated by a few large session-transcript .jsonl -- took ~1.3 s
cold and ~1.5 s warm (~460 MB/s). That is negligible beside a real `claude` session,
so the tool ALWAYS hashes rather than skipping unchanged files by (size, mtime): the
skip would save ~1 s while trusting mtime, and a content change that preserves or
restores mtime -- exactly the kind of unexpected change this instrument exists to
catch -- would be missed. Scope the roots (e.g. just settings.json + CLAUDE.md) when
a targeted run wants to avoid the large transcripts.
"""
import hashlib
import os
import stat
import sys

_CHUNK = 1 << 16
_SEC = 10**9


def _sha_file(path):
    """(sha256, used_noatime) for a regular file's content, read through O_NOATIME so
    hashing does not bump the file's access time. Falls back to a plain read if
    O_NOATIME is not permitted (only the owner may use it) -- which DOES bump atime,
    hence the second return value. sha is None if the file cannot be read."""
    noatime = getattr(os, "O_NOATIME", 0)
    modes = [(os.O_RDONLY | noatime, True), (os.O_RDONLY, False)] if noatime else [(os.O_RDONLY, False)]
    for flags, is_noatime in modes:
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
            return h.hexdigest(), is_noatime
        except OSError:
            return None, is_noatime
        finally:
            os.close(fd)
    return None, False


def _read_is_already_recorded(st):
    """Whether relatime would record the NEXT read of this file without our help.

    man mount: "Access time is only updated if the previous access time was earlier
    than or equal to the current modify or change time." Compared in whole seconds,
    which is the granularity the kernel uses.

    The documented rule has a third clause -- an atime more than 24 hours stale is
    also refreshed -- deliberately NOT implemented here. It cannot be exercised in a
    test (we can neither wait a day nor set ctime, since any utime sets it to now),
    and skipping a file on an untestable branch would reintroduce exactly the silent
    false negative arming exists to remove. Such a file is armed needlessly instead:
    one extra utime, erring toward detection."""
    at = st.st_atime_ns // _SEC
    return at <= st.st_mtime_ns // _SEC or at <= st.st_ctime_ns // _SEC


def _arm(path, st, noatime_ok, report):
    """Make the next read of a regular file observable, and return the atime to
    record. Sets atime to the file's own mtime: by the rule above that is enough,
    and unlike an epoch timestamp it leaves plausible metadata behind.

    Skipped when the next read is already recorded -- but only if hashing used
    O_NOATIME. The plain-read fallback bumps atime itself, so a file that looked
    skippable a moment ago may no longer be."""
    if noatime_ok and _read_is_already_recorded(st):
        report["skipped"] += 1
        return st.st_atime_ns
    try:
        os.utime(path, ns=(st.st_mtime_ns, st.st_mtime_ns))
    except OSError as e:
        # A file we cannot re-time is a silent false negative later, so it is named.
        report["failed"].append("%s: %s" % (path, e.strerror or e))
        return st.st_atime_ns
    report["armed"] += 1
    return st.st_mtime_ns


def _entry(path, arm=None):
    """One manifest tuple for a path. Uses lstat, so it neither follows a symlink
    nor changes any timestamp. With `arm` (a report dict), regular files are armed
    AFTER being hashed -- the order matters, because the O_NOATIME fallback would
    otherwise undo the arming it had just set up."""
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
        sha, noatime_ok = _sha_file(path)
        at = st.st_atime_ns
        if arm is not None:
            at = _arm(path, st, noatime_ok, arm)
        if sha is None:
            return ("unreadable", st.st_size, mt, 0, "-", path)
        return ("file", st.st_size, mt, at, sha, path)
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


def cmd_manifest(roots, arm=False):
    report = {"armed": 0, "skipped": 0, "failed": []} if arm else None
    seen = set()
    rows = []
    for root in roots:
        for p in _walk(root):
            if p in seen:
                continue
            seen.add(p)
            rows.append(_entry(p, report))
    rows.sort(key=lambda r: r[5])
    w = sys.stdout.write
    for kind, size, mt, at, sha, path in rows:
        w("%s\t%d\t%d\t%d\t%s\t%s\n" % (kind, size, mt, at, sha, path))
    if report is not None:
        e = sys.stderr.write
        e(
            "snapshot: armed %d file(s), skipped %d already-observable, %d could not be armed\n"
            % (report["armed"], report["skipped"], len(report["failed"]))
        )
        # Named, not just counted: a file that could not be armed reads as
        # "not accessed" afterwards whether or not it was accessed.
        for line in report["failed"][:20]:
            e("snapshot:   not armed: %s\n" % line)
        if len(report["failed"]) > 20:
            e("snapshot:   ... and %d more\n" % (len(report["failed"]) - 20))
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
        args = argv[2:]
        arm = "--arm" in args
        roots = [a for a in args if a != "--arm"]
        if roots:
            return cmd_manifest(roots, arm)
    if len(argv) == 4 and argv[1] == "diff":
        return cmd_diff(argv[2], argv[3])
    sys.stderr.write(
        "usage: snapshot.py manifest [--arm] ROOT [ROOT...]\n"
        "       snapshot.py diff BEFORE AFTER\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
