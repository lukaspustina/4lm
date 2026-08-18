#!/usr/bin/env bats
# Tests for install.sh step 4: an installed profile is never overwritten, and
# drift against the repo version is reported instead of passing silently.

load helpers/setup

INSTALL="${REPO_ROOT}/install.sh"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles"
  # Seed the default profile so install.sh step 5 can symlink to it.
  cp "${REPO_ROOT}/config/profiles/default.yaml" \
    "${HOME}/.4lm/config/profiles/default.yaml"
}

@test "install.sh: reports an installed profile matching the repo as up to date" {
  run "${INSTALL}"
  [ "$status" -eq 0 ]

  [[ "${output}" == *"Profile up to date: default.yaml"* ]]
  [[ "${output}" != *"differs from repo"* ]]
}

@test "install.sh: warns about a drifted profile and leaves it untouched" {
  target="${HOME}/.4lm/config/profiles/default.yaml"
  printf '\n# local drift marker\n' >>"${target}"
  before="$(cat "${target}")"

  run "${INSTALL}"
  [ "$status" -eq 0 ]

  [[ "${output}" == *"Profile differs from repo, not overwriting: default.yaml"* ]]
  [[ "${output}" == *"cp ${REPO_ROOT}/config/profiles/default.yaml ${target}"* ]]
  [ "$(cat "${target}")" = "${before}" ]
}
