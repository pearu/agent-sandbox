#!/usr/bin/env python3
"""Read-event watcher for the cross-project leak study.

Reports which files a session READ, by watching inotify IN_ACCESS/IN_OPEN over one
or more roots. Complements probes/snapshot.py, which reports what a session WROTE:

    watch-reads.py ROOT... [--out EVENTS.tsv] [--seconds N]

It prints "READY ..." on stdout once every watch is registered, then blocks. Run the
session, then send SIGINT/SIGTERM: the watcher drains what is left, writes the sorted
distinct accessed paths to stdout, and exits. **Wait for READY before starting the
session** -- a read that happens before the watches exist raises nothing at all.

Why inotify rather than atime, or fanotify:
  - atime needs arming (snapshot.py --arm), which writes metadata into the tree, and
    records only one bit per file, one-shot. This perturbs nothing and sees repeats.
  - fanotify would add the accessing PID, but its mount-wide watch wants
    CAP_SYS_ADMIN. inotify needs no privileges.
  - Measured: a HOST-side watch sees reads made INSIDE a bwrap sandbox, through
    read-only binds as well as read-write ones -- the watch follows the inode, not
    the mount.

Three limits, measured rather than assumed:
  - A symlink leaving the watched tree is a BLIND SPOT. Watches cover directories,
    so an open that resolves to an inode outside them raises nothing -- under
    neither the link path nor the target path. Reads through such a link are
    invisible; watch the target's tree as well, or accept the gap knowingly.
  - Watches are per-directory and NOT recursive. Directories created mid-run are
    picked up via IN_CREATE|IN_ISDIR and rescanned immediately, which narrows but
    cannot close the window in which a file is created AND read inside a directory
    before its watch lands.
  - The queue holds one pending event per distinct (wd, mask, name) -- identical
    events coalesce while unread -- so IN_Q_OVERFLOW needs more than
    fs.inotify.max_queued_events DISTINCT files touched before the reader drains.
    Measured on ~/.claude: 5,591 distinct files, 14,602 events draining normally,
    zero overflows even with the reader stalled; the cap here is 16,384, so that
    target has ~3x margin. A large project tree (node_modules) can exceed it. An
    overflow means dropped events and therefore a LOWER BOUND, not an answer, so it
    is reported and the exit status is non-zero rather than silently continuing.

Also from man 7 inotify: coalescing means an application "can't use inotify to
reliably count file events". The set of paths is trustworthy; a tally is not, so
none is reported.
"""
import ctypes
import errno
import os
import select
import signal
import struct
import sys
import time

IN_ACCESS = 0x00000001
IN_OPEN = 0x00000020
IN_CREATE = 0x00000100
IN_MOVED_TO = 0x00000080
IN_IGNORED = 0x00008000
IN_ISDIR = 0x40000000
IN_Q_OVERFLOW = 0x00004000

# IN_CREATE/IN_MOVED_TO are watched only to keep the watch set current; they are
# not reported as accesses.
_WATCH_MASK = IN_ACCESS | IN_OPEN | IN_CREATE | IN_MOVED_TO

_EVENT_HDR = struct.Struct("iIII")

_libc = ctypes.CDLL("libc.so.6", use_errno=True)


