#!/usr/bin/env bats

load helpers/setup

@test "__HOME__ placeholder is substituted in installed plists" {
  for plist in "${REPO_ROOT}"/launchd/*.plist; do
    grep -q "__HOME__" "${plist}"   # source contains the marker

    target="${BATS_TMPDIR}/$(basename "${plist}")"
    sed "s|__HOME__|${HOME}|g" "${plist}" > "${target}"

    # No literal __HOME__ remains.
    run grep -F "__HOME__" "${target}"
    [ "$status" -ne 0 ]

    # Processed plist passes plutil and xmllint.
    run plutil -lint "${target}"
    [ "$status" -eq 0 ]
    run xmllint --noout "${target}"
    [ "$status" -eq 0 ]
  done
}
