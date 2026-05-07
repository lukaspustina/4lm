#!/usr/bin/env bats
# Phase 4: 4lm diag wires print_clients (Backend + WebUI client lists).

bats_require_minimum_version 1.5.0

load helpers/setup

setup() {
  mkdir -p "${HOME}/.4lm/config/profiles" "${HOME}/.4lm/logs" "${HOME}/.4lm/launchd"
  cp "${REPO_ROOT}/config/profiles/default.yaml" "${HOME}/.4lm/config/profiles/default.yaml"
  ln -sfn "${HOME}/.4lm/config/profiles/default.yaml" "${HOME}/.4lm/config/active-profile"
  cat >"${HOME}/.4lm/config/network.yaml" <<'YAML'
mode: local
backend_port: 11434
webui_port: 3000
YAML
  export LLM_HOME="${HOME}/.4lm"

  # Stub lsof so print_clients returns a fake connection line.
  # The stub echos a fake established connection including the port so the
  # caller can filter.  We mimic lsof's -nP output format:
  # COMMAND  PID  USER  FD  TYPE  DEVICE  SIZE  NODE  NAME
  cat >"${BATS_TMPDIR}/lsof" <<'STUB'
#!/usr/bin/env bash
# Fake one established connection for whichever port is requested.
for arg; do
  case "$arg" in
    -iTCP:11434) printf 'COMMAND    PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NODE  NAME\ncurl     1234  user   5u  IPv4  0xabc  0t0  TCP  127.0.0.1:55555->127.0.0.1:11434 (ESTABLISHED)\n'; exit 0 ;;
    -iTCP:3000)  printf 'COMMAND    PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NODE  NAME\nSafari   5678  user   7u  IPv4  0xdef  0t0  TCP  127.0.0.1:44444->127.0.0.1:3000 (ESTABLISHED)\n'; exit 0 ;;
  esac
done
exit 0
STUB
  chmod +x "${BATS_TMPDIR}/lsof"
  export PATH="${BATS_TMPDIR}:${PATH}"
}

@test "4lm diag stdout contains Backend client address" {
  run "${REPO_ROOT}/bin/4lm" diag
  echo "$output" | grep -q "Backend"
  echo "$output" | grep -qE '127\.0\.0\.1'
}

@test "4lm diag stdout contains WebUI client address" {
  run "${REPO_ROOT}/bin/4lm" diag
  echo "$output" | grep -q "WebUI"
  echo "$output" | grep -qE '127\.0\.0\.1'
}

@test "4lm diag output does not contain CPU or RSS column header" {
  run "${REPO_ROOT}/bin/4lm" diag
  ! echo "$output" | grep -qi '%CPU\|CPU.*RSS\|RSS.*CPU'
}
