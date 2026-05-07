#!/usr/bin/env bats
# Phase 5: help surface, destructive-op guards, expose flag parser, empty states.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs" "${HOME}/.4lm/launchd"
  cp "${REPO_ROOT}/config/profiles/default.yaml" "${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/active-profile"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
  for p in "${REPO_ROOT}"/launchd/*.plist; do
    sed "s|__HOME__|${HOME}|g" "$p" >"${HOME}/.4lm/launchd/$(basename "$p")"
  done
  export LLM_HOME="${HOME}/.4lm"
  export LAUNCHD_DIR="${HOME}/.4lm/launchd"
}

# ---- models rm --confirm guard -----------------------------------------------

@test "models rm without --confirm exits 0 and prints --confirm hint and repo name" {
  run "${REPO_ROOT}/bin/4lm" models rm org/myrepo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--confirm"
  echo "$output" | grep -q "org/myrepo"
}

@test "models rm with --confirm invokes hf cache rm with correct repo" {
  run "${REPO_ROOT}/bin/4lm" models rm org/myrepo --confirm
  [ "$status" -eq 0 ]
  grep -q "cache rm org/myrepo" "${BATS_TMPDIR}/hf-calls"
}

# ---- uninstall --confirm guard -----------------------------------------------

@test "uninstall without --confirm exits 0 and prints ~/.4lm path" {
  run "${REPO_ROOT}/bin/4lm" uninstall
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ".4lm"
  # ~/.local/bin/4lm symlink not removed
  [ -L "${HOME}/.4lm/config/active-profile" ]
}

# ---- expose flag-based parser ------------------------------------------------

@test "expose lan with extraneous arg exits 1 with error: and unknown argument" {
  run "${REPO_ROOT}/bin/4lm" expose lan bogusarg
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "error:"
  echo "$output" | grep -qi "unknown"
}

@test "expose lan --confirm proceeds and writes lan mode" {
  run "${REPO_ROOT}/bin/4lm" expose lan --confirm
  [ "$status" -eq 0 ]
  grep -q "^mode: lan" "${HOME}/.4lm/config/network.yaml"
}

# ---- profile list empty state ------------------------------------------------

@test "profile list with no yaml files prints No profiles and make install" {
  rm -f "${HOME}/.4lm/config/profiles/"*.yaml
  run "${REPO_ROOT}/bin/4lm" profile list
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "No profiles"
  echo "$output" | grep -q "make install"
}

# ---- help surface: models cleanup entry ------------------------------------

@test "4lm help contains models cleanup entry" {
  run "${REPO_ROOT}/bin/4lm" help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "models cleanup"
}

# ---- hf cache prune --yes ---------------------------------------------------

@test "models clean invokes hf cache prune with --yes" {
  run "${REPO_ROOT}/bin/4lm" models clean
  [ "$status" -eq 0 ]
  # The hf stub logs its arguments; verify --yes was passed.
  grep -q -- "cache prune --yes" "${BATS_TMPDIR}/hf-calls"
}
