#!/usr/bin/env bats
# start stages a missing runtime dir for the active omlx profile, or refuses to
# bootstrap — instead of letting the wrapper crash-loop with EX_CONFIG.

bats_require_minimum_version 1.5.0

load helpers/setup

BIN="${REPO_ROOT}/bin/4lm"

setup() {
  mkdir -p "${HOME}/.4lm/launchd" "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  cp "${REPO_ROOT}/config/profiles/default.yaml" "${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/active-profile"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
  printf 'test-key\n' >"${HOME}/.4lm/config/api-key"
  for p in "${REPO_ROOT}"/launchd/*.plist; do
    sed "s|__HOME__|${HOME}|g" "$p" >"${HOME}/.4lm/launchd/$(basename "$p")"
  done
  export HF_HOME="${HOME}/hf"
  # Staging renders model_settings.json with jq; the suite stubs jq on PATH.
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq; do [[ -x "$c" ]] && { export JQ_BIN="$c"; break; }; done
}

_cache_default_models() {
  local repo slug
  for repo in $(awk '/^[[:space:]]*-[[:space:]]*model_path:/ {print $NF}' "${REPO_ROOT}/config/profiles/default.yaml"); do
    slug="${repo//\//--}"
    mkdir -p "${HF_HOME}/hub/models--${slug}/refs" "${HF_HOME}/hub/models--${slug}/snapshots/abc123"
    echo abc123 >"${HF_HOME}/hub/models--${slug}/refs/main"
  done
}

@test "start refuses to bootstrap when the active profile's models are missing" {
  run "${BIN}" start backend
  [ "$status" -ne 0 ]
  [[ "$output" == *"model download --profile default"* ]] || false
  run ! grep -q bootstrap "${LAUNCHCTL_LOG}"
  [ ! -d "${HOME}/.4lm/runtime/default/models" ]
}

@test "start stages the runtime dir when the models are cached" {
  _cache_default_models
  run "${BIN}" start backend
  [ "$status" -eq 0 ]
  [ -L "${HOME}/.4lm/runtime/default/models/qwen3-embedding" ]
  grep -q bootstrap "${LAUNCHCTL_LOG}"
}

@test "start leaves an existing runtime dir alone" {
  mkdir -p "${HOME}/.4lm/runtime/default/models"
  run "${BIN}" start backend
  [ "$status" -eq 0 ]
  grep -q bootstrap "${LAUNCHCTL_LOG}"
}

@test "_prepare stages or fails like start, without launchd" {
  run "${BIN}" _prepare
  [ "$status" -ne 0 ]
  _cache_default_models
  run "${BIN}" _prepare
  [ "$status" -eq 0 ]
  [ -d "${HOME}/.4lm/runtime/default/models" ]
  [ ! -s "${LAUNCHCTL_LOG}" ]
}
