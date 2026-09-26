#!/usr/bin/env bats
# The backend API key is always on.

bats_require_minimum_version 1.5.0

load helpers/setup

KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs" "${HOME}/.4lm/launchd"
  printf 'mode: local\nbackend_port: 8000\nwebui_port: 3000\n' >"${HOME}/.4lm/config/network.yaml"
  export OMLX_LOG="${BATS_TMPDIR}/omlx-${BATS_TEST_NAME}"
  export OMLX_ENV_LOG="${BATS_TMPDIR}/omlx-env-${BATS_TEST_NAME}"
  export OLLAMA_LOG="${BATS_TMPDIR}/ollama-${BATS_TEST_NAME}"
  export MLXLM_LOG="${BATS_TMPDIR}/mlxlm-${BATS_TEST_NAME}"
  export CURL_LOG="${BATS_TMPDIR}/curl-${BATS_TEST_NAME}"
  export WEBUI_ENV_LOG="${BATS_TMPDIR}/webui-env-${BATS_TEST_NAME}"
  rm -f "${OMLX_LOG}" "${OMLX_ENV_LOG}" "${OLLAMA_LOG}" "${MLXLM_LOG}" "${CURL_LOG}" "${WEBUI_ENV_LOG}"
}

_seed_key() {
  printf '%s\n' "${KEY}" >"${HOME}/.4lm/config/api-key"
  chmod 600 "${HOME}/.4lm/config/api-key"
}

_lan() { printf 'mode: lan\nbackend_port: 8000\nwebui_port: 3000\n' >"${HOME}/.4lm/config/network.yaml"; }

_profile() { # $1 = backend
  cat >"${HOME}/.4lm/config/profiles/t-$1.yaml" <<YAML
backend: $1
models:
  - model_path: mlx-community/test-model
    served_model_name: test-model
YAML
  ln -sfn "${HOME}/.4lm/config/profiles/t-$1.yaml" "${HOME}/.4lm/config/active-profile"
  mkdir -p "${HOME}/.4lm/runtime/t-$1/models"
}

# ---- installer ---------------------------------------------------------------

