#!/usr/bin/env bats
#
# Phase 1 tests for SDD: 4lm-backend-only.
# Verifies:
#   - Brewfile no longer contains 'opencode'
#   - Brewfile-tui (new file) contains exactly one 'brew "opencode"' line
#   - make bootstrap runs both Brewfiles; BACKEND_ONLY=1 skips Brewfile-tui
#   - make install BACKEND_ONLY=1 forwards --backend-only to install.sh
#   - bin/4lm exposes webui_installed/opencode_installed/require_component
#   - require_component writes WEBUI_MISSING_MSG to stderr verbatim (no die prefix)
#   - tests/helpers/opencode stub is executable
#   - shellcheck + shfmt -d pass on bin/4lm

bats_require_minimum_version 1.5.0
load helpers/setup

readonly EXPECTED_WEBUI_MISSING="WebUI not installed (re-run ./install.sh to enable)"
readonly EXPECTED_OPENCODE_MISSING="OpenCode not installed (re-run ./install.sh to enable)"

@test "Brewfile no longer contains opencode" {
  run grep -c '^brew "opencode"' "${REPO_ROOT}/Brewfile"
  [ "${output}" = "0" ]
}

@test "Brewfile-tui exists and contains exactly one opencode line" {
  [ -f "${REPO_ROOT}/Brewfile-tui" ]
  run grep -c '^brew "opencode"' "${REPO_ROOT}/Brewfile-tui"
  [ "${output}" = "1" ]
}

@test "Brewfile-tui has a comment header explaining its purpose" {
  run head -n 1 "${REPO_ROOT}/Brewfile-tui"
  [[ "${output}" == \#* ]]
}

@test "make bootstrap (no env) runs brew bundle on both Brewfile and Brewfile-tui" {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  RECORD="${BATS_TMPDIR}/brew-record-${BATS_TEST_NAME}"
  : >"${RECORD}"
  cat >"${STUB_BIN}/brew" <<SH
#!/usr/bin/env bash
echo "\$@" >>"${RECORD}"
exit 0
SH
  chmod +x "${STUB_BIN}/brew"
  cat >"${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"
  export PATH="${STUB_BIN}:${PATH}"

  cd "${REPO_ROOT}"
  run make bootstrap
  [ "$status" -eq 0 ]
  run grep -c 'bundle --file=Brewfile$' "${RECORD}"
  [ "${output}" = "1" ]
  run grep -c 'bundle --file=Brewfile-tui' "${RECORD}"
  [ "${output}" = "1" ]
}

@test "make bootstrap BACKEND_ONLY=1 skips Brewfile-tui" {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  RECORD="${BATS_TMPDIR}/brew-record-${BATS_TEST_NAME}"
  : >"${RECORD}"
  cat >"${STUB_BIN}/brew" <<SH
#!/usr/bin/env bash
echo "\$@" >>"${RECORD}"
exit 0
SH
  chmod +x "${STUB_BIN}/brew"
  cat >"${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"
  export PATH="${STUB_BIN}:${PATH}"

  cd "${REPO_ROOT}"
  run make bootstrap BACKEND_ONLY=1
  [ "$status" -eq 0 ]
  run grep -c 'bundle --file=Brewfile$' "${RECORD}"
  [ "${output}" = "1" ]
  run grep -c 'Brewfile-tui' "${RECORD}"
  [ "${output}" = "0" ]
}

@test "make install BACKEND_ONLY=1 passes --backend-only to install.sh" {
  ORIG="${REPO_ROOT}/install.sh"
  BACKUP="${BATS_TMPDIR}/install.sh.real-${BATS_TEST_NAME}"
  RECORD="${BATS_TMPDIR}/install-record-${BATS_TEST_NAME}"
  cp "${ORIG}" "${BACKUP}"
  cat >"${ORIG}" <<SH
#!/usr/bin/env bash
echo "\$@" >>"${RECORD}"
exit 0
SH
  chmod +x "${ORIG}"
  : >"${RECORD}"

  cd "${REPO_ROOT}"
  run make install BACKEND_ONLY=1

  # Restore unconditionally so a failure doesn't leave the repo broken.
  cp "${BACKUP}" "${ORIG}"

  [ "$status" -eq 0 ]
  run grep -c -- '--backend-only' "${RECORD}"
  [ "${output}" = "1" ]
}

@test "webui_installed returns 1 when plist absent" {
  run bash -c "source '${REPO_ROOT}/bin/4lm' && webui_installed"
  [ "$status" -eq 1 ]
}

@test "webui_installed returns 0 when plist present" {
  mkdir -p "${HOME}/.4lm/launchd"
  touch "${HOME}/.4lm/launchd/com.4lm.webui.plist"
  run bash -c "source '${REPO_ROOT}/bin/4lm' && webui_installed"
  [ "$status" -eq 0 ]
}

@test "opencode_installed returns 1 when opencode absent from PATH" {
  # Strip the stub PATH so opencode is unresolvable.
  CLEAN_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v 'tests/helpers' | paste -sd ':' -)"
  run env -i HOME="${HOME}" PATH="${CLEAN_PATH}" bash -c "source '${REPO_ROOT}/bin/4lm' && opencode_installed"
  [ "$status" -eq 1 ]
}

@test "opencode_installed returns 1 when opencode present but config absent" {
  [ -x "${REPO_ROOT}/tests/helpers/opencode" ]
  rm -rf "${HOME}/.config/opencode"
  run bash -c "source '${REPO_ROOT}/bin/4lm' && opencode_installed"
  [ "$status" -eq 1 ]
}

@test "opencode_installed returns 0 when opencode present and config present" {
  mkdir -p "${HOME}/.config/opencode"
  touch "${HOME}/.config/opencode/opencode.jsonc"
  [ -x "${REPO_ROOT}/tests/helpers/opencode" ]
  run bash -c "source '${REPO_ROOT}/bin/4lm' && opencode_installed"
  [ "$status" -eq 0 ]
}

@test "require_component webui writes WEBUI_MISSING_MSG verbatim to stderr (no die prefix)" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/bin/4lm' && require_component webui"
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
  [[ "${stderr}" != error:* ]]
  [[ "${stderr}" != *"$(printf '\033')"* ]]
}

@test "require_component opencode writes OPENCODE_MISSING_MSG and exits 1" {
  CLEAN_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v 'tests/helpers' | paste -sd ':' -)"
  run --separate-stderr env -i HOME="${HOME}" PATH="${CLEAN_PATH}" bash -c "source '${REPO_ROOT}/bin/4lm' && require_component opencode"
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_OPENCODE_MISSING}" ]
}

@test "require_component with unknown name dies" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/bin/4lm' && require_component bogus"
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *"require_component"* ]]
  [[ "${stderr}" == *"unknown component"* ]]
}

@test "tests/helpers/opencode stub exists, is executable, exits 0" {
  [ -f "${REPO_ROOT}/tests/helpers/opencode" ]
  [ -x "${REPO_ROOT}/tests/helpers/opencode" ]
  run "${REPO_ROOT}/tests/helpers/opencode"
  [ "$status" -eq 0 ]
}

@test "shellcheck on bin/4lm is clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
  fi
  run shellcheck "${REPO_ROOT}/bin/4lm"
  [ "$status" -eq 0 ]
}

@test "shfmt diff on bin/4lm is clean" {
  if ! command -v shfmt >/dev/null 2>&1; then
    skip "shfmt not installed"
  fi
  run shfmt -i 2 -ci -d "${REPO_ROOT}/bin/4lm"
  [ "$status" -eq 0 ]
}
