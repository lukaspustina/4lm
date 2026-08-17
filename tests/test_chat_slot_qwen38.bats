#!/usr/bin/env bats
#
# Chat-slot contents after the Qwen3.8-27B swap (SDD qwen38-profile.md).
# Static-content assertions against the shipped profile YAMLs and the
# opencode template — same genre as tests/test_phase4_ci_docs.bats.

load helpers/setup

@test "default profile: chat slot serves Qwen3.8-27B as a vlm" {
  yaml="${REPO_ROOT}/config/profiles/default.yaml"
  run grep -c "mlx-community/Qwen3.8-27B-4bit" "${yaml}"
  [ "${output}" -ge 1 ]
  run grep -c "served_model_name: qwen3.8-27b" "${yaml}"
  [ "${output}" -ge 1 ]
  # The chat entry is models[1]; assert its three fields sit together.
  run awk '/model_path: mlx-community\/Qwen3.8-27B-4bit/{f=1} f&&/model_type: vlm/{print "ok"; exit}' "${yaml}"
  [ "${output}" = "ok" ]
}

@test "default profile: outgoing chat model is gone" {
  run grep -c "Qwen3.6-35B-A3B-4bit" "${REPO_ROOT}/config/profiles/default.yaml"
  [ "${output}" -eq 0 ]
}

@test "mlx-knowledge profile: chat slot swapped, pin and ttl preserved" {
  yaml="${REPO_ROOT}/config/profiles/mlx-knowledge.yaml"
  run grep -c "mlx-community/Qwen3.8-27B-4bit" "${yaml}"
  [ "${output}" -ge 1 ]
  run grep -c "served_model_name: qwen3.8-27b" "${yaml}"
  [ "${output}" -ge 1 ]
  run grep -c "Qwen3.6-35B-A3B-4bit" "${yaml}"
  [ "${output}" -eq 0 ]
  # The chat entry keeps its pre-existing pin/ttl values.
  run awk '/model_path: mlx-community\/Qwen3.8-27B-4bit/{f=1} f&&/pin: true/{print "pinned"; exit}' "${yaml}"
  [ "${output}" = "pinned" ]
  run awk '/model_path: mlx-community\/Qwen3.8-27B-4bit/{f=1} f&&/ttl: null/{print "nottl"; exit}' "${yaml}"
  [ "${output}" = "nottl" ]
}

@test "lean profile: deliberately keeps the MoE chat model" {
  run grep -c "mlx-community/Qwen3.6-35B-A3B-4bit" "${REPO_ROOT}/config/profiles/lean.yaml"
  [ "${output}" -ge 1 ]
  run grep -c "Qwen3.8-27B" "${REPO_ROOT}/config/profiles/lean.yaml"
  [ "${output}" -eq 0 ]
}

@test "changed profiles validate and carry today's review date" {
  for p in default mlx-knowledge; do
    run "${REPO_ROOT}/tests/lint-profiles.sh" "${REPO_ROOT}/config/profiles/${p}.yaml"
    [ "$status" -eq 0 ]
    run grep -c "Last reviewed: 2026-08-17" "${REPO_ROOT}/config/profiles/${p}.yaml"
    [ "${output}" -ge 1 ]
  done
}

@test "changed profile headers state the measured size and the reasoning caveat" {
  for p in default mlx-knowledge; do
    yaml="${REPO_ROOT}/config/profiles/${p}.yaml"
    run grep -c "15.27" "${yaml}"
    [ "${output}" -ge 1 ]
    run grep -ci "reasoning_effort" "${yaml}"
    [ "${output}" -ge 1 ]
  done
}

@test "opencode template lists both chat slots" {
  # lean still serves qwen3.6-35b, so the template must keep that alias
  # alongside the new one — dropping it would strip lean's chat model.
  jsonc="${REPO_ROOT}/config/opencode.example.jsonc"
  run grep -c '"qwen3.8-27b"' "${jsonc}"
  [ "${output}" -ge 1 ]
  run grep -c '"qwen3.6-35b"' "${jsonc}"
  [ "${output}" -ge 1 ]
}

@test "state-machine test no longer hard-codes a chat model name" {
  bats_file="${REPO_ROOT}/tests/test_profile_state_machine.bats"
  run grep -c "Qwen3.6-35B-A3B-4bit" "${bats_file}"
  [ "${output}" -eq 0 ]
  run grep -c "Qwen3.8-27B-4bit" "${bats_file}"
  [ "${output}" -eq 0 ]
}
