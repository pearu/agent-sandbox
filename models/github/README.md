# The github model

Three kinds of work on a project's GitHub issues and pull requests, one instance per
number, each in a layer of its own over the project as the setup role built it:

    asb --init github --env torch-dev        # once, in your checkout; torch-dev may not exist yet
    asb --trust
    asb --role gh-setup claude               # builds main into torch-dev; again after main moves
    asb --role gh-review-1234 claude         # review pull request 1234
    asb --role gh-triage-5678 claude         # triage issue 5678
    asb --role gh-fix-1234 claude            # implement 1234; it pushes over HTTPS on your word
    asb --delete --role gh-review-1234       # when its work is done

- **gh-setup**, one per project, builds `main` as checked out into the `--env`
  environment, from the project's CI and documentation, and records why in
  `.asb/setup.md` and how in `.asb/build_env.sh` (`setup`, the full build; `rebuild`,
  the incremental one the other roles run after their change). Last, it checks what
  the other roles will need -- a current `gh`, the fixers' push path, ghstack's lines,
  the GPU's `/dev/nvidia-uvm` -- fixes what it can, and records the rest, with the
  command you run on the host, under `## Readiness` in `.asb/setup.md`, which every
  role reads at its start. It writes the checkout
  and the environment, reads the web with GET only, and has no git transport and no gh
  login. Submodules are yours: it cannot fetch, so `git submodule update --init
  --recursive` on the host first -- or `asb --apply '[net:gh-setup]' 'git = fetch'`,
  and it fetches them over HTTPS itself, a read; a push stays refused. Dependencies CI builds from git or fetches from a
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
  say so: over HTTPS, as you, with your gh login (`[net:gh-fix-*] git = allow` and
  `gh = read-only`, both in the file you approve), to your fork or directly as the
  checkout's remotes say -- to the remote's HTTPS URL whatever its scheme, saying so
  once when `origin` is SSH. SSH is for ghstack, which pushes through `origin` as it is:
  where the project uses it, ghstack's login and, for an SSH `origin`, SSH are opt-in
  per project, `asb --apply '[connect:gh-fix-*]' '~/.ghstackrc = read-only'` and
  `asb --apply '[ssh:gh-fix-*]' github.com` (or `--ssh github.com` for one launch),
  reviewed and approved like any other line.

Each sees the project and its environment through overlays of its own
(`project = copy-on-write`): its checkout, incremental rebuild, commits and installs stay
in its layer, and no instance sees another's. Review and triage cannot push -- their
`[net] git = fetch` refuses a push over HTTPS, and they get no SSH host (an `--ssh` you
give one is honoured, push included: `[net] git` does not reach into SSH) -- and every
post is on your word, after the project's policy on AI-written contributions. The
sections are appended once to an
existing `.agent-sandbox` (`[...:gh-*]`); add a `[...:gh-fix-1234]` section only for a
number that needs something specific. Any `gh-<other>-N` name is admitted with the
shared boundary and no purpose.

Before deleting a fixer, publish its work: its commits live in its layer. After `main`
moves (a pull on the host, then `asb --role gh-setup claude` again), an instance
re-syncs its layer at its next launch -- a fixer rebases its branch, a reviewer
re-applies the diff; nothing is deleted or reset. After a rewrite of `main`'s history on
the host, an instance's branch keeps its old base only as long as the host's reflog
keeps it (30 days by default, `gc.reflogExpireUnreachable`), so launch or publish each
unpublished fixer within that window. Shut down the instances running at the time before
the pull (`asb --role R --shutdown claude`; an instance that exited is still running for
its keeper's two-second grace): a lower tree changing under a mounted overlay is
undefined. Launch from the shell you build in: an instance's `PATH` is that shell's, and
a build that cannot find its compilers reconfigures from scratch. conda's base reaches
`gh-setup` whether or not an env is active in that shell, so it can create the
environment the dot-file names: the host's (`MAMBA_ROOT_PREFIX`, `CONDA_ROOT_PREFIX`, or
`conda` on PATH), or under `[conda] base = sandbox` agent-sandbox's own, whose command
is `micromamba` and whose environments are under
`~/.local/share/agent-sandbox/conda/envs`.
