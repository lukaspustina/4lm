#!/usr/bin/env bats
#
# Shared tests/helpers/pipx stub: `list --short` behaviour (SDD
# bump-omlx.md, Requirement 8/11). Asserted directly against the shared
# stub, not the local override in tests/test_install_idempotent.bats.

bats_require_minimum_version 1.5.0
load helpers/setup

@test "pipx stub: list --short emits PIPX_LIST_SHORT verbatim when set" {
  export PIPX_LIST_SHORT="omlx 0.6.0
open-webui 0.6.43"
  run pipx list --short
  [ "$status" -eq 0 ]
  [ "$output" = "${PIPX_LIST_SHORT}" ]
}

@test "pipx stub: list --short emits nothing when PIPX_LIST_SHORT is unset" {
  unset PIPX_LIST_SHORT
  run pipx list --short
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pipx stub: unrelated invocation still logs and exits 0" {
  export PIPX_LOG="${BATS_TMPDIR}/pipx-calls-${BATS_TEST_NAME}"
  : >"${PIPX_LOG}"
  run pipx install foo
  [ "$status" -eq 0 ]
  grep -qF "install foo" "${PIPX_LOG}"
}
