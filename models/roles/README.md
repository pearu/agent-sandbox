# The roles model

Planners, Implementers, Reviewers and a Supervisor, with the user between every pair:
[docs/roles.md](../../docs/roles.md) is the model and how to run it.

    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev

writes this project's `.agent-sandbox` from `agent-sandbox`, a purpose file per instance
from `roles/`, the coord index from `coord/COORDINATION.md`, and a clone per Implementer.
Every "may not" of a role is a line of the dot-file template (enforced by the sandbox)
or a sentence of its purpose file (told), and docs/roles.md section 3 says which.
