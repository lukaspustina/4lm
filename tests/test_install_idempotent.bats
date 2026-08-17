#!/usr/bin/env bats

load helpers/setup

setup() {
  # Disable interactive sudo prompts in the test by stubbing sudo.
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  cat > "${STUB_BIN}/sudo" <<'SH'
#!/usr/bin/env bash
# Discard tee'd output silently.
if [[ "$1" == "tee" ]]; then
  cat > /dev/null
  exit 0
fi
exit 0
SH
  chmod +x "${STUB_BIN}/sudo"

  # Stub pipx so install.sh doesn't try to install real packages.
  # `pipx list --short` returns the lines requirements.txt expects, so the
  # idempotency check sees both pkgs as already-installed.
  #
  # omlx's line is marker-aware (SDD bump-omlx, Requirement 10): when
  # OMLX_INSTALLED_MARKER is set and the file exists, its contents become
  # the reported version — empty contents mean "not installed" (no omlx
  # line at all). Otherwise fall back to the hardcoded 0.3.8 literal, so
  # the pre-existing "runs twice" test (which never seeds the marker)
  # keeps working unmodified.
  #
  # omlx `install` invocations are logged to OMLX_INSTALL_LOG and, when
  # both OMLX_INSTALLED_MARKER and OMLX_INSTALL_RESULT_VERSION are set,
  # simulate a successful install by overwriting the marker file.
  cat > "${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list)
    if [[ -n "${OMLX_INSTALLED_MARKER:-}" && -f "${OMLX_INSTALLED_MARKER}" ]]; then
      omlx_version="$(cat "${OMLX_INSTALLED_MARKER}")"
      [[ -n "${omlx_version}" ]] && echo "omlx ${omlx_version}"
    else
      echo "omlx 0.3.8"
    fi
    echo "open-webui 0.6.43"
    ;;
  install)
    if [[ "$*" == *"omlx.git@"* ]]; then
      echo "$*" >> "${OMLX_INSTALL_LOG:-/dev/null}"
      if [[ -n "${OMLX_INSTALLED_MARKER:-}" && -n "${OMLX_INSTALL_RESULT_VERSION:-}" ]]; then
        echo "${OMLX_INSTALL_RESULT_VERSION}" > "${OMLX_INSTALLED_MARKER}"
      fi
    fi
    ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"

  # Stub python3.12: handles compat-Python check and venv creation.
  cat > "${STUB_BIN}/python3.12" <<'SH'
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
}

@test "install.sh runs twice and produces identical state" {
  # OMLX_INSTALLED_MARKER is deliberately not seeded here (SDD bump-omlx,
  # Requirement 10): the stub falls back to the hardcoded 0.3.8 literal on
  # both runs, and the stub must not error on that unset-marker path.
  [ -z "${OMLX_INSTALLED_MARKER:-}" ]

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  # Snapshot directory listing + symlink target.
  snap1="$(find "${HOME}/.4lm" -mindepth 1 -maxdepth 4 -print 2>/dev/null | sort)"
  link1="$(readlink "${HOME}/.local/bin/4lm")"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  snap2="$(find "${HOME}/.4lm" -mindepth 1 -maxdepth 4 -print 2>/dev/null | sort)"
  link2="$(readlink "${HOME}/.local/bin/4lm")"

  [ "$snap1" = "$snap2" ]
  [ "$link1" = "$link2" ]
}

@test "install.sh installs omlx when absent" {
  git_ref=$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)
  marker="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  : >"${marker}"
  log="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${log}"
  export OMLX_INSTALLED_MARKER="${marker}"
  export OMLX_INSTALL_LOG="${log}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  run grep -c 'omlx.git@' "${log}"
  [ "${output}" = "1" ]

  run grep -c -- "${git_ref}" "${log}"
  [ "${output}" = "1" ]

  run grep -c -- '--force' "${log}"
  [ "${output}" = "0" ]
}

@test "install.sh reports omlx already installed at expected version" {
  marker="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "0.3.9.dev1" >"${marker}"
  log="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${log}"
  export OMLX_INSTALLED_MARKER="${marker}"
  export OMLX_INSTALL_LOG="${log}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  install_output="${output}"

  run grep -c 'omlx.git@' "${log}"
  [ "${output}" = "0" ]

  [[ "${install_output}" == *"0.3.9.dev1"* ]]
  [[ "${install_output}" == *"already installed"* ]]
}

@test "install.sh force-reinstalls omlx when version mismatches" {
  git_ref=$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)
  marker="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "0.3.8" >"${marker}"
  log="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${log}"
  export OMLX_INSTALLED_MARKER="${marker}"
  export OMLX_INSTALL_LOG="${log}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  install_output="${output}"

  run grep -c -- '--force' "${log}"
  [ "${output}" = "1" ]

  run grep -c -- "${git_ref}" "${log}"
  [ "${output}" = "1" ]

  [[ "${install_output}" == *"0.3.8"* ]]
  [[ "${install_output}" == *"0.3.9.dev1"* ]]
}

@test "install.sh converges omlx to expected version across two runs" {
  marker="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "0.3.8" >"${marker}"
  log="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${log}"
  export OMLX_INSTALLED_MARKER="${marker}"
  export OMLX_INSTALL_LOG="${log}"
  export OMLX_INSTALL_RESULT_VERSION="0.3.9.dev1"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  run grep -c 'omlx.git@' "${log}"
  [ "${output}" = "1" ]

  run grep -c -- '--force' "${log}"
  [ "${output}" = "1" ]

  [ "$(cat "${marker}")" = "0.3.9.dev1" ]

  : >"${log}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  run grep -c 'omlx.git@' "${log}"
  [ "${output}" = "0" ]
}
