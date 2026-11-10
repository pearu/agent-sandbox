#!/usr/bin/env python3
"""The `copy` mode's three-way sync, for one channel path.

`copy` seeds a sandbox from a source once and, at every later launch, brings
across what the source changed WITHOUT overwriting what the sandbox did. That is
a three-way comparison and nothing less: source now, the sandbox's copy now, and
a BASE recording what the source held at the last sync. Two of those three are
not enough -- with only source and copy you cannot tell "the sandbox edited this"
from "the source did", and you would either clobber the sandbox's work or freeze
the channel at its seed.

NOTHING IS EVER MERGED TEXTUALLY. These are instruction files, settings and
skills; a three-way text merge on a natural-language instruction file invents
text nobody wrote, and the agent would then follow it. When both sides changed
the sandbox keeps its own and the launch says so, which is the whole of the
conflict policy. Nothing is ever written back to the source either: `copy` is
one-way by definition, and the study's C2 asserts it byte for byte.

The base is a manifest of hashes, not a copy of the files. Restoring never reads
it -- a restore comes from the source -- so its content is dead weight, and the
one thing it must record is what the source looked like, which a hash says.

    sync    --kind file|dir --source S --copy C --base M
    reset   --kind file|dir --source S --copy C --base M
    shadows --source S --upper U --seen M

`sync` prints one `conflict <path>` line per file it refused to overwrite, for
the engine to relay as a warning; the paths are relative for a directory channel
and the channel's own name for a file one. `reset` throws the sandbox's copy away
and re-seeds, which is the supported way back to the source.

`shadows` answers the same question for `copy-on-write`, where the kernel hides
and nothing here copies anything. An overlay's upper layer IS the list of files
the sandbox has written, so the scan is: for each of them, has the source changed
since we first noticed the shadow? That is the one thing the mode hides, and it hides
it loudly -- the source moved on and the sandbox will never see it.
"""

import hashlib
import json
import os
import shutil
import stat
import sys

# The eight states a file can be in, as (source, copy, base) presence and
# equality, and what `copy` does with each. Written out because the matrix is
# the whole design and a reader should not have to re-derive it from branches:
#
#   source == base          the source has not moved: keep the copy, whatever it
#                           is. This is the common case and the reason an edit
#                           inside is never lost.
#   source != base, copy == base
#                           only the source moved: take it. The refresh.
#   source != base, copy != base
#                           both moved: KEEP THE COPY and report a conflict. The
#                           base is deliberately NOT advanced, so the warning
#                           persists at every launch until a reset resolves it.
#                           Warning once would be quieter and would let the one
#                           launch that said so scroll past unseen.
#   source gone, copy == base
#                           the source deleted a file the sandbox never touched:
#                           delete it here too.
#   source gone, copy != base
#                           the source deleted a file the sandbox had changed:
#                           the sandbox keeps its own, and the base entry goes
#                           because there is no longer a source to track.
#   copy gone, base present
#                           THE SANDBOX DELETED IT. Stay deleted: the base entry
#                           is kept precisely so the next launch can tell this
#                           apart from "never seeded" and not resurrect it.
#   nothing in base, source present, copy absent
#                           new upstream, or the first seed: take it.
#   nothing in base, source present, copy present
#                           both created the same path independently: keep the
#                           sandbox's, report a conflict.
#   source absent, base absent
#                           the sandbox's own file. Leave it alone.


# What sha() says of a path that is there but is no regular file: a FIFO, a device, a
# socket, a directory. Never opened -- a FIFO the sandbox made at a tracked name blocked
# the open, and with it the launch, for ever (measured) -- and never equal to a hash.
SPECIAL = "special"


def sha(path):
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):
            return SPECIAL
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    h = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):  # changed since the stat
            return SPECIAL
        with os.fdopen(fd, "rb") as fh:
            fd = None
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
    except OSError:
        return None
    finally:
        if fd is not None:
            os.close(fd)
    return h.hexdigest()


