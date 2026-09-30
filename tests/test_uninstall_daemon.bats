#!/usr/bin/env bats
# uninstall.sh --daemon: removes the system pieces only. The account and its
# home — install, config, downloaded models — stay.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  rm -rf "${STUB_BIN}" && mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/id" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "-u" ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
SH
  chmod +x "${STUB_BIN}/id"
  export PATH="${STUB_BIN}:${PATH}"

  export FOURLM_DAEMON_PLIST="${BATS_TMPDIR}/daemon-${BATS_TEST_NAME}.plist"
  export FOURLM_SYSTEM_BIN="${BATS_TMPDIR}/sysbin-${BATS_TEST_NAME}"
  export FOURLM_DAEMON_NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-daemon-${BATS_TEST_NAME}.conf"
  export SUDO_LOG="${BATS_TMPDIR}/sudo-${BATS_TEST_NAME}.log"
  rm -f "${SUDO_LOG}"
  sed "s|__HOME__|${HOME}|g" "${REPO_ROOT}/launchd/com.4lm.backend.plist" >"${FOURLM_DAEMON_PLIST}"
  mkdir -p "${FOURLM_SYSTEM_BIN}" "${HOME}/.4lm/config" "${HOME}/.cache/huggingface/hub"
  cp "${REPO_ROOT}/bin/4lm" "${FOURLM_SYSTEM_BIN}/4lm"
  echo "x" >"${FOURLM_DAEMON_NEWSYSLOG_CONF}"
  echo "key" >"${HOME}/.4lm/config/api-key"
}

@test "--daemon without root fails and removes nothing" {
  export STUB_UID=501
  run "${REPO_ROOT}/uninstall.sh" --daemon
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo"* ]] || false
  [ -f "${FOURLM_DAEMON_PLIST}" ]
  [ -f "${FOURLM_SYSTEM_BIN}/4lm" ]
}

@test "--daemon boots out a loaded daemon" {
  export LAUNCHCTL_PRINT_OUTPUT="state = running"
  run "${REPO_ROOT}/uninstall.sh" --daemon
  [ "$status" -eq 0 ]
  grep -qxF "bootout system/com.4lm.backend" "${LAUNCHCTL_LOG}"
}

@test "--daemon removes the system plist, CLI copy and newsyslog file" {
  run "${REPO_ROOT}/uninstall.sh" --daemon
  [ "$status" -eq 0 ]
  [ ! -e "${FOURLM_DAEMON_PLIST}" ]
  [ ! -e "${FOURLM_SYSTEM_BIN}/4lm" ]
  [ ! -e "${FOURLM_DAEMON_NEWSYSLOG_CONF}" ]
}

@test "--daemon leaves the account's home and models alone" {
  run "${REPO_ROOT}/uninstall.sh" --daemon
  [ "$status" -eq 0 ]
  [ -f "${HOME}/.4lm/config/api-key" ]
  [ -d "${HOME}/.cache/huggingface/hub" ]
  [ ! -e "${SUDO_LOG}" ]
}

@test "--daemon is idempotent" {
  run "${REPO_ROOT}/uninstall.sh" --daemon
  run "${REPO_ROOT}/uninstall.sh" --daemon
  [ "$status" -eq 0 ]
}
