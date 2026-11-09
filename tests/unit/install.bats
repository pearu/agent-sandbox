#!/usr/bin/env bats
# `asb --install AGENT[@VERSION] [--from FILE]` (#6): the host-side installer. A scratch
# profile, `fake`, has its own trivial resolver that reads a fake release source,
# $SRC/VERSION/{asset,sum,size}, given as AGENT_SANDBOX_INSTALL_BASE; the engine
# downloads the asset with curl from file://, checks it, and installs it under the
# state directory. Nothing here reaches the network. The claude profile's own resolver,
# with its signed manifest, is tested end to end in profile-claude/install.bats.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  P="$H/profiles2"
  F="$P/fake"
  SRC="$H/src"
  ST="$H/home/.local/state/agent-sandbox"
  I="$ST/fake/install"
  mkdir -p "$F" "$SRC"
  printf 'profile_command=fakeagent\n' >"$F/profile.sh"
  printf '[agent]\ninstall = file\n' >"$F/agent-sandbox"
  printf '1.0.0\n1.1.0 pinned\n' >"$F/versions"
  # The fake resolver: VERSION's asset, its SHA-256 and size from the source; the
  # platform and the gpg it would run recorded beside it.
  cat >"$F/resolve.sh" <<'EOF'
#!/usr/bin/env bash
v="$1" plat="$2" base="${3:?no BASE}"
d="${base#file://}/$v"
[[ -f "$d/sum" ]] || { echo "fake resolve.sh: no release $v" >&2; exit 1; }
printf '%s\n' "$plat" >"$d/platform"
printf '%s\n' "$(command -v gpg || echo none)" >"$d/gpg"
if [[ -f "$d/printed" ]]; then cat "$d/printed"; exit 0; fi
printf 'file://%s/asset\t%s\t%s\n' "$d" "$(cat "$d/sum")" "$(cat "$d/size" 2>/dev/null)"
EOF
  chmod +x "$F/resolve.sh"
}

# release VERSION FILE [size] -- the source's VERSION: FILE as its asset, its SHA-256,
# and with `size` its size too.
release() {
  mkdir -p "$SRC/$1"
  cp "$2" "$SRC/$1/asset"
  sha256sum "$SRC/$1/asset" | cut -d' ' -f1 >"$SRC/$1/sum"
  [[ "${3:-}" != size ]] || stat -c %s "$SRC/$1/asset" >"$SRC/$1/size"
}

# binary TEXT -- a fake agent binary at $H/bin-TEXT, printing TEXT.
binary() {
  printf '#!/bin/sh\necho %s\n' "$1" >"$H/bin-$1"
  printf '%s' "$H/bin-$1"
}

# install WORDS... -- asb --install WORDS, with the fake profile and source.
install() {
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_INSTALL_BASE="$SRC" -- asb --install "$@"
}

# nothing_left -- the install directory holds no version and no temporary directory.
nothing_left() {
  [ -z "$(find "$I" -mindepth 1 -maxdepth 1 ! -name current 2>/dev/null)" ]
}

@test "--install AGENT: the pin, downloaded, checked, in <state>/AGENT/install/VERSION/, made current" {
  release 1.1.0 "$(binary v110)" size
  install fake
  [ "$status" -eq 0 ]
  local plat
  plat="$(uname -m)-gnu"
  [ "$(cat "$SRC/1.1.0/platform")" = "$plat" ]
  [ "$output" = "agent-sandbox: --install: downloading fake 1.1.0 for $plat, 0 MB, from file://$SRC/1.1.0/asset
agent-sandbox: --install: fake 1.1.0 is installed at ~/.local/state/agent-sandbox/fake/install/1.1.0/fakeagent, and is now fake's current version" ]
  [ "$("$I/1.1.0/fakeagent")" = v110 ]
  [ "$(readlink "$I/current")" = 1.1.0 ]
  [ "$(find "$I" -mindepth 1 -printf '%P\n' | sort | paste -sd' ')" = "1.1.0 1.1.0/fakeagent current" ]
  [ ! -s "$H/argv" ]
}

@test "--install AGENT@VERSION: a listed version beside the pin; current moves to it, and back" {
  release 1.1.0 "$(binary v110)"
  release 1.0.0 "$(binary v100)"
  install fake
  [ "$status" -eq 0 ]
  install fake@1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"downloading fake 1.0.0 for "*" (size not stated) from file://$SRC/1.0.0/asset"* ]]
  [ "$(readlink "$I/current")" = 1.0.0 ]
  [ "$("$I/1.0.0/fakeagent")" = v100 ] && [ "$("$I/1.1.0/fakeagent")" = v110 ]
  # installed already: no resolver, no download -- the source is gone
  rm -r "$SRC"
  install fake@1.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "agent-sandbox: --install: fake 1.1.0 is installed already at ~/.local/state/agent-sandbox/fake/install/1.1.0/fakeagent (no download), and is now fake's current version" ]
  [ "$(readlink "$I/current")" = 1.1.0 ]
}

