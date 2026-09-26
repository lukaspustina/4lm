#!/usr/bin/env bats
# 4lm no longer touches iogpu.* sysctls
# and removes the sudoers rule it used to install.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"

  # sudo stub: logs every call; performs `rm` so a second run sees the file gone.
  export SUDO_LOG="${BATS_TMPDIR}/sudo-${BATS_TEST_NAME}.log"
  : >"${SUDO_LOG}"
  cat >"${STUB_BIN}/sudo" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${SUDO_LOG}"
case "$1" in
  tee) cat >/dev/null ;;
  rm) shift; /bin/rm -f "$@" ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/sudo"

  cat >"${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "list" ]] && { echo "omlx 0.6.0"; echo "open-webui 0.6.43"; }
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"

  cat >"${STUB_BIN}/python3.12" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-m" && "$2" == "venv" && -n "$3" ]]; then
  mkdir -p "$3/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$3/bin/pip"
  chmod +x "$3/bin/pip"
fi
exit 0
SH
  chmod +x "${STUB_BIN}/python3.12"

  export PATH="${STUB_BIN}:${PATH}"
  export NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-${BATS_TEST_NAME}.conf"
  export LEGACY_SUDOERS_FILE="${BATS_TMPDIR}/sudoers-${BATS_TEST_NAME}"
  rm -f "${LEGACY_SUDOERS_FILE}"
}

@test "mlx_lm wrapper never calls sudo" {
  mkdir -p "${HOME}/.4lm/config" "${HOME}/.4lm/logs"
  printf 'mode: local\nbackend_port: 8000\n' >"${HOME}/.4lm/config/network.yaml"
  cat >"${BATS_TMPDIR}/mlxlm.yaml" <<'YAML'
backend: mlx_lm
models:
  - model_path: mlx-community/test-model
    served_model_name: test-model
YAML
  ln -sfn "${BATS_TMPDIR}/mlxlm.yaml" "${HOME}/.4lm/config/active-profile"
  export MLXLM_LOG="${BATS_TMPDIR}/mlxlm-calls"
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 0 ]
  [ ! -s "${SUDO_LOG}" ]
}

@test "install.sh sets no sysctl and installs no sudoers rule" {
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  run ! grep -q "sysctl -w" "${SUDO_LOG}"
  run ! grep -q "sudoers.d" "${SUDO_LOG}"
  [ ! -e "${LEGACY_SUDOERS_FILE}" ]
}

@test "install.sh removes a legacy sudoers file once" {
  echo "legacy" >"${LEGACY_SUDOERS_FILE}"
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  [ ! -e "${LEGACY_SUDOERS_FILE}" ]
  [ "$(grep -c "^rm .*${LEGACY_SUDOERS_FILE}" "${SUDO_LOG}")" -eq 1 ]

  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  [ "$(grep -c "^rm .*${LEGACY_SUDOERS_FILE}" "${SUDO_LOG}")" -eq 1 ]
}

@test "uninstall.sh removes a legacy sudoers file" {
  echo "legacy" >"${LEGACY_SUDOERS_FILE}"
  run "${REPO_ROOT}/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${LEGACY_SUDOERS_FILE}" ]
}

@test "4lm doctor reports no wired-limit check" {
  "${REPO_ROOT}/install.sh" --backend-only >/dev/null 2>&1
  run "${HOME}/.local/bin/4lm" doctor
  [[ "$output" != *"wired_limit"* ]]
}
