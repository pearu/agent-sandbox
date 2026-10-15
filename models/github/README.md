# The github model

Three kinds of work on a project's GitHub issues and pull requests, one instance per
number, each in a layer of its own over the project as the setup role built it:

    asb --init github --env torch-dev        # once, in your checkout; torch-dev may not exist yet
    asb --trust
    asb --role gh-setup claude               # builds main into torch-dev; again after main moves
    asb --role gh-review-1234 claude         # review pull request 1234
    asb --role gh-triage-5678 claude         # triage issue 5678
    asb --ssh github.com --role gh-fix-1234 claude   # implement 1234, able to push
    asb --apply '[ssh:gh-fix-*]' github.com  # ...or let every fixer here push, for good
    asb --delete --role gh-review-1234       # when its work is done

- **gh-setup**, one per project, builds `main` as checked out into the `--env`
  environment, from the project's CI and documentation, and records why in
  `.asb/setup.md` and how in `.asb/build_env.sh` (`setup`, the full build; `rebuild`,
  the incremental one the other roles run after their change). It writes the checkout
  and the environment, reads the web with GET only, and has no git transport and no gh
  login. Submodules are yours: it cannot fetch, so `git submodule update --init
  --recursive` on the host first. Dependencies CI builds from git or fetches from a
  refused host are yours to provide, as a clone under `~/git/<org>/<repo>` declared
  `copy-on-write` under `[connect:gh-*]` (or a host under `[allow:gh-setup]`), approved
  with `--trust`; gh-setup asks for exactly that and installs what it builds from them
  into the environment. `--init` takes an `--env` NAME not built yet (a conda env name,
  made empty under the conda base that applies: the host's, or agent-sandbox's conda root).
- **gh-review** builds and tests a pull request, reviews it with `/pr-review`, and posts
  the review when you say so.
- **gh-triage** reproduces an issue on your build, measures its claims, finds
  duplicates, concludes (confirmed / not reproducible / needs information / duplicate),
  and posts the triage and labels when you say so.
- **gh-fix** implements an issue or a pull request on a branch, and publishes it when you
  say so: over SSH, to your fork or directly as the checkout's remotes say, or with
  `ghstack submit` where the project uses it. SSH is opt-in: `--ssh github.com` for one
  launch, or `asb --apply '[ssh:gh-fix-*]' github.com` for every fixer of the project,
  reviewed and approved like any other line; ghstack's login is opt-in per project too,
  `asb --apply '[connect:gh-fix-*]' '~/.ghstackrc = read-only'`.

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
build that cannot find its compilers reconfigures from scratch. conda's base reaches
`gh-setup` whether or not an env is active in that shell, so it can create the
environment the dot-file names: the host's (`MAMBA_ROOT_PREFIX`, `CONDA_ROOT_PREFIX`, or
`conda` on PATH), or under `[conda] base = sandbox` agent-sandbox's own, whose command is
`micromamba` and whose environments are under `~/.local/share/agent-sandbox/conda/envs`.
