#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helpers/setup

BIN="${REPO_ROOT}/bin/4lm"

setup() {
  mkdir -p "${HOME}/.4lm/launchd" "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cp "${REPO_ROOT}/config/profiles/default.yaml" "${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/active-profile"
  cp "${REPO_ROOT}/config/network.example.yaml" "${HOME}/.4lm/config/network.yaml"
  for p in "${REPO_ROOT}"/launchd/*.plist; do
    sed "s|__HOME__|${HOME}|g" "$p" > "${HOME}/.4lm/launchd/$(basename "$p")"
  done
}

# ---- status -----------------------------------------------------------------

@test "autostart status: both disabled by default" {
  run "${BIN}" autostart status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend"*"disabled"* ]]
  [[ "$output" == *"webui"*"disabled"* ]]
}

@test "autostart status: shows enabled when LaunchAgents symlink present" {
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  run "${BIN}" autostart status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend"*"enabled"* ]]
  [[ "$output" == *"webui"*"disabled"* ]]
}

# ---- enable -----------------------------------------------------------------

@test "autostart enable backend: creates LaunchAgents symlink for backend" {
  run "${BIN}" autostart enable backend
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [[ "$output" == *"enabled"* ]]
}

@test "autostart enable webui: creates LaunchAgents symlink for webui" {
  skip_if_no_webui
  run "${BIN}" autostart enable webui
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart enable all: creates both LaunchAgents symlinks" {
  skip_if_no_webui
  run "${BIN}" autostart enable all
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart enable backend: calls launchctl bootstrap when not loaded" {
  run "${BIN}" autostart enable backend
  [ "$status" -eq 0 ]
  grep -q "bootstrap" "${LAUNCHCTL_LOG}"
}

@test "autostart enable backend: idempotent (enable twice leaves symlink intact)" {
  run "${BIN}" autostart enable backend
  [ "$status" -eq 0 ]
  run "${BIN}" autostart enable backend
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
}

@test "autostart enable: unknown service exits 1 with hint" {
  run "${BIN}" autostart enable bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown service"* ]]
  [[ "$output" == *"backend|webui|all"* ]]
}

# ---- disable ----------------------------------------------------------------

@test "autostart disable backend: removes LaunchAgents symlink" {
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  run "${BIN}" autostart disable backend
  [ "$status" -eq 0 ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [[ "$output" == *"disabled"* ]]
}

@test "autostart disable all: removes both LaunchAgents symlinks" {
  skip_if_no_webui
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.webui.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.webui.plist"
  run "${BIN}" autostart disable all
  [ "$status" -eq 0 ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart disable backend: idempotent when not enabled" {
  run "${BIN}" autostart disable backend
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not enabled"* ]]
}

# ---- missing source plist ---------------------------------------------------

@test "autostart enable backend: missing source plist exits 1 with error" {
  rm -f "${HOME}/.4lm/launchd/com.4lm.backend.plist"
  run "${BIN}" autostart enable backend
  [ "$status" -ne 0 ]
  [[ "$output" == *"source plist not found"* ]]
}

# ---- bootstrap failure cleanup ----------------------------------------------

@test "autostart enable backend: bootstrap failure removes symlink" {
  # Inject a launchctl stub that fails on bootstrap but makes is_loaded return false
  local stub_bin="${BATS_TMPDIR}/fail-bootstrap-$$"
  mkdir -p "${stub_bin}"
  cat > "${stub_bin}/launchctl" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "bootstrap" ]]; then
  echo "Bootstrap failed: error 125" >&2
  exit 1
fi
if [[ "$1" == "print" ]]; then
  # Simulate service not loaded so bootstrap is attempted
  exit 1
fi
echo "$@" >> "${LAUNCHCTL_LOG:-/dev/null}"
exit 0
SH
  chmod +x "${stub_bin}/launchctl"
  PATH="${stub_bin}:${PATH}" run "${BIN}" autostart enable backend
  [ "$status" -ne 0 ]
  # Symlink must be cleaned up on failure
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
}

# ---- bare autostart ---------------------------------------------------------

@test "autostart bare (no subcommand) exits 1 with usage error" {
  run "${BIN}" autostart
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
  [[ "$output" == *"enable|disable|status"* ]]
}

# ---- unknown subcommand -----------------------------------------------------

@test "autostart unknown subcommand exits 1" {
  run "${BIN}" autostart bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}