@test "--install: a version not in the table, a profile with no table, no pin, or no recipe is refused (2); nothing is made" {
  release 9.9.9 "$(binary v999)"
  install fake@9.9.9
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: fake 9.9.9 is not in profile 'fake''s versions table, $F/versions: asb installs only the versions tested with it (listed: 1.0.0 1.1.0)" ]
  install fake@
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: 'fake@' names no version after the @: asb --install AGENT[@VERSION]" ]
  install fake@'>=1.0'
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: --install: fake >=1.0 is not in profile 'fake''s versions table"* ]]
  [ ! -e "$ST" ]
  printf '1.0.0\n' >"$F/versions"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: profile 'fake': $F/versions: no version is pinned
agent-sandbox: --install: profile 'fake' has no pinned version; name one of its versions: asb --install fake@VERSION (listed: 1.0.0)" ]
  rm "$F/versions"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: profile 'fake' lists no versions in $F/versions" ]
  printf '[agent]\n' >"$F/agent-sandbox"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: profile 'fake' has no install recipe ([agent] install in $F/agent-sandbox), so asb does not install its agent" ]
  install nosuch
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: --install: 'nosuch' names no profile. Profiles available in $P: fake" ]]
  printf '[agent]\ninstall = file\n' >"$F/agent-sandbox"
  printf '1.1.0 pinned\n' >"$F/versions"
  chmod -x "$F/resolve.sh"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: profile 'fake' has no resolver, an executable $F/resolve.sh" ]
  [ ! -e "$ST" ]
}

