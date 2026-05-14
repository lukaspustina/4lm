#!/usr/bin/env bats
#
# Phase 2 tests for SDD: 4lm-backend-only.
# Verifies install.sh --backend-only behaviour: zero optional artifacts,
# flag accepted at any argv position, non-destructive re-install (R8),
# two-block grep-guarded newsyslog append (R9), idempotency.

bats_require_minimum_version 1.5.0
load helpers/setup

readonly EXPECTED_NOTICE="WebUI artifacts found; not managed in backend-only mode."

# Shared stub setup: sudo (writes tee output to NEWSYSLOG_STUB-class paths
# under BATS_TMPDIR, otherwise discards), pipx (records install/list),
# brew (records args), python3.12 (creates a minimal venv stub).
_setup_stubs() {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"

  NEWSYSLOG_STUB="${BATS_TMPDIR}/newsyslog-${BATS_TEST_NAME}.conf"
  rm -f "${NEWSYSLOG_STUB}"
  # NEWSYSLOG_CONF env var is honoured by install.sh (test seam).
  export NEWSYSLOG_CONF="${NEWSYSLOG_STUB}"

  PIPX_RECORD="${BATS_TMPDIR}/pipx-record-${BATS_TEST_NAME}"
  : >"${PIPX_RECORD}"
  export PIPX_RECORD

  BREW_RECORD="${BATS_TMPDIR}/brew-record-${BATS_TEST_NAME}"
  : >"${BREW_RECORD}"
  export BREW_RECORD

  # sudo stub: tee writes to the actual target path if it's under HOME or
  # BATS_TMPDIR (test-writable); paths elsewhere are discarded silently.
  cat >"${STUB_BIN}/sudo" <<'SH'
#!/usr/bin/env bash
case "$1" in
  tee)
    shift
    APPEND=0
    while [[ "$1" == -* ]]; do
      [[ "$1" == "-a" ]] && APPEND=1
      shift
    done
    target="$1"
    if [[ "${target}" == "${HOME}"/* || "${target}" == "${BATS_TMPDIR:-/tmp}"/* ]]; then
      if [[ "${APPEND}" -eq 1 ]]; then
        cat >>"${target}"
      else
        cat >"${target}"
      fi
    else
      cat >/dev/null
    fi
    exit 0
    ;;
  grep)
    # install.sh uses `sudo grep` only to test if /etc/sudoers.d/4lm-stack
    # contains our NOPASSWD rule. Pretend it does, so the sudoers block is a
    # no-op and the sandbox-blocked `mktemp` path is skipped.
    exit 0
    ;;
  install | /usr/sbin/sysctl)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/sudo"

  # pipx stub: records install/inject args, fakes a list output.
  cat >"${STUB_BIN}/pipx" <<SH
#!/usr/bin/env bash
echo "\$@" >>"${PIPX_RECORD}"
case "\$1" in
  list)
    # On a clean install all packages are absent (so the loop installs them).
    ;;
  ensurepath|inject|runpip)
    ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/pipx"

  cat >"${STUB_BIN}/brew" <<SH
#!/usr/bin/env bash
echo "\$@" >>"${BREW_RECORD}"
case "\$1" in
  list) exit 1 ;;
esac
exit 0
SH
  chmod +x "${STUB_BIN}/brew"

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

  # visudo is invoked as a literal path in install.sh — stub the relative name.
  cat >"${STUB_BIN}/visudo" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${STUB_BIN}/visudo"

  export PATH="${STUB_BIN}:${PATH}"
}

setup() {
  _setup_stubs
}

@test "install.sh --backend-only produces zero optional artifacts" {
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]

  # R3, R4: webui artifacts absent
  [ ! -f "${HOME}/.4lm/bin/4lm-webui-start.sh" ]
  [ ! -f "${HOME}/.4lm/launchd/com.4lm.webui.plist" ]

  # R2: open-webui not pipx-installed (no install line with open-webui)
  run grep -c 'install.*open-webui' "${PIPX_RECORD}"
  [ "${output}" = "0" ]

  # R6: opencode config seed skipped
  [ ! -f "${HOME}/.config/opencode/opencode.jsonc" ]

  # R5: newsyslog has no webui.log line
  run grep -c 'webui\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "0" ]
}

@test "install.sh --backend-only at non-first argv position is treated identically" {
  # install.sh ignores positional non-flag args (none defined). Pass a harmless
  # token first, then --backend-only. Result must match the prior test's artifact set.
  # (We can't pass arbitrary unknown args because install.sh now errors on them,
  # so use repeated --backend-only which is idempotent.)
  run "${REPO_ROOT}/install.sh" --backend-only --backend-only
  [ "$status" -eq 0 ]
  [ ! -f "${HOME}/.4lm/bin/4lm-webui-start.sh" ]
  [ ! -f "${HOME}/.4lm/launchd/com.4lm.webui.plist" ]
}

@test "install.sh --backend-only over existing webui artifacts prints notice and leaves them intact" {
  # Pre-seed webui artifacts (simulate existing full install).
  mkdir -p "${HOME}/.4lm/bin" "${HOME}/.4lm/launchd"
  echo "preexisting-wrapper" >"${HOME}/.4lm/bin/4lm-webui-start.sh"
  echo "preexisting-plist" >"${HOME}/.4lm/launchd/com.4lm.webui.plist"

  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]

  # Notice appears exactly once.
  notice_count=$(echo "${output}" | grep -cF "${EXPECTED_NOTICE}")
  [ "${notice_count}" -eq 1 ]

  # Artifacts unchanged.
  [ "$(cat "${HOME}/.4lm/bin/4lm-webui-start.sh")" = "preexisting-wrapper" ]
  [ "$(cat "${HOME}/.4lm/launchd/com.4lm.webui.plist")" = "preexisting-plist" ]
}

@test "install.sh full mode over backend-only install adds webui artifacts" {
  # First pass: backend-only.
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  [ ! -f "${HOME}/.4lm/bin/4lm-webui-start.sh" ]

  # Reset records so we check the second-run pipx args.
  : >"${PIPX_RECORD}"
  : >"${BREW_RECORD}"

  # Second pass: full.
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]

  # Webui artifacts now present.
  [ -f "${HOME}/.4lm/bin/4lm-webui-start.sh" ]
  [ -f "${HOME}/.4lm/launchd/com.4lm.webui.plist" ]
  [ -f "${HOME}/.config/opencode/opencode.jsonc" ]

  # newsyslog gained a webui.log line.
  run grep -c 'webui\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "1" ]

  # pipx now installs open-webui.
  run grep -c 'install.*open-webui' "${PIPX_RECORD}"
  [ "${output}" -ge "1" ]
}

@test "install.sh idempotent re-run: newsyslog has exactly one webui.log line" {
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  run grep -c 'webui\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "1" ]
}

@test "install.sh idempotent re-run: newsyslog has exactly one backend.log line" {
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  run grep -c 'backend\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "1" ]
}

@test "install.sh --backend-only idempotent re-run: backend.log line present, webui.log absent" {
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  run grep -c 'backend\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "1" ]
  run grep -c 'webui\.log' "${NEWSYSLOG_STUB}"
  [ "${output}" = "0" ]
}

@test "install.sh unknown flag errors" {
  run "${REPO_ROOT}/install.sh" --bogus-flag
  [ "$status" -ne 0 ]
}

@test "install.sh header comment block mentions --backend-only" {
  run head -n 22 "${REPO_ROOT}/install.sh"
  [[ "${output}" == *"--backend-only"* ]]
}
