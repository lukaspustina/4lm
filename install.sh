#!/usr/bin/env bash
# install.sh — One-shot installer for 4lm.
#
# Usage:
#   ./install.sh                 # full install (workstation: backend + WebUI + OpenCode)
#   ./install.sh --backend-only  # headless LAN inference server (backend only)
#
# What it does:
#   1. Verifies prerequisites (macOS arm64, Python 3.11+)
#   2. Creates ~/.4lm/{bin,config/profiles,launchd,logs}
#   3. Installs scripts, profile YAMLs, plists (plists live in ~/.4lm/launchd/,
#      NOT ~/Library/LaunchAgents/, so launchd never auto-loads them)
#      With --backend-only: 4lm-webui-start.sh and the webui plist are skipped.
#   4. Seeds ~/.4lm/config/network.yaml from network.example.yaml if absent
#   5. Symlinks ~/.local/bin/4lm → ~/.4lm/bin/4lm
#   6. pipx install each pinned package from requirements.txt (python3.12)
#      With --backend-only: the open-webui line is filtered out in-memory.
#   7. sudo tee /etc/newsyslog.d/4lm.conf for log rotation
#      Two grep-guarded `sudo tee -a` appends: backend.log always; webui.log
#      only when not --backend-only.
#   8. Installs /etc/sudoers.d/4lm-stack and sets iogpu.wired_limit_mb=98304
#   9. Seeds ~/.config/opencode/opencode.jsonc from the template if absent
#      With --backend-only: skipped.
#
# Idempotent. Re-run after updates is safe. Does NOT bootstrap services.
# Re-running with --backend-only over an existing full install is
# non-destructive: prints a notice and leaves webui artifacts in place.
# Stop running agents with `4lm stop` before re-running this script if the
# plist contents have changed.
# After install, run: 4lm start

set -euo pipefail

# ---- 0. Argument parsing ---------------------------------------------------
BACKEND_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-only)
      BACKEND_ONLY=1
      shift
      ;;
    -h | --help)
      sed -n '2,32p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "✗ unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done
readonly BACKEND_ONLY

readonly WEBUI_ARTIFACTS_NOTICE="WebUI artifacts found; not managed in backend-only mode."

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
if [[ "${BACKEND_ONLY}" -eq 1 ]]; then
  echo " 4lm — Installer (backend-only)"
else
  echo " 4lm — Installer"
fi
echo "${C_DIM}════════════════════════════════════${C_RST}"

# ---- 0b. Detect existing webui artifacts ----------------------------------
# Used to emit the non-destructive notice (R8) when --backend-only runs over
# an install that already has webui artifacts. We do not modify them.
webui_artifacts_present=0
if [[ -f "${LAUNCHD_DIR}/com.4lm.webui.plist" ]] ||
  [[ -f "${LLM_HOME}/bin/4lm-webui-start.sh" ]] ||
  (command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -q '^open-webui '); then
  webui_artifacts_present=1
fi
readonly webui_artifacts_present

if [[ "${BACKEND_ONLY}" -eq 1 && "${webui_artifacts_present}" -eq 1 ]]; then
  echo "${WEBUI_ARTIFACTS_NOTICE}"
fi

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
  "${BIN_DIR}" \
  "${LLM_HOME}/runtime" \
  "${LLM_HOME}/cache/omlx"

# Create omlx config directory with restricted permissions.
if [[ ! -d "${HOME}/.omlx" ]]; then
  mkdir -m 0700 "${HOME}/.omlx"
  # shellcheck disable=SC2088  # tilde in display string is intentional
  ok "~/.omlx/ created"
else
  # shellcheck disable=SC2088
  ok "~/.omlx/ already exists"
fi

# ---- 3. Install scripts ---------------------------------------------------
info "Installing scripts…"
scripts_to_install=(4lm 4lm-backend-start.sh 4lm_helpers.py)
if [[ "${BACKEND_ONLY}" -eq 0 ]]; then
  scripts_to_install+=(4lm-webui-start.sh)
fi
for script in "${scripts_to_install[@]}"; do
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