def load_base(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_base(path, base):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(base, fh, sort_keys=True)
    os.replace(tmp, path)


def walk(root):
    """Relative paths of the regular files under root (or [""] for a file)."""
    if os.path.isfile(root):
        return [""]
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            if os.path.isfile(full):
                out.append(os.path.relpath(full, root))
    return out


def at(root, rel):
    return root if rel == "" else os.path.join(root, rel)


def empty(path):
    try:
        return os.path.getsize(path) == 0
    except OSError:
        return False


class InWay(Exception):
    """Something at PATH in the copy store where the sync was to write or remove: KIND
    `link`, a symlink, or `special`, neither a regular file nor (above it) a directory."""

    def __init__(self, path, kind="link"):
        super().__init__(path)
        self.path = path
        self.kind = kind


def _mode(name, dir_fd):
    """NAME's own mode at DIR_FD (a link's, not its target's), or None if absent."""
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False).st_mode
    except FileNotFoundError:
        return None


def _check(name, dir_fd, path, want):
    """InWay unless NAME at DIR_FD is absent or of the type WANT tests for."""
    m = _mode(name, dir_fd)
    if m is None:
        return
    if stat.S_ISLNK(m):
        raise InWay(path)
    if not want(m):
        raise InWay(path, "special")


def _split(copy, rel):
    """(anchor, parent components, name) of REL in the store COPY: the anchor is the
    engine's own directory, every component below it the sandbox's to change."""
    if rel == "":
        return os.path.dirname(copy) or ".", [], os.path.basename(copy)
    parts = rel.split(os.sep)
    return copy, parts[:-1], parts[-1]


def _open_parent(anchor, parts, create):
    """A descriptor of ANCHOR/PARTS..., each component opened without following a
    link (made first when CREATE); InWay names the first one that is a link, or no
    directory.

    THE COPY STORE IS THE SANDBOX'S: it can leave a symlink at any name in it, and a
    host-side write that follows one lands outside the store (a dangling one at an
    upstream file's name made the old copy2 create the file wherever it pointed). So
    no write and no removal here follows a link, at the name or above it."""
    fd = os.open(anchor, os.O_RDONLY | os.O_DIRECTORY)
    path = anchor
    try:
        for part in parts:
            path = os.path.join(path, part)
            if create:
                try:
                    os.mkdir(part, 0o777, dir_fd=fd)
                except FileExistsError:
                    pass
            _check(part, fd, path, stat.S_ISDIR)
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except BaseException:
        os.close(fd)
        raise
    return fd


def copy_file(src, copy, rel):
    """SRC's content, mode and times to REL in the store COPY, in place: the file
    there keeps its inode (a running bind of a file channel sees the change), and
    is opened with O_NOFOLLOW, so a link at its name is refused, never followed; and
    with O_NONBLOCK, so a FIFO there cannot hang it -- anything but a regular file is
    refused before the open, and checked again after it."""
    anchor, parts, name = _split(copy, rel)
    path = os.path.join(anchor, *parts, name)
    fd = _open_parent(anchor, parts, create=True)
    try:
        _check(name, fd, path, stat.S_ISREG)
        st = os.stat(src)
        flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            out = os.open(name, flags, 0o600, dir_fd=fd)
        except OSError:
            _check(name, fd, path, stat.S_ISREG)  # changed between the check and the open
            raise
        try:
            if not stat.S_ISREG(os.fstat(out).st_mode):
                raise InWay(path, "special")
            os.ftruncate(out, 0)
            with open(src, "rb") as fh:
                for chunk in iter(lambda: fh.read(65536), b""):
                    os.write(out, chunk)
            os.fchmod(out, stat.S_IMODE(st.st_mode))
            # The source's mtime, as copy2 kept it: a seeded file looks to the agent
            # exactly as it does natively, and a tool that caches on mtime behaves the
            # same inside.
            os.utime(out, ns=(st.st_atime_ns, st.st_mtime_ns))
        finally:
            os.close(out)
    finally:
        os.close(fd)


