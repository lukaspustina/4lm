#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/launchd" "${HOME}/.4lm/logs"
  cp "${REPO_ROOT}/config/profiles/mlx-coding.yaml" "${HOME}/.4lm/config/profiles/mlx-coding.yaml"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
  # Create placeholder plist files so doctor doesn't fail on missing plists
  touch "${HOME}/.4lm/launchd/com.4lm.backend.plist"
  touch "${HOME}/.4lm/launchd/com.4lm.webui.plist"
}

_make_omlx_active_profile() {
  cat > "${HOME}/.4lm/config/profiles/omlx-test.yaml" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  ln -sfn "${HOME}/.4lm/config/profiles/omlx-test.yaml" \
    "${HOME}/.4lm/config/active-profile"
}

# ---- Phase 1: dispatch guard and green path ---------------------------------

@test "4lm doctor phase3-ready routes to cmd_doctor_phase3_ready (does not run full doctor)" {
  _make_omlx_active_profile
  # Full doctor would fail (mlx-openai-server not in PATH in test env).
  # phase3-ready is read-only and must not run the full doctor preamble.
  run "${REPO_ROOT}/bin/4lm" doctor phase3-ready
  # Must produce green or red, not the full doctor header
  [[ "$output" != *"─── 4lm Doctor ───"* ]]
  # Must exit 0 or 1 (not 127)
  [ "$status" -ne 127 ]
}

@test "phase3-ready: absent rollback log + omlx active profile exits 0 with green" {
  _make_omlx_active_profile
  # No rollback log exists
  rm -f "${HOME}/.4lm/logs/profile-rollback.log"
  run "${REPO_ROOT}/bin/4lm" doctor phase3-ready
  [ "$status" -eq 0 ]
  [[ "$output" == green:* ]]
}

@test "phase3-ready: empty rollback log + omlx active profile exits 0 with green" {
  _make_omlx_active_profile
  : > "${HOME}/.4lm/logs/profile-rollback.log"
  run "${REPO_ROOT}/bin/4lm" doctor phase3-ready
  [ "$status" -eq 0 ]
  [[ "$output" == green:* ]]
}

# ---- Phase 3: red-path cases (marked pending until Phase 3 code lands) -----

@test "phase3-ready: rollback log entry newer than active-profile symlink exits 1 with red" {
  skip "Phase 3 red-path: requires log-vs-mtime comparison code"
  _make_omlx_active_profile
  sleep 0.1
  # Write a rollback log entry with a current timestamp (newer than the symlink)
  printf '%s\tmlx-coding\tomlx-test\tpoll_timeout\n' "$(date -Iseconds)" \
    > "${HOME}/.4lm/logs/profile-rollback.log"
  run "${REPO_ROOT}/bin/4lm" doctor phase3-ready
  [ "$status" -eq 1 ]
  [[ "$output" == red:* ]]
}

@test "phase3-ready: active profile has backend: ollama exits 1 with red" {
  skip "Phase 3 red-path: requires backend check code"
  cat > "${HOME}/.4lm/config/profiles/ollama-active.yaml" <<'YAML'
backend: ollama
models:
  - model_path: gemma4:27b
    served_model_name: gemma4-27b
YAML
  ln -sfn "${HOME}/.4lm/config/profiles/ollama-active.yaml" \
    "${HOME}/.4lm/config/active-profile"
  run "${REPO_ROOT}/bin/4lm" doctor phase3-ready
  [ "$status" -eq 1 ]
  [[ "$output" == red:* ]]
}
