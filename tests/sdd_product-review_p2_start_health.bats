#!/usr/bin/env bats
# Phase 2: onboarding URL hints and cmd_doctor formatting.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs" "${HOME}/.4lm/launchd"
  cp "${REPO_ROOT}/config/profiles/mlx-coding.yaml" "${HOME}/.4lm/config/profiles/mlx-coding.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/mlx-coding.yaml" "${HOME}/.4lm/config/active-profile"
  cat > "${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: local
backend_port: 8080
webui_port: 3000
YAML
  # Install fake plists so service_start doesn't die "plist not found"
  cp "${REPO_ROOT}/launchd/com.4lm.backend.plist" \
     "${HOME}/.4lm/launchd/com.4lm.backend.plist"
  cp "${REPO_ROOT}/launchd/com.4lm.webui.plist" \
     "${HOME}/.4lm/launchd/com.4lm.webui.plist"
  # Substitute __HOME__ placeholder
  sed -i '' "s|__HOME__|${HOME}|g" \
    "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/.4lm/launchd/com.4lm.webui.plist"
  export LLM_HOME="${HOME}/.4lm"
  export LAUNCHD_DIR="${HOME}/.4lm/launchd"
}

# ---- cmd_start first-run / subsequent-run hints ----------------------------

@test "cmd_start: absent openwebui-data prints URL + account hint + 4lm open" {
  skip_if_no_webui
  # openwebui-data/ absent → first run
  run "${REPO_ROOT}/bin/4lm" start
  [ "$status" -eq 0 ]
  [[ "$output" =~ http://127\.0\.0\.1:[0-9]+ ]]
  [[ "$output" == *"account"* ]]
  [[ "$output" == *"4lm open"* ]]
}

@test "cmd_start: present openwebui-data prints URL + 4lm open but no account hint" {
  skip_if_no_webui
  mkdir -p "${HOME}/.4lm/openwebui-data"
  run "${REPO_ROOT}/bin/4lm" start
  [ "$status" -eq 0 ]
  [[ "$output" =~ http://127\.0\.0\.1:[0-9]+ ]]
  [[ "$output" != *"account"* ]]
  [[ "$output" == *"4lm open"* ]]
}

# ---- cmd_doctor formatting --------------------------------------------------

@test "cmd_doctor: active profile with uncached mlx model prints warn: and download hint" {
  # Use mlx-coding profile (has mlx backend + models), point HF_HOME at empty dir.
  # Doctor may exit non-zero due to wired-memory check in sandbox; only assert output.
  cp "${REPO_ROOT}/config/profiles/mlx-coding.yaml" \
     "${HOME}/.4lm/config/profiles/mlx-coding.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/mlx-coding.yaml" \
     "${HOME}/.4lm/config/active-profile"
  export HF_HOME="${BATS_TMPDIR}/empty-hf-cache"
  mkdir -p "${HF_HOME}/hub"
  run "${REPO_ROOT}/bin/4lm" doctor
  echo "$output" | grep -q "warn:"
  echo "$output" | grep -q "download"
}

@test "cmd_doctor: backend not loaded skips smoke test" {
  # Backend is not loaded in the test environment; smoke test must be absent from output.
  run "${REPO_ROOT}/bin/4lm" doctor
  [[ "$output" != *"smoke test"* ]]
}
