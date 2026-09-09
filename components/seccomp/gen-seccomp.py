#!/usr/bin/env python3
"""Compile a seccomp BPF filter from a Docker/OCI seccomp profile (moby-default.json)
for one architecture, as for a container holding NO capabilities (agent-sandbox drops
them all). Run by install.sh on the host it will protect, so the blob matches that
host's libseccomp; nothing binary ships.

    gen-seccomp.py PROFILE.json ARCH OUT.bpf        ARCH: x86_64 | aarch64

Interpretation of the profile:
  * defaultAction ERRNO(defaultErrnoRet): everything not allowed fails with EPERM.
  * rules gated on a capability (includes.caps) are SKIPPED: we hold none, so
    unshare/setns/mount/pivot_root/chroot/bpf/ptrace-with-caps/... stay denied;
  * rules for the cap-LESS case (excludes.caps) are kept: clone allowed only without
    namespace flags (so no CLONE_NEWUSER), clone3 -> ENOSYS so libc falls back to it;
  * arch-gated rules are resolved for ARCH; minKernel-gated ones are applied (our
    supported hosts run kernels far newer than any minKernel in the profile).
"""
import json, sys
import pyseccomp as s

OPS = {"SCMP_CMP_LT": s.LT, "SCMP_CMP_LE": s.LE, "SCMP_CMP_EQ": s.EQ, "SCMP_CMP_NE": s.NE,
       "SCMP_CMP_GE": s.GE, "SCMP_CMP_GT": s.GT, "SCMP_CMP_MASKED_EQ": s.MASKED_EQ}
# target -> (libseccomp arch, its sub-arches for 32-bit binaries, profile arch tags)
ARCHES = {"x86_64": (s.Arch.X86_64, (s.Arch.X86, s.Arch.X32), {"amd64", "x86", "x32"}),
          "aarch64": (s.Arch.AARCH64, (s.Arch.ARM,), {"arm64", "arm"})}
KERNEL_FLOOR = (5, 15)  # oldest kernel we support (Ubuntu 22.04)

def kernel_ok(spec):
    want = tuple(int(x) for x in spec.split(".")[:2])
    return KERNEL_FLOOR >= want

def action_of(entry):
    a = entry["action"]
    if a == "SCMP_ACT_ALLOW": return s.ALLOW
    if a == "SCMP_ACT_ERRNO": return s.ERRNO(int(entry.get("errnoRet", 1)))
    if a == "SCMP_ACT_LOG": return s.LOG
    return None  # TRACE/NOTIFY/etc: leave at default

def applies(entry, tags):
    inc, exc = entry.get("includes") or {}, entry.get("excludes") or {}
    if inc.get("caps"): return False                              # needs a cap we lack
    if inc.get("arches") and tags.isdisjoint(inc["arches"]): return False
    if inc.get("minKernel") and not kernel_ok(inc["minKernel"]): return False
    if exc.get("arches") and not tags.isdisjoint(exc["arches"]): return False
    return True                                                   # excludes.caps == us

def build(profile, arch):
    native, subs, tags = ARCHES[arch]
    f = s.SyscallFilter(defaction=s.ERRNO(int(profile.get("defaultErrnoRet", 1))))
    for a in (s.Arch.NATIVE, native, *subs):
        try: f.remove_arch(a)
        except Exception: pass
    for a in (native, *subs):
        try: f.add_arch(a)
        except Exception: pass
    kept = unknown = 0
    for entry in profile["syscalls"]:
        if not applies(entry, tags): continue
        act = action_of(entry)
        if act is None: continue
        args = []
        for a in entry.get("args") or []:
            op = OPS[a["op"]]
            args.append(s.Arg(a["index"], op, int(a["value"]), int(a.get("valueTwo", 0)))
                        if op == s.MASKED_EQ else s.Arg(a["index"], op, int(a["value"])))
        for name in entry["names"]:
            try: f.add_rule(act, name, *args); kept += 1
            except Exception: unknown += 1                        # not a syscall on this arch
    print(f"gen-seccomp: {arch}: {kept} rules ({unknown} names absent on this arch)", file=sys.stderr)
    return f

def main(argv):
    if len(argv) != 4 or argv[2] not in ARCHES:
        print(__doc__, file=sys.stderr); return 2
    profile = json.load(open(argv[1]))
    if profile.get("defaultAction") != "SCMP_ACT_ERRNO":
        print("gen-seccomp: refusing a profile whose defaultAction is not ERRNO (not default-deny)", file=sys.stderr); return 1
    with open(argv[3], "wb") as fh:
        build(profile, argv[2]).export_bpf(fh)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
