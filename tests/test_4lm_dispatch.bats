#!/usr/bin/env bats

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/launchd" "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs"
  # Provide a default profile + symlink so commands that read it don't fail.
  cp "${REPO_ROOT}/config/profiles/default.yaml" "${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/mlx-active"
  cp "${REPO_ROOT}/config/network.example.yaml"     "${HOME}/.4lm/config/network.yaml"
  # Substituted plists in the launchd dir.
  for p in "${REPO_ROOT}"/launchd/*.plist; do
    sed "s|__HOME__|${HOME}|g" "$p" > "${HOME}/.4lm/launchd/$(basename "$p")"
  done
}

@test "help is dispatched" {
  run "${REPO_ROOT}/bin/4lm" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"start"* ]]
  [[ "$output" == *"expose"* ]]
  [[ "$output" == *"profile"* ]]
  [[ "$output" == *"outdated"* ]]
  [[ "$output" == *"upgrade"* ]]
}

@test "outdated outside a repo dir exits 1 with hint" {
  cd "${HOME}"
  run "${REPO_ROOT}/bin/4lm" outdated
  [ "$status" -eq 1 ]
  [[ "$output" == *"4lm clone"* ]] || [[ "${stderr:-}" == *"4lm clone"* ]]
}

@test "upgrade outside a repo dir exits 1 with hint" {
  cd "${HOME}"
  run "${REPO_ROOT}/bin/4lm" upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"4lm clone"* ]] || [[ "${stderr:-}" == *"4lm clone"* ]]
}

@test "upgrade with unknown channel exits 1" {
  run "${REPO_ROOT}/bin/4lm" upgrade bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown channel"* ]] || [[ "${stderr:-}" == *"Unknown channel"* ]]
}

@test "upgrade with item names but no channel exits 1" {
  run "${REPO_ROOT}/bin/4lm" upgrade opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown channel"* ]] || [[ "${stderr:-}" == *"Unknown channel"* ]]
}

@test "status is dispatched (no args == status)" {
  run "${REPO_ROOT}/bin/4lm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4lm Status"* ]]
}

@test "profile current shows active profile name" {
  run "${REPO_ROOT}/bin/4lm" profile current
  [ "$status" -eq 0 ]
  [[ "$output" == "default" ]]
}

@test "profile list shows all profiles, marks active" {
  run "${REPO_ROOT}/bin/4lm" profile list
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
  [[ "$output" == *"(active)"* ]]
}

@test "expose lan without --confirm exits 1 with risk message" {
  run "${REPO_ROOT}/bin/4lm" expose lan
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --confirm"* ]] || [[ "${stderr:-}" == *"requires --confirm"* ]]
}

@test "expose with invalid mode exits 1" {
  run "${REPO_ROOT}/bin/4lm" expose bogus
  [ "$status" -eq 1 ]
}

@test "unknown command exits 1" {
  run "${REPO_ROOT}/bin/4lm" frobnicate
  [ "$status" -eq 1 ]
}

@test "start backend invokes launchctl bootstrap" {
  run "${REPO_ROOT}/bin/4lm" start backend
  # The launchctl stub returns 0 by default and the readiness loop is short.
  # Status may be 0 (started) — we mainly assert bootstrap was called.
  grep -q "bootstrap" "${LAUNCHCTL_LOG}"
}
