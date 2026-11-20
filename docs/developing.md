# Developing agent-sandbox with its own roles

How to set up agent-sandbox's own repository for the [roles model](roles.md): the
development environment the roles work in, and a test account where the full test suite
runs. It was first done on Ubuntu 26.04, with the test account on the same machine.

## Why a test account

The roles work in sandboxes, and a sandbox can't create the user namespaces that real
`bwrap` needs. So agent-sandbox's integration, end-to-end and live suites, which start
bubblewrap themselves, **skip and report success** inside a role: a green
`tests/run.sh integration` there has tested nothing. The unit suite runs, except its
host-only tests (`require_host`, about 120 of them), which skip with their reason.

So the work is split in two:

- **In a role's own sandbox:** lint and the unit tests the change affects. This is the
  `iterate` command of `.asb/tests`.
- **On a dedicated test account, over ssh:** the whole suite (unit and integration, and
  the live suite when you ask for it), run as CI runs it. This is the `final` command.

The test account is an unprivileged user that holds nothing of yours. Its only login is
a dedicated agent login for the live tests. Its ssh key can run one thing: the test
command. The roles decide what code it runs, so anything the account holds is theirs
too.

Names used below:
- `SERVER`: the test machine, or `127.0.0.1` for this one.
- `asb-test`: the account, and the ssh alias for it.
- `ENVDIR`: the account's dev environment, `/home/asb-test/env` here.

## 1. The development environment

On the host, at the top of the repository:

    asb --init roles --env agent-sandbox-dev
    asb --trust

Under agent-sandbox's own conda (`[conda] base = sandbox`), the prefix is in the
project's directory under the conda root:
`<root>/envs/<project>-<hash>/agent-sandbox-dev`.
`--init` makes it empty; the setup role builds it. Launch it with
`asb --role setup claude`, or with `asb --roles`, which opens the setup role first while
the environment isn't built yet.

There's nothing to compile. The engine is bash, plus a small Python addon, and the test
suites run the checkout's own `./agent-sandbox`, so the checkout itself is the build.
The environment provides only the tooling, from `environment.yml`, as CI's
`setup-micromamba` installs it:

    micromamba create -y -p PREFIX -f environment.yml

This takes a few seconds and needs no extra hosts in `.agent-sandbox`; pyseccomp comes
from PyPI through the environment's `pip:` list. kcov (`scripts/coverage.sh`, engine
coverage) isn't on conda-forge. Leave it out unless you need coverage of the engine:
nothing else depends on it.

Smoke test, in the environment:

    AGENT_SANDBOX_CHECK_TESTS=0 scripts/check.sh     # CI's check job: lint, shfmt, ruff, seccomp, bundle sync, dry run
    tests/run.sh unit                                # all unit tests ok; the host-only ones skip

The setup role records this in `.asb/setup.md` and `.asb/build_env.sh`. Since nothing is
compiled, `rebuild` needs to do something only when `environment.yml` changes: a
`micromamba env update -p PREFIX -f environment.yml`. A tool that writes under `~` needs
`XDG_CACHE_HOME=$HOME/.cache` in a sandbox, where `~` is read-only.

## 2. The test account (you, with sudo on SERVER)

**What the machine needs.** Bubblewrap 0.12.0 or newer, with unprivileged user
namespaces allowed for it, and also `passt`, `nftables`, `openssh-server` (with sshd
running), `git` and `python3`. On Ubuntu, `./install.sh` from your own checkout installs
the AppArmor profiles for bwrap and pasta, and `./install.sh --rebuild-bwrap` builds
bubblewrap where the distribution's is older. Its smoke test, "bwrap can create
user+pid namespaces", must pass.

**The account**, with a user systemd that runs without a login (the proxy the live tests
use is a user service):

    sudo useradd --create-home --shell /bin/bash asb-test
    sudo loginctl enable-linger asb-test

**A shell as the account.** `install.sh` refuses to run under sudo and needs the
account's own user manager, so open the shell with the account's `XDG_RUNTIME_DIR`:

    sudo -iu asb-test env XDG_RUNTIME_DIR=/run/user/$(id -u asb-test) bash

