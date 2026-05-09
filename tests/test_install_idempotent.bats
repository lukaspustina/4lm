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
  cat > "${STUB_BIN}/pipx" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list)
    echo "omlx 0.3.8"
    echo "open-webui 0.6.43"
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
