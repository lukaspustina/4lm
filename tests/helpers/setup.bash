#!/usr/bin/env bash
# Common bats setup: stub PATH, isolated $HOME under BATS_TMPDIR.

# Resolve repo root from the test file's directory.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

# Capture real home before sandbox so Python helper path survives the override.
_REAL_4LM_VENV="${HOME}/.4lm/venv/bin/python"

# Prepend stub helpers so launchctl/curl in scripts resolve to stubs.
export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"

# Sandbox HOME per test run — wipe first so state never bleeds across runs.
export HOME="${BATS_TMPDIR}/home-${BATS_TEST_NAME:-default}"
rm -rf "${HOME}" 2>/dev/null || true
mkdir -p "${HOME}"

# Default log file for launchctl stub.
export LAUNCHCTL_LOG="${BATS_TMPDIR}/launchctl.log"
: >"${LAUNCHCTL_LOG}"

# Point 4lm at the real venv so bats tests avoid the python3 PATH stub.
export LLM_HELPERS_PYTHON="${_REAL_4LM_VENV}"

# skip_if_no_webui: skips the current bats test when the webui plist is not
# staged under ${HOME}/.4lm/launchd/. Tests that exercise webui-specific
# behaviour must either (a) stage the plist in their setup, or (b) call this
# helper so they are skipped on a backend-only fixture.
skip_if_no_webui() {
  local plist="${HOME}/.4lm/launchd/com.4lm.webui.plist"
  [[ -f "${plist}" ]] || skip "webui not installed in test fixture"
}