`sudo -i` runs a command through the account's login shell, which expands `$` before the
command sees it. For a one-line command with variables, use `sudo -u asb-test -H bash -c
'...'` instead, and `cd ~` first: tools such as pip write temporary files in the current
directory.

**In that shell:** agent-sandbox itself, which the live tests run against (its proxy
service, compiled seccomp filter and micromamba); then the dev environment; then the
agent and its login:

    git clone https://github.com/pearu/agent-sandbox ~/agent-sandbox
    cd ~/agent-sandbox && ./install.sh
    ~/.local/share/agent-sandbox/micromamba/bin/micromamba create -y -p /home/asb-test/env -f ~/agent-sandbox/environment.yml
    ~/agent-sandbox/agent-sandbox --install claude
    ~/.local/state/agent-sandbox/claude/install/current/claude auth login

The account's proxy gets a port of its own: `install.sh` takes the next free one when
yours holds 8888. Log in with a **dedicated** login, never yours, and do it there.
Don't copy a login file from elsewhere: Claude Code rotates its refresh tokens, so a
copied login stops working once either copy refreshes.

**The one command the account's ssh key may run**, `~/bin/asb-run-tests` (mode 755).
Replace `ENVDIR` with the environment's path:

    #!/usr/bin/env bash
    # asb-run-tests KEY SUITE... -- a tar of a checkout on stdin; tests/run.sh SUITE... in it.
    # SUITE: unit, integration, default (both; when none is named) or live (only when named).
    # The forced command of the roles' key: SSH_ORIGINAL_COMMAND holds KEY SUITE...
    set -euo pipefail
    read -r -a words <<<"${SSH_ORIGINAL_COMMAND:-$*}"
    key="${words[0]:-}"
    [[ "$key" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "asb-run-tests: bad key" >&2; exit 2; }
    suites=("${words[@]:1}")
    ((${#suites[@]})) || suites=(default)
    for s in "${suites[@]}"; do
      [[ "$s" =~ ^(unit|integration|default|live)$ ]] || { echo "asb-run-tests: suite '$s' not allowed" >&2; exit 2; }
      [[ "$s" != live ]] || export AGENT_SANDBOX_LIVE=1   # live only when named: it spends the login's usage
    done
    export PATH="ENVDIR/bin:$PATH"
    exec 9>"$HOME/.asb-run-tests.lock"
    flock 9                                   # one run at a time in this account
    d="$HOME/runs/$key"
    rm -rf -- "$d"
    mkdir -p -- "$d"
    tar -xf - -C "$d"
    cd -- "$d"
    exec tests/run.sh "${suites[@]}"

## 3. The key and the alias (you, on your machine)

A key used for nothing else:

    ssh-keygen -t ed25519 -f ~/.ssh/asb-test -N '' -C asb-test

On SERVER, the account's `~/.ssh/authorized_keys` (mode 600, `~/.ssh` 700) gets the
public key, restricted to that command. Write the home as an absolute path: `$HOME` is
not expanded there.

    restrict,command="/home/asb-test/bin/asb-run-tests" ssh-ed25519 AAAA... asb-test

In your `~/.ssh/config`:

    Host asb-test
        HostName SERVER
        User asb-test
        IdentityFile ~/.ssh/asb-test
        IdentitiesOnly yes

Check that the key runs the test command and nothing else. With `SERVER` at 127.0.0.1,
the first connection asks about a host key that `known_hosts` already has under the
machine's other names; answer yes.

    printf '' | ssh asb-test probe unit      # tar: This does not look like a tar archive
    ssh asb-test probe e2e                   # asb-run-tests: suite 'e2e' not allowed

## 4. The project's side (`.asb/`, never committed)

**`.asb/host-tests.sh [-C DIR] [SUITE...]`** sends a tree, as it is now (uncommitted
changes included), to the account and runs the suites there. Three things matter for
it to work from every role:

- **It sends a self-contained `.git`.** About 30 unit tests (`--setup-remote`, the
  standalone installer) install from the checkout's repository, and fail without one.
  An Implementer's clone has a `.git` *file* pointing at `.asb/git/N`, with `main`'s
  objects as alternates, which is useless on the server. So the script sends a
  `git clone --bare --no-local` copy, with its index at HEAD. A Reviewer sees no
  history, so for a tree with no repository it makes a one-commit repository of the
  tree.
- **It never sends `.asb/`, `.env/` or `.agent-sandbox`.** `.agent-sandbox` is your own
  policy, untracked. On the account it is unapproved, so every launch the live tests
  make in the run directory would be refused.
- **The key names the tree's run directory there**, and runs take turns (`flock`).

```bash
#!/usr/bin/env bash
# .asb/host-tests.sh [-C DIR] [SUITE...] -- run tests/run.sh SUITE... (default: unit +
# integration; SUITE one of unit, integration, default, live) on the test account
# (ssh alias asb-test), on the tree DIR (default: the current directory) as it is now,
# uncommitted changes included.
#
#   .asb/host-tests.sh                       main, from the project directory
#   .asb/host-tests.sh -C .asb/impl/1        Implementer 1's clone (a Reviewer's final run)
#   .asb/host-tests.sh unit                  one suite
set -euo pipefail

tree=$PWD
if [[ "${1:-}" == -C ]]; then
  [[ -n "${2:-}" ]] || {
    echo "host-tests: -C needs a directory" >&2
    exit 2
  }
  tree=$(cd -- "$2" && pwd)
  shift 2
fi
[[ -f "$tree/tests/run.sh" ]] || {
  echo "host-tests: $tree is not an agent-sandbox tree (no tests/run.sh)" >&2
  exit 2
}
key=$(printf '%s' "$tree" | sha256sum | cut -c1-16)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/host-tests.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
g="$tmp/dotgit" # becomes ./.git in the archive

top=$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null || true)
if [[ "$top" == "$tree" ]]; then
  git clone -q --bare --no-local -- "$tree" "$g"
  git --git-dir="$g" config core.bare false
  if b=$(git -C "$tree" symbolic-ref -q --short HEAD); then
    git --git-dir="$g" symbolic-ref HEAD "refs/heads/$b"
  else
    git --git-dir="$g" update-ref --no-deref HEAD "$(git -C "$tree" rev-parse HEAD)"
  fi
  if url=$(git -C "$tree" remote get-url origin 2>/dev/null); then
    git --git-dir="$g" config remote.origin.url "$url"
  else
    git --git-dir="$g" config --unset remote.origin.url || true
  fi
  git --git-dir="$g" read-tree HEAD
  how="its repository at $(git --git-dir="$g" rev-parse --short HEAD)"
else
  git init -q --bare "$g"
  git --git-dir="$g" config core.bare false
  GIT_DIR="$g" GIT_WORK_TREE="$tree" git add -A -- . ':!.asb' ':!.env' ':!.agent-sandbox'
  GIT_DIR="$g" GIT_WORK_TREE="$tree" git -c user.name='asb host-tests' \
    -c user.email='host-tests@localhost' -c commit.gpgsign=false \
    commit -q -m "the tree of $tree, for a host test run"
  how="no history here: a one-commit repository of the tree"
fi
echo "host-tests: $tree ($how) -> asb-test, run $key: ${*:-default}" >&2

tar -cf - --exclude=./.git --exclude=./.asb --exclude=./.env --exclude=./.agent-sandbox \
  -C "$tree" . \
  -C "$tmp" --transform='s,^\./dotgit,./.git,' ./dotgit |
  ssh asb-test "$key" "$@"
```

**`.asb/iterate.sh [-C DIR] [PATH...]`**: an iterating round's tests, in the role's own
sandbox. It runs the unit `.bats` files among the changed paths (and any unit file named
as an extra path), then `shellcheck -x` and `shfmt -d` on the shell files among them. It
refuses `tests/integration/`, `tests/e2e/` and `tests/live/` files, which would skip and
pass there. With no paths it diffs against `main`'s merge base. A Reviewer passes the
Handoff's changed paths and `-C .asb/impl/N`.

```bash
#!/usr/bin/env bash
# .asb/iterate.sh [-C DIR] [PATH...] -- an iterating round's tests, in the role's own
# sandbox: the unit .bats files among PATH (and any unit .bats file named as extra
# PATH, the ones the change affects by judgement), then shellcheck -x and shfmt -d on the
# shell files among PATH. Integration, e2e and live files are refused here: inside a
# role they skip and report success (host-tests-setup.md); .asb/host-tests.sh runs them.
#
# PATH relative to the tree DIR (default: the current directory). With no PATH, the
# paths changed since main's merge base, uncommitted and untracked included (needs the
# tree's .git: a Reviewer passes the Handoff's changed paths instead).
set -euo pipefail

tree=$PWD
if [[ "${1:-}" == -C ]]; then
  tree=$(cd -- "$2" && pwd)
  shift 2
fi
cd -- "$tree"

if (($# == 0)); then
  base=$(git merge-base HEAD main 2>/dev/null) || {
    echo "iterate: no PATH given and no main to diff against here; pass the changed paths" >&2
    exit 2
  }
  mapfile -t paths < <({
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
  } | sort -u)
else
  paths=("$@")
fi

bats_files=() sh_files=()
for p in "${paths[@]}"; do
  [[ -e "$p" ]] || continue # deleted
  case "$p" in
    tests/integration/* | tests/e2e/* | tests/live/*)
      echo "iterate: $p not run here (it would skip and pass in a sandbox): .asb/host-tests.sh runs it" >&2
      continue
      ;;
    tests/unit/*.bats) bats_files+=("$p") ;;
  esac
  case "$p" in
    *.bats | *.md | *.yml | *.yaml | *.toml | *.json | *.py | *.txt) ;;
    *.sh | *.bash | agent-sandbox | install.sh.in | install.sh) sh_files+=("$p") ;;
    *) head -c 64 -- "$p" 2>/dev/null | head -n1 | grep -Eq '^#!.*\b(ba)?sh\b' && sh_files+=("$p") ;;
  esac
done

rc=0
if ((${#bats_files[@]})); then
  bats -j 4 "${bats_files[@]}" || rc=1
else
  echo "iterate: no unit .bats file among the paths; name the ones the change affects as extra PATH" >&2
fi
if ((${#sh_files[@]})); then
  shellcheck -x "${sh_files[@]}" || rc=1
  shfmt -d "${sh_files[@]}" || rc=1
fi
exit "$rc"
```

**`.asb/tests`:**

    iterate = .asb/iterate.sh          # unit .bats + shellcheck + shfmt, in the sandbox; paths as arguments (a Reviewer: the Handoff's changed paths, and -C .asb/impl/N)
    final = .asb/host-tests.sh         # unit + integration on the asb-test account; a Reviewer: -C .asb/impl/N

## 5. Grant the alias to the roles

Do this once the alias exists and step 3's check passes. On the host:

    asb --apply '[ssh:implementer-*]' 'asb-test'
    asb --apply '[ssh:reviewer-*]' 'asb-test'

Then restart those roles. The private key stays on your machine: each role gets an ssh
agent that works for that host only. With SERVER at 127.0.0.1 the grant is made by the
resolved address and port (#396), and the role signs in only where this key is
authorized, which is the test account alone. Under `asb --init github`, the gh-* roles
take the same line: `[ssh:gh-review-*]`, `[ssh:gh-fix-*]`, and so on.

## 6. Check

1. From your machine, in the project: `.asb/host-tests.sh unit` runs the whole unit
   suite on the account, the host-only tests included. Expect the atime tests of
   `tests/unit/snapshot.bats` to skip on a filesystem mounted `strictatime`.
2. From your machine: `.asb/host-tests.sh live` runs one cheap agent turn per network
   mode, with the account's login. Two skips are expected: the seccomp control's
   second half, where AppArmor refuses unprivileged user namespaces outside a sandbox,
   and the strict `--ssh` test, while `github.com` isn't in the account's
   `~/.ssh/known_hosts`.
3. From an Implementer: `.asb/host-tests.sh integration`. No test in its output may say
   `# skip unprivileged user namespaces unavailable`; if one does, the user namespace
   check in section 2 isn't satisfied on SERVER.
4. From a Reviewer: `.asb/host-tests.sh -C .asb/impl/N unit`. This is the one-commit
   repository case.

## Not to do

- Give the test account anything of yours: no tokens, no `gh` login, no keys but the
  authorized one, no other checkouts, no copy of your agent login.
- Put `live` in `.asb/tests`: it would spend the login's usage at every final run.
- Run the integration suites inside a role: they skip and report success.
- Turn off the seccomp filter for a role so they can run there.