@test "--install: the versions table's problems are said here; two pins is no pin" {
  release 1.1.0 "$(binary v110)"
  printf '1.0.0\n1.1.0 pinned\n1.2 latest\n1.0.0\n' >"$F/versions"
  install fake
  [ "$status" -eq 0 ]
  [[ "$output" == "agent-sandbox: profile 'fake': $F/versions:3: '1.2 latest' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'fake': $F/versions:4: 1.0.0 is listed again; ignoring
agent-sandbox: --install: downloading fake 1.1.0 "* ]]
  printf '1.0.0 pinned\n1.1.0 pinned\n' >"$F/versions"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: profile 'fake': $F/versions: more than one version is pinned (1.0.0 1.1.0); none is the pin
agent-sandbox: --install: profile 'fake' has no pinned version; name one of its versions: asb --install fake@VERSION (listed: 1.0.0 1.1.0)" ]
}

@test "--install: a checksum that does not match, or a truncated download, leaves nothing (1); current stays" {
  release 1.0.0 "$(binary v100)"
  install fake@1.0.0
  [ "$status" -eq 0 ]
  release 1.1.0 "$(binary v110)"
  printf 'tampered\n' >>"$SRC/1.1.0/asset"
  install fake
  [ "$status" -eq 1 ]
  local got
  got="$(sha256sum "$SRC/1.1.0/asset" | cut -d' ' -f1)"
  [[ "$output" == *"agent-sandbox: --install: the SHA-256 of file://$SRC/1.1.0/asset is $got, not the $(cat "$SRC/1.1.0/sum") its resolver gives; nothing installed" ]]
  [ ! -e "$I/1.1.0" ]
  [ "$(find "$I" -mindepth 1 -maxdepth 1 -name '.*')" = "" ]
  [ "$(readlink "$I/current")" = 1.0.0 ]
  # truncated: shorter than the size the resolver states
  release 1.1.0 "$(binary v110)" size
  head -c 5 "$H/bin-v110" >"$SRC/1.1.0/asset"
  install fake
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --install: file://$SRC/1.1.0/asset is 5 bytes, not the $(cat "$SRC/1.1.0/size") its resolver states; nothing installed" ]]
  [ ! -e "$I/1.1.0" ]
  # longer than it: curl stops it
  release 1.1.0 "$(binary v110)" size
  printf 'more' >>"$SRC/1.1.0/asset"
  install fake
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --install: the download of file://$SRC/1.1.0/asset failed (curl exit 63); nothing installed" ]]
  [ ! -e "$I/1.1.0" ]
  [ "$(find "$I" -mindepth 1 -maxdepth 1 -name '.*')" = "" ]
  [ "$(readlink "$I/current")" = 1.0.0 ]
}

@test "--install: a resolver that fails, or prints another shape, installs nothing (1)" {
  install fake
  [ "$status" -eq 1 ]
  [ "$output" = "fake resolve.sh: no release 1.1.0
agent-sandbox: --install: profile 'fake''s resolver could not say which file is fake 1.1.0 for $(uname -m)-gnu (exit 1); nothing installed" ]
  release 1.1.0 "$(binary v110)"
  local bad
  for bad in "http://x/asset	$(cat "$SRC/1.1.0/sum")	" "file://$SRC/1.1.0/asset	notasum	" \
    "file://$SRC/1.1.0/asset	$(cat "$SRC/1.1.0/sum")	12ab" ""; do
    printf '%s\n' "$bad" >"$SRC/1.1.0/printed"
    install fake
    [ "$status" -eq 1 ]
    [ "$output" = "agent-sandbox: --install: profile 'fake''s resolver printed '$bad', not URL<TAB>SHA256<TAB>SIZE; nothing installed" ]
  done
  [ ! -e "$I/1.1.0" ]
}

@test "--install --from FILE: the file, checked against the resolver's SHA-256; a wrong one leaves nothing" {
  release 1.1.0 "$(binary v110)"
  cp "$H/bin-v110" "$H/local-copy"
  rm "$SRC/1.1.0/asset" # never downloaded
  install fake --from "$H/local-copy"
  [ "$status" -eq 0 ]
  [ "$output" = "agent-sandbox: --install: fake 1.1.0 for $(uname -m)-gnu from $H/local-copy, checked against the SHA-256 its resolver gives
agent-sandbox: --install: fake 1.1.0 is installed at ~/.local/state/agent-sandbox/fake/install/1.1.0/fakeagent, and is now fake's current version" ]
  [ "$("$I/1.1.0/fakeagent")" = v110 ]
  release 1.0.0 "$(binary v100)"
  install fake@1.0.0 --from "$H/local-copy"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --install: the SHA-256 of $H/local-copy is "*", not the $(cat "$SRC/1.0.0/sum") its resolver gives; nothing installed" ]]
  [ ! -e "$I/1.0.0" ]
  [ "$(readlink "$I/current")" = 1.1.0 ]
  install fake@1.0.0 --from "$H/no-such-file"
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: --from $H/no-such-file is not a file" ]
}

@test "--install: refused inside a sandbox, and with anything else on the line (2)" {
  release 1.1.0 "$(binary v110)"
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_INSTALL_BASE="$SRC" AGENT_SANDBOX=1 -- asb --install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install runs on the host: it downloads the agent there, for every sandbox to run; a role proposes the line, you run it." ]
  local words
  for words in "--install" "--install fake extra" "--verbose --install fake" "--install fake --from" \
    "--install --from x" "--install fake --to x" "--install fake --from x y"; do
    # shellcheck disable=SC2086 # the words, split
    run_engine AGENT_SANDBOX_PROFILE_DIR="$P" -- asb $words
    [ "$status" -eq 2 ]
    [ "$output" = "agent-sandbox: --install takes an agent, optionally @VERSION, and nothing else on the line but --from FILE: asb --install AGENT[@VERSION] [--from FILE] (e.g. asb --install claude)" ]
  done
  [ ! -e "$ST" ]
  [ ! -s "$H/argv" ]
}

@test "--install: the resolver runs with the tools env's engine-bin/ first on PATH (gpg)" {
  local slot="$H/home/.local/share/agent-sandbox/tools/a"
  mkdir -p "$slot/bin" "$slot/engine-bin"
  ln -s a "$H/home/.local/share/agent-sandbox/tools/current"
  printf '#!/bin/sh\n' >"$slot/engine-bin/gpg"
  chmod +x "$slot/engine-bin/gpg"
  release 1.1.0 "$(binary v110)"
  install fake
  [ "$status" -eq 0 ]
  [ "$(cat "$SRC/1.1.0/gpg")" = "$slot/engine-bin/gpg" ]
}

@test "--install: through a symlinked state level, or over a current that is not a symlink, is refused (2)" {
  release 1.1.0 "$(binary v110)"
  mkdir -p "$ST" "$H/elsewhere"
  ln -s "$H/elsewhere" "$ST/fake"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: $ST/fake is a symlink or not a directory; refusing to install through it" ]
  [ -z "$(ls -A "$H/elsewhere")" ]
  rm "$ST/fake"
  mkdir -p "$I/current"
  install fake
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install: $I/current is not a symlink; it names the version launches run. Remove it, then run this again" ]
  [ ! -e "$I/1.1.0" ]
}

# ---- a tarball: [agent] install = tar PATH ---------------------------------------------

# tarball NAME SPEC... -- $H/NAME.tar.gz made with python's tarfile from SPECs:
# `f:NAME` a file (executable), `d:NAME` a directory, `l:NAME:TARGET` a symlink,
# `h:NAME:TARGET` a hard link, `p:NAME` a fifo.
tarball() {
  local out="$H/$1.tar.gz"
  shift
  python3 -I -c '
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for s in sys.argv[2:]:
        k, name, *rest = s.split(":")
        ti = tarfile.TarInfo(name)
        ti.mode = 0o755
        if k == "f":
            data = b"#!/bin/sh\necho tree\n"
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
            continue
        ti.type = {"d": tarfile.DIRTYPE, "l": tarfile.SYMTYPE, "h": tarfile.LNKTYPE, "p": tarfile.FIFOTYPE}[k]
        ti.linkname = rest[0] if rest else ""
        t.addfile(ti)
' "$out" "$@"
  printf '%s' "$out"
}

@test "--install, tar PATH: the tree unpacked, the binary at PATH, its siblings and inside symlinks kept" {
  printf '[agent]\ninstall = tar pkg/bin/fakeagent\n' >"$F/agent-sandbox"
  release 1.1.0 "$(tarball good d:pkg d:pkg/bin f:pkg/bin/fakeagent f:pkg/lib/helper l:pkg/bin/h:../lib/helper l:pkg/self:. h:pkg/bin/hard:pkg/lib/helper)"
  install fake
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake 1.1.0 is installed at ~/.local/state/agent-sandbox/fake/install/1.1.0/pkg/bin/fakeagent, and is now fake's current version" ]]
  [ "$("$I/1.1.0/pkg/bin/fakeagent")" = tree ]
  [ -x "$I/1.1.0/pkg/bin/h" ] && [ -f "$I/1.1.0/pkg/lib/helper" ]
  [ "$(readlink "$I/current")" = 1.1.0 ]
}

@test "--install, tar PATH: an absolute member, a '..' member, an escaping symlink, a fifo, or no binary at PATH is refused with nothing left" {
  printf '[agent]\ninstall = tar pkg/bin/fakeagent\n' >"$F/agent-sandbox"
  # `chain`: e is inside the tree when read lexically (pkg/x/d/../../.. is the tree), and
  # outside when its symlink d is followed, as the kernel does (d is pkg/x itself).
  local bad
  for bad in "abs f:pkg/bin/fakeagent f:/tmp/evil" "dotdot f:pkg/bin/fakeagent f:pkg/../../evil" \
    "abslink f:pkg/bin/fakeagent l:pkg/etc:/etc" "uplink f:pkg/bin/fakeagent l:pkg/up:../.." \
    "chain f:pkg/bin/fakeagent d:pkg/x l:pkg/x/d:. l:pkg/x/e:d/../../.." \
    "fifo f:pkg/bin/fakeagent p:pkg/pipe" "nobin f:pkg/bin/other" "binlink f:pkg/lib/x l:pkg/bin/fakeagent:/bin/sh" \
    "bindir d:pkg/bin/fakeagent"; do
    # shellcheck disable=SC2086 # the words, split
    release 1.1.0 "$(tarball $bad)"
    install fake
    [ "$status" -eq 1 ]
    case "${bad%% *}" in
      abs) [[ "$output" == *"agent-sandbox: --install: the tarball has a member '/tmp/evil', which is absolute or has a '..' part; nothing installed" ]] ;;
      dotdot) [[ "$output" == *"agent-sandbox: --install: the tarball has a member 'pkg/../../evil', which is absolute or has a '..' part; nothing installed" ]] ;;
      abslink) [[ "$output" == *"agent-sandbox: --install: the tarball's symlink 'pkg/etc' -> '/etc' points outside it; nothing installed" ]] ;;
      uplink) [[ "$output" == *"agent-sandbox: --install: the tarball's symlink 'pkg/up' -> '../..' points outside it; nothing installed" ]] ;;
      chain) [[ "$output" == *"agent-sandbox: --install: the tarball's symlink 'pkg/x/e' -> 'd/../../..' points outside it; nothing installed" ]] ;;
      fifo) [[ "$output" == *"agent-sandbox: --install: the tarball has 'pkg/pipe', which is not a file, a directory or a symlink; nothing installed" ]] ;;
      binlink) [[ "$output" == *"agent-sandbox: --install: the tarball's symlink 'pkg/bin/fakeagent' -> '/bin/sh' points outside it; nothing installed" ]] ;;
      *) [[ "$output" == *"agent-sandbox: --install: the tarball has no executable file at pkg/bin/fakeagent (the profile's [agent] install); nothing installed" ]] ;;
    esac
    nothing_left
    [ ! -e "$I/current" ]
    [ ! -e "$H/evil" ] && [ ! -e "$ST/fake/evil" ]
  done
  # not a tarball at all
  release 1.1.0 "$(binary v110)"
  install fake
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --install: tar cannot read the download as a tarball; nothing installed" ]]
  nothing_left
}
