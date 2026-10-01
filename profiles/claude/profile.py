"""The claude profile's file formats: what profile.sh needs read or written in Claude
Code's own JSON, one subcommand each.

    profile.py config-view SOURCE VIEW --project DIR
    profile.py history-view SOURCE VIEW --project DIR
    profile.py trust-recorded FILE --project DIR
    profile.py mark-trust FILE --project DIR
    profile.py merge-settings --ours JSON --user VALUE --out FILE

Beside profile.sh, which keeps the hooks. Each subcommand does one thing and exits
nonzero, saying why on stderr, when it cannot; what a launch then does -- refuse, or
keep the user's own settings -- is the hook's.
"""

import json
import os
import sys


def _load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def config_view(source, view, project):
    """The config file a seeding mode reads: every top-level key and, of the
    per-project entries, only PROJECT's. A missing or unreadable SOURCE is an empty
    config, so a seed from it still parses. VIEW is created, never overwritten, 0600."""
    try:
        native = _load_json(source)
    except (OSError, ValueError):
        native = {}
    if not isinstance(native, dict):
        native = {}
    out = {k: v for k, v in native.items() if k != "projects"}
    projects = native.get("projects")
    out["projects"] = (
        {project: projects[project]}
        if isinstance(projects, dict) and project in projects
        else {}
    )
    fd = os.open(view, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    return 0


def history_view(source, view, project):
    """The prompt history a seeding mode reads: the records of PROJECT only.

    MATCH THE FIELD, NOT THE BYTES. This was a fixed-string grep, and `grep -F` matches
    the path ANYWHERE on a line, in any field, at any nesting depth: a record of
    another project reached this one as soon as it quoted or nested the target path
    (leak study row 4, #73). A line that does not parse is dropped, not passed: too few
    lines is the safe direction. A missing SOURCE is an empty history."""
    fd = os.open(view, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        try:
            fh = open(source, encoding="utf-8")
        except OSError:
            return 0
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and rec.get("project") == project:
                    out.write(line if line.endswith("\n") else line + "\n")
    return 0


def trust_recorded(path, project):
    """Exit 0 when the config FILE records PROJECT's workspace trust, else 1."""
    try:
        data = _load_json(path)
    except (OSError, ValueError):
        return 1
    projects = data.get("projects") if isinstance(data, dict) else None
    entry = projects.get(project) if isinstance(projects, dict) else None
    return 0 if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") else 1


def mark_trust(path, project):
    """Record PROJECT's workspace trust in the config FILE, IN PLACE: the file is
    bind-mounted into a running launch, and a rename would leave the launch on the
    old one."""
    try:
        data = _load_json(path)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    projects = data.setdefault("projects", {})
    if not isinstance(projects, dict):
        projects = data["projects"] = {}
    entry = projects.setdefault(project, {})
    if not isinstance(entry, dict):
        entry = projects[project] = {}
    entry["hasTrustDialogAccepted"] = True
    with open(path, "r+", encoding="utf-8") as fh:
        fh.seek(0)
        json.dump(data, fh)
        fh.truncate()
    return 0


def merge_settings(ours, user, out):
    """The user's --settings (a path or inline JSON) with OUR hook entries appended,
    written to OUT.

    There is nothing to resolve: our whole contribution is hook entries, appended per
    event after theirs -- hook entries merge across settings levels, so a per-event
    union is what Claude Code itself does with two sources. Nothing else of theirs is
    read, rewritten or merged. A shape we do not recognise is refused rather than
    coerced (list() of a dict would replace their data with its keys). Prints
    `hooks-disabled` when their settings switch every hook off, so the hook can say
    the briefing will not arrive."""
    try:
        text = user.strip()
        if text.startswith("{"):
            theirs = json.loads(text)
        else:
            theirs = _load_json(os.path.expanduser(text))
        mine = json.loads(ours)
    except (OSError, ValueError) as exc:
        print(f"cannot read --settings: {exc}", file=sys.stderr)
        return 1
    if not isinstance(theirs, dict):
        print("refusing to merge --settings, leaving yours untouched: top level is not an object", file=sys.stderr)
        return 1
    hooks = theirs.get("hooks", {})
    if not isinstance(hooks, dict):
        print("refusing to merge --settings, leaving yours untouched: hooks is not an object", file=sys.stderr)
        return 1
    hooks = dict(hooks)
    for event, entries in mine["hooks"].items():
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            print(f"refusing to merge --settings, leaving yours untouched: hooks.{event} is not an array", file=sys.stderr)
            return 1
        # Order is cosmetic, not precedence: matching hooks run in parallel and these
        # events are context-only. Theirs reads first because it is theirs.
        hooks[event] = existing + entries
    merged = dict(theirs)
    merged["hooks"] = hooks
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, indent=2)
    if merged.get("disableAllHooks"):
        print("hooks-disabled")
    return 0


def _opts(argv, names):
    """`--name VALUE` pairs among ARGV, and the positional rest."""
    opts, rest, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--") and a[2:] in names and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 2
        else:
            rest.append(a)
            i += 1
    return opts, rest


USAGE = __doc__.split("\n\n")[1]


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    opts, rest = _opts(args, {"project", "ours", "user", "out"})
    try:
        if cmd in ("config-view", "history-view") and len(rest) == 2 and "project" in opts:
            fn = config_view if cmd == "config-view" else history_view
            return fn(rest[0], rest[1], opts["project"])
        if cmd in ("trust-recorded", "mark-trust") and len(rest) == 1 and "project" in opts:
            fn = trust_recorded if cmd == "trust-recorded" else mark_trust
            return fn(rest[0], opts["project"])
        if cmd == "merge-settings" and not rest and {"ours", "user", "out"} <= opts.keys():
            return merge_settings(opts["ours"], opts["user"], opts["out"])
    except OSError as exc:
        print(f"{cmd}: {exc}", file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
