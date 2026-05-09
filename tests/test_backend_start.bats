#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helpers/setup

BACKEND_START="${REPO_ROOT}/bin/4lm-backend-start.sh"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  export OMLX_LOG="${BATS_TMPDIR}/omlx-calls"
  rm -f "${OMLX_LOG}"

  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: local
backend_port: 8000
YAML

  export OLLAMA_LOG="${BATS_TMPDIR}/ollama-calls"
  export MLX_LOG="${BATS_TMPDIR}/mlx-calls"
  export MLXLM_LOG="${BATS_TMPDIR}/mlxlm-calls"
  export SYSCTL_LOG="${BATS_TMPDIR}/sysctl-calls"
  rm -f "${OLLAMA_LOG}" "${MLX_LOG}" "${MLXLM_LOG}" "${SYSCTL_LOG}"
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
backend: mlx
models:
  - model_path: mlx-community/test-model
    served_model_name: test-model
    context_length: 8192
YAML
  ln -sfn "${BATS_TMPDIR}/mlx-test.yaml" "${HOME}/.4lm/config/active-profile"
}

_write_mlxlm_profile() {
  cat > "${BATS_TMPDIR}/mlxlm-test.yaml" <<'YAML'
backend: mlx_lm
models:
  - model_path: mlx-community/gemma-4-26b-a4b-it-4bit
    served_model_name: gemma4-26b
YAML
  ln -sfn "${BATS_TMPDIR}/mlxlm-test.yaml" "${HOME}/.4lm/config/active-profile"
}

@test "ollama profile: ollama serve is called with correct OLLAMA_HOST" {
  _write_ollama_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q "serve" "${OLLAMA_LOG}"
  grep -q "OLLAMA_HOST=127.0.0.1:8000" "${OLLAMA_LOG}"
}

@test "ollama profile: LAN mode sets OLLAMA_HOST to 0.0.0.0" {
  _write_ollama_profile
  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: lan
backend_port: 8000
YAML
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q "OLLAMA_HOST=0.0.0.0:8000" "${OLLAMA_LOG}"
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
  # Note: the wired-memory sysctl block is also entered here but uses
  # /usr/sbin/sysctl with a full path, which bypasses PATH-based stubs.
  # Its invocation cannot be asserted via SYSCTL_LOG in this harness.
  # The negative case (ollama skips the block) is verified in the sysctl test.
}

@test "ollama profile: ollama absent from PATH exits 127 with FATAL message" {
  _write_ollama_profile
  # Remove ollama from PATH by using a PATH without tests/helpers
  run -127 env PATH="/usr/bin:/bin" "${BACKEND_START}"
  [[ "$output" == *"FATAL: ollama not found"* ]]
}

# ---- mlx_lm backend tests ---------------------------------------------------

@test "mlx_lm profile: python3 called with -m mlx_lm server --model --host --port" {
  _write_mlxlm_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "-m mlx_lm server" "${MLXLM_LOG}"
  grep -q -- "--model mlx-community/gemma-4-26b-a4b-it-4bit" "${MLXLM_LOG}"
  grep -q -- "--host 127.0.0.1" "${MLXLM_LOG}"
  grep -q -- "--port 8000" "${MLXLM_LOG}"
}

@test "mlx_lm profile: does not pass --config or --repetition-penalty" {
  _write_mlxlm_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  ! grep -q -- "--config" "${MLXLM_LOG}"
  ! grep -q -- "--repetition-penalty" "${MLXLM_LOG}"
}

@test "mlx_lm profile: LAN mode sets --host 0.0.0.0" {
  _write_mlxlm_profile
  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: lan
backend_port: 8000
YAML
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "--host 0.0.0.0" "${MLXLM_LOG}"
}

@test "mlx_lm profile: python3 absent from venv exits 127 with FATAL message" {
  _write_mlxlm_profile
  # Use a PATH with mlx-openai-server stub but no python3 stub
  local bin="${BATS_TMPDIR}/no-python3"
  mkdir -p "${bin}"
  ln -sfn "${REPO_ROOT}/tests/helpers/mlx-openai-server" "${bin}/mlx-openai-server"
  run -127 env PATH="${bin}:/usr/bin:/bin" "${BACKEND_START}"
  [[ "$output" == *"FATAL: python3 not found"* ]]
}

# ---- Phase 1: inline profile validation -------------------------------------

# ---- omlx backend tests (Phase 1) ------------------------------------------

_write_omlx_profile() {
  cat > "${BATS_TMPDIR}/omlx-test.yaml" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  ln -sfn "${BATS_TMPDIR}/omlx-test.yaml" "${HOME}/.4lm/config/active-profile"
  # backend-start derives model-dir from symlink basename; create the staging dir.
  mkdir -p "${HOME}/.4lm/runtime/omlx-test/models"
}

