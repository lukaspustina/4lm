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
  [[ "$output" == *"Backend: disabled"* ]]
  [[ "$output" == *"WebUI: disabled"* ]]
}

@test "autostart status: shows enabled when LaunchAgents symlink present" {
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  run "${BIN}" autostart status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backend: enabled"* ]]
  [[ "$output" == *"WebUI: disabled"* ]]
}

# ---- enable -----------------------------------------------------------------

@test "autostart enable omlx: creates LaunchAgents symlink for backend" {
  run "${BIN}" autostart enable omlx
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [[ "$output" == *"enabled"* ]]
}

@test "autostart enable webui: creates LaunchAgents symlink for webui" {
  run "${BIN}" autostart enable webui
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart enable all: creates both LaunchAgents symlinks" {
  run "${BIN}" autostart enable all
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart enable omlx: calls launchctl bootstrap when not loaded" {
  run "${BIN}" autostart enable omlx
  [ "$status" -eq 0 ]
  grep -q "bootstrap" "${LAUNCHCTL_LOG}"
}

@test "autostart enable omlx: idempotent (enable twice leaves symlink intact)" {
  run "${BIN}" autostart enable omlx
  [ "$status" -eq 0 ]
  run "${BIN}" autostart enable omlx
  [ "$status" -eq 0 ]
  [ -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
}

@test "autostart enable: unknown service exits 1" {
  run "${BIN}" autostart enable bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown service"* ]]
}

# ---- disable ----------------------------------------------------------------

@test "autostart disable omlx: removes LaunchAgents symlink" {
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  run "${BIN}" autostart disable omlx
  [ "$status" -eq 0 ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [[ "$output" == *"disabled"* ]]
}

@test "autostart disable all: removes both LaunchAgents symlinks" {
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist"
  ln -sfn "${HOME}/.4lm/launchd/com.4lm.webui.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.webui.plist"
  run "${BIN}" autostart disable all
  [ "$status" -eq 0 ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" ]
  [ ! -L "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" ]
}

@test "autostart disable omlx: idempotent when not enabled" {
  run "${BIN}" autostart disable omlx
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not enabled"* ]]
}

# ---- unknown subcommand -----------------------------------------------------

@test "autostart unknown subcommand exits 1" {
  run "${BIN}" autostart bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}
