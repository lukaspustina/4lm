#!/usr/bin/env bash
# Validate each YAML in config/profiles/ using bin/4lm:validate_profile.
# Usage: tests/lint-profiles.sh [path ...]   (default: config/profiles/*.yaml)
# Bash-3.2 compatible (macOS system bash).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/4lm
source "${REPO_ROOT}/bin/4lm"

if [[ $# -gt 0 ]]; then
  targets=("$@")
else
  targets=("${REPO_ROOT}"/config/profiles/*.yaml)
fi

fail=0
for p in "${targets[@]}"; do
  if validate_profile "${p}"; then
    echo "OK   ${p}"
  else
    echo "FAIL ${p}" >&2
    fail=1
  fi
done
exit "${fail}"
