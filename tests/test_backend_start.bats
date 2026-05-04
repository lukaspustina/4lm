#!/usr/bin/env bats

load helpers/setup

BACKEND_START="${REPO_ROOT}/bin/4lm-backend-start.sh"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"

  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: local
backend_port: 8000
YAML

  export OLLAMA_LOG="${BATS_TMPDIR}/ollama-calls"
  export MLX_LOG="${BATS_TMPDIR}/mlx-calls"
  export SYSCTL_LOG="${BATS_TMPDIR}/sysctl-calls"
  rm -f "${OLLAMA_LOG}" "${MLX_LOG}" "${SYSCTL_LOG}"
}

_write_ollama_profile() {
  cat > "${BATS_TMPDIR}/ollama-test.yaml" <<'YAML'
backend: ollama
models:
  - model_path: gemma4:27b
    served_model_name: gemma4-27b
YAML
  ln -sfn "${BATS_TMPDIR}/ollama-test.yaml" "${HOME}/.4lm/config/active-profile"
}

_write_mlx_profile() {
  cat > "${BATS_TMPDIR}/mlx-test.yaml" <<'YAML'
models:
  - model_path: mlx-community/test-model
    served_model_name: test-model
    context_length: 8192
YAML
  ln -sfn "${BATS_TMPDIR}/mlx-test.yaml" "${HOME}/.4lm/config/active-profile"
}

@test "ollama profile: ollama serve is called with correct OLLAMA_HOST" {
  _write_ollama_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q "serve" "${OLLAMA_LOG}"
}

@test "ollama profile: sysctl wired-limit block is skipped" {
  _write_ollama_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  # sysctl stub must NOT have been called (wired-limit gated behind mlx check)
  [ ! -s "${SYSCTL_LOG}" ]
}

@test "mlx profile: mlx-openai-server is called with launch --config" {
  _write_mlx_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q "launch --config" "${MLX_LOG}"
}

@test "ollama profile: ollama absent from PATH exits 127 with FATAL message" {
  _write_ollama_profile
  # Remove ollama from PATH by using a PATH without tests/helpers
  run env PATH="/usr/bin:/bin" "${BACKEND_START}"
  [ "$status" -eq 127 ]
  [[ "$output" == *"FATAL: ollama not found"* ]]
}