# Warn about profiles in ~/.4lm/config/profiles/ that no longer exist in the repo.
for installed in "${PROFILES_DIR}"/*.yaml; do
  [[ -f "${installed}" ]] || continue
  base="$(basename "${installed}")"
  if [[ ! -f "${SOURCE_DIR}/config/profiles/${base}" ]]; then
    warn "Orphaned profile (not in repo, remove if unused): ${base}"
  fi
done

# ---- 4b. Install chat template files (always overwrite — not user-editable) -
for tmpl in "${SOURCE_DIR}"/config/*.jinja; do
  [[ -f "${tmpl}" ]] || continue
  cp "${tmpl}" "${CONFIG_DIR}/$(basename "${tmpl}")"
  ok "Chat template → $(basename "${tmpl}")"
done

# ---- 4c. Migrate legacy symlink names (mlx-active → active-profile) --------
OLD_ACTIVE="${CONFIG_DIR}/mlx-active"
OLD_PREVIOUS="${CONFIG_DIR}/mlx-previous"
NEW_ACTIVE="${CONFIG_DIR}/active-profile"
NEW_PREVIOUS="${CONFIG_DIR}/previous-profile"
if [[ -L "${OLD_ACTIVE}" && ! -L "${NEW_ACTIVE}" ]]; then
  ln -sfn "$(readlink "${OLD_ACTIVE}")" "${NEW_ACTIVE}"
  rm "${OLD_ACTIVE}"
  ok "Migrated mlx-active → active-profile"
fi
if [[ -f "${OLD_PREVIOUS}" && ! -f "${NEW_PREVIOUS}" ]]; then
  mv "${OLD_PREVIOUS}" "${NEW_PREVIOUS}"
  ok "Migrated mlx-previous → previous-profile"
fi

# ---- 5. Active profile default --------------------------------------------
ACTIVE="${CONFIG_DIR}/active-profile"
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
  base="$(basename "${plist_src}")"
  # Skip the webui plist in backend-only mode (R4).
  if [[ "${BACKEND_ONLY}" -eq 1 && "${base}" == "com.4lm.webui.plist" ]]; then
    continue
  fi
  target="${LAUNCHD_DIR}/${base}"
  sed "s|__HOME__|${HOME}|g" "${plist_src}" >"${target}"
  ok "Plist → ${base}"
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
# fails. Packages ship CLI entrypoints, so pipx (per-app venv) is the right
# tool. Pin to python3.12 (or 3.11) for compatibility.
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

# Remove legacy mlx-openai-server pipx env if present (replaced by omlx).
if pipx list --short 2>/dev/null | grep -q "^mlx-openai-server "; then
  info "Removing legacy mlx-openai-server pipx env…"
  pipx uninstall mlx-openai-server >/dev/null
  ok "mlx-openai-server removed"
fi

while IFS= read -r line; do
  [[ -z "${line}" || "${line}" =~ ^# ]] && continue
  pkg="${line%%==*}"
  ver="${line#*==}"
  # `pipx list --short` normalises names: drops [extras], turns _ into -.
  pkg_listed="${pkg%%[*}"
  pkg_listed="${pkg_listed//_/-}"
  # Skip open-webui in backend-only mode (R2). The on-disk requirements.txt
  # is not modified — only the in-memory iteration filters it.
  if [[ "${BACKEND_ONLY}" -eq 1 && "${pkg_listed}" == "open-webui" ]]; then
    info "skipping ${pkg} (backend-only)"
    continue
  fi
  if pipx list --short 2>/dev/null | grep -qE "^${pkg_listed} ${ver}( |$)"; then
    info "${pkg}==${ver} already installed"
  else
    info "pipx install --python ${PIPX_PYTHON} ${pkg}==${ver}"
    pipx install --python "${PIPX_PYTHON}" --force "${pkg}==${ver}"
  fi
done <"${SOURCE_DIR}/requirements.txt"

# ---- 9b. Install omlx from GitHub (not on PyPI) ----------------------------
# omlx has no PyPI release; install directly from source.
# Pinned to a specific commit for reproducibility; bump deliberately.
# Idempotent: skip if already installed.
readonly OMLX_GIT_REF="51907f08074742defec4375fb629e289801a8a9f" # 2026-05-14
if pipx list --short 2>/dev/null | grep -q "^omlx "; then
  ok "omlx already installed ($(pipx list --short 2>/dev/null | grep "^omlx " | awk '{print $2}'))"
else
  info "pipx install --python ${PIPX_PYTHON} git+https://github.com/jundot/omlx.git@${OMLX_GIT_REF}"
  pipx install --python "${PIPX_PYTHON}" "git+https://github.com/jundot/omlx.git@${OMLX_GIT_REF}"
fi

# ---- 9c. Inject extras into huggingface-hub venv ----------------------------
# hf-transfer: Rust-backed parallel downloader; activated via
#   HF_HUB_ENABLE_HF_TRANSFER=1 at download time.
# socksio: required by httpx (used by huggingface_hub) when macOS system
#   network settings configure a SOCKS proxy; without it downloads fail or
#   fall back to a slow path.
if pipx list --short 2>/dev/null | grep -q "^huggingface-hub "; then
  for _pkg in hf-transfer socksio; do
    if pipx runpip huggingface-hub show "${_pkg}" >/dev/null 2>&1; then
      ok "${_pkg} already injected into huggingface-hub venv"
    else
      info "pipx inject huggingface-hub ${_pkg}"
      pipx inject huggingface-hub "${_pkg}"
      ok "${_pkg} injected"
    fi
  done
fi

# ---- 9e. Python helpers venv ------------------------------------------------
info "Setting up Python helpers venv…"
if [[ ! -x "${LLM_HOME}/venv/bin/python" ]]; then
  "${PIPX_PYTHON}" -m venv "${LLM_HOME}/venv"
  ok "venv created at ${LLM_HOME}/venv"
else
  ok "venv already exists at ${LLM_HOME}/venv"
fi
"${LLM_HOME}/venv/bin/pip" install --quiet -r "${SOURCE_DIR}/requirements-helpers.txt"
ok "helpers deps installed from requirements-helpers.txt"

# ---- 10. newsyslog log rotation ------------------------------------------
# Two grep-guarded `sudo tee -a` appends — one for backend.log (always), one
# for webui.log (only when not --backend-only). The header line is written
# only when the file does not exist; re-runs do not produce duplicate lines.
# NEWSYSLOG_CONF is overrideable via env var for the bats test harness.
NEWSYSLOG_CONF="${NEWSYSLOG_CONF:-/etc/newsyslog.d/4lm.conf}"
NEWSYSLOG_HEADER="# logfilename                                 [owner:group]  mode count size  when  flags"
NEWSYSLOG_BACKEND_LINE="${HOME}/.4lm/logs/backend.log               600  7     10240 *     J"
NEWSYSLOG_WEBUI_LINE="${HOME}/.4lm/logs/webui.log                 600  7     10240 *     J"

if grep -qE '^[^#]*\.4lm/logs/backend\.log[[:space:]]' "${NEWSYSLOG_CONF}" 2>/dev/null; then
  ok "newsyslog backend.log entry already present"
else
  # Per SDD R5: the header comment is written only by the unconditional
  # backend `sudo tee -a` block, gated by [[ ! -f NEWSYSLOG_CONF ]] so a
  # re-run does not produce a duplicate header. Same `-a` operation as the
  # entry — single sudo invocation, single file write.
  if [[ ! -f "${NEWSYSLOG_CONF}" ]]; then
    echo "Requires sudo: creating ${NEWSYSLOG_CONF}"
    printf '%s\n%s\n' "${NEWSYSLOG_HEADER}" "${NEWSYSLOG_BACKEND_LINE}" |
      sudo tee -a "${NEWSYSLOG_CONF}" >/dev/null
  else
    printf '%s\n' "${NEWSYSLOG_BACKEND_LINE}" | sudo tee -a "${NEWSYSLOG_CONF}" >/dev/null
  fi
  ok "newsyslog backend.log rotation → ${NEWSYSLOG_CONF}"
fi

if [[ "${BACKEND_ONLY}" -eq 0 ]]; then
  if grep -qE '^[^#]*\.4lm/logs/webui\.log[[:space:]]' "${NEWSYSLOG_CONF}"; then
    ok "newsyslog webui.log entry already present"
  else
    printf '%s\n' "${NEWSYSLOG_WEBUI_LINE}" | sudo tee -a "${NEWSYSLOG_CONF}" >/dev/null
    ok "newsyslog webui.log rotation → ${NEWSYSLOG_CONF}"
  fi
fi

# ---- 11. Sudoers + wired memory limit -------------------------------------
# Install the NOPASSWD rule for the wrapper, then set the limit now. The
# wrapper invokes the same literal command (`sudo -n /usr/sbin/sysctl -w
# iogpu.wired_limit_mb=98304`); any drift between this string and the
# wrapper's call breaks passwordless sudo.
SUDOERS_FILE="/etc/sudoers.d/4lm-stack"
SUDOERS_CONTENT="${USER} ALL=(root) NOPASSWD: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304"

if sudo grep -qF "${SUDOERS_CONTENT}" "${SUDOERS_FILE}" 2>/dev/null; then
  ok "sudoers already configured at ${SUDOERS_FILE}"
else
  echo "Requires sudo: installing ${SUDOERS_FILE}"
  TEMP_SUDOERS="$(mktemp)"
  trap 'rm -f "${TEMP_SUDOERS}"' EXIT
  printf '%s\n' "${SUDOERS_CONTENT}" >"${TEMP_SUDOERS}"
  if ! visudo -c -q -f "${TEMP_SUDOERS}"; then
    die "sudoers content failed visudo validation"
  fi
  sudo install -m 0440 -o root -g wheel "${TEMP_SUDOERS}" "${SUDOERS_FILE}"
  rm -f "${TEMP_SUDOERS}"
  trap - EXIT
  ok "sudoers → ${SUDOERS_FILE}"
fi

CURRENT="$(/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "${CURRENT}" -lt 98304 ]]; then
  echo "Requires sudo: setting iogpu.wired_limit_mb=98304"
  sudo /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304 >/dev/null
  ok "iogpu.wired_limit_mb=98304 (was ${CURRENT})"
else
  ok "iogpu.wired_limit_mb=${CURRENT}"
fi

# ---- 12. OpenCode config --------------------------------------------------
# Skipped entirely in --backend-only (R6).
if [[ "${BACKEND_ONLY}" -eq 0 ]]; then
  OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
  OPENCODE_CONFIG="${OPENCODE_CONFIG_DIR}/opencode.jsonc"
  OPENCODE_TEMPLATE="${SOURCE_DIR}/config/opencode.example.jsonc"
  mkdir -p "${OPENCODE_CONFIG_DIR}"
  if [[ ! -f "${OPENCODE_CONFIG}" ]]; then
    cp "${OPENCODE_TEMPLATE}" "${OPENCODE_CONFIG}"
    ok "opencode config seeded → ${OPENCODE_CONFIG}"
  else
    info "opencode config exists, not overwriting: ${OPENCODE_CONFIG}"
  fi
fi

# ---- 13. Ollama -------------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
  ok "ollama: $(command -v ollama)"
else
  info "Installing ollama…"
  brew install ollama
  ok "ollama installed"
fi

# ---- 14. Final summary ----------------------------------------------------
echo
echo "${C_GRN}════════════════════════════════════${C_RST}"
echo "${C_GRN} Installation complete${C_RST}"
echo "${C_GRN}════════════════════════════════════${C_RST}"
echo
echo "Next steps:"
echo "  ${C_BLU}1.${C_RST} Pre-download models:"
echo "       ${C_DIM}(default profile: ~140 GB download, 15-30 min on residential fiber — run from a reliable connection)${C_RST}"
echo "       ${C_DIM}4lm model download${C_RST}"
echo
echo "  ${C_BLU}2.${C_RST} Start the stack:"
echo "       ${C_DIM}4lm start${C_RST}"
echo
echo "  ${C_BLU}3.${C_RST} Verify:"
echo "       ${C_DIM}4lm status${C_RST}"
echo "       ${C_DIM}4lm doctor${C_RST}    (prereqs + smoke-test inference)"
echo
echo "Services do NOT auto-start at login. Run \`4lm start\` after each reboot."
echo "Opt in to autostart per service with \`4lm autostart enable\`."
