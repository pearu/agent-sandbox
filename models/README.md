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
  and a `[briefing:name-*]` with its own `file = PATH` gets `roles/name.md` written there
  once. `[x:default]` keeps the unnamed role admitted once role sections exist. A line
  `#@ clone = TREE GITDIR BRANCH` in a role's section makes a clone of the project per
  instance (`git clone --shared --separate-git-dir=GITDIR . TREE`, on BRANCH), with an
  environment cloned from `--env` at that role's `[conda:...] prefix`. Every path the
  written file declares under `.asb/` is created.
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