_write_omlx_profile_with_block() {
  cat > "${BATS_TMPDIR}/omlx-block-test.yaml" <<'YAML'
backend: omlx
omlx:
  max_process_memory: "80%"
  max_model_memory: "100GB"
  hot_cache_max_size: "20%"
  paged_ssd_cache_dir: "~/.4lm/cache/omlx"
  max_concurrent_requests: 8
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  ln -sfn "${BATS_TMPDIR}/omlx-block-test.yaml" "${HOME}/.4lm/config/active-profile"
  mkdir -p "${HOME}/.4lm/runtime/omlx-block-test/models"
}

@test "omlx profile: omlx serve called with --host 127.0.0.1 and --port 8000" {
  _write_omlx_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "--host 127.0.0.1" "${OMLX_LOG}"
  grep -q -- "--port 8000" "${OMLX_LOG}"
}

@test "omlx profile: LAN mode sets --host 0.0.0.0" {
  _write_omlx_profile
  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: lan
backend_port: 8000
YAML
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "--host 0.0.0.0" "${OMLX_LOG}"
}

@test "omlx profile: present omlx: block flags are passed to omlx serve" {
  _write_omlx_profile_with_block
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "--max-process-memory" "${OMLX_LOG}"
  grep -q -- "--max-model-memory" "${OMLX_LOG}"
  grep -q -- "--hot-cache-max-size" "${OMLX_LOG}"
  grep -q -- "--max-concurrent-requests" "${OMLX_LOG}"
}

@test "omlx profile: absent omlx: block means no optional flags in invocation" {
  _write_omlx_profile
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  ! grep -q -- "--max-process-memory" "${OMLX_LOG}"
  ! grep -q -- "--max-model-memory" "${OMLX_LOG}"
  ! grep -q -- "--hot-cache-max-size" "${OMLX_LOG}"
  ! grep -q -- "--paged-ssd-cache-dir" "${OMLX_LOG}"
  ! grep -q -- "--max-concurrent-requests" "${OMLX_LOG}"
}

@test "omlx profile: paged_ssd_cache_dir tilde is expanded to absolute path" {
  _write_omlx_profile_with_block
  run "${BACKEND_START}"
  [ "$status" -eq 0 ]
  grep -q -- "--paged-ssd-cache-dir ${HOME}/.4lm/cache/omlx" "${OMLX_LOG}"
  # Must not contain literal ~
  ! grep -q -- "--paged-ssd-cache-dir ~" "${OMLX_LOG}"
}

@test "omlx profile: paged_ssd_cache_dir with special chars is rejected" {
  cat > "${BATS_TMPDIR}/omlx-badcache.yaml" <<'YAML'
backend: omlx
omlx:
  paged_ssd_cache_dir: "/tmp/x;rm -rf ~"
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  ln -sfn "${BATS_TMPDIR}/omlx-badcache.yaml" "${HOME}/.4lm/config/active-profile"
  run "${BACKEND_START}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid paged_ssd_cache_dir"* ]]
}

@test "omlx profile: paged_ssd_cache_dir with .. component is rejected" {
  cat > "${BATS_TMPDIR}/omlx-traversal.yaml" <<'YAML'
backend: omlx
omlx:
  paged_ssd_cache_dir: "/valid/../../etc"
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  ln -sfn "${BATS_TMPDIR}/omlx-traversal.yaml" "${HOME}/.4lm/config/active-profile"
  run "${BACKEND_START}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid paged_ssd_cache_dir"* ]]
}

@test "backend-start: profile missing models: key exits non-zero with profile+invalid on stderr" {
  cat > "${BATS_TMPDIR}/no-models.yaml" <<'YAML'
backend: mlx
YAML
  ln -sfn "${BATS_TMPDIR}/no-models.yaml" "${HOME}/.4lm/config/active-profile"
  run "${BACKEND_START}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile"* ]] && [[ "$output" == *"invalid"* ]]
}

@test "backend-start: profile missing backend: key exits non-zero with profile+invalid on stderr" {
  cat > "${BATS_TMPDIR}/no-backend.yaml" <<'YAML'
models:
  - model_path: mlx-community/test
    served_model_name: test
    context_length: 4096
YAML
  ln -sfn "${BATS_TMPDIR}/no-backend.yaml" "${HOME}/.4lm/config/active-profile"
  run "${BACKEND_START}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile"* ]] && [[ "$output" == *"invalid"* ]]
}
