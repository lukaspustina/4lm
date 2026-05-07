#!/usr/bin/env bats
# Tests for bin/4lm-webui-start.sh security invariants.

bats_require_minimum_version 1.5.0

setup() {
  export HOME="${BATS_TMPDIR}/home"
  rm -rf "${HOME}"
  mkdir -p "${HOME}/.4lm/config" "${HOME}/.4lm/logs"
  export LLM_HOME="${HOME}/.4lm"
  export ACTIVE_CONFIG="${LLM_HOME}/config/active-profile"
  # Minimal network.yaml
  printf 'mode: local\nbackend_port: 8080\nwebui_port: 3000\n' \
    >"${LLM_HOME}/config/network.yaml"
  # Stub open-webui first on PATH
  export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"
}

@test "registration disabled: env contains WEBUI_REGISTRATION_ENABLED=false" {
  run "${BATS_TEST_DIRNAME}/../bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  grep -qx 'WEBUI_REGISTRATION_ENABLED=false' "${BATS_TMPDIR}/open-webui.env"
}

@test "default role pending: env contains DEFAULT_USER_ROLE=pending" {
  run "${BATS_TEST_DIRNAME}/../bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  grep -qx 'DEFAULT_USER_ROLE=pending' "${BATS_TMPDIR}/open-webui.env"
}

@test "secret key from existing file: env contains WEBUI_SECRET_KEY=known-secret" {
  printf 'known-secret' >"${HOME}/.4lm/config/webui_secret_key"
  chmod 600 "${HOME}/.4lm/config/webui_secret_key"
  run "${BATS_TEST_DIRNAME}/../bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  grep -qx 'WEBUI_SECRET_KEY=known-secret' "${BATS_TMPDIR}/open-webui.env"
}

@test "secret key generated and persisted when file absent" {
  rm -f "${HOME}/.4lm/config/webui_secret_key"
  run "${BATS_TEST_DIRNAME}/../bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  # Non-empty WEBUI_SECRET_KEY in captured env
  grep -q 'WEBUI_SECRET_KEY=.' "${BATS_TMPDIR}/open-webui.env"
  # File was created
  [ -f "${HOME}/.4lm/config/webui_secret_key" ]
  # File has 600 permissions (stat -f %Lp on macOS returns without leading zero)
  [ "$(stat -f %Lp "${HOME}/.4lm/config/webui_secret_key")" = "600" ]
}

@test "non-numeric webui_port falls back to 3000" {
  printf 'mode: local\nbackend_port: 8080\nwebui_port: notanumber\n' \
    >"${LLM_HOME}/config/network.yaml"
  run "${BATS_TEST_DIRNAME}/../bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--port 3000' "${BATS_TMPDIR}/open-webui.args"
}
