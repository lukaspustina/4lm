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
_be_val="$(grep '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null \
  | awk '{print $2}' | tr -d "\"'" || true)"
case "${_be_val}" in
  ollama) BACKEND_TYPE="ollama" ;;
  mlx | "") BACKEND_TYPE="mlx" ;;
  *)
    echo "[$(date -Iseconds)] FATAL: unknown backend '${_be_val}' in ${ACTIVE_CONFIG}" >&2
    exit 78
    ;;
esac

if [[ "${BACKEND_TYPE}" == "ollama" ]]; then
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
  # ---- mlx-openai-server -----------------------------------------------------

  # ---- Wired memory limit (best-effort) ------------------------------------
  # Required for large MoE models on 128 GB Macs. Needs sudoers config (see docs/setup.md §Sudoers).
  # Sudoers literal must match exactly: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
  CURRENT_LIMIT="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
  if [[ "${CURRENT_LIMIT}" -lt 98304 ]]; then
    if ! sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304 >/dev/null 2>&1; then
      echo "[$(date -Iseconds)] WARN: wired_limit_mb not set — run \`4lm doctor\` for fix" >&2
    fi
  fi

  # ---- Locate mlx-openai-server --------------------------------------------
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
