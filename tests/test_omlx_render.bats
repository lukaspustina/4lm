#!/usr/bin/env bats
# Tests for render_omlx_settings() and related install.sh changes.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs" "${HOME}/.4lm/launchd"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"

  # Find real jq (not the tests/helpers stub) for render tests.
  REAL_JQ=""
  for _candidate in /opt/homebrew/bin/jq /usr/local/bin/jq; do
    [[ -x "${_candidate}" ]] && { REAL_JQ="${_candidate}"; break; }
  done
  if [[ -z "${REAL_JQ}" ]]; then
    skip "real jq not found; install via: brew install jq"
  fi
  export REAL_JQ
}

# ---- render_omlx_settings: source bin/4lm and call function directly --------

_render() {
  local yaml="$1" out="$2"
  # Source bin/4lm with JQ_BIN pointing to real jq so render bypasses the stub.
  bash -c "
    export JQ_BIN='${REAL_JQ}'
    export HOME='${HOME}'
    source '${REPO_ROOT}/bin/4lm'
    render_omlx_settings '$yaml' '$out'
  "
}

@test "render: pin: true emits JSON boolean true (not quoted string)" {
  local yaml="${BATS_TMPDIR}/render-bool.yaml"
  local out="${BATS_TMPDIR}/settings-bool.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    pin: true
YAML
  _render "${yaml}" "${out}"
  [ -f "${out}" ]
  # pin must be boolean true, not "true"
  pin_val="$("${REAL_JQ}" '.models[0].pin' "${out}")"
  [ "${pin_val}" = "true" ]
}

@test "render: pin: false emits JSON boolean false" {
  local yaml="${BATS_TMPDIR}/render-false.yaml"
  local out="${BATS_TMPDIR}/settings-false.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/bge-m3
    served_model_name: bge-m3
    pin: false
    ttl: 600
YAML
  _render "${yaml}" "${out}"
  pin_val="$("${REAL_JQ}" '.models[0].pin' "${out}")"
  [ "${pin_val}" = "false" ]
}

@test "render: ttl: null in YAML emits JSON null" {
  local yaml="${BATS_TMPDIR}/render-null-ttl.yaml"
  local out="${BATS_TMPDIR}/settings-null-ttl.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    ttl: null
YAML
  _render "${yaml}" "${out}"
  ttl_val="$("${REAL_JQ}" '.models[0].ttl' "${out}")"
  [ "${ttl_val}" = "null" ]
}

@test "render: absent ttl: key emits no ttl field in JSON" {
  local yaml="${BATS_TMPDIR}/render-no-ttl.yaml"
  local out="${BATS_TMPDIR}/settings-no-ttl.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  _render "${yaml}" "${out}"
  # ttl key must be absent (jq returns null for missing keys but has() returns false)
  has_ttl="$("${REAL_JQ}" '.models[0] | has("ttl")' "${out}")"
  [ "${has_ttl}" = "false" ]
}

@test "render: integer ttl emits JSON number" {
  local yaml="${BATS_TMPDIR}/render-int-ttl.yaml"
  local out="${BATS_TMPDIR}/settings-int-ttl.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/bge-m3
    served_model_name: bge-m3
    ttl: 600
YAML
  _render "${yaml}" "${out}"
  ttl_val="$("${REAL_JQ}" '.models[0].ttl' "${out}")"
  [ "${ttl_val}" = "600" ]
}

@test "render: empty chat_template_kwargs dict is omitted from JSON" {
  local yaml="${BATS_TMPDIR}/render-empty-dict.yaml"
  local out="${BATS_TMPDIR}/settings-empty-dict.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    chat_template_kwargs: {}
    sampling: {}
YAML
  _render "${yaml}" "${out}"
  has_ctk="$("${REAL_JQ}" '.models[0] | has("chat_template_kwargs")' "${out}")"
  has_samp="$("${REAL_JQ}" '.models[0] | has("sampling")' "${out}")"
  [ "${has_ctk}" = "false" ]
  [ "${has_samp}" = "false" ]
}

@test "render: multi-model profile produces array with correct served_model_name entries" {
  local yaml="${BATS_TMPDIR}/render-multi.yaml"
  local out="${BATS_TMPDIR}/settings-multi.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    pin: true
    ttl: null
    model_type: lm
  - model_path: mlx-community/bge-m3
    served_model_name: bge-m3
    pin: false
    ttl: 600
    model_type: lm
YAML
  _render "${yaml}" "${out}"
  count="$("${REAL_JQ}" '.models | length' "${out}")"
  [ "${count}" = "2" ]
  name0="$("${REAL_JQ}" -r '.models[0].served_model_name' "${out}")"
  name1="$("${REAL_JQ}" -r '.models[1].served_model_name' "${out}")"
  [ "${name0}" = "qwen3-coder-next" ]
  [ "${name1}" = "bge-m3" ]
}

@test "render: output directory ~/.omlx/ is created if absent" {
  local yaml="${BATS_TMPDIR}/render-mkdir.yaml"
  # Use a unique output path inside ~/.omlx/
  local out="${HOME}/.omlx/settings.json"
  # Ensure ~/.omlx does not exist
  rm -rf "${HOME}/.omlx"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  _render "${yaml}" "${out}"
  [ -d "${HOME}/.omlx" ]
  [ -f "${out}" ]
}
