# Development models

A model is a set of roles, what each may do, and how they hand work to each other, as
data: `asb --init MODEL [ROLE=N ...] [--env NAME]` writes a project's files from one.
`MODEL` is a directory here or a path to your own.

A model directory holds:

- `agent-sandbox` -- the dot-file template. Its role-suffixed sections declare the
  roles: `[connect:planner-{n}]` a role with numbered instances, `[connect:supervisor]`
  a single one; `[briefing:planner-*]` is written once when the role has any instance.
  Placeholders, inside a role's own sections: `{role}` (`planner-1`), `{n}` (`1`),
  `{handle}` (`P1`; the role's initial, and `S` for a single role -- two roles with one
  initial are refused); anywhere: `{project}` (the directory's name), `{env}` (`--env`),
  `{envpath}` (that environment's prefix). Without `--env`, `[conda]` sections and lines
  naming `{envpath}` are written commented out. A role with no `{n}` sections at all --
  only `[x:name-*]` -- has its instances named at launch (`asb --role name-<anything>`)
  and no handles (so its initial may repeat another's),
  and a `[briefing:name-*]` with its own `file = PATH` gets `roles/name.md` written there. `[x:default]` keeps the unnamed role admitted once role sections exist. A line
  `#@ clone = TREE GITDIR BRANCH` in a role's section makes a clone of the project per
  instance (`git clone --shared --separate-git-dir=GITDIR . TREE`, on BRANCH), with an
  environment cloned from `--env` at that role's `[conda:...] prefix`, and needs the
  project to be a git repository, at its top; a model without one runs in any directory,
  a repository's subdirectory included. A line `#@ setup = ROLE` names the role that
  builds the `--env` environment: `--init` then takes a NAME not built yet, makes its
  prefix as an empty directory (for conda to create into, and for a declaration of it
  to bind), and says to launch ROLE; without one, a missing environment is refused. The
  setup role has no handle and no row in the index, and while the environment is not
  built a `#@ clone` role gets no environment: `--init` says so, and run again once
  ROLE has built it, clones it.
  A line `#@ scope = roles` makes the unsuffixed sections after it the model's common
  block, written once per role pattern of the model instead of unsuffixed --
  `[connect:planner-*]`, `[connect:supervisor]`, the broadest pattern of each role with
  an instance -- each line as the template has it, the block's comments with the first
  copy, before the roles' own sections, so a role's own key wins; a key a role's own
  section of the same header sets is left out of that copy. Put the line before the
  block, and the block before the roles. Nothing the model writes is then unsuffixed, and
  it composes with other models in one `.agent-sandbox`; without the line an unsuffixed
  section is written as it is, once, with a new file, and reaches every role.
  `--init` refuses a model whose role patterns (`name-*`, `name`) meet a role section
  the file already has -- the same pattern, or one glob matching the other (`gh-*` and
  `gh-review-bot`) -- naming both, unless the section is the model's own: the file names
  the model in a `# ---- written by` or `# ---- added by asb --init MODEL ----` line (a
  file without one: it has a section of one of the model's single or launch-named roles).
  `[x:default]` and `[x:*]` are nobody's. Any model's `--init` refuses a file that has a
  scoped model's block unsuffixed -- this model's or a shipped one's -- next to sections
  of that model's roles, as the --init before this wrote it: remove those blocks (or
  start from a fresh file) and run it again.
  `.asb/.gitignore` keeps `.asb/` out of git.
  Every path the written file declares under `.asb/` is created.
- `roles/<role>.md` -- one purpose file per role, written per instance to
  `.asb/roles/<instance>.md` with the same placeholders; `[briefing:<role>]` injects it
  at every start.
- `coord/COORDINATION.md` -- the coord index; `{instances}` becomes a table row per
  instance.
- `README.md` -- what the model is, and which of its "may not"s are enforced.

Run again with more instances, `--init` adds what is missing and touches nothing else
that exists, except a purpose file it wrote and nobody changed since: that one takes the
model's current text (`.asb/init.sums` records what it wrote). The changed
`.agent-sandbox` or purpose file then needs `asb --trust` again.
