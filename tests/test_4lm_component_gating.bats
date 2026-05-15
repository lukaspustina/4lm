#!/usr/bin/env bats
#
# Phase 3 tests for SDD: 4lm-backend-only.
# Verifies bin/4lm runtime gating of webui- and opencode-targeted commands
# based on plist existence and opencode_installed.

bats_require_minimum_version 1.5.0
load helpers/setup

readonly EXPECTED_WEBUI_MISSING="WebUI not installed (re-run ./install.sh to enable)"
readonly EXPECTED_OPENCODE_MISSING="OpenCode not installed (re-run ./install.sh to enable)"
readonly NO_COMPONENTS_MSG="no components installed"

# 4lm binary under test.
FLM="${REPO_ROOT}/bin/4lm"

setup() {
  # Seed network.yaml so net_*_port helpers don't blow up.
  mkdir -p "${HOME}/.4lm/config"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
}

_stage_backend_plist() {
  mkdir -p "${HOME}/.4lm/launchd"
  touch "${HOME}/.4lm/launchd/com.4lm.backend.plist"
}

_stage_webui_plist() {
  mkdir -p "${HOME}/.4lm/launchd"
  touch "${HOME}/.4lm/launchd/com.4lm.webui.plist"
}

# ---------- Webui-gated commands (plist absent) ----------------------------

@test "4lm start webui with no plist: WEBUI_MISSING_MSG to stderr, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" start webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm stop webui with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" stop webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm restart webui with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" restart webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm logs webui with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" logs webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm open with no arg and no webui plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" open
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm open webui (explicit) with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" open webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm autostart enable webui with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" autostart enable webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

@test "4lm autostart disable webui with no plist: WEBUI_MISSING_MSG, exit 1" {
  _stage_backend_plist
  run --separate-stderr "${FLM}" autostart disable webui
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_WEBUI_MISSING}" ]
}

# ---------- OpenCode-gated commands ---------------------------------------

@test "4lm opencode with opencode absent: OPENCODE_MISSING_MSG, exit 1" {
  _stage_backend_plist
  # Strip tests/helpers from PATH so opencode is unresolvable.
  CLEAN_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v 'tests/helpers' | paste -sd ':' -)"
  run --separate-stderr env PATH="${CLEAN_PATH}" HOME="${HOME}" "${FLM}" opencode
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_OPENCODE_MISSING}" ]
}

@test "4lm code (alias) with opencode absent: OPENCODE_MISSING_MSG, exit 1" {
  _stage_backend_plist
  CLEAN_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v 'tests/helpers' | paste -sd ':' -)"
  run --separate-stderr env PATH="${CLEAN_PATH}" HOME="${HOME}" "${FLM}" code
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_OPENCODE_MISSING}" ]
}

@test "4lm opencode with binary present but config absent: OPENCODE_MISSING_MSG, exit 1" {
  _stage_backend_plist
  [ ! -f "${HOME}/.config/opencode/opencode.jsonc" ]
  run --separate-stderr "${FLM}" opencode
  [ "$status" -eq 1 ]
  [ "${stderr}" = "${EXPECTED_OPENCODE_MISSING}" ]
}

# ---------- All-target iteration -----------------------------------------

@test "4lm start all: both plists absent -> no components installed, exit 1" {
  rm -rf "${HOME}/.4lm/launchd"
  run --separate-stderr "${FLM}" start all
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *"${NO_COMPONENTS_MSG}"* ]]
}

@test "4lm start all: backend only present -> succeeds, no webui error" {
  _stage_backend_plist
  run "${FLM}" start all
  [ "$status" -eq 0 ]
  [[ "${output}" != *"${EXPECTED_WEBUI_MISSING}"* ]]
}

@test "4lm start all: backend launchctl fails -> exit 1 (R18 partial-failure path)" {
  _stage_backend_plist
  # Per-test launchctl override: bootstrap returns 1 with stderr message.
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  print) exit 1 ;;
  bootstrap)
    echo "launchctl: bootstrap failed (test stub)" >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/launchctl"
  export PATH="${STUB_BIN}:${PATH}"

  run "${FLM}" start all
  [ "$status" -eq 1 ]
}

# ---------- Status output -------------------------------------------------

@test "4lm status (no webui plist): text output contains no 'webui' or 'WebUI'" {
  _stage_backend_plist
  run "${FLM}" status
  [ "$status" -eq 0 ]
  # Case-insensitive substring check via tr (bash 3.2 compatible).
  lower="$(echo "${output}" | tr '[:upper:]' '[:lower:]')"
  [[ "${lower}" != *"webui"* ]]
}

@test "4lm status (no webui plist): JSON output has no 'webui' key" {
  _stage_backend_plist
  run "${FLM}" status --json
  [ "$status" -eq 0 ]
  # webui_port (network block) is allowed; "webui" as a JSON key under
  # autostart/services/http is not.
  [[ "${output}" != *'"webui":'* ]]
}

@test "4lm status (webui plist present): JSON output has 'webui' keys" {
  _stage_backend_plist
  _stage_webui_plist
  run "${FLM}" status --json
  [ "$status" -eq 0 ]
  [[ "${output}" == *'"webui":'* ]]
}

@test "4lm status (no webui plist): autostart line has no webui state" {
  _stage_backend_plist
  run "${FLM}" status
  [ "$status" -eq 0 ]
  # Autostart line should appear and reference backend only.
  echo "${output}" | grep '^Autostart:' | grep -qv 'webui'
}

# ---------- Doctor probe gating ------------------------------------------

@test "4lm doctor (no webui plist, no opencode): no 'open-webui not in PATH' failure" {
  _stage_backend_plist
  CLEAN_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v 'tests/helpers' | paste -sd ':' -)"
  run env PATH="${CLEAN_PATH}" HOME="${HOME}" "${FLM}" doctor
  # Doctor exits non-zero for many reasons (wired memory, missing network.yaml,
  # etc.) — we only check that webui/opencode aren't named in the failures.
  [[ "${output}" != *"open-webui not in PATH"* ]]
  [[ "${output}" != *"opencode not in PATH"* ]]
  [[ "${output}" != *"missing ${HOME}/.4lm/launchd/com.4lm.webui.plist"* ]]
}

# ---------- require_component placement ---------------------------------

@test "all-target start with both plists absent: exit before iterating" {
  rm -rf "${HOME}/.4lm/launchd"
  # Even if launchctl would succeed for the backend, the no-components check
  # fires first.
  run --separate-stderr "${FLM}" start all
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *"${NO_COMPONENTS_MSG}"* ]]
}
