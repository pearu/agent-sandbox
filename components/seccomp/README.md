# seccomp: default-deny syscall filter (opt-in)

`AGENT_SANDBOX_SECCOMP=on` loads a seccomp filter into the sandbox: every
syscall not on an allowlist fails with `EPERM`. It is defense in depth behind
the namespaces and `--cap-drop ALL`, off by default (issue #4).

- `moby-default.json` is Docker's default seccomp profile, vendored unmodified
  from [moby/profiles](https://github.com/moby/profiles) (`seccomp/default.json`),
  Apache License 2.0 (`LICENSE.moby`). The only local change is a trailing
  newline, so the installer can embed it in a heredoc. It is the widely deployed baseline that
  runs ordinary Node, Python and native toolchains.
- `gen-seccomp.py` compiles it for one architecture **as for a container with no
  capabilities** (agent-sandbox drops them all): rules that Docker grants only
  with a capability are skipped, so `unshare`, `setns`, `mount`, `pivot_root`,
  `chroot`, `bpf` and friends stay denied; `clone` is allowed only without
  namespace flags (no `CLONE_NEWUSER`); `clone3` returns `ENOSYS` so libc falls
  back to `clone`. This is what closes the "make your own user namespace and get
  capabilities back" path that capability dropping alone leaves open.

`install.sh` runs the generator on the installing host, with `pyseccomp` in the
proxy's private Python environment against the host's own `libseccomp`, and
writes `~/.local/share/agent-sandbox/seccomp/<arch>.bpf`. Nothing binary is
committed; the blob always matches the libseccomp that will interpret it.
Regenerate by re-running `install.sh`. To inspect by hand from the dev env:

    python3 components/seccomp/gen-seccomp.py components/seccomp/moby-default.json "$(uname -m)" /tmp/f.bpf
