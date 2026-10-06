# The github model

Three kinds of work on a project's GitHub issues and pull requests, one instance per
number, each in a layer of its own over the project as you built it:

    asb --init github --env torch-dev        # once, in your built checkout
    asb --trust
    asb --role gh-review-1234 claude         # review pull request 1234
    asb --role gh-triage-5678 claude         # triage issue 5678
    asb --ssh github.com --role gh-fix-1234 claude   # implement 1234, able to push
    asb --delete --role gh-review-1234       # when its work is done

- **gh-review** builds and tests a pull request, reviews it with `/pr-review`, and posts
  the review when you say so.
- **gh-triage** reproduces an issue on your build, measures its claims, finds
  duplicates, concludes (confirmed / not reproducible / needs information / duplicate),
  and posts the triage and labels when you say so.
- **gh-fix** implements an issue or a pull request on a branch, and publishes it when you
  say so: over SSH, to your fork or directly as the checkout's remotes say, or with
  `ghstack submit` where the project uses it.

Each sees the project and its environment through overlays of its own
(`project = copy-on-write`): its checkout, incremental rebuild, commits and installs stay
in its layer, and no instance sees another's. Review and triage cannot push -- their
`[net] git = fetch` refuses a push and `--ssh` -- and every post is on your word, after
the project's policy on AI-written contributions. The sections are appended once to an
existing `.agent-sandbox` (`[...:gh-*]`); add a `[...:gh-fix-1234]` section only for a
number that needs something specific. Any `gh-<other>-N` name is admitted with the
shared boundary and no purpose.

Before deleting a fixer, publish its work: its commits live in its layer. After you
rebuild or move `main`, delete or reset live instances: their layers lie over the old
tree. Launch from the shell you build in: an instance's `PATH` is that shell's, and a
build that cannot find its compilers reconfigures from scratch.