class Watcher:
    def __init__(self):
        self.fd = _libc.inotify_init1(0)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.wd_path = {}
        self.failed = []
        self.overflows = 0
        self.accessed = set()
        self.opened = set()

    def add_tree(self, root):
        """Watch root and every directory beneath it. Symlinks are not followed:
        a symlinked directory belongs to whatever tree it really lives in.

        os.walk never yields a directory it cannot read, so without onerror such a
        directory would be neither watched nor reported -- it would simply read as
        "nothing was accessed here"."""
        for dirpath, _dirnames, _files in os.walk(
            root, followlinks=False, onerror=self._walk_error
        ):
            self.add_dir(dirpath)

    def _walk_error(self, exc):
        self.failed.append(
            "%s: %s" % (exc.filename, exc.strerror or exc)
        )

    def add_dir(self, path):
        wd = _libc.inotify_add_watch(self.fd, os.fsencode(path), _WATCH_MASK)
        if wd < 0:
            # Named, not counted: an unwatched directory reads as "nothing here".
            self.failed.append("%s: %s" % (path, os.strerror(ctypes.get_errno())))
            return None
        self.wd_path[wd] = path
        return wd

    def _rescan_new_dir(self, path):
        """A directory can be created, filled and read before its watch lands. Add
        the watch, then walk it, so at least anything still present is covered."""
        self.add_dir(path)
        try:
            for entry in os.scandir(path):
                if entry.is_dir(follow_symlinks=False):
                    self._rescan_new_dir(entry.path)
        except OSError:
            pass

    def drain(self, timeout):
        """Read whatever is queued. Returns False on timeout with nothing read."""
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        try:
            data = os.read(self.fd, 1 << 20)
        except OSError as e:
            if e.errno == errno.EAGAIN:
                return False
            raise
        off = 0
        while off + _EVENT_HDR.size <= len(data):
            wd, mask, _cookie, nlen = _EVENT_HDR.unpack_from(data, off)
            off += _EVENT_HDR.size
            name = data[off : off + nlen].split(b"\0", 1)[0]
            off += nlen
            self._handle(wd, mask, name)
        return True

    def _handle(self, wd, mask, name):
        if mask & IN_Q_OVERFLOW:
            self.overflows += 1
            return
        base = self.wd_path.get(wd)
        if base is None:
            return
        if mask & IN_IGNORED:
            self.wd_path.pop(wd, None)
            return
        path = os.path.join(base, os.fsdecode(name)) if name else base
        if mask & IN_ISDIR:
            if mask & (IN_CREATE | IN_MOVED_TO):
                self._rescan_new_dir(path)
            return  # a directory's own access is scandir noise, not a file read
        if mask & IN_ACCESS:
            self.accessed.add(path)
        if mask & IN_OPEN:
            self.opened.add(path)
        return path

    def close(self):
        os.close(self.fd)


def main(argv):
    roots, out, seconds = [], None, None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            i += 1
            out = argv[i] if i < len(argv) else None
        elif a == "--seconds":
            i += 1
            seconds = float(argv[i]) if i < len(argv) else None
        else:
            roots.append(a)
        i += 1
    if not roots:
        sys.stderr.write(
            "usage: watch-reads.py ROOT [ROOT...] [--out EVENTS.tsv] [--seconds N]\n"
        )
        return 2

    w = Watcher()
    log = open(out, "w", encoding="utf-8") if out else None
    for root in roots:
        w.add_tree(root)

    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_a: stop.append(True))

    # Only now can a read be observed; a harness that starts the session earlier
    # measures nothing and cannot tell that apart from "nothing was read".
    sys.stdout.write("READY watches=%d unwatched=%d\n" % (len(w.wd_path), len(w.failed)))
    sys.stdout.flush()
    for line in w.failed:
        sys.stderr.write("watch-reads: not watched: %s\n" % line)

    t0 = time.time()
    deadline = t0 + seconds if seconds else None
    while not stop:
        timeout = 0.5 if deadline is None else min(0.5, max(0.0, deadline - time.time()))
        if deadline is not None and time.time() >= deadline:
            break
        w.drain(timeout)
    # Drain what is still queued so a signal right after a read does not lose it.
    while w.drain(0.0):
        pass

    if log:
        for p in sorted(w.opened | w.accessed):
            kinds = []
            if p in w.accessed:
                kinds.append("IN_ACCESS")
            if p in w.opened:
                kinds.append("IN_OPEN")
            log.write("%s\t%s\n" % (",".join(kinds), p))
        log.close()

    for p in sorted(w.accessed):
        sys.stdout.write("%s\n" % p)
    sys.stdout.flush()
    sys.stderr.write(
        "watch-reads: %d file(s) read, %d opened, %d unwatched director(ies), "
        "%d overflow(s)\n"
        % (len(w.accessed), len(w.opened), len(w.failed), w.overflows)
    )
    if w.overflows:
        sys.stderr.write(
            "watch-reads: IN_Q_OVERFLOW -- events were DROPPED; this result is a "
            "lower bound, not an answer\n"
        )
    w.close()
    return 1 if w.overflows else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
