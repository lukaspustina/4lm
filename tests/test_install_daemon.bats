#!/usr/bin/env bats
# install.sh --daemon <user>: root installs the system pieces and runs the
# regular backend-only install as the account (--service).

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  SVC="$(/usr/bin/id -un)"
  SVC_HOME="${BATS_TMPDIR}/svc-home-${BATS_TEST_NAME}"
  rm -rf "${SVC_HOME}" && mkdir -p "${SVC_HOME}"

  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  rm -rf "${STUB_BIN}" && mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/id" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "-u" ]] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
SH
  cat >"${STUB_BIN}/dscl" <<'SH'
#!/usr/bin/env bash
echo "NFSHomeDirectory: ${STUB_SVC_HOME}"
SH
  cat >"${STUB_BIN}/chown" <<'SH'
#!/usr/bin/env bash
echo "chown $*" >>"${CHOWN_LOG}"
SH
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"
  export STUB_SVC_HOME="${SVC_HOME}"
  export CHOWN_LOG="${BATS_TMPDIR}/chown-${BATS_TEST_NAME}.log"
  export SUDO_LOG="${BATS_TMPDIR}/sudo-${BATS_TEST_NAME}.log"
  export FOURLM_DAEMON_PLIST="${BATS_TMPDIR}/daemon-${BATS_TEST_NAME}.plist"
  export FOURLM_SYSTEM_BIN="${BATS_TMPDIR}/sysbin-${BATS_TEST_NAME}"
  export NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-${BATS_TEST_NAME}.conf"
  export FOURLM_DAEMON_NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-daemon-${BATS_TEST_NAME}.conf"
  rm -f "${CHOWN_LOG}" "${SUDO_LOG}" "${FOURLM_DAEMON_PLIST}" "${NEWSYSLOG_CONF}" "${FOURLM_DAEMON_NEWSYSLOG_CONF}"
  rm -rf "${FOURLM_SYSTEM_BIN}"
}

install_daemon() { run "${REPO_ROOT}/install.sh" --daemon "${SVC}"; }

# ---- fail fast ---------------------------------------------------------------------

@test "--daemon without root fails before touching anything" {
  export STUB_UID=501
  install_daemon
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo"* ]] || false
  [ ! -e "${FOURLM_DAEMON_PLIST}" ]
  [ ! -e "${SUDO_LOG}" ]
}

@test "--daemon for a missing account fails" {
  run "${REPO_ROOT}/install.sh" --daemon no_such_account_4lm
  [ "$status" -ne 0 ]
  [[ "$output" == *"no_such_account_4lm"* ]] || false
  [ ! -e "${FOURLM_DAEMON_PLIST}" ]
}

@test "--daemon fails when the account's home is missing" {
  rmdir "${SVC_HOME}"
  install_daemon
  [ "$status" -ne 0 ]
  [[ "$output" == *"home"* ]] || false
  [ ! -e "${FOURLM_DAEMON_PLIST}" ]
}

@test "--daemon requires a user argument" {
  run "${REPO_ROOT}/install.sh" --daemon
  [ "$status" -ne 0 ]
}

# ---- what it installs ------------------------------------------------------------------

@test "--daemon runs the account install as the account" {
  install_daemon
  [ "$status" -eq 0 ]
  grep -qE -- "^-u ${SVC} -H .*${REPO_ROOT}/install.sh --service$" "${SUDO_LOG}"
}

@test "--daemon writes the system plist with UserName and the account's home" {
  install_daemon
  [ "$status" -eq 0 ]
  [ "$(plutil -extract UserName raw -o - "${FOURLM_DAEMON_PLIST}")" = "${SVC}" ]
  [ "$(plutil -extract WorkingDirectory raw -o - "${FOURLM_DAEMON_PLIST}")" = "${SVC_HOME}/.4lm" ]
  run ! grep -q __HOME__ "${FOURLM_DAEMON_PLIST}"
  grep -qxF "chown root:wheel ${FOURLM_DAEMON_PLIST}" "${CHOWN_LOG}"
  [ "$(stat -f %Lp "${FOURLM_DAEMON_PLIST}")" = "644" ]
}

@test "--daemon installs a root-owned CLI copy, not a link into the account's home" {
  install_daemon
  [ "$status" -eq 0 ]
  [ -f "${FOURLM_SYSTEM_BIN}/4lm" ]
  [ ! -L "${FOURLM_SYSTEM_BIN}/4lm" ]
  cmp -s "${REPO_ROOT}/bin/4lm" "${FOURLM_SYSTEM_BIN}/4lm"
  grep -qxF "chown root:wheel ${FOURLM_SYSTEM_BIN}/4lm" "${CHOWN_LOG}"
  [ "$(stat -f %Lp "${FOURLM_SYSTEM_BIN}/4lm")" = "755" ]
}

@test "--daemon adds one newsyslog entry owned by the account, in its own file" {
  install_daemon
  install_daemon
  [ "$status" -eq 0 ]
  [ "$(grep -c "^${SVC_HOME}/.4lm/logs/backend.log[[:space:]]\+${SVC}:" "${FOURLM_DAEMON_NEWSYSLOG_CONF}")" -eq 1 ]
  # The GUI uninstaller deletes the shared file; the daemon entry must not live there.
  [ ! -e "${NEWSYSLOG_CONF}" ]
}

@test "--daemon does not bootstrap the daemon" {
  install_daemon
  [ "$status" -eq 0 ]
  run ! grep -q bootstrap "${LAUNCHCTL_LOG}"
}

@test "--daemon leaves the invoking user's home alone" {
  install_daemon
  [ "$status" -eq 0 ]
  [ ! -e "${HOME}/.4lm" ]
  [ ! -e "${HOME}/.local/bin/4lm" ]
}

# ---- account side (--service) ------------------------------------------------------------

_service_install() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/pipx"
  cat >"${STUB_BIN}/python3.12" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-m" && "$2" == "venv" && -n "$3" ]]; then
  mkdir -p "$3/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$3/bin/pip"; chmod +x "$3/bin/pip"
fi
exit 0
SH
  chmod +x "${STUB_BIN}"/*
  export STUB_UID=450 LEGACY_SUDOERS_FILE="${BATS_TMPDIR}/sudoers-${BATS_TEST_NAME}"
  touch "${LEGACY_SUDOERS_FILE}"
  run "${REPO_ROOT}/install.sh" --service
}

@test "--service is a backend-only install in the account's home" {
  _service_install
  [ "$status" -eq 0 ]
  [ -f "${HOME}/.4lm/bin/4lm-backend-start.sh" ]
  [ -f "${HOME}/.4lm/launchd/com.4lm.backend.plist" ]
  [ ! -e "${HOME}/.4lm/launchd/com.4lm.webui.plist" ]
  [ -s "${HOME}/.4lm/config/api-key" ]
}

@test "--service skips everything that needs root or a GUI user" {
  _service_install
  [ "$status" -eq 0 ]
  [ ! -e "${HOME}/.local/bin/4lm" ]
  [ ! -e "${NEWSYSLOG_CONF}" ]
  [ -e "${LEGACY_SUDOERS_FILE}" ]
  [ ! -e "${SUDO_LOG}" ]
  [ ! -e "${HOME}/.config/opencode" ]
}
