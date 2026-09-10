#!/usr/bin/env bats
# Conda passthrough with the real bwrap and a fake conda layout (directories
# only): read-only by default; write mode opens only the active env.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
w() { touch "$1" 2>/dev/null && { rm -f "$1"; echo yes; } || echo no; }
say env_writable "$(w "$CONDA_PREFIX/x")"
say base_writable "$(w "$CONDA_BASE_FOR_TEST/x")"
say other_env_writable "$(w "$CONDA_BASE_FOR_TEST/envs/other/x")"
say host_pkgs_writable "$(w "$CONDA_BASE_FOR_TEST/pkgs/x")"
say dotconda_writable "$(w "$HOME/.conda/x")"
say condarc_cf "$(grep -c conda-forge "$HOME/.condarc" 2>/dev/null)"
say pkgs_dirs "${CONDA_PKGS_DIRS-unset}"
say sandbox_pkgs_writable "$([[ -n ${CONDA_PKGS_DIRS-} ]] && w "${CONDA_PKGS_DIRS%%,*}/x" || echo n/a)"
PROBE
  BASE="$I/conda"
  ENV="$BASE/envs/myenv"
  mkdir -p "$ENV" "$BASE/envs/other" "$BASE/pkgs" "$BASE/condabin" "$I/pkgs"
  printf 'channels:\n  - conda-forge\n' >"$IHOME/.condarc"
  CENV=(CONDA_PREFIX="$ENV" CONDA_DEFAULT_ENV=myenv CONDA_SHLVL=1 AGENT_SANDBOX_FORWARD=CONDA_BASE_FOR_TEST CONDA_BASE_FOR_TEST="$BASE" AGENT_SANDBOX_NET=none)
}

@test "default: env, base, other envs and host cache all read-only; ~/.conda writable; .condarc visible" {
  run_sandboxed "${CENV[@]}" -- run
  [ "$status" -eq 0 ]
  [ "$(report env_writable)" = no ]
  [ "$(report base_writable)" = no ]
  [ "$(report other_env_writable)" = no ]
  [ "$(report host_pkgs_writable)" = no ]
  [ "$(report dotconda_writable)" = yes ]
  [ "$(report condarc_cf)" = 1 ]
  [ "$(report pkgs_dirs)" = unset ]
}

@test "write mode: only the active env becomes writable; downloads go to the sandbox-owned cache listed first" {
  run_sandboxed "${CENV[@]}" AGENT_SANDBOX_CONDA_WRITE=1 AGENT_SANDBOX_CONDA_PKGS="$I/pkgs" -- run
  [ "$status" -eq 0 ]
  [ "$(report env_writable)" = yes ]
  [ "$(report base_writable)" = no ]
  [ "$(report other_env_writable)" = no ]
  [ "$(report host_pkgs_writable)" = no ]
  [ "$(report pkgs_dirs)" = "$I/pkgs,$BASE/pkgs" ]
  [ "$(report sandbox_pkgs_writable)" = yes ]
}
