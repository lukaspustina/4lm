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
[[ "$WEBUI_PORT" =~ ^[0-9]+$ ]] || {
  echo "[$(date -Iseconds)] WARN: invalid WEBUI_PORT, using 3000" >&2
  WEBUI_PORT=3000
}
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || {
  echo "[$(date -Iseconds)] WARN: invalid BACKEND_PORT, using 8080" >&2
  BACKEND_PORT=8080
}

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
export WEBUI_REGISTRATION_ENABLED="false"

# ---- Branding & UX ---------------------------------------------------------
export WEBUI_NAME="4lm"
export ENABLE_COMMUNITY_SHARING="False"
export ENABLE_MESSAGE_RATING="False"
export ENABLE_FOLLOW_UP_GENERATION="True"
export ENABLE_AUTOCOMPLETE_GENERATION="True"

# ---- Personal memory (Claude Desktop "remember about me") -----------------
export ENABLE_MEMORIES="True"

# ---- Web search (DuckDuckGo — no API key, no telemetry) -------------------
export ENABLE_RAG_WEB_SEARCH="True"
export RAG_WEB_SEARCH_ENGINE="duckduckgo"
export RAG_WEB_SEARCH_RESULT_COUNT="3"

# ---- Code interpreter (Pyodide runs in-browser, no extra service) ---------
export ENABLE_CODE_INTERPRETER="True"
export CODE_INTERPRETER_ENGINE="pyodide"

# ---- RAG embeddings via omlx /v1/embeddings -------------------------------
# Requires the active profile to expose an embedding model under the
# served_model_name below (the lean / default / max-100gb profiles all
# load mlx-community/Qwen3-Embedding-8B-4bit-DWQ — MTEB-multilingual
# leader, 32k ctx). If you switch to a profile without an embedding
# model, file uploads / RAG fall back to OpenWebUI's bundled
# sentence-transformers.
export RAG_EMBEDDING_ENGINE="openai"
export RAG_OPENAI_API_BASE_URL="${BACKEND_URL}"
export RAG_OPENAI_API_KEY="${OPENAI_API_KEY}"
export RAG_EMBEDDING_MODEL="qwen3-embedding"

# ---- RAG reranking via omlx /v1/rerank ------------------------------------
# Hybrid search posts retrieved documents to the active profile's
# reranker (served_model_name=qwen3-reranker; lean/default load the
# 0.6B variant, max-100gb the 4B). omlx exposes POST /v1/rerank in
# Cohere/Jina-compatible shape; OpenWebUI's "external" reranker engine
# speaks that contract directly. URL is the FULL endpoint, not a base.
export ENABLE_RAG_HYBRID_SEARCH="True"
export RAG_RERANKING_ENGINE="external"
export RAG_EXTERNAL_RERANKER_URL="http://127.0.0.1:${BACKEND_PORT}/v1/rerank"
export RAG_EXTERNAL_RERANKER_API_KEY="${OPENAI_API_KEY}"
export RAG_RERANKING_MODEL="qwen3-reranker"

# NOTE on PersistentConfig: most ENABLE_* / RAG_* / DEFAULT_* vars above are
# stored in webui.db on first launch. After that the admin UI is the source
# of truth — re-running with a new env value won't override the DB. To force
# env vars to win on every start, set ENABLE_PERSISTENT_CONFIG=False (this
# also disables all admin UI persistence across restarts).

# ---- Secret key (all modes) -----------------------------------------------
if [[ ! -f "${SECRET_KEY_FILE}" ]]; then
  umask 077
  openssl rand -hex 32 >"${SECRET_KEY_FILE}"
  chmod 600 "${SECRET_KEY_FILE}"
fi
WEBUI_SECRET_KEY="$(<"${SECRET_KEY_FILE}")"
export WEBUI_SECRET_KEY

# ---- Launch ----------------------------------------------------------------
echo "[$(date -Iseconds)] Starting Open WebUI"
echo "  binary:  ${WEBUI_BIN}"
echo "  bind:    ${BIND_HOST}:${WEBUI_PORT} (mode=${NET_MODE})"
echo "  backend: ${BACKEND_URL}"
echo "  data:    ${DATA_DIR}"

exec "${WEBUI_BIN}" serve \
  --host "${BIND_HOST}" \
  --port "${WEBUI_PORT}"
