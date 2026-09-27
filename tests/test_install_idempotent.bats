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
  # omlx is commit-aware: install.sh compares the pinned OMLX_GIT_REF with the
  # commit pipx recorded in the package's direct_url.json. The stub keeps that
  # commit in OMLX_INSTALLED_MARKER (empty file = not installed) and renders it
  # into a fake venv tree that `pipx environment --value PIPX_LOCAL_VENVS`
  # points at. Without a marker, omlx counts as installed at the pinned ref, so
  # the "runs twice" test sees a settled install.
  #
  # omlx `install` invocations are logged to OMLX_INSTALL_LOG; with
  # OMLX_INSTALL_RESULT_COMMIT set, a successful install rewrites the marker.
  cat > "${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
venvs="${BATS_TMPDIR}/venvs-${BATS_TEST_NAME// /_}"
ref="$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)"
commit="${ref}"
if [[ -n "${OMLX_INSTALLED_MARKER:-}" && -f "${OMLX_INSTALLED_MARKER}" ]]; then
  commit="$(cat "${OMLX_INSTALLED_MARKER}")"
fi
case "$1" in
  list)
    [[ -n "${commit}" ]] && echo "omlx 0.7.0rc1"
    echo "open-webui 0.6.43"
    ;;
  environment)
    d="${venvs}/omlx/lib/python3.12/site-packages/omlx-0.7.0rc1.dist-info"
    rm -rf "${venvs}"
    if [[ -n "${commit}" && "${commit}" != "none" ]]; then
      mkdir -p "${d}"
      printf '{"url": "https://github.com/jundot/omlx.git", "vcs_info": {"vcs": "git", "commit_id": "%s"}}\n' "${commit}" > "${d}/direct_url.json"
    fi
    echo "${venvs}"
    ;;
  install)
    if [[ "$*" == *"omlx.git@"* ]]; then
      echo "$*" >> "${OMLX_INSTALL_LOG:-/dev/null}"
      if [[ -n "${OMLX_INSTALLED_MARKER:-}" && -n "${OMLX_INSTALL_RESULT_COMMIT:-}" ]]; then
        echo "${OMLX_INSTALL_RESULT_COMMIT}" > "${OMLX_INSTALLED_MARKER}"
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
  # Requirement 10): the stub falls back to the hardcoded 0.7.0rc1 literal on
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
  export OMLX_INSTALLED_MARKER="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALLED_MARKER}"
  export OMLX_INSTALL_LOG="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALL_LOG}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c "omlx.git@${git_ref}" "${OMLX_INSTALL_LOG}")" = "1" ]
  [ "$(grep -c -- '--force' "${OMLX_INSTALL_LOG}")" = "0" ]
}

@test "install.sh leaves omlx alone when the installed commit is the pin" {
  git_ref=$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)
  export OMLX_INSTALLED_MARKER="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "${git_ref}" >"${OMLX_INSTALLED_MARKER}"
  export OMLX_INSTALL_LOG="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALL_LOG}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'omlx.git@' "${OMLX_INSTALL_LOG}")" = "0" ]
  [[ "${output}" == *"omlx already installed"*"${git_ref:0:8}"* ]] || false
}

@test "install.sh force-reinstalls omlx at another commit with the same version" {
  git_ref=$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)
  export OMLX_INSTALLED_MARKER="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "0123456789abcdef0123456789abcdef01234567" >"${OMLX_INSTALLED_MARKER}"
  export OMLX_INSTALL_LOG="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALL_LOG}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "--force.*omlx.git@${git_ref}" "${OMLX_INSTALL_LOG}")" = "1" ]
  [[ "${output}" == *"01234567"*"${git_ref:0:8}"* ]] || false
}

@test "install.sh force-reinstalls omlx whose commit it cannot read" {
  export OMLX_INSTALLED_MARKER="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "none" >"${OMLX_INSTALLED_MARKER}"
  export OMLX_INSTALL_LOG="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALL_LOG}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--force' "${OMLX_INSTALL_LOG}")" = "1" ]
}

@test "install.sh converges omlx to the pinned commit across two runs" {
  git_ref=$(grep -E '^readonly OMLX_GIT_REF=' "${REPO_ROOT}/install.sh" | cut -d'"' -f2)
  export OMLX_INSTALLED_MARKER="${BATS_TMPDIR}/omlx-marker-${BATS_TEST_NAME}"
  echo "0123456789abcdef0123456789abcdef01234567" >"${OMLX_INSTALLED_MARKER}"
  export OMLX_INSTALL_LOG="${BATS_TMPDIR}/omlx-install-log-${BATS_TEST_NAME}"
  : >"${OMLX_INSTALL_LOG}"
  export OMLX_INSTALL_RESULT_COMMIT="${git_ref}"

  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'omlx.git@' "${OMLX_INSTALL_LOG}")" = "1" ]

  : >"${OMLX_INSTALL_LOG}"
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'omlx.git@' "${OMLX_INSTALL_LOG}")" = "0" ]
}