def remove(copy, rel):
    """Unlink REL in the store COPY -- never through a link at it or above it
    (InWay) -- and prune the directories it left empty, STRICTLY BELOW the store.

    The bound never used to be enforced -- the comment claimed it and the loop
    climbed until rmdir refused, which meant the channel's own copy directory
    went as soon as it was empty. The engine binds that directory, and for a
    file-shaped channel it then could not even recreate the slot inside it: the
    launch died on a redirection into a directory that had just been pruned away.
    """
    anchor, parts, name = _split(copy, rel)
    try:
        fd = _open_parent(anchor, parts, create=False)
    except FileNotFoundError:
        return
    try:
        m = _mode(name, fd)
        if m is not None and stat.S_ISLNK(m):
            raise InWay(os.path.join(anchor, *parts, name))
        try:
            os.unlink(name, dir_fd=fd)
        except OSError:
            pass
    finally:
        os.close(fd)
    if rel == "":
        return
    root = os.path.abspath(copy)
    d = os.path.dirname(os.path.abspath(at(copy, rel)))
    while d != root and d.startswith(root + os.sep):
        try:
            os.rmdir(d)
        except OSError:
            return
        d = os.path.dirname(d)


def sync(kind, source, copy, base_path):
    """The conflicts (relative paths), and what was in the way: (kind, store path)."""
    base = load_base(base_path)
    conflicts, links = [], []
    if kind == "dir":
        os.makedirs(copy, exist_ok=True)

    rels = set(walk(source)) | set(walk(copy)) | set(base)
    for rel in sorted(rels):
        s = sha(at(source, rel))
        c = sha(at(copy, rel))
        b = base.get(rel)

        if c == SPECIAL:
            links.append(("special", at(copy, rel)))  # never opened, never replaced
            continue
        if s == SPECIAL:
            continue  # yours, and no file to copy
        if s is None and b is None:
            continue  # the sandbox's own file, or nothing at all
        if c is None and b is not None:
            continue  # the sandbox deleted it: stays deleted, base keeps the memory
        if s is None:
            # the source deleted it
            if c == b:
                try:
                    remove(copy, rel)
                except InWay as e:
                    links.append((e.kind, e.path))  # the base entry goes all the same
            base.pop(rel, None)
            continue
        if b is None:
            # Never synced. An EMPTY file here is not content: it is the mount
            # point the engine had to create so a launch could bind the channel
            # at a path the source did not have yet. Measured -- without this,
            # a launch that happened before the source had the file poisoned
            # every later seed, which came out as a conflict on the very first
            # one. Scoped to this branch on purpose: a sandbox that deliberately
            # empties a file it already had is a real edit, and the conflict
            # rules below protect it.
            if c is None or empty(at(copy, rel)):
                try:
                    copy_file(at(source, rel), copy, rel)  # seed, or new upstream
                    base[rel] = s
                except InWay as e:
                    links.append((e.kind, e.path))  # not seeded: the next launch tries again
            else:
                conflicts.append(rel)  # both created it; keep the sandbox's
            continue
        if s == b:
            continue  # the source has not moved; the copy is the sandbox's business
        if c == b:
            try:
                copy_file(at(source, rel), copy, rel)  # refresh
                base[rel] = s
            except InWay as e:
                links.append((e.kind, e.path))  # the base stays: said again next launch
        else:
            # Both moved. Keep the copy, say so, and LEAVE THE BASE where it is
            # so the next launch says so again.
            conflicts.append(rel)

    save_base(base_path, base)
    return conflicts, links


