#!/usr/bin/env bash
# install.sh — One-shot installer for 4lm.
#
# What it does:
#   1. Verifies prerequisites (macOS arm64, Python 3.11+)
#   2. Creates ~/.4lm/{bin,config/profiles,launchd,logs}
#   3. Installs scripts, profile YAMLs, plists (plists in ~/.4lm/launchd/, NOT ~/Library/LaunchAgents/)
#   4. Seeds ~/.4lm/config/network.yaml from network.example.yaml if absent
#   5. pipx install each pinned package from requirements.txt
#   6. sudo tee /etc/newsyslog.d/4lm.conf for log rotation
#   7. Symlinks ~/.local/bin/4lm → ~/.4lm/bin/4lm
#
# Idempotent. Re-run after updates is safe. Does NOT bootstrap services.
# Stop running agents with `4lm stop` before re-running this script if the
# plist contents have changed.
# After install, run: 4lm start

set -euo pipefail

readonly LLM_HOME="${HOME}/.4lm"
readonly LAUNCHD_DIR="${LLM_HOME}/launchd"
readonly LOG_DIR="${LLM_HOME}/logs"
readonly CONFIG_DIR="${LLM_HOME}/config"
readonly PROFILES_DIR="${CONFIG_DIR}/profiles"
readonly BIN_DIR="${HOME}/.local/bin"

readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
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
die() {
  echo "${C_RED}✗${C_RST} $*" >&2
  exit 1
}

echo "${C_DIM}════════════════════════════════════${C_RST}"
echo " 4lm — Installer"
echo "${C_DIM}════════════════════════════════════${C_RST}"

