# The roles model

Planners, Implementers, Reviewers, a Supervisor that coordinates and a Gate that
publishes, with the user approving every message in the Supervisor's terminal:
[docs/roles.md](../../docs/roles.md) is the model and how to run it.

    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev

writes this project's `.agent-sandbox` from `agent-sandbox`, a purpose file per instance
from `roles/`, the coord index from `coord/COORDINATION.md`, an inbox per role under
`.asb/coord/to/`, the watcher `bin/inbox-wait` as `.asb/bin/inbox-wait`, the prompt a
Planner, Implementer or Reviewer is told at each turn when it runs with no terminal
(`asb --role NAME --serve claude`) from `serve/` as `.asb/serve/<instance>.md`, and a
clone per Implementer.
`x-dev` need not exist yet: `asb --role setup claude` builds `main` into it, and
`--init`, run again then, clones it for each Implementer.
Every "may not" of a role is a line of the dot-file template (enforced by the sandbox)
or a sentence of its purpose file (told), and docs/roles.md section 3 says which.