def shadows(source, upper, seen_path):
    """Which of the sandbox's shadowed files has the source changed underneath?

    A shadow is a regular file in the overlay's upper layer. Whiteouts are
    character devices and are skipped: a file the sandbox DELETED is not one it
    is holding a stale version of, and W5 already covers the hiding.

    THE SNAPSHOT IS OF THE WHOLE SOURCE, TAKEN EVERY LAUNCH, not of shadowed
    files when they are first noticed. That was the first version and it was a
    launch too late: a shadow is created DURING a session, so the launch that
    first sees it is already after any source edit the user made in between, and
    recording the source's state then records the changed file as the baseline.
    The warning never fired. Snapshotting every source file at every launch means
    a shadow's baseline is the source as of the previous launch, which is what
    "has your copy changed since" actually needs.
    """
    old = load_base(seen_path)
    seen, conflicts = {}, []
    shadowed = set(walk_regular(upper))
    for rel in sorted(set(walk(source)) | shadowed | set(old)):
        if rel == "":
            continue  # a file-shaped path never gets here: overlays need a directory
        cur = sha(os.path.join(source, rel))
        if rel in shadowed and rel in old and old[rel] != cur:
            # The source moved under a file this sandbox is holding. Keep the OLD
            # hash rather than the current one, so the next launch says it again:
            # the same reasoning as `copy`'s conflicts, and for the same reason --
            # a single line at one launch is a line that scrolls past unseen.
            conflicts.append(rel)
            seen[rel] = old[rel]
        elif cur is not None:
            seen[rel] = cur
    save_base(seen_path, seen)
    return conflicts


def walk_regular(root):
    """Relative paths of the REGULAR files under root: no whiteouts, no dirs."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            # os.path.isfile is False for a character device, which is what an
            # overlay whiteout is, so this filters them without naming them.
            if os.path.isfile(full):
                out.append(os.path.relpath(full, root))
    return out


def reset(kind, source, copy, base_path):
    """Throw the sandbox's copy away and seed again from the source."""
    if kind == "dir":
        shutil.rmtree(copy, ignore_errors=True)
    else:
        try:
            os.unlink(copy)
        except OSError:
            pass
    try:
        os.unlink(base_path)
    except OSError:
        pass
    return sync(kind, source, copy, base_path)


def main(argv):
    if len(argv) < 1 or argv[0] not in ("sync", "reset", "shadows"):
        sys.stderr.write("connect-sync.py sync|reset --kind file|dir "
                         "--source S --copy C --base M\n"
                         "connect-sync.py shadows --source S --upper U --seen M\n")
        return 2
    cmd, opts = argv[0], {}
    i = 1
    while i < len(argv):
        if i + 1 >= len(argv):
            sys.stderr.write("connect-sync.py: %s needs a value\n" % argv[i])
            return 2
        opts[argv[i].lstrip("-")] = argv[i + 1]
        i += 2
    needed = ("source", "upper", "seen") if cmd == "shadows" \
        else ("kind", "source", "copy", "base")
    for need in needed:
        if need not in opts:
            sys.stderr.write("connect-sync.py: missing --%s\n" % need)
            return 2
    if cmd != "shadows" and opts["kind"] not in ("file", "dir"):
        sys.stderr.write("connect-sync.py: --kind is file or dir\n")
        return 2

    links = []
    if cmd == "shadows":
        rels = shadows(opts["source"], opts["upper"], opts["seen"])
        base_name = opts["source"]
    else:
        fn = sync if cmd == "sync" else reset
        rels, links = fn(opts["kind"], opts["source"], opts["copy"], opts["base"])
        base_name = opts["source"]
    for rel in rels:
        # A file channel has one unnamed entry; name it after the source so the
        # warning reads as a path the user recognises.
        sys.stdout.write("conflict %s\n" % (rel or os.path.basename(base_name)))
    for kind, path in links:
        # A symlink, or no regular file, in the sandbox's copy where the sync was to
        # write or remove: not followed, not opened, not replaced; the engine says so.
        sys.stdout.write("%s %s\n" % (kind, path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
