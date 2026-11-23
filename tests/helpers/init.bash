# shellcheck shell=bash
# The helpers several of tests/unit/init-*.bats use (asb --init; they were one file,
# init.bats). Each file loads this at its top level; its setup makes the harness ($H,
# $PROJ) these use.
# shellcheck disable=SC2034 # what sandbox_base sets (ROOT, PDIR) is read by the suites

# has_section HEADER FILE -- FILE has a line that starts with HEADER (a comment may follow).
has_section() { grep -F -- "$1" "$2" | grep -q "^$(printf '%s' "$1" | sed 's/[][*.]/\\&/g')"; }

# init [VAR=value ...] -- ARGS: `asb --init ARGS` from the project, in a clean environment.
init() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift
  engine_cmd
  run bash -c 'proj="$1" home="$2" path="$3" n="$4"; shift 4; eng=("${@:1:n}"); shift "$n"; n="$1"; shift; envs=("${@:1:n}"); shift "$n"
    cd "$proj" && env -i HOME="$home" PATH="$path" "${envs[@]}" "${eng[@]}" --init "$@" 2>&1 </dev/null' \
    _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${#ENGINE_CMD[@]}" "${ENGINE_CMD[@]}" "${#envs[@]}" ${envs[@]+"${envs[@]}"} "$@"
}

# The sandbox base (`[conda] base = sandbox`): no conda on the host, a stub micromamba
# that clones as conda-stub does. ROOT is the conda root, PDIR this project's directory
# name there (the state directory's slug).
sandbox_base() {
  ROOT="$H/home/.local/share/agent-sandbox/conda" PDIR="$(project_env_dir "$PROJ")"
  local mm="$H/home/.local/share/agent-sandbox/micromamba/bin"
  printf '#!/bin/sh\nexit 1\n' >"$H/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$H/bin/mamba"
  chmod +x "$H/bin/conda" "$H/bin/mamba"
  mkdir -p "$mm" "$ROOT"
  cp "$H/bin/conda-stub" "$mm/micromamba"
}

# a date that says one time, for a backup's name
fixed_date() {
  cat >"$H/bin/date" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "-u +%Y%m%dT%H%M%SZ" ]] && { echo 20260101T000000Z; exit 0; }
exec /usr/bin/date "$@"
STUB
  chmod +x "$H/bin/date"
}

# tree_of DIR -- every path under DIR but .git/, with a link's target and a file's hash: two
# runs compare equal when nothing under DIR was written.
tree_of() {
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [[ -L "$f" ]]; then
      printf '%s -> %s\n' "$f" "$(readlink "$f")"
    elif [[ -f "$f" ]]; then
      printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -c1-16)"
    else
      printf '%s/\n' "$f"
    fi
  done)
}

# section HEADER FILE -- the lines of every section FILE has under HEADER.
section() { awk -v h="$1" '$1 == h { on = 1; next } /^(# )?\[/ { on = 0 } on' "$2"; }
# check ROLE -- `asb --check --role ROLE` from the project.
check() {
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" MAMBA_ROOT_PREFIX="$4" "${@:5}" --profile claude --check --role "$0" 2>&1 </dev/null' \
    "$1" "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$H/conda" "${ENGINE_CMD[@]}"
}
approve() {
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
}

# shared_env NAME -- a built env under $H/conda/envs/NAME whose editable installs import from
# $H/src/torch (direct_url.json, pip install -e) and $H/src/vision (an .egg-link, setup.py
# develop); a .pth line inside the env itself is not a source.
shared_env() {
  local ep="$H/conda/envs/$1" sp
  sp="$ep/lib/python3.12/site-packages"
  mkdir -p "$ep/conda-meta" "$sp/torch-2.15.dist-info" "$sp/extra" "$H/src/torch" "$H/src/vision"
  printf '{"url": "file://%s/src/torch", "dir_info": {"editable": true}}\n' "$H" >"$sp/torch-2.15.dist-info/direct_url.json"
  printf '%s/src/vision\n.\n' "$H" >"$sp/torchvision.egg-link"
  printf '%s\n' "$sp/extra" >"$sp/extra.pth"
}

# snap NAME -- every file of .agent-sandbox and .asb/ but the clones, with its hash, and
# the dot-file's inode: what a refused --init leaves as it was
snap() {
  (cd "$PROJ" && find .agent-sandbox .asb -path .asb/impl -prune -o -path .asb/git -prune -o -type f -print0 \
    | sort -z | xargs -0 sha256sum && stat -c %i .agent-sandbox) >"$H/snap.$1"
}
