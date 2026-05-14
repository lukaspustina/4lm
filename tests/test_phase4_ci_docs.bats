#!/usr/bin/env bats
#
# Phase 4 verification: CI matrix + docs updates for backend-only install.
# These are static-content checks against the repo, not behavioural tests.

load helpers/setup

@test ".github/workflows/ci.yml contains install_mode matrix" {
  run grep -c 'install_mode' "${REPO_ROOT}/.github/workflows/ci.yml"
  [ "${output}" -ge 1 ]
}

@test ".github/workflows/ci.yml contains 'backend-only' matrix value" {
  run grep -c 'backend-only' "${REPO_ROOT}/.github/workflows/ci.yml"
  [ "${output}" -ge 1 ]
}

@test "ci.yml BACKEND_ONLY assignment is conditional on the backend-only matrix leg" {
  # The env var must reference matrix.install_mode (a templated expression),
  # not be a static '1' assignment.
  run grep -E "BACKEND_ONLY:.*matrix.install_mode" "${REPO_ROOT}/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "ci.yml conditionally bundles Brewfile-tui only on default leg" {
  run grep -B1 'Brewfile-tui' "${REPO_ROOT}/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
  # The grep -B1 output should mention 'default' (the matrix value gating it).
  [[ "${output}" == *"default"* ]]
}

@test "README mentions --backend-only at least once" {
  run grep -c -- '--backend-only' "${REPO_ROOT}/README.md"
  [ "${output}" -ge 1 ]
}

@test "README has a Backend-only install subsection" {
  run grep -ic 'backend-only' "${REPO_ROOT}/README.md"
  [ "${output}" -ge 2 ]
}

@test "docs/setup.md has a Backend-only install section with OPENAI_API_BASE_URL example" {
  run grep -c 'Backend-only install' "${REPO_ROOT}/docs/setup.md"
  [ "${output}" -ge 1 ]
  run grep 'OPENAI_API_BASE_URL' "${REPO_ROOT}/docs/setup.md"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"8000/v1"* ]]
}

@test "docs/setup.md mentions --backend-only flag and BACKEND_ONLY env var" {
  run grep -c -- '--backend-only' "${REPO_ROOT}/docs/setup.md"
  [ "${output}" -ge 1 ]
  run grep -c 'BACKEND_ONLY=' "${REPO_ROOT}/docs/setup.md"
  [ "${output}" -ge 1 ]
}
