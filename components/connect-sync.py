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
    shadows --source S --upper U --seen M

`sync` prints one `conflict <path>` line per file it refused to overwrite, for
the engine to relay as a warning; the paths are relative for a directory channel
and the channel's own name for a file one. The way back to the source is the
engine's `--reset`, which discards the copy and its manifest; the next launch's
`sync` seeds it again.

A SYMBOLIC LINK INSIDE A DIRECTORY SOURCE IS COPIED AS A LINK, never read through, as
`seed-only`'s `cp -a` keeps it: its state is its target, `link:TARGET`, compared like a
hash, and what the store gets is the same link. Read through, a link the role could
make in a source it may write would hand it whatever the link names (measured: a link to
~/secret/s came into the copy as a regular file holding the secret). The source itself,
the path the channel or declaration names, is followed as before: the engine checks the
links on its way. NO COMPONENT INSIDE THE SOURCE IS EVER FOLLOWED either: every
path below it is opened from a descriptor of the source, each directory with O_NOFOLLOW,
so a name whose directory in the source is now a link (or no directory) is simply not
in the source -- not read through it (measured: a directory the role replaced by a link
to ~/secret brought ~/secret/s into the copy). `--follow-links yes`, which the engine
passes only under `--preset native` (parity with no sandbox), keeps the old reading:
every link followed.

