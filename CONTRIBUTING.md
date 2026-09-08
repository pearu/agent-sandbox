# Contributing

Thank you. A few things make changes here easy to review.

- **Run `scripts/check.sh` before committing.** It runs what CI runs: syntax,
  shellcheck, shfmt (style from `.editorconfig`; fix with `shfmt -w .`), the
  Python components compile, `install.sh` in sync with its sources, the
  installer's dry run, and the bats suites (`tests/run.sh`; `AGENTS.md`
  explains the harness). The development tooling, bats included, comes from
  `environment.yml` (`mamba env create -f environment.yml`). `scripts/coverage.sh`
  reports line coverage: coverage.py (in `environment.yml`) for the addon and
  kcov (a system package, `apt install kcov`) for the engine.
- **`install.sh` is generated.** Edit `install.sh.in` or a file under
  `components/`, then run `scripts/bundle.sh` and commit the result.
- **The engine is security-sensitive.** A change to what the sandbox can see
  or reach (binds, environment, network, CA, SSH, session liveness, refusals)
  comes with a test that fails without it and, where a risk moves, an update to
  the residual-risk list in `docs/design.md`. New capabilities are opt-in.
  Verify claims about tools and proxies empirically; several surprises are
  recorded in `AGENTS.md`.
- **Profiles** are the way to support another agent; the engine should not
  need to know about it. See `docs/profiles.md`.
- **Commits**: one logical change each, an imperative subject, a body that says
  why and what was verified. If an AI agent authored the change, keep its
  `Co-Authored-By` trailer and have a human review the message.
- **Security issues**: please report them privately to the maintainer rather
  than in a public issue.

AI agents maintaining this repository should read `AGENTS.md` first.
