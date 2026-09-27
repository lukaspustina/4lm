#!/usr/bin/env bats
# `4lm model download --profile <name>` and `just models <name>` fetch one profile's models only.

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  export HF_LOG="${BATS_TMPDIR}/hf-${BATS_TEST_NAME}"
  rm -f "${HF_LOG}"
  for p in small big; do
    cat >"${HOME}/.4lm/config/profiles/${p}.yaml" <<YAML
backend: omlx
models:
  - model_path: org/${p}-model
    served_model_name: ${p}-model
YAML
  done
}

@test "model download --profile fetches only that profile's models" {
  run "${REPO_ROOT}/bin/4lm" model download --profile small
  [ "$status" -eq 0 ]
  grep -q "org/small-model" "${HF_LOG}"
  run ! grep -q "org/big-model" "${HF_LOG}"
}

@test "model download without --profile still fetches every profile" {
  run "${REPO_ROOT}/bin/4lm" model download
  [ "$status" -eq 0 ]
  grep -q "org/small-model" "${HF_LOG}"
  grep -q "org/big-model" "${HF_LOG}"
}

@test "model download --profile rejects an unknown profile" {
  run "${REPO_ROOT}/bin/4lm" model download --profile nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope"* ]] || false
  [ ! -s "${HF_LOG}" ]
}

@test "model download --profile rejects a path-like name" {
  run "${REPO_ROOT}/bin/4lm" model download --profile ../small
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid profile name"* ]] || false
  [ ! -s "${HF_LOG}" ]
}

@test "model download --profile without a name fails" {
  run "${REPO_ROOT}/bin/4lm" model download --profile
  [ "$status" -ne 0 ]
  [ ! -s "${HF_LOG}" ]
}

@test "just models <profile> fetches only that repo profile's models" {
  cd "${REPO_ROOT}"
  run just models lean
  [ "$status" -eq 0 ]
  while read -r m; do
    grep -qF "${m}" "${HF_LOG}"
  done < <(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $NF}' config/profiles/lean.yaml)
  run ! grep -qF "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp" "${HF_LOG}"
}
