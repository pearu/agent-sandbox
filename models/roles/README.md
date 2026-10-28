# The roles model

Planners, Implementers, Reviewers, a Supervisor that coordinates and a Gate that
publishes, with the user approving every message in the Supervisor's terminal:
[docs/roles.md](../../docs/roles.md) is the model and how to run it.

    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev

writes this project's `.agent-sandbox` from `agent-sandbox`, a purpose file per instance
from `roles/`, the coord index from `coord/COORDINATION.md`, an inbox per role under
`.asb/coord/to/`, the watcher `bin/inbox-wait` as `.asb/bin/inbox-wait`, the prompt a
Planner, Implementer or Reviewer is told at each turn when it runs with no terminal
(`asb --role NAME --serve claude`) from `serve/` as `.asb/serve/<instance>.md`, the
project's test commands from `tests` as `.asb/tests` (an iterating round runs the
affected tests, the Reviewer the whole suite once, at a zero-finding acceptance: fill in
the two lines), and a clone per Implementer.
`x-dev` need not exist yet: `asb --role setup claude` builds `main` into it, and
`--init`, run again then, clones it for each Implementer.
Every "may not" of a role is a line of the dot-file template (enforced by the sandbox)
or a sentence of its purpose file (told), and docs/roles.md section 3 says which.
The Supervisor (`asb --role supervisor claude --continue`) prints at start every other
role's launch line, `asb --role NAME claude --continue`, which starts a role's session
or resumes it, and one line that opens them all, a tmux pane each:
`asb --roles NAME NAME ... claude --continue` (docs/roles.md section 9). It leaves the
Supervisor out, as it is running already; a round with the Supervisor in the top pane,
the first role's, is started from a plain terminal, not from the Supervisor's own:
`asb --roles supervisor planner-1 implementer-1 reviewer-1 gate claude --continue`.
