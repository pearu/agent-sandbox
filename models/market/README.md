# The market model

Research for a purchase or a tender, one instance per topic: what is on the market,
what reviews and tests say about it, who sells it at what price -- gathered from the
web, analysed locally, reported with every source.

    mkdir ~/market && cd ~/market
    asb --init market --env analysis          # once; any directory, git or not
    asb --trust
    asb --role market-laptops claude          # research laptops, in ./laptops/
    asb --delete --role market-laptops        # when the topic is done

Each instance reaches **every public website** (`[net] hosts = public`), by any method:
the sites are not known in advance and are many, and many give their data out only to
a search form or an API's POST. The proxy stays in the path: localhost, the LAN and
`[deny]` hosts are refused, and `mode = strict` leaves no route around it. What bounds the reach is what is in it:
`preset = isolated` and no `gh`, SSH or git transport, so nothing of yours is there to
leak or to act with. Its purpose file says it creates no account, logs in nowhere,
orders nothing and submits nothing that commits you without your word -- that is
**told**, not enforced: a page's text could lead it to post a form, and the review of
its work is yours.

The analysis environment (`--env`) is bound copy-on-write: what an instance installs
stays in its layer. Without `--env` the environment's lines are written commented out.
GPUs are off (`[gpu:market-*] mode = off`); set it to `on` if an analysis needs one.
`mode = strict` needs `passt` (`install.sh` installs it).
