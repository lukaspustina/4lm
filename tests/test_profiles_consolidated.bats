#!/usr/bin/env bats
# One profile per memory class, all on the stability standard; the installer picks by RAM.

bats_require_minimum_version 1.5.0

load helpers/setup

P="${BATS_TEST_DIRNAME}/../config/profiles"

@test "the repo ships exactly default, mid, lean and ollama" {
  run bash -c "cd '${P}' && ls *.yaml | sort | tr '\n' ' '"
  [ "$output" = "default.yaml lean.yaml mid.yaml ollama.yaml " ]
}

@test "every omlx profile sets a memory guard" {
  for f in default mid lean; do
    grep -qE '^[[:space:]]+memory_guard_gb:[[:space:]]*[0-9]' "${P}/${f}.yaml"
  done
}

@test "every omlx model is pinned without a TTL" {
  for f in default mid lean; do
    n_models=$(grep -cE '^[[:space:]]*-[[:space:]]*model_path:' "${P}/${f}.yaml")
    [ "$(grep -cE '^[[:space:]]+pin:[[:space:]]*true' "${P}/${f}.yaml")" -eq "${n_models}" ]
    [ "$(grep -cE '^[[:space:]]+ttl:[[:space:]]*null' "${P}/${f}.yaml")" -eq "${n_models}" ]
  done
}

@test "every generative omlx model has a context cap" {
  for f in default mid lean; do
    gen=$(awk '/served_model_name:/ && $NF !~ /embedding|reranker/' "${P}/${f}.yaml" | wc -l)
    caps=$(grep -cE '^[[:space:]]+max_context_window:[[:space:]]*[1-9]' "${P}/${f}.yaml")
    [ "${caps}" -eq "${gen}" ]
  done
}

@test "default serves Flash-Next with MTP, medium effort and top_k 20" {
  grep -q 'served_model_name: qwen3.8-flash-next' "${P}/default.yaml"
  grep -qE '^[[:space:]]+mtp:[[:space:]]*true' "${P}/default.yaml"
  grep -qE '^[[:space:]]+reasoning_effort:[[:space:]]*medium' "${P}/default.yaml"
  grep -qE '^[[:space:]]+top_k:[[:space:]]*20' "${P}/default.yaml"
}

@test "no profile serves qwen3-vl-8b any more" {
  run grep -lE 'served_model_name:[[:space:]]*qwen3-vl-8b' "${P}"/*.yaml
  [ "$status" -ne 0 ]
}

@test "every repo profile validates" {
  for f in "${P}"/*.yaml; do
    run bash -c "source '${REPO_ROOT}/bin/4lm'; validate_profile '$f'"
    [ "$status" -eq 0 ]
  done
}

# ---- installer picks the profile by RAM ----------------------------------------

_install() { # memsize bytes
  STUB_BIN="${BATS_TMPDIR}/stubs-${BATS_TEST_NAME}"
  mkdir -p "${STUB_BIN}"
  printf '#!/usr/bin/env bash\n[[ "$1" == tee ]] && cat >/dev/null\nexit 0\n' >"${STUB_BIN}/sudo"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/pipx"
  cat >"${STUB_BIN}/python3.12" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-m" && "$2" == "venv" && -n "$3" ]]; then
  mkdir -p "$3/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$3/bin/pip"; chmod +x "$3/bin/pip"
fi
exit 0
SH
  chmod +x "${STUB_BIN}"/*
  export NEWSYSLOG_CONF="${BATS_TMPDIR}/newsyslog-${BATS_TEST_NAME}.conf"
  export LEGACY_SUDOERS_FILE="${BATS_TMPDIR}/sudoers-${BATS_TEST_NAME}"
  export SYSCTL_MEMSIZE="$1"
  PATH="${STUB_BIN}:${PATH}" run "${REPO_ROOT}/install.sh" --backend-only
}

@test "fresh install on 256 GB activates default" {
  _install 274877906944
  [ "$status" -eq 0 ]
  [ "$(basename "$(readlink "${HOME}/.4lm/config/active-profile")")" = "default.yaml" ]
}

@test "fresh install on 128 GB activates mid" {
  _install 137438953472
  [ "$status" -eq 0 ]
  [ "$(basename "$(readlink "${HOME}/.4lm/config/active-profile")")" = "mid.yaml" ]
}

@test "fresh install on 64 GB activates lean" {
  _install 68719476736
  [ "$status" -eq 0 ]
  [ "$(basename "$(readlink "${HOME}/.4lm/config/active-profile")")" = "lean.yaml" ]
}

@test "re-install keeps an existing active profile" {
  _install 274877906944
  ln -sfn "${HOME}/.4lm/config/profiles/lean.yaml" "${HOME}/.4lm/config/active-profile"
  _install 274877906944
  [ "$(basename "$(readlink "${HOME}/.4lm/config/active-profile")")" = "lean.yaml" ]
}

# ---- doctor's RAM table ------------------------------------------------------------

@test "doctor knows the minimum RAM of each profile" {
  grep -qE '^[[:space:]]+default\) need_gb=256 ;;' "${REPO_ROOT}/bin/4lm"
  grep -qE '^[[:space:]]+mid\) need_gb=128 ;;' "${REPO_ROOT}/bin/4lm"
  grep -qE '^[[:space:]]+lean\) need_gb=64 ;;' "${REPO_ROOT}/bin/4lm"
}

@test "README, index and CLAUDE.md list the same four profiles" {
  for doc in README.md index.md CLAUDE.md; do
    for p in default mid lean ollama; do
      grep -qE "^\| \`${p}\`" "${REPO_ROOT}/${doc}"
    done
    run grep -cE '^\| `(max-100gb|max-170gb|mlx-coding|mlx-knowledge|ornith-vs-qwen)`' "${REPO_ROOT}/${doc}"
    [ "${output}" = "0" ]
  done
}
