#!/usr/bin/env bash
# 4lm-backend-start.sh — Starts the mlx-openai-server backend daemon.
# Called by launchd. Not meant to be run directly (use `4lm start` instead).

set -euo pipefail

readonly LLM_HOME="${HOME}/.4lm"
readonly CONFIG_DIR="${LLM_HOME}/config"
readonly LOG_DIR="${LLM_HOME}/logs"
readonly NETWORK_YAML="${CONFIG_DIR}/network.yaml"
readonly ACTIVE_CONFIG="${CONFIG_DIR}/mlx-active"

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

# ---- Locate mlx-openai-server ---------------------------------------------
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

# ---- Wired memory limit (best-effort) --------------------------------------
# Required for large MoE models on 128 GB Macs. Needs sudoers config (see docs/setup.md §Sudoers).
# Sudoers literal must match exactly: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
CURRENT_LIMIT="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "${CURRENT_LIMIT}" -lt 98304 ]]; then
  if ! sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304 >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] WARN: wired_limit_mb not set — run \`4lm doctor\` for fix" >&2
  fi
fi

# ---- Launch ----------------------------------------------------------------
echo "[$(date -Iseconds)] Starting mlx-openai-server"
echo "  binary: ${MLX_BIN}"
echo "  config: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
echo "  bind:   ${BIND_HOST}:${NET_PORT} (mode=${NET_MODE})"

exec "${MLX_BIN}" \
  --config "${ACTIVE_CONFIG}" \
  --host "${BIND_HOST}" \
  --port "${NET_PORT}"