_install_stubs() {
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  printf '#!/usr/bin/env bash\n[[ "$1" == tee ]] && cat >/dev/null\nexit 0\n' >"${STUB_BIN}/sudo"
  printf '#!/usr/bin/env bash\n[[ "$1" == list ]] && echo "omlx 0.6.0"\nexit 0\n' >"${STUB_BIN}/pipx"
  cat >"${STUB_BIN}/python3.12" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-m" && "$2" == "venv" && -n "$3" ]]; then
  mkdir -p "$3/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$3/bin/pip"; chmod +x "$3/bin/pip"
fi
exit 0
SH
  chmod +x "${STUB_BIN}"/*
  export PATH="${STUB_BIN}:${PATH}"
  export NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-${BATS_TEST_NAME}.conf"
  export LEGACY_SUDOERS_FILE="${BATS_TMPDIR}/sudoers-${BATS_TEST_NAME}"
}

@test "install creates a 0600 64-hex key once and never rewrites it" {
  _install_stubs
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  f="${HOME}/.4lm/config/api-key"
  [ "$(stat -f %Lp "${f}")" = "600" ]
  grep -qxE '[0-9a-f]{64}' "${f}"
  first="$(cat "${f}")"
  run "${REPO_ROOT}/install.sh" --backend-only
  [ "$status" -eq 0 ]
  [ "$(cat "${f}")" = "${first}" ]
}

@test "install warns when an existing opencode config has no apiKey" {
  _install_stubs
  mkdir -p "${HOME}/.config/opencode"
  echo '{"provider": {}}' >"${HOME}/.config/opencode/opencode.jsonc"
  run "${REPO_ROOT}/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"apiKey": "{file:~/.4lm/config/api-key}"'* ]] || false
  [ "$(cat "${HOME}/.config/opencode/opencode.jsonc")" = '{"provider": {}}' ]
}

@test "opencode template reads the key file" {
  grep -q '"apiKey": "{file:~/.4lm/config/api-key}"' "${REPO_ROOT}/config/opencode.example.jsonc"
}

# ---- backend wrapper ---------------------------------------------------------

@test "omlx wrapper exports OMLX_API_KEY and keeps it out of argv" {
  _seed_key
  _profile omlx
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 0 ]
  grep -qx "OMLX_API_KEY=${KEY}" "${OMLX_ENV_LOG}"
  run ! grep -q "${KEY}" "${OMLX_LOG}"
}

@test "omlx wrapper exits 78 without a key file" {
  _profile omlx
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 78 ]
  [[ "$output" == *"api-key"* ]] || false
  [ ! -s "${OMLX_LOG}" ]
}

@test "omlx wrapper tightens ~/.omlx/settings.json to 0600" {
  _seed_key
  _profile omlx
  mkdir -p "${HOME}/.omlx"
  echo '{}' >"${HOME}/.omlx/settings.json"
  chmod 644 "${HOME}/.omlx/settings.json"
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 0 ]
  [ "$(stat -f %Lp "${HOME}/.omlx/settings.json")" = "600" ]
}

@test "ollama wrapper refuses a LAN bind" {
  _profile ollama
  _lan
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 78 ]
  [ ! -s "${OLLAMA_LOG}" ]
}

@test "mlx_lm wrapper refuses a LAN bind" {
  _profile mlx_lm
  _lan
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 78 ]
  [ ! -s "${MLXLM_LOG}" ]
}

# ---- webui wrapper -----------------------------------------------------------

@test "webui wrapper passes the key to Open WebUI" {
  _seed_key
  run "${REPO_ROOT}/bin/4lm-webui-start.sh"
  [ "$status" -eq 0 ]
  grep -qx "OPENAI_API_KEY=${KEY}" "${WEBUI_ENV_LOG}"
  grep -qx "RAG_OPENAI_API_KEY=${KEY}" "${WEBUI_ENV_LOG}"
  grep -qx "RAG_EXTERNAL_RERANKER_API_KEY=${KEY}" "${WEBUI_ENV_LOG}"
}

@test "webui wrapper exits 78 without a key file" {
  run "${REPO_ROOT}/bin/4lm-webui-start.sh"
  [ "$status" -eq 78 ]
}

# ---- CLI ---------------------------------------------------------------------

@test "expose lan fails without a key file and leaves network.yaml alone" {
  _profile omlx
  run "${REPO_ROOT}/bin/4lm" expose lan --confirm
  [ "$status" -ne 0 ]
  [[ "$output" == *"api-key"* ]] || false
  grep -q "^mode: local" "${HOME}/.4lm/config/network.yaml"
}

@test "expose lan fails for a backend that cannot enforce the key" {
  _seed_key
  _profile ollama
  run "${REPO_ROOT}/bin/4lm" expose lan --confirm
  [ "$status" -ne 0 ]
  grep -q "^mode: local" "${HOME}/.4lm/config/network.yaml"
}

@test "expose lan succeeds with key and omlx" {
  _seed_key
  _profile omlx
  run "${REPO_ROOT}/bin/4lm" expose lan --confirm
  [ "$status" -eq 0 ]
  grep -q "^mode: lan" "${HOME}/.4lm/config/network.yaml"
}

@test "backend probes send the key via stdin config, not argv" {
  _seed_key
  _profile omlx
  mkdir -p "${HOME}/.config/opencode"
  echo '{}' >"${HOME}/.config/opencode/opencode.jsonc"
  run "${REPO_ROOT}/bin/4lm" opencode --version
  grep -q "^config: header = \"Authorization: Bearer ${KEY}\"" "${CURL_LOG}"
  run ! grep -q "argv: .*${KEY}" "${CURL_LOG}"
}

@test "doctor flags a key file that is not 0600" {
  _seed_key
  _profile omlx
  chmod 644 "${HOME}/.4lm/config/api-key"
  run "${REPO_ROOT}/bin/4lm" doctor
  [[ "$output" == *"api-key"*"600"* ]] || false
}

@test "expose on a backend-only install prints no WebUI URL" {
  _seed_key
  _profile omlx
  run "${REPO_ROOT}/bin/4lm" expose lan --confirm
  [ "$status" -eq 0 ]
  [[ "$output" != *"WebUI"* ]]
}
