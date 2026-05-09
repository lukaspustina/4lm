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

# Output format is model_settings.json: {"version":1,"models":{"<id>":{...}}}
# Keys use omlx's ModelSettings field names: is_pinned (bool), ttl_seconds (int).

@test "render: pin: true emits JSON boolean is_pinned: true" {
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
  pin_val="$("${REAL_JQ}" '.models."qwen3-coder-next".is_pinned' "${out}")"
  [ "${pin_val}" = "true" ]
}

@test "render: pin: false omits is_pinned from JSON (omlx default is false)" {
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
  # pin: false means is_pinned is absent (omlx default is false)
  has_pin="$("${REAL_JQ}" '.models."bge-m3" | has("is_pinned")' "${out}")"
  [ "${has_pin}" = "false" ]
}

@test "render: ttl: null in YAML omits ttl_seconds from JSON" {
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
  # ttl: null means never-unload; ttl_seconds is absent (omlx built-in default)
  has_ttl="$("${REAL_JQ}" '.models."qwen3-coder-next" | has("ttl_seconds")' "${out}")"
  [ "${has_ttl}" = "false" ]
}

@test "render: absent ttl: key omits ttl_seconds from JSON" {
  local yaml="${BATS_TMPDIR}/render-no-ttl.yaml"
  local out="${BATS_TMPDIR}/settings-no-ttl.json"
  cat > "${yaml}" <<'YAML'
backend: omlx
models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
YAML
  _render "${yaml}" "${out}"
  has_ttl="$("${REAL_JQ}" '.models."qwen3-coder-next" | has("ttl_seconds")' "${out}")"
  [ "${has_ttl}" = "false" ]
}

@test "render: integer ttl emits ttl_seconds JSON number" {
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
  ttl_val="$("${REAL_JQ}" '.models."bge-m3".ttl_seconds' "${out}")"
  [ "${ttl_val}" = "600" ]
}

@test "render: chat_template_kwargs and sampling fields in YAML are ignored in model_settings.json" {
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
  # model_settings.json only carries is_pinned / ttl_seconds; other fields
  # (chat_template_kwargs, sampling) are omlx admin-UI concerns, not 4lm's.
  has_ctk="$("${REAL_JQ}" '.models."qwen3-coder-next" | has("chat_template_kwargs")' "${out}")"
  [ "${has_ctk}" = "false" ]
}

@test "render: multi-model profile produces dict with correct model_id keys" {
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
  "${REAL_JQ}" -e '.models."qwen3-coder-next"' "${out}" >/dev/null
  "${REAL_JQ}" -e '.models."bge-m3"' "${out}" >/dev/null
}

@test "render: output directory ~/.omlx/ is created if absent" {
  local yaml="${BATS_TMPDIR}/render-mkdir.yaml"
  local out="${HOME}/.omlx/model_settings.json"
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
