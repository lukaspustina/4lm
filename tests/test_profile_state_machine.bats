#!/usr/bin/env bats

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/launchd" "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  cp "${REPO_ROOT}/config/profiles/default.yaml"      "${HOME}/.4lm/config/profiles/default.yaml"
  cp "${REPO_ROOT}/config/profiles/coding-only.yaml"  "${HOME}/.4lm/config/profiles/coding-only.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/active-profile"
  cp "${REPO_ROOT}/config/network.example.yaml"       "${HOME}/.4lm/config/network.yaml"
}

@test "valid profile switch succeeds (backend not loaded → no poll, just symlink swap)" {
  # launchctl print returns non-zero by default → is_loaded false → no poll path.
  run "${REPO_ROOT}/bin/4lm" profile set coding-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"Switched to coding-only"* ]]
  target="$(readlink "${HOME}/.4lm/config/active-profile")"
  [[ "${target}" == *"coding-only.yaml" ]]
}

@test "invalid profile name (path traversal) is rejected before any FS op" {
  pre_target="$(readlink "${HOME}/.4lm/config/active-profile")"
  run "${REPO_ROOT}/bin/4lm" profile set "../../../etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid profile name"* ]]
  [ "$(readlink "${HOME}/.4lm/config/active-profile")" = "${pre_target}" ]
}

@test "invalid profile name (special chars) is rejected" {
  run "${REPO_ROOT}/bin/4lm" profile set 'foo;rm -rf /'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid profile name"* ]]
}

@test "missing profile YAML is rejected" {
  run "${REPO_ROOT}/bin/4lm" profile set nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile not found"* ]]
}

@test "malformed YAML (no models key) is rejected before symlink swap" {
  echo "broken: 1" > "${HOME}/.4lm/config/profiles/broken.yaml"
  pre_target="$(readlink "${HOME}/.4lm/config/active-profile")"
  run "${REPO_ROOT}/bin/4lm" profile set broken
  [ "$status" -eq 1 ]
  [[ "$output" == *"validation failed"* ]] || [[ "${stderr:-}" == *"models:"* ]]
  [ "$(readlink "${HOME}/.4lm/config/active-profile")" = "${pre_target}" ]
}

@test "valid switch succeeds and leaves previous-profile = old profile" {
  run "${REPO_ROOT}/bin/4lm" profile set coding-only
  [ "$status" -eq 0 ]
  [ -f "${HOME}/.4lm/config/previous-profile" ]
  [ "$(cat "${HOME}/.4lm/config/previous-profile")" = "default" ]
}

@test "switch fails to load and rolls back when backend loaded but /v1/models never responds" {
  # Force is_loaded true so the poll path is exercised. curl stub returns failure
  # (default), so the poll times out and rollback should fire. BACKEND_POLL_SECS
  # caps the wait so the test runs in seconds rather than minutes.
  export LAUNCHCTL_PRINT_OUTPUT="state = running
pid = 12345"
  echo "default" > "${HOME}/.4lm/config/previous-profile"
  BACKEND_POLL_SECS=2 run "${REPO_ROOT}/bin/4lm" profile set coding-only
  [ "$status" -eq 1 ]
  target="$(readlink "${HOME}/.4lm/config/active-profile")"
  [[ "${target}" == *"default.yaml" ]]
}

# ---- Ollama backend profile tests (Phase 2) ---------------------------------

@test "ollama profile with only model_path + served_model_name validates (no context_length)" {
  cat > "${HOME}/.4lm/config/profiles/ollama-test.yaml" <<'YAML'
backend: ollama
models:
  - model_path: gemma4:27b
    served_model_name: gemma4-27b
YAML
  run "${REPO_ROOT}/bin/4lm" profile set ollama-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Switched to ollama-test"* ]]
}

@test "ollama profile switch updates active-profile symlink" {
  cat > "${HOME}/.4lm/config/profiles/ollama-test.yaml" <<'YAML'
backend: ollama
models:
  - model_path: gemma4:27b
    served_model_name: gemma4-27b
YAML
  run "${REPO_ROOT}/bin/4lm" profile set ollama-test
  [ "$status" -eq 0 ]
  target="$(readlink "${HOME}/.4lm/config/active-profile")"
  [[ "${target}" == *"ollama-test.yaml" ]]
}

@test "ollama profile with extra mlx fields (context_length) still validates" {
  cat > "${HOME}/.4lm/config/profiles/ollama-extra.yaml" <<'YAML'
backend: ollama
models:
  - model_path: gemma4:27b
    served_model_name: gemma4-27b
    context_length: 8192
YAML
  run "${REPO_ROOT}/bin/4lm" profile set ollama-extra
  [ "$status" -eq 0 ]
}

@test "profile with unknown backend value is rejected" {
  cat > "${HOME}/.4lm/config/profiles/bad-backend.yaml" <<'YAML'
backend: llamacpp
models:
  - model_path: some/model
    served_model_name: mymodel
    context_length: 4096
YAML
  run "${REPO_ROOT}/bin/4lm" profile set bad-backend
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown backend"* ]] || [[ "$output" == *"validation failed"* ]]
}

@test "mlx profile without context_length still fails validation" {
  cat > "${HOME}/.4lm/config/profiles/mlx-noctx.yaml" <<'YAML'
models:
  - model_path: mlx-community/some-model
    served_model_name: mymodel
YAML
  run "${REPO_ROOT}/bin/4lm" profile set mlx-noctx
  [ "$status" -eq 1 ]
  [[ "$output" == *"context_length"* ]] || [[ "$output" == *"validation failed"* ]]
}
