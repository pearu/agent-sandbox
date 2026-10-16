# Coordination: {project}

Every role writes only its own messages, `.asb/coord/<role>/messages.md`, and reads
the others'. Nobody writes here: `asb --init` keeps this index, a row per instance.
Address another role by its handle.
The user moves every artefact: a role that writes one says where, in its messages.

| handle | role | messages | writes in |
|---|---|---|---|
{instances}
