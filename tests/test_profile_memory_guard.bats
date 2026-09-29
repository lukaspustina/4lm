#!/usr/bin/env bats
# Memory guard and per-model context cap.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  printf 'mode: local\nbackend_port: 8000\n' >"${HOME}/.4lm/config/network.yaml"
  printf 'test-key\n' >"${HOME}/.4lm/config/api-key"
  export OMLX_LOG="${BATS_TMPDIR}/omlx-${BATS_TEST_NAME}"
  rm -f "${OMLX_LOG}"
  REAL_JQ=""
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq; do [[ -x "$c" ]] && { REAL_JQ="$c"; break; }; done
  [[ -n "${REAL_JQ}" ]] || skip "real jq not found"
}

_yaml() { # $1 = omlx: block body (may be empty), $2 = extra model field line (may be empty)
  local f="${BATS_TMPDIR}/mg-${BATS_TEST_NAME}.yaml"
  {
    echo "backend: omlx"
    [[ -n "$1" ]] && printf 'omlx:\n  %s\n' "$1"
    echo "models:"
    echo "  - model_path: mlx-community/test-model"
    echo "    served_model_name: test-model"
    [[ -n "$2" ]] && echo "    $2"
  } >"$f"
  echo "$f"
}

_validate() {
  bash -c "export HOME='${HOME}'; source '${REPO_ROOT}/bin/4lm'; validate_profile '$1'"
}

_render() {
  bash -c "export JQ_BIN='${REAL_JQ}' HOME='${HOME}'; source '${REPO_ROOT}/bin/4lm'; render_omlx_settings '$1' '$2'"
}

@test "memory_guard_gb is forwarded as --memory-guard-gb" {
  f="$(_yaml 'memory_guard_gb: 212' '')"
  ln -sfn "$f" "${HOME}/.4lm/config/active-profile"
  mkdir -p "${HOME}/.4lm/runtime/$(basename "$f" .yaml)/models"
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--memory-guard-gb 212" "${OMLX_LOG}"
}

@test "memory_guard_gb accepts a positive number" {
  run _validate "$(_yaml 'memory_guard_gb: 212' '')"
  [ "$status" -eq 0 ]
  run _validate "$(_yaml 'memory_guard_gb: 96.5' '')"
  [ "$status" -eq 0 ]
}

@test "memory_guard_gb rejects zero, negative and non-numeric values" {
  for v in 0 -1 abc '"212"'; do
    run _validate "$(_yaml "memory_guard_gb: $v" '')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"memory_guard_gb"* ]] || false
  done
}

@test "unknown omlx: keys are rejected, including the dropped memory flags" {
  for k in 'max_process_memory: "80%"' 'max_model_memory: "100GB"' 'bogus: 1'; do
    run _validate "$(_yaml "$k" '')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"omlx"* ]] || false
  done
}

@test "max_context_window is rendered into model_settings.json" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' 'max_context_window: 65536')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model".max_context_window' "${out}")" = "65536" ]
}

@test "absent max_context_window is not rendered" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' '')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model" | has("max_context_window")' "${out}")" = "false" ]
}

@test "max_context_window rejects zero and non-integers" {
  for v in 0 64k -5 1.5; do
    run _validate "$(_yaml '' "max_context_window: $v")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"max_context_window"* ]] || false
  done
}

@test "mtp: true is rendered as mtp_enabled" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' 'mtp: true')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model".mtp_enabled' "${out}")" = "true" ]
}

@test "absent or false mtp is not rendered" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' 'mtp: false')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model" | has("mtp_enabled")' "${out}")" = "false" ]
}

@test "mtp rejects non-boolean values" {
  for v in yes 1 on; do
    run _validate "$(_yaml '' "mtp: $v")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mtp"* ]] || false
  done
}

@test "paged_ssd_cache_max_size is forwarded as --paged-ssd-cache-max-size" {
  f="$(_yaml 'paged_ssd_cache_max_size: 50GB' '')"
  ln -sfn "$f" "${HOME}/.4lm/config/active-profile"
  mkdir -p "${HOME}/.4lm/runtime/$(basename "$f" .yaml)/models"
  run "${REPO_ROOT}/bin/4lm-backend-start.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--paged-ssd-cache-max-size 50GB" "${OMLX_LOG}"
}

@test "paged_ssd_cache_max_size accepts sizes and auto, rejects the rest" {
  for v in 50GB 512MB 1.5TB auto; do
    run _validate "$(_yaml "paged_ssd_cache_max_size: $v" '')"
    [ "$status" -eq 0 ]
  done
  for v in 50 50gb fifty -1GB; do
    run _validate "$(_yaml "paged_ssd_cache_max_size: $v" '')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"paged_ssd_cache_max_size"* ]] || false
  done
}

@test "reasoning_effort is rendered into chat_template_kwargs" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' 'reasoning_effort: medium')" "${out}"
  [ "$("${REAL_JQ}" -r '.models."test-model".chat_template_kwargs.reasoning_effort' "${out}")" = "medium" ]
}

@test "top_k is rendered as an integer" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' 'top_k: 20')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model".top_k' "${out}")" = "20" ]
}

@test "absent reasoning_effort and top_k are not rendered" {
  out="${BATS_TMPDIR}/ms-${BATS_TEST_NAME}.json"
  _render "$(_yaml '' '')" "${out}"
  [ "$("${REAL_JQ}" '.models."test-model" | has("chat_template_kwargs") or has("top_k")' "${out}")" = "false" ]
}

@test "reasoning_effort and top_k reject malformed values" {
  for line in 'reasoning_effort: Medium!' 'reasoning_effort: ""' 'top_k: 0' 'top_k: -3' 'top_k: 2.5'; do
    run _validate "$(_yaml '' "${line}")"
    [ "$status" -ne 0 ]
  done
  run _validate "$(_yaml '' 'reasoning_effort: xhigh')"
  [ "$status" -eq 0 ]
}
