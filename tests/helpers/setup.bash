#!/usr/bin/env bash
# Common bats setup: stub PATH, isolated $HOME under BATS_TMPDIR.

# Resolve repo root from the test file's directory.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

# Prepend stub helpers so launchctl/curl in scripts resolve to stubs.
export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"

# Sandbox HOME per test run.
export HOME="${BATS_TMPDIR}/home-${BATS_TEST_NAME:-default}"
mkdir -p "${HOME}"

# Default log file for launchctl stub.
export LAUNCHCTL_LOG="${BATS_TMPDIR}/launchctl.log"
: > "${LAUNCHCTL_LOG}"
