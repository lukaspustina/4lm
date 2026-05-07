#!/usr/bin/env bats
# Tests that install.sh creates the helpers venv and installs requirements.

load helpers/setup

PIP_LOG="${BATS_TMPDIR}/pip-calls"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles"
  cp "${REPO_ROOT}/config/profiles/default.yaml" \
    "${HOME}/.4lm/config/profiles/default.yaml"

  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"

  cat > "${STUB_BIN}/sudo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "tee" ]] && { cat > /dev/null; exit 0; }
exit 0
SH
  chmod +x "${STUB_BIN}/sudo"

  cat > "${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list)
    echo "mlx-openai-server 1.7.1"
    echo "open-webui 0.6.43"
    ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"

  # python3.12 stub: creates a real-ish venv with a logging pip.
  cat > "${STUB_BIN}/python3.12" <<SH
#!/usr/bin/env bash
if [[ "\$1" == "-m" && "\$2" == "venv" && -n "\$3" ]]; then
  mkdir -p "\$3/bin"
  cat > "\$3/bin/pip" <<'PIPSH'
#!/usr/bin/env bash
echo "\$*" >> "${PIP_LOG}"
exit 0
PIPSH
  chmod +x "\$3/bin/pip"
fi
exit 0
SH
  chmod +x "${STUB_BIN}/python3.12"

  export PATH="${STUB_BIN}:${PATH}"
  rm -f "${PIP_LOG}"
}

@test "install.sh creates helpers venv at ~/.4lm/venv" {
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [ -d "${HOME}/.4lm/venv/bin" ]
}

@test "install.sh installs requirements-helpers.txt into venv" {
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  grep -q "requirements-helpers.txt" "${PIP_LOG}"
}
