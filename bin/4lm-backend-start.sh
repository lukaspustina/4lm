#!/usr/bin/env bash
# 4lm-backend-start.sh — Starts the backend daemon (mlx-openai-server or Ollama)
# based on the active profile's backend: key.
# Called by launchd. Not meant to be run directly (use `4lm start` instead).

set -euo pipefail

readonly LLM_HOME="${HOME}/.4lm"
readonly CONFIG_DIR="${LLM_HOME}/config"
readonly LOG_DIR="${LLM_HOME}/logs"
readonly NETWORK_YAML="${CONFIG_DIR}/network.yaml"
readonly ACTIVE_CONFIG="${CONFIG_DIR}/active-profile"

mkdir -p "${LOG_DIR}"

if [[ ! -L "${ACTIVE_CONFIG}" && ! -f "${ACTIVE_CONFIG}" ]]; then
  echo "[$(date -Iseconds)] FATAL: No active profile at ${ACTIVE_CONFIG}" >&2
  echo "  Run: 4lm profile set <profile-name>" >&2
  exit 78 # EX_CONFIG
fi

if ! grep -q '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null ||
  ! grep -q '^models:' "${ACTIVE_CONFIG}" 2>/dev/null; then
  echo "[$(date -Iseconds)] FATAL: profile invalid: missing backend or models key" >&2
  exit 78
fi

# ---- Bind host / port from network.yaml ------------------------------------
NET_MODE="local"
NET_PORT="8000"
if [[ -f "${NETWORK_YAML}" ]]; then
  NET_MODE="$(grep '^mode:' "${NETWORK_YAML}" | awk '{print $2}')"
  NET_PORT="$(grep '^backend_port:' "${NETWORK_YAML}" | awk '{print $2}')"
fi
case "${NET_MODE}" in
  local) BIND_HOST="127.0.0.1" ;;
  lan) BIND_HOST="0.0.0.0" ;;
  *)
    echo "[$(date -Iseconds)] FATAL: invalid mode '${NET_MODE}' in ${NETWORK_YAML}" >&2
    exit 78
    ;;
esac
[[ -n "${NET_PORT}" ]] || NET_PORT="8000"

# ---- Detect backend from active profile ------------------------------------
# Duplicated inline from profile_backend() in bin/4lm — cannot source bin/4lm
# from a launchd entry point (circular dependency, different env).
BACKEND_TYPE="mlx"
_be_val="$(grep '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null |
  awk '{print $2}' | tr -d "\"'" || true)"
case "${_be_val}" in
  omlx) BACKEND_TYPE="omlx" ;;
  ollama) BACKEND_TYPE="ollama" ;;
  mlx_lm) BACKEND_TYPE="mlx_lm" ;;
  mlx | "") BACKEND_TYPE="mlx" ;;
  *)
    echo "[$(date -Iseconds)] FATAL: unknown backend '${_be_val}' in ${ACTIVE_CONFIG}" >&2
    exit 78
    ;;
esac