`shadows` answers the same question for `copy-on-write`, where the kernel hides
and nothing here copies anything. An overlay's upper layer IS the list of files
the sandbox has written, so the scan is: for each of them, has the source changed
since we first noticed the shadow? That is the one thing the mode hides, and it hides
it loudly -- the source moved on and the sandbox will never see it.
"""

import hashlib
import json
import os
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


# What sha() says of a path that is there but is neither a regular file nor a directory:
# a FIFO, a socket, a device. Never opened -- a FIFO the sandbox made at a tracked name
# blocked the open, and with it the launch, for ever (measured) -- and never equal to a
# hash. A directory is None, no file at all, as it always was: a file the source turned
# into a directory is the source deleting the file (and seeding what is under it), and
# a directory the sandbox made at a tracked file's name is the sandbox deleting it.
SPECIAL = "special"


LINK = "link:"


def link_state(target):
    return LINK + target


def is_link_state(state):
    return isinstance(state, str) and state.startswith(LINK)


# --follow-links yes: read the source as the old sync did, every link followed (the
# engine's `--preset native` only, whose claim is parity with no sandbox).
FOLLOW = False


def _hash_fd(fd):
    """The hash of the regular file open at FD (closed here), or SPECIAL."""
    h = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
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


def _src_parent(source, rel):
    """(descriptor, name) of REL's directory in SOURCE and REL's last name: the source
    itself opened as declared (followed), every directory below it with O_NOFOLLOW;
    None when one of them is a link, or no directory -- REL is then not in the source."""
    parts = rel.split(os.sep)
    try:
        fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return None
    try:
        for part in parts[:-1]:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except OSError:
        os.close(fd)
        return None
    return fd, parts[-1]


def src_state(source, rel):
    """The source's state at REL, read through no link inside the source: a link there
    is its target (link_state), never read; the source itself (REL "") is followed."""
    if FOLLOW:
        return sha(at(source, rel))
    if rel == "":
        return sha(source)
    pn = _src_parent(source, rel)
    if pn is None:
        return None
    fd, name = pn
    try:
        try:
            m = os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode
        except OSError:
            return None
        if stat.S_ISLNK(m):
            return link_state(os.readlink(name, dir_fd=fd))
        if stat.S_ISDIR(m):
            return None
        if not stat.S_ISREG(m):
            return SPECIAL
        try:
            f = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd)
        except OSError:
            return None
        return _hash_fd(f)
    finally:
        os.close(fd)


def src_open(source, rel):
    """A descriptor of the regular file at REL in SOURCE, opened once, through no link
    inside the source (the source itself followed; every link under --follow-links);
    None when there is no regular file there now."""
    try:
        if FOLLOW or rel == "":
            f = os.open(at(source, rel), os.O_RDONLY | os.O_NONBLOCK)
        else:
            pn = _src_parent(source, rel)
            if pn is None:
                return None
            fd, name = pn
            try:
                f = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd)
            finally:
                os.close(fd)
    except OSError:
        return None
    if not stat.S_ISREG(os.fstat(f).st_mode):
        os.close(f)
        return None
    return f


def walk_src(root):
    """Relative paths of the regular files and the symbolic links in the source root
    (or [""] for a file), from descriptors: no link inside it followed or descended."""
    if FOLLOW:
        return walk_follow(root)
    if os.path.isfile(root):
        return [""]
    out = []
    try:
        top = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return out

    def scan(fd, prefix):
        try:
            entries = list(os.scandir(fd))
        except OSError:
            return
        for e in entries:
            rel = prefix + e.name
            try:
                if e.is_symlink() or e.is_file(follow_symlinks=False):
                    out.append(rel)
                elif e.is_dir(follow_symlinks=False):
                    try:
                        sub = os.open(e.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    except OSError:
                        continue
                    try:
                        scan(sub, rel + os.sep)
                    finally:
                        os.close(sub)
            except OSError:
                continue

    try:
        scan(top, "")
    finally:
        os.close(top)
    return out


def walk_follow(root):
    """The old listing (--follow-links): regular files under root, links to files
    followed, links to directories not descended."""
    if os.path.isfile(root):
        return [""]
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            if os.path.isfile(full):
                out.append(os.path.relpath(full, root))
    return out


def sha(path):
    """The state of PATH, every link followed (the source itself, or --follow-links):
    its hash, SPECIAL, or None (no file)."""
    try:
        m = os.stat(path).st_mode
        if stat.S_ISDIR(m):
            return None
        if not stat.S_ISREG(m):
            return SPECIAL
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    return _hash_fd(fd)


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
    """Relative paths of the regular files and the symbolic links under root (or [""]
    for a file); a link to a directory is not descended into, and none is followed."""
    if os.path.isfile(root):
        return [""]
    out = []
    for dirpath, dirs, files in os.walk(root):
        for name in files + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or os.path.isfile(full):
                out.append(os.path.relpath(full, root))
    return out





def at(root, rel):
    return root if rel == "" else os.path.join(root, rel)


class InWay(Exception):
    """Something at PATH in the copy store where the sync was to write or remove: KIND
    `link`, a symlink; `special`, neither a regular file nor a directory; `file`, a
    regular file where the source has a directory; `dir`, a directory where the source
    has a file."""

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
    if want(m):
        return
    if want is stat.S_ISDIR and stat.S_ISREG(m):
        raise InWay(path, "file")
    if want is stat.S_ISREG and stat.S_ISDIR(m):
        raise InWay(path, "dir")
    raise InWay(path, "special")


def _split(copy, rel):
    """(anchor, parent components, name) of REL in the store COPY: the anchor is the
    engine's own directory, every component below it the sandbox's to change."""
    if rel == "":
        return os.path.dirname(copy) or ".", [], os.path.basename(copy)
    parts = rel.split(os.sep)
    return copy, parts[:-1], parts[-1]


def _open_chain(anchor, parts, create):
    """Descriptors of ANCHOR and of ANCHOR/PARTS[:1], [:2], ..., each component opened
    without following a link (made first when CREATE); InWay names the first one that
    is a link, or no directory.

    THE COPY STORE IS THE SANDBOX'S: it can leave a symlink at any name in it, and a
    host-side write that follows one lands outside the store (a dangling one at an
    upstream file's name made the old copy2 create the file wherever it pointed). So
    nothing here -- a read, a write, a removal, a prune -- follows a link, at the name
    or above it."""
    fds = [os.open(anchor, os.O_RDONLY | os.O_DIRECTORY)]
    path = anchor
    try:
        for part in parts:
            path = os.path.join(path, part)
            if create:
                try:
                    os.mkdir(part, 0o777, dir_fd=fds[-1])
                except FileExistsError:
                    pass
            _check(part, fds[-1], path, stat.S_ISDIR)
            fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
    except BaseException:
        for fd in fds:
            os.close(fd)
        raise
    return fds


def _open_parent(anchor, parts, create):
    """The descriptor of ANCHOR/PARTS..., opened as _open_chain opens it."""
    fds = _open_chain(anchor, parts, create)
    for fd in fds[:-1]:
        os.close(fd)
    return fds[-1]


def copy_state(copy, rel):
    """(STATE, SIZE) of REL in the store COPY, read through no link: STATE is the hash
    of a regular file there; None when there is none (nothing, a directory, or a file
    above it where a directory would be); an InWay, never raised, for a link at it or
    above it, or for what is neither a file nor a directory -- never read, so a link to
    a huge file is not read either, and a FIFO cannot hang the launch."""
    anchor, parts, name = _split(copy, rel)
    path = os.path.join(anchor, *parts, name)
    try:
        fd = _open_parent(anchor, parts, create=False)
    except InWay as e:
        return (e if e.kind == "link" else None), 0
    except OSError:
        return None, 0
    try:
        m = _mode(name, fd)
        if m is None or stat.S_ISDIR(m):
            return None, 0
        if stat.S_ISLNK(m):
            # a link here is a state like a file's, its target, never followed: one this
            # sync made from the source's, or the sandbox's own
            return link_state(os.readlink(name, dir_fd=fd)), 0
        if not stat.S_ISREG(m):
            return InWay(path, "special"), 0
        try:
            f = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd)
        except OSError:
            return None, 0
        h = hashlib.sha256()
        with os.fdopen(f, "rb") as fh:
            st = os.fstat(fh.fileno())
            if not stat.S_ISREG(st.st_mode):  # changed since the check
                return InWay(path, "special"), 0
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest(), st.st_size
    finally:
        os.close(fd)


def copy_file(src_fd, copy, rel):
    """SRC's content, mode and times to REL in the store COPY, in place: the file
    there keeps its inode (a running bind of a file channel sees the change), and
    is opened with O_NOFOLLOW, so a link at its name is refused, never followed; and
    with O_NONBLOCK, so a FIFO there cannot hang it -- anything but a regular file is
    refused before the open, and checked again after it. The source is SRC_FD, opened
    once (src_open) and read from that descriptor: the hash of what was copied is
    returned, for the base."""
    anchor, parts, name = _split(copy, rel)
    path = os.path.join(anchor, *parts, name)
    fd = _open_parent(anchor, parts, create=True)
    try:
        m = _mode(name, fd)
        if m is not None and stat.S_ISLNK(m):
            # a link the base says is this sync's (the caller decided): replaced, never
            # written through
            os.unlink(name, dir_fd=fd)
        _check(name, fd, path, stat.S_ISREG)
        st = os.fstat(src_fd)
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
            h = hashlib.sha256()
            while True:
                chunk = os.read(src_fd, 65536)
                if not chunk:
                    break
                h.update(chunk)
                view = memoryview(chunk)
                while view:  # os.write may write less than it was given
                    view = view[os.write(out, view):]
            os.fchmod(out, stat.S_IMODE(st.st_mode))
            # The source's mtime, as copy2 kept it: a seeded file looks to the agent
            # exactly as it does natively, and a tool that caches on mtime behaves the
            # same inside.
            os.utime(out, ns=(st.st_atime_ns, st.st_mtime_ns))
        finally:
            os.close(out)
    finally:
        os.close(fd)
    return h.hexdigest()


def copy_link(target, copy, rel):
    """A symbolic link to TARGET at REL in the store COPY, as the source has it: what is
    at that name (a file or a link the caller decided is this sync's) replaced, never
    followed; a directory there is in the way (InWay)."""
    anchor, parts, name = _split(copy, rel)
    path = os.path.join(anchor, *parts, name)
    fd = _open_parent(anchor, parts, create=True)
    try:
        m = _mode(name, fd)
        if m is not None:
            if stat.S_ISDIR(m):
                raise InWay(path, "dir")
            os.unlink(name, dir_fd=fd)
        os.symlink(target, name, dir_fd=fd)
    finally:
        os.close(fd)


def put(source, rel, s, copy):
    """Bring the source's state S at REL into the store COPY: a link as a link, a file
    from one descriptor (src_open). The state now there, for the base, or None when the
    source has no regular file there any more (nothing written)."""
    if is_link_state(s):
        copy_link(s[len(LINK):], copy, rel)
        return s
    f = src_open(source, rel)
    if f is None:
        return None
    try:
        return copy_file(f, copy, rel)
    finally:
        os.close(f)


def remove(copy, rel):
    """Unlink REL in the store COPY -- never through a link at it or above it
    (InWay) -- and prune the directories it left empty, STRICTLY BELOW the store.

    The bound never used to be enforced -- the comment claimed it and the loop
    climbed until rmdir refused, which meant the channel's own copy directory
    went as soon as it was empty. The engine binds that directory, and for a
    file-shaped channel it then could not even recreate the slot inside it: the
    launch died on a redirection into a directory that had just been pruned away.

    The prune goes up the descriptors the removal came down by, each directory removed
    by name from its parent's (rmdir at a descriptor): a parent swapped for a link in
    between cannot have a directory outside the store removed.
    """
    anchor, parts, name = _split(copy, rel)
    try:
        fds = _open_chain(anchor, parts, create=False)
    except FileNotFoundError:
        return
    try:
        # a link at the name is unlinked, never followed: the caller removes only what
        # the base says is this sync's (a link included)
        try:
            os.unlink(name, dir_fd=fds[-1])
        except OSError:
            pass
        # parts[k] is a directory in fds[k]; for a file channel there are none, and the
        # store itself (the anchor of a directory channel) is never among them.
        for k in range(len(parts) - 1, -1, -1):
            try:
                os.rmdir(parts[k], dir_fd=fds[k])
            except OSError:
                break
    finally:
        for fd in fds:
            os.close(fd)


def sync(kind, source, copy, base_path):
    """The conflicts (relative paths), and what was in the way: (kind, store path)."""
    base = load_base(base_path)
    conflicts, links = [], []
    if kind == "dir":
        os.makedirs(copy, exist_ok=True)

    relinked = []
    rels = sorted(set(walk_src(source)) | set(walk(copy)) | set(base))
    src = {rel: src_state(source, rel) for rel in rels}
    # TWO PASSES: what the source deleted first, then what it has. A directory the source
    # turned into a file (or the reverse) is then the old entries removed -- the emptied
    # directory pruned -- before the new one is seeded, in one sync and silently; in one
    # sorted pass the seed came first and found the old directory in its way.
    for deletions in (True, False):
        for rel in rels:
            s = src[rel]
            if (s is None) != deletions:
                continue
            if s == SPECIAL:
                continue  # yours, and no file to copy
            c, csize = copy_state(copy, rel)
            b = base.get(rel)
            if is_link_state(c) and c != b and c != s:
                # a link this sync did not make: the sandbox's, named and never
                # written through, as before links were copied
                c, csize = InWay(at(copy, rel)), 0
            inway = isinstance(c, InWay)

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
                if inway:
                    links.append((c.kind, c.path))  # not seeded: said again next launch
                elif c is None or (csize == 0 and not is_link_state(c)):
                    try:
                        st = put(source, rel, s, copy)  # seed, or new upstream
                        if st is not None:
                            base[rel] = st
                    except InWay as e:
                        links.append((e.kind, e.path))  # not seeded: the next launch tries again
                else:
                    conflicts.append(rel)  # both created it; keep the sandbox's
                continue
            if s == b:
                continue  # the source has not moved; the copy is the sandbox's business
            if c == b:
                try:
                    st = put(source, rel, s, copy)  # refresh
                    if st is not None:
                        if is_link_state(st) and not is_link_state(b):
                            relinked.append(rel)  # a file it copied, now the source's link
                        base[rel] = st
                except InWay as e:
                    links.append((e.kind, e.path))  # the base stays: said again next launch
            elif inway:
                links.append((c.kind, c.path))  # the base stays: said again next launch
            else:
                # Both moved. Keep the copy, say so, and LEAVE THE BASE where it is
                # so the next launch says so again.
                conflicts.append(rel)

    save_base(base_path, base)
    return conflicts, links, relinked


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
    for rel in sorted(set(walk_src(source)) | shadowed | set(old)):
        if rel == "":
            continue  # a file-shaped path never gets here: overlays need a directory
        cur = src_state(source, rel)  # a link: its target, unread; through none
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


def main(argv):
    if len(argv) < 1 or argv[0] not in ("sync", "shadows"):
        sys.stderr.write("connect-sync.py sync --kind file|dir "
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
    global FOLLOW
    FOLLOW = opts.get("follow-links") == "yes"

    links, relinked = [], []
    if cmd == "shadows":
        rels = shadows(opts["source"], opts["upper"], opts["seen"])
        base_name = opts["source"]
    else:
        rels, links, relinked = sync(opts["kind"], opts["source"], opts["copy"], opts["base"])
        base_name = opts["source"]
    for rel in rels:
        # A file channel has one unnamed entry; name it after the source so the
        # warning reads as a path the user recognises.
        sys.stdout.write("conflict %s\n" % (rel or os.path.basename(base_name)))
    for kind, path in links:
        # A symlink, or no regular file, in the sandbox's copy where the sync was to
        # write or remove: not followed, not opened, not replaced; the engine says so.
        sys.stdout.write("%s %s\n" % (kind, path))
    for rel in relinked:
        # a file the copy held as the content of a link, now the link itself
        sys.stdout.write("relinked %s\n" % (rel or os.path.basename(base_name)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
