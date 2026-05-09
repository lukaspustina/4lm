#!/usr/bin/env bash
# uninstall.sh — Remove 4lm completely.
#
# What it does:
#   1. Boots out running agents (com.4lm.{backend,webui})
#   2. Removes ~/.local/bin/4lm symlink
#   3. Removes ~/.4lm/ (configs, profiles, launchd plists, logs, openwebui-data)
#   4. pipx uninstall each package listed in requirements.txt
#   5. Removes /etc/newsyslog.d/4lm.conf (requires sudo)
#
# DESTRUCTIVE. ~/.4lm/openwebui-data/ contains WebUI chat history, MCP
# configs, and uploaded files. Back it up first if you want to keep any of it.

set -euo pipefail

readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LLM_HOME="${HOME}/.4lm"
readonly BIN_DIR="${HOME}/.local/bin"
readonly NEWSYSLOG_CONF="/etc/newsyslog.d/4lm.conf"
readonly BACKEND_LABEL="com.4lm.backend"
readonly WEBUI_LABEL="com.4lm.webui"

UID_NUM="$(id -u)"
readonly UID_NUM

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'
  C_GRN=$'\033[0;32m'
  C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'
  C_DIM=$'\033[2m'
  C_RST=$'\033[0m'
else
  C_RED=""
  C_GRN=""
  C_YEL=""
  C_BLU=""
  C_DIM=""
  C_RST=""
fi
ok() { echo "${C_GRN}✓${C_RST} $*"; }
warn() { echo "${C_YEL}⚠${C_RST} $*" >&2; }
info() { echo "${C_BLU}→${C_RST} $*"; }

echo "${C_DIM}════════════════════════════════════${C_RST}"
echo " 4lm — Uninstaller"
echo "${C_DIM}════════════════════════════════════${C_RST}"
echo
echo "${C_RED}Will remove:${C_RST}"
echo "  - ~/.4lm/         (configs, profiles, logs, openwebui-data)"
echo "  - ~/.local/bin/4lm"
echo "  - pipx-installed packages from requirements.txt"
echo "  - /etc/newsyslog.d/4lm.conf"
echo
echo "Press Ctrl-C within 3 s to abort."
sleep 3

# ---- 1. Bootout running agents --------------------------------------------
info "Booting out agents…"
for label in "${BACKEND_LABEL}" "${WEBUI_LABEL}"; do
  if launchctl print "gui/${UID_NUM}/${label}" >/dev/null 2>&1; then
    launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
    ok "bootout ${label}"
  fi
done

# ---- 2. Remove CLI symlink ------------------------------------------------
if [[ -L "${BIN_DIR}/4lm" ]]; then
  rm "${BIN_DIR}/4lm"
  ok "removed ${BIN_DIR}/4lm"
fi

# ---- 3. Remove ~/.4lm/ ----------------------------------------------------
if [[ -d "${LLM_HOME}/venv" ]]; then
  rm -rf "${LLM_HOME}/venv"
  ok "removed ${LLM_HOME}/venv"
fi
if [[ -d "${LLM_HOME}" ]]; then
  rm -rf "${LLM_HOME}"
  ok "removed ${LLM_HOME}"
fi

# ---- 4. pipx uninstall packages -------------------------------------------
if command -v pipx >/dev/null; then
  # Uninstall packages from requirements.txt.
  if [[ -f "${SOURCE_DIR}/requirements.txt" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" || "${line}" =~ ^# ]] && continue
      pkg="${line%%==*}"
      # `pipx list --short` normalises names: drops [extras], turns _ into -.
      pkg_listed="${pkg%%[*}"
      pkg_listed="${pkg_listed//_/-}"
      if pipx list --short 2>/dev/null | grep -qE "^${pkg_listed} "; then
        pipx uninstall "${pkg_listed}" >/dev/null
        ok "pipx uninstall ${pkg_listed}"
      fi
    done <"${SOURCE_DIR}/requirements.txt"
  fi
  # Uninstall packages installed from git (not in requirements.txt).
  for _pkg in omlx mlx-openai-server; do
    if pipx list --short 2>/dev/null | grep -qE "^${_pkg} "; then
      pipx uninstall "${_pkg}" >/dev/null
      ok "pipx uninstall ${_pkg}"
    fi
  done
fi

# ---- 5. Remove newsyslog config -------------------------------------------
if [[ -f "${NEWSYSLOG_CONF}" ]]; then
  echo "Requires sudo: removing ${NEWSYSLOG_CONF}"
  sudo rm "${NEWSYSLOG_CONF}"
  ok "removed ${NEWSYSLOG_CONF}"
fi

echo
echo "${C_GRN}Uninstall complete.${C_RST}"
