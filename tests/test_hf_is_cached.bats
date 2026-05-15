#!/usr/bin/env bats
#
# hf_is_cached() bash + python parity tests.
# Regression: the earlier ≥ 1 GB threshold rejected small models like
# `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. The new check is
# size-agnostic — it requires refs/main, a populated snapshot dir, and no
# *.incomplete files in blobs/.

bats_require_minimum_version 1.5.0
load helpers/setup

_call_hf_is_cached() {
  local repo="$1"
  bash -c "
    export HOME='${HOME}'
    export HF_HOME='${HF_HOME}'
    source '${REPO_ROOT}/bin/4lm'
    hf_is_cached '${repo}'
  "
}

# Build a fake HF cache entry under HF_HOME for repo $1 with options:
#   --no-refs        omit refs/main
#   --no-snap        omit snapshots/<sha>/
#   --empty-snap     snapshots/<sha>/ exists but has no files
#   --incomplete     add a *.incomplete file in blobs/
#   --small          create a tiny single-blob (50 KB) — the OLD check would fail
_make_cache_entry() {
  local repo="$1"; shift
  local slug="models--${repo//\//--}"
  local base="${HF_HOME}/hub/${slug}"
  local sha="abc123def456"
  local no_refs=0 no_snap=0 empty_snap=0 incomplete=0 small=0
  for arg in "$@"; do
    case "${arg}" in
      --no-refs) no_refs=1 ;;
      --no-snap) no_snap=1 ;;
      --empty-snap) empty_snap=1 ;;
      --incomplete) incomplete=1 ;;
      --small) small=1 ;;
    esac
  done
  mkdir -p "${base}/refs" "${base}/snapshots" "${base}/blobs"
  [[ "${no_refs}" -eq 0 ]] && printf '%s' "${sha}" >"${base}/refs/main"
  if [[ "${no_snap}" -eq 0 ]]; then
    mkdir -p "${base}/snapshots/${sha}"
    if [[ "${empty_snap}" -eq 0 ]]; then
      # Make one blob + one snapshot symlink that points at it.
      if [[ "${small}" -eq 1 ]]; then
        # 50 KB — well under the legacy 1 GB threshold.
        dd if=/dev/zero of="${base}/blobs/blob1" bs=1k count=50 >/dev/null 2>&1
      else
        # 1 KB sample (size-agnostic check doesn't care).
        printf 'x%.0s' {1..1024} >"${base}/blobs/blob1"
      fi
      ln -s ../../blobs/blob1 "${base}/snapshots/${sha}/model.safetensors"
    fi
  fi
  [[ "${incomplete}" -eq 1 ]] && : >"${base}/blobs/blob2.incomplete"
  return 0
}

setup() {
  export HF_HOME="${BATS_TMPDIR}/hf-${BATS_TEST_NAME}"
  rm -rf "${HF_HOME}"
  mkdir -p "${HF_HOME}/hub"
}

@test "hf_is_cached: complete download returns 0" {
  _make_cache_entry "mlx-community/test-repo"
  run _call_hf_is_cached "mlx-community/test-repo"
  [ "$status" -eq 0 ]
}

@test "hf_is_cached: small model (well under 1 GB) returns 0 — regression" {
  # This is the embedding-model bug: a real download well under 1 GB.
  _make_cache_entry "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ" --small
  run _call_hf_is_cached "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
  [ "$status" -eq 0 ]
}

@test "hf_is_cached: missing repo returns 1" {
  run _call_hf_is_cached "mlx-community/nonexistent"
  [ "$status" -eq 1 ]
}

@test "hf_is_cached: refs/main missing returns 1" {
  _make_cache_entry "mlx-community/test-repo" --no-refs
  run _call_hf_is_cached "mlx-community/test-repo"
  [ "$status" -eq 1 ]
}

@test "hf_is_cached: snapshot dir missing returns 1" {
  _make_cache_entry "mlx-community/test-repo" --no-snap
  run _call_hf_is_cached "mlx-community/test-repo"
  [ "$status" -eq 1 ]
}

@test "hf_is_cached: empty snapshot dir returns 1" {
  _make_cache_entry "mlx-community/test-repo" --empty-snap
  run _call_hf_is_cached "mlx-community/test-repo"
  [ "$status" -eq 1 ]
}

@test "hf_is_cached: *.incomplete in blobs returns 1" {
  _make_cache_entry "mlx-community/test-repo" --incomplete
  run _call_hf_is_cached "mlx-community/test-repo"
  [ "$status" -eq 1 ]
}

# Resolve a real Python interpreter, bypassing the tests/helpers/python3 stub.
# Used for the parity tests below (the stub exits 0 silently and would mask
# our assertions).
_real_python3() {
  for cand in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/bin/python3; do
    [[ -x "${cand}" ]] && { echo "${cand}"; return 0; }
  done
  return 1
}

@test "_hf_is_cached (python): mirrors bash behaviour for small model" {
  PY="$(_real_python3)" || skip "no real python3 found"
  _make_cache_entry "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ" --small
  run "${PY}" -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/bin')
from importlib import import_module
helpers = import_module('4lm_helpers')
ok = helpers._hf_is_cached('${HF_HOME}', 'mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ')
sys.exit(0 if ok else 1)
"
  [ "$status" -eq 0 ]
}

@test "_hf_is_cached (python): rejects *.incomplete" {
  PY="$(_real_python3)" || skip "no real python3 found"
  _make_cache_entry "mlx-community/test-repo" --incomplete
  run "${PY}" -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/bin')
from importlib import import_module
helpers = import_module('4lm_helpers')
ok = helpers._hf_is_cached('${HF_HOME}', 'mlx-community/test-repo')
sys.exit(0 if ok else 1)
"
  [ "$status" -eq 1 ]
}
