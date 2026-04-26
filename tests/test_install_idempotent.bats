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

  # Stub pip3/pip so install.sh doesn't try to install real packages.
  cat > "${STUB_BIN}/pip3" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "${STUB_BIN}/pip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB_BIN}/pip3" "${STUB_BIN}/pip"

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
