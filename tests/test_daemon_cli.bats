#!/usr/bin/env bats
# Daemon mode in the CLI: a system plist with UserName switches bin/4lm to the
# system domain. Root handles start/stop/restart and re-executes everything
# else as the service account; the account restarts by signal.

bats_require_minimum_version 1.5.0

load helpers/setup

BIN="${REPO_ROOT}/bin/4lm"
SVC=_svc4lm

setup() {
  mkdir -p "${HOME}/.4lm/launchd" "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
  sed "s|__HOME__|${HOME}|g" "${REPO_ROOT}/launchd/com.4lm.backend.plist" \
    >"${HOME}/.4lm/launchd/com.4lm.backend.plist"

  export FOURLM_DAEMON_PLIST="${BATS_TMPDIR}/daemon-${BATS_TEST_NAME}.plist"
  cp "${HOME}/.4lm/launchd/com.4lm.backend.plist" "${FOURLM_DAEMON_PLIST}"
  plutil -insert UserName -string "${SVC}" "${FOURLM_DAEMON_PLIST}"

  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/id" <<'SH'
#!/usr/bin/env bash
case "$*" in
  -u) echo "${STUB_UID:-$(/usr/bin/id -u)}" ;;
  -un) echo "${STUB_USER:-$(/usr/bin/id -un)}" ;;
  *) exec /usr/bin/id "$@" ;;
esac
SH
  chmod +x "${STUB_BIN}/id"
  export PATH="${STUB_BIN}:${PATH}"
  export SUDO_LOG="${BATS_TMPDIR}/sudo-${BATS_TEST_NAME}.log"
  : >"${SUDO_LOG}"
}

teardown() { [[ -z "${pid:-}" ]] || kill "${pid}" 2>/dev/null || true; }

as_root() { export STUB_UID=0 STUB_USER=root; }
as_svc() { export STUB_UID=450 STUB_USER="${SVC}"; }
as_other() { export STUB_UID=501 STUB_USER=someone; }

# ---- root ------------------------------------------------------------------------

@test "root start bootstraps the system plist" {
  as_root
  run "${BIN}" start
  [ "$status" -eq 0 ]
  grep -qxF "bootstrap system ${FOURLM_DAEMON_PLIST}" "${LAUNCHCTL_LOG}"
}

@test "root start kickstarts an already loaded daemon" {
  as_root
  export LAUNCHCTL_PRINT_OUTPUT="state = running"
  run "${BIN}" start backend
  [ "$status" -eq 0 ]
  grep -qxF "kickstart -k system/com.4lm.backend" "${LAUNCHCTL_LOG}"
  run ! grep -q '^bootstrap' "${LAUNCHCTL_LOG}"
}

@test "root stop boots out the system job" {
  as_root
  export LAUNCHCTL_PRINT_OUTPUT="state = running"
  run "${BIN}" stop
  [ "$status" -eq 0 ]
  grep -qxF "bootout system/com.4lm.backend" "${LAUNCHCTL_LOG}"
}

@test "root restart kickstarts the system job" {
  as_root
  export LAUNCHCTL_PRINT_OUTPUT="state = running"
  run "${BIN}" restart
  [ "$status" -eq 0 ]
  grep -qxF "kickstart -k system/com.4lm.backend" "${LAUNCHCTL_LOG}"
}

@test "root refuses the WebUI in daemon mode" {
  as_root
  run "${BIN}" start webui
  [ "$status" -ne 0 ]
  [[ "$output" == *"no WebUI"* ]] || false
  [ ! -s "${LAUNCHCTL_LOG}" ]
}

@test "root re-executes every other command as the service account" {
  as_root
  run "${BIN}" profile set default
  [ "$status" -eq 0 ]
  grep -qxF -- "-u ${SVC} -H ${BIN} profile set default" "${SUDO_LOG}"
  [ ! -s "${LAUNCHCTL_LOG}" ]
}

@test "root re-executes a bare 4lm as status" {
  as_root
  run "${BIN}"
  [ "$status" -eq 0 ]
  grep -qxF -- "-u ${SVC} -H ${BIN} status" "${SUDO_LOG}"
}

# ---- service account --------------------------------------------------------------

@test "service account refuses start, stop, autostart and uninstall" {
  as_svc
  for c in start stop autostart uninstall; do
    run "${BIN}" "${c}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo"* ]] || false
  done
  [ ! -s "${LAUNCHCTL_LOG}" ]
}

@test "service account queries the system domain" {
  as_svc
  run "${BIN}" status
  grep -q '^print system/com.4lm.backend' "${LAUNCHCTL_LOG}"
  run ! grep -q 'gui/' "${LAUNCHCTL_LOG}"
}

@test "service account restarts by signalling the backend, not by kickstart" {
  as_svc
  pid="$(bash -c 'sleep 300 >/dev/null 2>&1 3>&- & echo $!')"
  export LAUNCHCTL_PRINT_OUTPUT=$'state = running\npid = '"${pid}"
  run "${BIN}" restart backend
  [ "$status" -eq 0 ]
  run ! kill -0 "${pid}"
  run ! grep -q kickstart "${LAUNCHCTL_LOG}"
}

# ---- anyone else ----------------------------------------------------------------------

@test "another user is pointed at sudo" {
  as_other
  run "${BIN}" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo 4lm status"* ]] || false
  [ ! -s "${SUDO_LOG}" ]
}

# ---- no daemon plist ---------------------------------------------------------------------

@test "without a system plist the GUI domain is used" {
  export FOURLM_DAEMON_PLIST="${BATS_TMPDIR}/absent.plist"
  run "${BIN}" stop backend
  run "${BIN}" status
  grep -q "^print gui/$(id -u)/com.4lm.backend" "${LAUNCHCTL_LOG}"
}
