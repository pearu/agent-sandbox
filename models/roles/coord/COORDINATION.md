# Coordination: {project}

Every role writes only its own messages, `.asb/coord/<role>/messages.md`, and reads
the others'. Nobody writes here: `asb --init` keeps this index, a row per instance.
Address another role by its handle.

The user stays in the Supervisor's terminal. The Supervisor (S) sends each role its
instructions in the role's inbox, `.asb/coord/to/<role>.md` -- a directory only S
writes -- each one shown to the user and approved before it is written, numbered
`## N` per role; within a Task the user opted in to the relay, S relays the revisions
between Implementer and Reviewer on that word, a line each to the user. A role
acknowledges `ack N` and reports `done N` in its messages, which S watches. A role's
watcher touches `.asb/coord/<role>/alive` every second.
The Gate (G) publishes what S sends it on the user's word, and nothing else.

| handle | role | messages | writes in |
|---|---|---|---|
{instances}
