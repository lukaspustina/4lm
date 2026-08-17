#!/usr/bin/env bats
#
# User-facing documents agree with the profiles after the Qwen3.8-27B
# chat-slot swap (SDD qwen38-profile.md, Phase 2). Static-content checks,
# same genre as tests/test_phase4_ci_docs.bats.

load helpers/setup

# Extract one profile row from a markdown table by its leading `profile` cell.
_row() {
  awk -v p="\`$2\`" -F'|' '$2 ~ p {print; exit}' "$1"
}

@test "README and index profile tables name the same chat model" {
  for profile in default mlx-knowledge; do
    readme_row="$(_row "${REPO_ROOT}/README.md" "${profile}")"
    index_row="$(_row "${REPO_ROOT}/index.md" "${profile}")"
    [ -n "${readme_row}" ]
    [ -n "${index_row}" ]
    [[ "${readme_row}" == *"Qwen3.8-27B"* ]]
    [[ "${index_row}" == *"Qwen3.8-27B"* ]]
  done
}

@test "README and index profile tables agree on the steady-state figures" {
  readme_default="$(_row "${REPO_ROOT}/README.md" default)"
  index_default="$(_row "${REPO_ROOT}/index.md" default)"
  [[ "${readme_default}" == *"~62 GB"* ]]
  [[ "${index_default}" == *"~62 GB"* ]]

  readme_know="$(_row "${REPO_ROOT}/README.md" mlx-knowledge)"
  index_know="$(_row "${REPO_ROOT}/index.md" mlx-knowledge)"
  [[ "${readme_know}" == *"~20 GB"* ]]
  [[ "${index_know}" == *"~20 GB"* ]]
}

@test "CLAUDE.md profile lineup matches the new steady-state figures" {
  claude_default="$(_row "${REPO_ROOT}/CLAUDE.md" default)"
  claude_know="$(_row "${REPO_ROOT}/CLAUDE.md" mlx-knowledge)"
  [[ "${claude_default}" == *"62 GB"* ]]
  [[ "${claude_know}" == *"20 GB"* ]]
}

@test "README memory math states the measured chat-model size" {
  run grep -c 'Qwen3.8-27B (~15.27 GB)' "${REPO_ROOT}/README.md"
  [ "${output}" -ge 1 ]
  run grep -c 'Qwen3.6-35B-A3B (~12 GB)' "${REPO_ROOT}/README.md"
  [ "${output}" -eq 0 ]
}

@test "docs/setup.md names the current chat slot" {
  run grep -c 'qwen3.6-35b' "${REPO_ROOT}/docs/setup.md"
  [ "${output}" -eq 0 ]
  run grep -c 'qwen3.8-27b' "${REPO_ROOT}/docs/setup.md"
  [ "${output}" -ge 1 ]
}

@test "CHANGELOG records the chat-model swap as breaking" {
  section="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "${REPO_ROOT}/CHANGELOG.md")"
  [[ "${section}" == *"qwen3.8-27b"* ]]
  [[ "${section}" == *"qwen3.6-35b"* ]]
  [[ "${section}" == *"BREAKING"* ]]
}
