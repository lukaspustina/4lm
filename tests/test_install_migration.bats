#!/usr/bin/env bats
# Tests for install.sh migration block: mlx-active → active-profile
# and mlx-previous → previous-profile (SDD Phase 1 scenarios S1–S3).

load helpers/setup

INSTALL="${REPO_ROOT}/install.sh"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles"
  # Seed the default profile so install.sh step 5 can symlink to it.
  cp "${REPO_ROOT}/config/profiles/default.yaml" \
    "${HOME}/.4lm/config/profiles/default.yaml"

  export SUDO_LOG="${BATS_TMPDIR}/sudo-calls"
  export PIPX_LOG="${BATS_TMPDIR}/pipx-calls"
  export OLLAMA_LOG="${BATS_TMPDIR}/ollama-calls"
  rm -f "${SUDO_LOG}" "${PIPX_LOG}" "${OLLAMA_LOG}"
}

@test "install.sh: migrates mlx-active symlink to active-profile" {
  local target="${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${target}" "${HOME}/.4lm/config/mlx-active"

  run "${INSTALL}"
  [ "$status" -eq 0 ]

  # New symlink exists and points to the same target.
  [ -L "${HOME}/.4lm/config/active-profile" ]
  [ "$(readlink "${HOME}/.4lm/config/active-profile")" = "${target}" ]
  # Old name is gone.
  [ ! -e "${HOME}/.4lm/config/mlx-active" ]
}

@test "install.sh: migrates mlx-previous file to previous-profile" {
  # Ensure active-profile already exists so migration step for it is a no-op.
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" \
    "${HOME}/.4lm/config/active-profile"

  echo "coding-only" > "${HOME}/.4lm/config/mlx-previous"

  run "${INSTALL}"
  [ "$status" -eq 0 ]

  [ -f "${HOME}/.4lm/config/previous-profile" ]
  [ "$(cat "${HOME}/.4lm/config/previous-profile")" = "coding-only" ]
  [ ! -e "${HOME}/.4lm/config/mlx-previous" ]
}

@test "install.sh: fresh install creates active-profile pointing to default.yaml" {
  # Neither mlx-active nor active-profile exist — verify fresh-install path.
  [ ! -e "${HOME}/.4lm/config/mlx-active" ]
  [ ! -e "${HOME}/.4lm/config/active-profile" ]

  run "${INSTALL}"
  [ "$status" -eq 0 ]

  [ -L "${HOME}/.4lm/config/active-profile" ]
  [[ "$(readlink "${HOME}/.4lm/config/active-profile")" == *"default.yaml" ]]
  [ ! -e "${HOME}/.4lm/config/mlx-active" ]
}

# ---- Phase 5: install.sh Ollama detection (T5.1, T5.2) ---------------------

@test "install.sh: warns when ollama is absent from PATH" {
  # Build a PATH that has all stubs except ollama.
  local stub_dir="${BATS_TEST_DIRNAME}/helpers"
  local bin="${BATS_TMPDIR}/no-ollama"
  mkdir -p "${bin}"
  for s in sudo pipx python3.12 visudo hf sysctl mlx-openai-server curl launchctl; do
    [[ -x "${stub_dir}/${s}" ]] && ln -sfn "${stub_dir}/${s}" "${bin}/${s}"
  done

  run env PATH="${bin}:/usr/bin:/bin" "${INSTALL}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama not found"* ]]
  [[ "$output" == *"brew install ollama"* ]]
}

@test "install.sh: reports ok when ollama is present in PATH" {
  # setup() already prepends tests/helpers/ (which has the ollama stub) to PATH.
  run "${INSTALL}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ollama:"* ]]
}