# ---- 1. Prereqs ------------------------------------------------------------
info "Checking prerequisites…"
[[ "$(uname)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required (uname -m must be arm64)"

if ! command -v python3 >/dev/null; then die "python3 not found"; fi
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
ok "Python ${PY_VER}"

# ---- 2. Directories --------------------------------------------------------
info "Creating ${LLM_HOME}/…"
mkdir -p "${LLM_HOME}/bin" \
  "${PROFILES_DIR}" \
  "${LAUNCHD_DIR}" \
  "${LOG_DIR}" \
  "${BIN_DIR}"

# ---- 3. Install scripts ---------------------------------------------------
info "Installing scripts…"
for script in 4lm 4lm-backend-start.sh 4lm-webui-start.sh; do
  cp "${SOURCE_DIR}/bin/${script}" "${LLM_HOME}/bin/${script}"
  chmod 755 "${LLM_HOME}/bin/${script}"
done
ok "Scripts → ${LLM_HOME}/bin/"

# ---- 4. Install profile YAMLs (don't overwrite local edits) ---------------
info "Installing profile templates…"
for profile in "${SOURCE_DIR}"/config/profiles/*.yaml; do
  [[ -f "${profile}" ]] || continue
  target="${PROFILES_DIR}/$(basename "${profile}")"
  if [[ -f "${target}" ]]; then
    info "Profile exists, not overwriting: $(basename "${profile}")"
  else
    cp "${profile}" "${target}"
    ok "Profile → $(basename "${profile}")"
  fi
done

# ---- 5. Active profile default --------------------------------------------
ACTIVE="${CONFIG_DIR}/mlx-active"
if [[ ! -L "${ACTIVE}" && ! -f "${ACTIVE}" ]]; then
  ln -sfn "${PROFILES_DIR}/default.yaml" "${ACTIVE}"
  ok "Active profile → default"
else
  info "Active profile already set: $(readlink "${ACTIVE}" 2>/dev/null || echo "${ACTIVE}")"
fi

# ---- 6. Seed network.yaml from example ------------------------------------
NETWORK_YAML="${CONFIG_DIR}/network.yaml"
NETWORK_EXAMPLE_SRC="${SOURCE_DIR}/config/network.example.yaml"
if [[ ! -f "${NETWORK_YAML}" ]]; then
  cp "${NETWORK_EXAMPLE_SRC}" "${NETWORK_YAML}"
  ok "network.yaml seeded from network.example.yaml"
else
  info "network.yaml exists, not overwriting"
fi

# ---- 7. Install plists into ~/.4lm/launchd/ -------------------------------
info "Installing launchd plists into ${LAUNCHD_DIR}/ (not ~/Library/LaunchAgents/)…"
for plist_src in "${SOURCE_DIR}"/launchd/*.plist; do
  [[ -f "${plist_src}" ]] || continue
  target="${LAUNCHD_DIR}/$(basename "${plist_src}")"
  sed "s|__HOME__|${HOME}|g" "${plist_src}" >"${target}"
  ok "Plist → $(basename "${plist_src}")"
done

# ---- 8. Symlink CLI ------------------------------------------------------
info "Linking 4lm command…"
ln -sfn "${LLM_HOME}/bin/4lm" "${BIN_DIR}/4lm"
# Remove legacy llm symlink if present and points at us.
if [[ -L "${BIN_DIR}/llm" ]]; then
  legacy_target="$(readlink "${BIN_DIR}/llm")"
  case "${legacy_target}" in
    *llm-stack* | *"/.4lm/"*)
      rm "${BIN_DIR}/llm"
      ok "Removed legacy llm symlink"
      ;;
  esac
fi
ok "4lm → ${BIN_DIR}/4lm"

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  warn "${BIN_DIR} is not in your PATH"
  echo "    Add to ~/.zshrc:  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

# ---- 9. pipx install pinned deps ------------------------------------------
# Homebrew's Python is PEP 668 "externally-managed", so plain `pip install`
# fails. Both deps ship CLI entrypoints, so pipx (per-app venv) is the right
# tool. mlx-openai-server 1.7.1 requires Python >=3.11,<3.13, so we pin pipx
# to python3.12 (or 3.11) regardless of the system default.
info "Installing Python deps with pipx…"
if ! command -v pipx >/dev/null; then
  die "pipx not found — run: make bootstrap"
fi

PIPX_PYTHON=""
for candidate in python3.12 python3.11; do
  if command -v "${candidate}" >/dev/null; then
    PIPX_PYTHON="${candidate}"
    break
  fi
done
if [[ -z "${PIPX_PYTHON}" ]]; then
  die "no compatible Python found (need 3.11 or 3.12) — run: make bootstrap"
fi
info "using ${PIPX_PYTHON} for pipx venvs"

while IFS= read -r line; do
  [[ -z "${line}" || "${line}" =~ ^# ]] && continue
  pkg="${line%%==*}"
  ver="${line#*==}"
  if pipx list --short 2>/dev/null | grep -qE "^${pkg} ${ver}( |$)"; then
    info "${pkg}==${ver} already installed"
  else
    info "pipx install --python ${PIPX_PYTHON} ${pkg}==${ver}"
    pipx install --python "${PIPX_PYTHON}" --force "${pkg}==${ver}"
  fi
done <"${SOURCE_DIR}/requirements.txt"

# ---- 10. newsyslog log rotation ------------------------------------------
NEWSYSLOG_CONF="/etc/newsyslog.d/4lm.conf"
NEWSYSLOG_BODY="${HOME}/.4lm/logs/backend.log               600  7     10240 *     J
${HOME}/.4lm/logs/webui.log                 600  7     10240 *     J"
if [[ -f "${NEWSYSLOG_CONF}" ]] && grep -qF "${HOME}/.4lm/logs/backend.log" "${NEWSYSLOG_CONF}"; then
  ok "newsyslog rotation already installed at ${NEWSYSLOG_CONF}"
else
  echo "Requires sudo: installing /etc/newsyslog.d/4lm.conf"
  printf "# logfilename                                 [owner:group]  mode count size  when  flags\n%s\n" "${NEWSYSLOG_BODY}" |
    sudo tee "${NEWSYSLOG_CONF}" >/dev/null
  ok "newsyslog rotation → ${NEWSYSLOG_CONF}"
fi

# ---- 11. Wired memory hint ------------------------------------------------
CURRENT="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "${CURRENT}" -lt 98304 ]]; then
  warn "iogpu.wired_limit_mb is ${CURRENT} (recommend ≥98304)"
  echo "    See docs/setup.md §Sudoers for the one-line fix."
else
  ok "iogpu.wired_limit_mb = ${CURRENT}"
fi

# ---- 12. Final summary ----------------------------------------------------
echo
echo "${C_GRN}════════════════════════════════════${C_RST}"
echo "${C_GRN} Installation complete${C_RST}"
echo "${C_GRN}════════════════════════════════════${C_RST}"
echo
echo "Next steps:"
echo "  ${C_BLU}1.${C_RST} Pre-download models (see docs/setup.md):"
echo "       ${C_DIM}huggingface-cli download mlx-community/GLM-4.7-Flash-8bit${C_RST}"
echo "       ${C_DIM}huggingface-cli download unsloth/Qwen3.6-35B-A3B-MLX-8bit${C_RST}"
echo
echo "  ${C_BLU}2.${C_RST} Start the stack:"
echo "       ${C_DIM}4lm start${C_RST}"
echo
echo "  ${C_BLU}3.${C_RST} Verify:"
echo "       ${C_DIM}4lm status${C_RST}"
echo "       ${C_DIM}4lm health${C_RST}"
echo
echo "Services do NOT auto-start at login. Run \`4lm start\` after each reboot."