if [[ "${BACKEND_TYPE}" == "omlx" ]]; then
  # ---- omlx ------------------------------------------------------------------
  OMLX_BIN="$(command -v omlx || true)"
  if [[ -z "${OMLX_BIN}" ]]; then
    echo "[$(date -Iseconds)] FATAL: omlx not found in PATH" >&2
    echo "  Install: pipx install omlx" >&2
    exit 127
  fi

  # Extract optional omlx: block fields via standalone awk (cannot source bin/4lm).
  # Use while-read with | separator to safely assign values without eval.
  _OMLX_MAX_PROC_MEM=""
  _OMLX_MAX_MODEL_MEM=""
  _OMLX_HOT_CACHE=""
  _OMLX_SSD_CACHE_DIR=""
  _OMLX_MAX_CONCUR=""
  while IFS='|' read -r _omlx_key _omlx_val; do
    case "${_omlx_key}" in
      max_process_memory) _OMLX_MAX_PROC_MEM="${_omlx_val}" ;;
      max_model_memory) _OMLX_MAX_MODEL_MEM="${_omlx_val}" ;;
      hot_cache_max_size) _OMLX_HOT_CACHE="${_omlx_val}" ;;
      paged_ssd_cache_dir) _OMLX_SSD_CACHE_DIR="${_omlx_val}" ;;
      max_concurrent_requests) _OMLX_MAX_CONCUR="${_omlx_val}" ;;
    esac
  done < <(awk '
    /^omlx:/ { in_block=1; next }
    in_block && /^[^[:space:]]/ { in_block=0 }
    function extract(line, key,   val) {
      sub("^[[:space:]]+" key ":[[:space:]]*", "", line)
      gsub(/^["\x27]|["\x27]$/, "", line)
      print key "|" line
    }
    in_block && /^[[:space:]]+max_process_memory:/     { extract($0, "max_process_memory") }
    in_block && /^[[:space:]]+max_model_memory:/       { extract($0, "max_model_memory") }
    in_block && /^[[:space:]]+hot_cache_max_size:/     { extract($0, "hot_cache_max_size") }
    in_block && /^[[:space:]]+paged_ssd_cache_dir:/    { extract($0, "paged_ssd_cache_dir") }
    in_block && /^[[:space:]]+max_concurrent_requests:/ { extract($0, "max_concurrent_requests") }
  ' "${ACTIVE_CONFIG}")

  # Tilde-expand and validate paged_ssd_cache_dir.
  if [[ -n "${_OMLX_SSD_CACHE_DIR}" ]]; then
    _expanded="${_OMLX_SSD_CACHE_DIR/#\~/$HOME}"
    # Component check (path-traversal prevention).
    if [[ "${_expanded}" == *"/../"* || "${_expanded}" == "../"* || "${_expanded}" == *"/.." ]]; then
      echo "[$(date -Iseconds)] FATAL: invalid paged_ssd_cache_dir value: ${_OMLX_SSD_CACHE_DIR}" >&2
      exit 78
    fi
    # Regex check: only safe characters allowed.
    if [[ ! "${_expanded}" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
      echo "[$(date -Iseconds)] FATAL: invalid paged_ssd_cache_dir value: ${_OMLX_SSD_CACHE_DIR}" >&2
      exit 78
    fi
    _OMLX_SSD_CACHE_DIR="${_expanded}"
  fi

  echo "[$(date -Iseconds)] Starting omlx"
  echo "  binary:  ${OMLX_BIN}"
  echo "  profile: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
  echo "  bind:    ${BIND_HOST}:${NET_PORT} (mode=${NET_MODE})"

  # Build omlx serve arguments.
  OMLX_ARGS=(serve
    --host "${BIND_HOST}"
    --port "${NET_PORT}"
  )
  [[ -n "${_OMLX_MAX_PROC_MEM}" ]] && OMLX_ARGS+=(--max-process-memory "${_OMLX_MAX_PROC_MEM}")
  [[ -n "${_OMLX_MAX_MODEL_MEM}" ]] && OMLX_ARGS+=(--max-model-memory "${_OMLX_MAX_MODEL_MEM}")
  [[ -n "${_OMLX_HOT_CACHE}" ]] && OMLX_ARGS+=(--hot-cache-max-size "${_OMLX_HOT_CACHE}")
  [[ -n "${_OMLX_SSD_CACHE_DIR}" ]] && OMLX_ARGS+=(--paged-ssd-cache-dir "${_OMLX_SSD_CACHE_DIR}")
  [[ -n "${_OMLX_MAX_CONCUR}" ]] && OMLX_ARGS+=(--max-concurrent-requests "${_OMLX_MAX_CONCUR}")

  exec "${OMLX_BIN}" "${OMLX_ARGS[@]}"

elif [[ "${BACKEND_TYPE}" == "ollama" ]]; then
  # ---- Ollama ----------------------------------------------------------------
  OLLAMA_BIN="$(command -v ollama || true)"
  if [[ -z "${OLLAMA_BIN}" ]]; then
    echo "[$(date -Iseconds)] FATAL: ollama not found in PATH" >&2
    echo "  Install: brew install ollama" >&2
    exit 127
  fi

  export OLLAMA_HOST="${BIND_HOST}:${NET_PORT}"

  echo "[$(date -Iseconds)] Starting Ollama"
  echo "  binary:  ${OLLAMA_BIN}"
  echo "  profile: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
  echo "  bind:    ${OLLAMA_HOST} (mode=${NET_MODE})"

  exec "${OLLAMA_BIN}" serve

else
  # ---- Wired memory limit (best-effort, applies to mlx and mlx_lm) ----------
  # Required for large MoE models on 128 GB Macs. Needs sudoers config (see docs/setup.md §Sudoers).
  # Sudoers literal must match exactly: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
  CURRENT_LIMIT="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
  if [[ "${CURRENT_LIMIT}" -lt 98304 ]]; then
    if ! sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304 >/dev/null 2>&1; then
      echo "[$(date -Iseconds)] WARN: wired_limit_mb not set — run \`4lm doctor\` for fix" >&2
    fi
  fi

  if [[ "${BACKEND_TYPE}" == "mlx_lm" ]]; then
    # ---- mlx_lm.server -------------------------------------------------------
    # python3 lives in the same venv as mlx-openai-server (mlx_lm co-installed).
    MLX_LM_PY=""
    _mlx_bin="$(command -v mlx-openai-server || true)"
    if [[ -n "${_mlx_bin}" ]]; then
      _candidate="$(dirname "${_mlx_bin}")/python3"
      [[ -x "${_candidate}" ]] && MLX_LM_PY="${_candidate}"
    fi
    if [[ -z "${MLX_LM_PY}" ]]; then
      for candidate in \
        "${HOME}/.local/pipx/venvs/mlx-openai-server/bin/python3" \
        "$(command -v python3.12 || true)"; do
        [[ -n "${candidate}" && -x "${candidate}" ]] && {
          MLX_LM_PY="${candidate}"
          break
        }
      done
    fi
    if [[ -z "${MLX_LM_PY}" ]]; then
      echo "[$(date -Iseconds)] FATAL: python3 not found for mlx_lm backend" >&2
      echo "  Install mlx-openai-server via pipx (mlx_lm is co-installed in its venv)" >&2
      exit 127
    fi

    MLX_LM_MODEL="$(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $NF; exit}' "${ACTIVE_CONFIG}")"
    if [[ -z "${MLX_LM_MODEL}" ]]; then
      echo "[$(date -Iseconds)] FATAL: no model_path found in ${ACTIVE_CONFIG}" >&2
      exit 78
    fi

    echo "[$(date -Iseconds)] Starting mlx_lm.server"
    echo "  python:  ${MLX_LM_PY}"
    echo "  model:   ${MLX_LM_MODEL}"
    echo "  profile: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
    echo "  bind:    ${BIND_HOST}:${NET_PORT} (mode=${NET_MODE})"

    exec "${MLX_LM_PY}" -m mlx_lm server \
      --model "${MLX_LM_MODEL}" \
      --host "${BIND_HOST}" \
      --port "${NET_PORT}"

  else
    # ---- mlx-openai-server ---------------------------------------------------
    MLX_BIN="$(command -v mlx-openai-server || true)"
    if [[ -z "${MLX_BIN}" ]]; then
      for candidate in \
        "${HOME}/.local/bin/mlx-openai-server" \
        "/opt/homebrew/bin/mlx-openai-server" \
        "${HOME}/.pyenv/shims/mlx-openai-server"; do
        if [[ -x "${candidate}" ]]; then
          MLX_BIN="${candidate}"
          break
        fi
      done
    fi
    if [[ -z "${MLX_BIN}" ]]; then
      echo "[$(date -Iseconds)] FATAL: mlx-openai-server not found in PATH or common locations" >&2
      echo "  Install: pip install -r requirements.txt" >&2
      exit 127
    fi

    echo "[$(date -Iseconds)] Starting mlx-openai-server"
    echo "  binary: ${MLX_BIN}"
    echo "  config: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
    echo "  bind:   ${BIND_HOST}:${NET_PORT} (mode=${NET_MODE})"

    # --repetition-penalty 1.05: mlx-openai-server defaults to 1.0 (off), and the
    # OpenAI API spec has no `repetition_penalty` field — clients (OpenCode,
    # Open WebUI) can't pass it per-request. Qwen3.6 in MLX 8-bit reliably loops
    # at 1.0 ("For client X: …" cycling verbatim). 1.05 is the Qwen authors'
    # recommended baseline: enough to break loops, low enough not to harm
    # normal output. Override per-request with frequency_penalty/presence_penalty
    # (those ARE in the OpenAI spec).
    exec "${MLX_BIN}" launch \
      --config "${ACTIVE_CONFIG}" \
      --host "${BIND_HOST}" \
      --port "${NET_PORT}" \
      --repetition-penalty 1.05
  fi
fi
