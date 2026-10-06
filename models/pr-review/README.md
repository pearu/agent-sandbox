# The pr-review model

One reviewer per pull request: `pr-reviewer-<N>` reviews PR N of the project you run it
in, builds and tests it, drafts a review with `/pr-review`, and posts it only when you
tell it to, after checking the project's policy on AI-written comments.

    asb --init pr-review --env torch-dev     # once, in your built checkout
    asb --trust
    asb --role pr-reviewer-1234 claude       # one per PR; the name is the PR
    asb --delete --role pr-reviewer-1234     # when the review is done

Each reviewer sees the project as you built it, through an overlay of its own
(`project = copy-on-write`), and the environment the same way: the PR's checkout, the
incremental rebuild and any reinstall stay in that reviewer's layer. Two reviewers never
see each other's work; your tree and environment are never written. The sections are
appended to an existing `.agent-sandbox` once, for every reviewer (`[...:pr-reviewer-*]`);
add a `[...:pr-reviewer-<N>]` section only for a PR that needs something specific.

Launch from the shell you build in: the reviewer's `PATH` is that shell's, and a build
that cannot find its compilers reconfigures from scratch.
