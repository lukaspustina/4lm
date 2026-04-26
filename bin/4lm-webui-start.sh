#!/usr/bin/env bash
# 4lm-webui-start.sh — Starts Open WebUI bound to the local mlx-openai-server.
# Called by launchd. Not meant to be run directly (use `4lm start webui` instead).

set -euo pipefail

readonly LLM_HOME="${HOME}/.4lm"
readonly CONFIG_DIR="${LLM_HOME}/config"
readonly LOG_DIR="${LLM_HOME}/logs"
readonly DATA_DIR="${LLM_HOME}/openwebui-data"
readonly NETWORK_YAML="${CONFIG_DIR}/network.yaml"
readonly SECRET_KEY_FILE="${CONFIG_DIR}/webui_secret_key"

mkdir -p "${LOG_DIR}" "${DATA_DIR}"

# ---- Bind host / port + backend URL from network.yaml ----------------------
NET_MODE="local"
WEBUI_PORT="3000"
BACKEND_PORT="8000"
if [[ -f "${NETWORK_YAML}" ]]; then
  NET_MODE="$(grep '^mode:' "${NETWORK_YAML}" | awk '{print $2}')"
  WEBUI_PORT="$(grep '^webui_port:' "${NETWORK_YAML}" | awk '{print $2}')"
  BACKEND_PORT="$(grep '^backend_port:' "${NETWORK_YAML}" | awk '{print $2}')"
fi
case "${NET_MODE}" in
  local) BIND_HOST="127.0.0.1" ;;
  lan) BIND_HOST="0.0.0.0" ;;
  *)
    echo "[$(date -Iseconds)] FATAL: invalid mode '${NET_MODE}' in ${NETWORK_YAML}" >&2
    exit 78
    ;;
esac
[[ -n "${WEBUI_PORT}" ]] || WEBUI_PORT="3000"
[[ -n "${BACKEND_PORT}" ]] || BACKEND_PORT="8000"

readonly BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}/v1"

# ---- Locate Open WebUI -----------------------------------------------------
WEBUI_BIN="$(command -v open-webui || true)"
if [[ -z "${WEBUI_BIN}" ]]; then
  for candidate in \
    "${HOME}/.local/bin/open-webui" \
    "/opt/homebrew/bin/open-webui" \
    "${HOME}/.pyenv/shims/open-webui"; do
    if [[ -x "${candidate}" ]]; then
      WEBUI_BIN="${candidate}"
      break
    fi
  done
fi
if [[ -z "${WEBUI_BIN}" ]]; then
  echo "[$(date -Iseconds)] FATAL: open-webui not found" >&2
  echo "  Install: pip install -r requirements.txt" >&2
  exit 127
fi

# ---- Environment for Open WebUI --------------------------------------------
export OPENAI_API_BASE_URL="${BACKEND_URL}"
export OPENAI_API_KEY="local-no-auth"
# DATA_DIR is already set above; readonly forbids reassignment, just mark for export.
export DATA_DIR
export ENABLE_OLLAMA_API="False"
export WEBUI_AUTH="True"
# Pending: operator must explicitly promote each new account to admin.
export DEFAULT_USER_ROLE="pending"
export ANONYMIZED_TELEMETRY="False"
export DO_NOT_TRACK="true"
export SCARF_NO_ANALYTICS="true"

# ---- LAN-mode hardening ----------------------------------------------------
if [[ "${NET_MODE}" == "lan" ]]; then
  if [[ ! -f "${SECRET_KEY_FILE}" ]]; then
    umask 077
    openssl rand -hex 32 >"${SECRET_KEY_FILE}"
    chmod 600 "${SECRET_KEY_FILE}"
  fi
  WEBUI_SECRET_KEY="$(cat "${SECRET_KEY_FILE}")"
  export WEBUI_SECRET_KEY
  export WEBUI_REGISTRATION_ENABLED="false"
fi

# ---- Launch ----------------------------------------------------------------
echo "[$(date -Iseconds)] Starting Open WebUI"
echo "  binary:  ${WEBUI_BIN}"
echo "  bind:    ${BIND_HOST}:${WEBUI_PORT} (mode=${NET_MODE})"
echo "  backend: ${BACKEND_URL}"
echo "  data:    ${DATA_DIR}"

exec "${WEBUI_BIN}" serve \
  --host "${BIND_HOST}" \
  --port "${WEBUI_PORT}"
