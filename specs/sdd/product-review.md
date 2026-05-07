# SDD: Product Review Remediation

Status: Ready for Implementation
Original: specs/sdd/product-review.md
Refined: 2026-05-07

## Overview

A structured product review of the 4lm CLI (run 2026-05-07) surfaced findings
across six quality lenses. This SDD captures all HIGH and impactful MEDIUM
issues as requirements organised into independently shippable phases. The work
is purely remediation — no new user-facing features are added.

## Context & Constraints

- **Stack**: Bash (`bin/4lm`, ~1410 lines), Python helpers (`bin/4lm_helpers.py`),
  bats test suite (`tests/*.bats`), pytest suite (`tests/python/`).
- **Conventions**: `set -euo pipefail`; shellcheck clean; shfmt formatted;
  conventional commit prefixes; no `Co-Authored-By` lines.
- **Error helpers** (`bin/4lm` only): `die()` → `error:` prefix → stderr → exit 1.
  `warn()` → `warn:` prefix → stderr (no exit). `ok()` / `info()` → stdout.
  `die()` and `warn()` are NOT defined in `bin/4lm-backend-start.sh` or
  `bin/4lm-webui-start.sh`. Those scripts must use bare `echo >&2` with the
  existing fatal pattern `echo "[$(date -Iseconds)] FATAL: ..." >&2; exit N`
  or `echo "[$(date -Iseconds)] WARN: ..." >&2` respectively.
- **Tests**: every changed behaviour needs a bats or pytest test;
  `make check` must pass after each phase.
- **Atomic writes**: prefer `tmp + mv` over in-place `sed -i` for files that
  must survive an interrupted write.
- **Active profile path**: `bin/4lm-backend-start.sh` reads the active profile
  via `${ACTIVE_CONFIG}` (defined as `${CONFIG_DIR}/active-profile`, which is a
  symlink to the chosen profile YAML). This variable is derived from `${HOME}`
  which the launchd plist injects via `EnvironmentVariables`. No separate
  `ACTIVE_PROFILE_PATH` env var is needed; use `${ACTIVE_CONFIG}` throughout.
- **Profile validation location**: validated inline in `bin/4lm-backend-start.sh`
  using shell primitives only — no `python3`, no `bin/4lm-lib.sh`. See Decision Log.

## Requirements

1. The system shall validate that the active profile YAML contains both a
   `backend:` key and a `models:` key before launching the backend in
   `bin/4lm-backend-start.sh`. On failure the script exits 78 with a FATAL
   message matching the existing script's error style.
2. `BACKEND_POLL_SECS` shall control elapsed wall-clock seconds. The poll loop
   shall record `_start=$SECONDS` before the first iteration, check
   `(( SECONDS - _start >= BACKEND_POLL_SECS ))` after each failed curl and
   before sleeping, and set `_timed_out=1` on budget exhaustion. Success sets
   `_timed_out=0` and breaks. Worst-case total wait is `BACKEND_POLL_SECS + 2`
   seconds (one 1-second sleep + one `curl --max-time 1`).
3. After a profile-switch rollback, the system shall reset `_start=$SECONDS`
   and poll `/v1/models` on the restored backend (same `$BACKEND_POLL_SECS`
   budget) before reporting to the user.
4. Switching to the currently active profile (same name) or calling
   `cmd_profile_set` when no `previous-profile` file exists shall never produce
   a fatal "no previous profile" error. If the backend is not loaded: exit 0
   silently. If the backend is loaded but times out: `die "backend did not start"`.
5. `bin/4lm-webui-start.sh` shall validate `WEBUI_PORT` and `BACKEND_PORT` as
   numeric before use, falling back to defaults on invalid values, matching the
   guard already in `bin/4lm`'s `net_webui_port()`.
6. `cmd_upgrade` shall write `requirements.txt` atomically: write to
   `${repo}/requirements.txt.tmp`, protect it with
   `trap 'rm -f "${repo}/requirements.txt.tmp"' EXIT`, then
   `mv "${repo}/requirements.txt.tmp" "${repo}/requirements.txt"`.
7. `4lm start` shall snapshot whether `${LLM_HOME}/openwebui-data/` is absent
   **before** calling `service_start` for the webui. On first start (snapshot
   absent): print the WebUI URL and `"Open it in a private window, create an
   account, then visit Admin → Settings → Users to promote yourself to admin."`.
   On subsequent starts: print the WebUI URL only.
   Always also print: `"Run \`4lm open\` to open in browser."`.
8. `install.sh` next-steps block shall insert a static note before the
   `4lm models download` step: `"(default profile: ~140 GB download,
   15-30 min on residential fiber — run from a reliable connection)"`.
9. `cmd_doctor` shall check that at least one model referenced by the active
   profile is present in the cache. Use `hf_is_cached <repo>` (defined at
   `bin/4lm:156`) for mlx and mlx_lm backends; use
   `ollama list | grep -qF '<model>'` for the ollama backend. If none are
   found cached: `warn "no models cached — run: 4lm models download"`.
   If `hf_is_cached` or `ollama` is absent from PATH, skip silently (best-effort).
   Extract the check into a named helper `_doctor_check_models_cached()`.
10. `cmd_health` success output shall display wired memory as
    `"GPU wired memory: ${human_gb} GB (${current} MB) — OK"` where
    `human_gb=$(( (current + 512) / 1024 ))` (round-to-nearest GB). The
    below-threshold path shall use `die "wired memory ${current} MB is below
    threshold"` (exits 1, `error:` prefix on stderr).
11. `require_helpers_python` (line 68 of `bin/4lm`) shall use
    `die "helpers venv missing — run: make install"` instead of raw
    `echo >&2 + exit 1`.
12. All rollback error paths in `cmd_profile_set` shall use `die()` or `warn()`
    (not raw `echo >&2`) for user-visible messages.
13. `cmd_diag` shall call `print_clients "$(net_backend_port)" "Backend"` and
    `print_clients "$(net_webui_port)" "WebUI"` before delegating to the Python
    helper, using the already-implemented `print_clients` function.
14. The per-worker CPU/RSS section in `cmd_diag` of `bin/4lm_helpers.py`
    (the stub output block within `cmd_diag`) shall be removed. `docs/setup.md`
    and `cmd_help` shall be updated to reflect the actual output — no
    per-worker CPU/RSS section. See Decision Log.
15. `4lm models cleanup` shall appear in the output of `cmd_help`.
16. `cmd_models_clean` shall pass `--yes` to `hf cache prune` so it is safe to
    run non-interactively and from scripts.
17. `cmd_models_rm` shall require `--confirm`; without it, print
    `"Pass --confirm to remove: <repo>"` and exit 0.
18. `cmd_uninstall` shall require `--confirm`; without it, print what would be
    removed and exit 0. The list shall include: `~/.4lm/`,
    `~/.local/bin/4lm`, installed launchd plists
    (`~/Library/LaunchAgents/com.4lm.*.plist`), and the
    newsyslog fragment. An interactive `read` prompt is out of scope.
19. `cmd_expose`'s flags shall be parsed via a `while case` loop (not positional
    `$2`), consistent with `cmd_models_cleanup`. Unknown arguments shall cause
    `die "unknown argument: <arg>"` (exit 1).
20. `4lm expose lan` called without `--confirm` shall call
    `die "pass --confirm to expose on LAN"` (exits 1, `error:` prefix). This
    exit 1 convention is intentional — see Decision Log.
21. Empty-state messages shall be shown for `4lm profile list` (when no `.yaml`
    files exist in `$PROFILES_DIR`:
    `"No profiles found in ${PROFILES_DIR} — run: make install"`) and for
    `4lm models list` (when no models are cached: `"No cached models found."`).
22. `bin/4lm-webui-start.sh` security invariants (`WEBUI_REGISTRATION_ENABLED`,
    `WEBUI_SECRET_KEY`, `DEFAULT_USER_ROLE`) shall have bats test coverage.
23. `docs/setup.md` LAN exposure risk description shall be updated to reflect
    that `WEBUI_REGISTRATION_ENABLED=false` is always active (not LAN-only),
    removing the stale "first-user race" risk entry.
24. `README.md` security posture description for `expose lan` shall be corrected
    to state that registration lock and `DEFAULT_USER_ROLE=pending` apply in
    all modes, not only LAN mode.
25. Exception strings in `bin/4lm_helpers.py` shall be wrapped in human-readable
    prefixes. Raw Python exception class names and socket-level errno strings
    shall not be surfaced. In `cmd_outdated` (line ~441):
    `except urllib.error.URLError as e:` → wrap as
    `f"could not reach PyPI ({type(e).__name__})"`. In `cmd_diag` (line ~316):
    the existing `reason = getattr(e, "reason", str(e))` is already reasonable
    but shall not surface raw `errno` strings; wrap as
    `f"could not reach backend ({type(e).__name__})"` if `reason` is an
    `OSError` instance.
26. `cmd_diag`'s orphan-worker detection in `bin/4lm_helpers.py` (the
    `orphaned = worker_pids if (worker_pids and not all_admit_uids) else set()`
    line): replace with a per-worker check so `is_orphaned(pid, log_entries,
    window_admissions)` returns `True` iff the PID appears in log entries AND
    `window_admissions == 0`.

## File & Module Structure

Files changed by this SDD:

| File | Change |
|---|---|
| `bin/4lm` | Poll loop, rollback poll, same-name switch, `require_helpers_python`, `cmd_health`, `cmd_start`, `cmd_doctor`, `cmd_help`, `cmd_models_clean`, `cmd_models_rm`, `cmd_uninstall`, `cmd_expose`, `cmd_profile_set`, `cmd_profile_list`, `cmd_diag`, `cmd_upgrade` |
| `bin/4lm-backend-start.sh` | Inline profile validation before launch |
| `bin/4lm-webui-start.sh` | Numeric port guards |
| `bin/4lm_helpers.py` | Orphan-worker inversion, exception wrapping, remove per-worker CPU/RSS stub, models-list empty state |
| `install.sh` | Next-steps size/time note |
| `docs/setup.md` | Diag section, LAN exposure risk section |
| `README.md` | Security posture for `expose lan` |
| `tests/test_webui_start.bats` | New file |
| `tests/helpers/open-webui` | New stub |

## Data Models

No new persistent data models. Existing types unchanged.

Inline profile validation in `bin/4lm-backend-start.sh` uses shell primitives:

```bash
if ! grep -q '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null || \
   ! grep -q '^models:' "${ACTIVE_CONFIG}" 2>/dev/null; then
  echo "[$(date -Iseconds)] FATAL: profile invalid: missing backend or models key" >&2
  exit 78
fi
```

This check runs immediately after the existing `ACTIVE_CONFIG` symlink check,
before the `profile_backend()` inline block. No `python3` dependency.

`is_orphaned(worker_pid: str, log_entries: list[str], window_admissions: int) -> bool`
in `bin/4lm_helpers.py`: returns `True` iff `worker_pid` appears in
`log_entries` AND `window_admissions == 0`. Returns `False` for active workers
(admissions > 0).

## API Contracts

No external API changes. Internal function contracts:

- `print_clients(port, label)` — already implemented in `bin/4lm`; called from
  `cmd_diag` in Phase 4.
- `require_helpers_python()` — signature unchanged; error path replaced.
- `_doctor_check_models_cached()` — new helper extracted from `cmd_doctor`;
  no arguments; reads `ACTIVE_CONFIG` and `PROFILES_DIR` from the enclosing
  scope; emits `warn` if no models cached.
- `is_orphaned(worker_pid, log_entries, window_admissions)` — extracted from
  the inline orphan check in `cmd_diag`; pure function, no I/O.

## Configuration

No new config keys. Existing key clarified:

- `BACKEND_POLL_SECS` — elapsed wall-clock seconds (not iteration count). Already
  defined; comment in `bin/4lm` updated to reflect corrected semantics.

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| Active profile missing `backend:` or `models:` key | `bin/4lm-backend-start.sh` starts | Exit 78 | `[<ISO8601>] FATAL: profile invalid: missing backend or models key` on stderr |
| Poll budget exceeded (new switch) | `cmd_profile_set` poll loop | Set `_timed_out=1`; trigger rollback | `error: backend did not respond; reverting` |
| Poll budget exceeded (rollback) | `cmd_profile_set` rollback poll | `warn` + exit 1 | `warn: reverted profile did not respond within ${BACKEND_POLL_SECS}s` |
| Same-name switch, backend not loaded | `cmd_profile_set` | Exit 0 silently | (none) |
| Same-name switch, backend timeout | `cmd_profile_set` | `die` | `error: backend did not start` |
| `require_helpers_python` venv absent | Any command using helpers | `die` + exit 1 | `error: helpers venv missing — run: make install` |
| `WEBUI_PORT` non-numeric | `bin/4lm-webui-start.sh` | Fall back to 3000 | `[<ISO8601>] WARN: invalid WEBUI_PORT, using 3000` on stderr |
| `BACKEND_PORT` non-numeric | `bin/4lm-webui-start.sh` | Fall back to 8080 | `[<ISO8601>] WARN: invalid BACKEND_PORT, using 8080` on stderr |
| `4lm expose lan` without `--confirm` | `cmd_expose` | `die` + exit 1 | `error: pass --confirm to expose on LAN` |
| `4lm expose lan <unknown-arg>` | `cmd_expose` flag parser | `die` + exit 1 | `error: unknown argument: <arg>` |
| `4lm models rm` without `--confirm` | `cmd_models_rm` | Exit 0, print guidance | `Pass --confirm to remove: <repo>` |
| `4lm uninstall` without `--confirm` | `cmd_uninstall` | Exit 0, print what would be removed | (descriptive list of paths) |
| No models cached (doctor check) | `cmd_doctor` via `_doctor_check_models_cached` | `warn` | `warn: no models cached — run: 4lm models download` |
| Wired memory below threshold | `cmd_health` | `die` + exit 1 | `error: wired memory <N> MB is below threshold` |
| PyPI unreachable in `cmd_outdated` | `bin/4lm_helpers.py:cmd_outdated` | Wrapped message, return 1 | `could not reach PyPI (<ExceptionType>)` on stderr |
| Backend unreachable in `cmd_diag` | `bin/4lm_helpers.py:cmd_diag` | Wrapped message, continue | `could not reach backend (<ExceptionType>)` on stderr |

## Implementation Phases

## Phase 1 — Correctness & Safety

Fix bugs that silently mis-behave or produce incorrect output regardless of UX
polish. No external user-facing behaviour changes — only corrects existing behaviour.

**Changes:**

**`bin/4lm-backend-start.sh` — inline profile validator**: Insert after the
existing `ACTIVE_CONFIG` symlink check (after line 20, before the `NET_MODE`
block):

```bash
if ! grep -q '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null || \
   ! grep -q '^models:' "${ACTIVE_CONFIG}" 2>/dev/null; then
  echo "[$(date -Iseconds)] FATAL: profile invalid: missing backend or models key" >&2
  exit 78
fi
```

No `python3`; no sourcing of `bin/4lm`.

**`bin/4lm` — poll loop** (`cmd_profile_set`, current `seq`/`sleep` loop):
Replace with an elapsed-time loop using `_timed_out` flag:

```bash
local _start=$SECONDS
local _timed_out=0
while true; do
  if curl --silent --max-time 1 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
    _timed_out=0
    break
  fi
  if (( SECONDS - _start >= BACKEND_POLL_SECS )); then
    _timed_out=1
    break
  fi
  sleep 1
done
```

Update the `BACKEND_POLL_SECS` comment to: `# elapsed wall-clock seconds`.

**`bin/4lm` — rollback poll** (`cmd_profile_set`): After restoring the
symlink and calling `launchctl kickstart`, reset `_start=$SECONDS` and run the
same elapsed-time poll loop (reuse the pattern above, budget `$BACKEND_POLL_SECS`).
On `_timed_out=0`: `ok "reverted to ${previous}"` then `exit 1`.
On `_timed_out=1`: `warn "reverted profile did not respond within ${BACKEND_POLL_SECS}s"` then `exit 1`.

**`bin/4lm` — same-name switch** (`cmd_profile_set`): At the top of the
function, after resolving `name`:

```bash
local current_name=""
if [[ -L "${ACTIVE_CONFIG}" ]]; then
  current_name="$(basename "$(readlink "${ACTIVE_CONFIG}")" .yaml)"
fi
```

If `name == current_name`:
- If backend is not loaded (`! is_loaded "${BACKEND_LABEL}"`): `return 0` silently.
- If backend is loaded: kickstart, run poll loop. On `_timed_out=1`:
  `die "backend did not start"`.

Only write `previous-profile` when `[[ -n "${current_name}" && "${current_name}" != "${name}" ]]`.

**`bin/4lm-webui-start.sh` — port guards**: Add after the port variables are
derived from `network.yaml`, before first use:

```bash
[[ "$WEBUI_PORT" =~ ^[0-9]+$ ]] || { echo "[$(date -Iseconds)] WARN: invalid WEBUI_PORT, using 3000" >&2; WEBUI_PORT=3000; }
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || { echo "[$(date -Iseconds)] WARN: invalid BACKEND_PORT, using 8080" >&2; BACKEND_PORT=8080; }
```

**`bin/4lm` — atomic requirements.txt** (`cmd_upgrade`): Replace the direct
write to `requirements.txt` with:

```bash
local _req_tmp="${repo}/requirements.txt.tmp"
trap 'rm -f "${_req_tmp}"' EXIT
# ... write to "${_req_tmp}" ...
mv "${_req_tmp}" "${repo}/requirements.txt"
```

**`bin/4lm_helpers.py` — orphan-worker detection** (`cmd_diag`): Extract an
`is_orphaned` function and replace the inline `orphaned = ...` expression:

```python
def is_orphaned(worker_pid: str, log_entries: list[str], window_admissions: int) -> bool:
    return any(worker_pid in line for line in log_entries) and window_admissions == 0
```

Call it per-worker using the count of `all_admit_uids` for `window_admissions`.

**Verification gate:** Phase complete when:
- `make check` passes.
- `test_profile_state_machine.bats` covers: same-name switch (backend not
  loaded → exit 0), rollback-poll success (`_timed_out=0` path: stdout contains
  "reverted", exit 1), rollback-poll failure (`_timed_out=1` path: stderr
  contains "warn:", exit 1).
- A bats test validates `4lm-backend-start.sh` exits non-zero on a profile
  YAML missing the `models:` key, with stderr containing "profile" and "invalid".
- Pytest tests for `is_orphaned()`: `window_admissions=0` → `True`;
  `window_admissions=5` → `False`.

### Test Scenarios

**GIVEN** `ACTIVE_CONFIG` points to a YAML file missing the `models:` key
**WHEN** `bin/4lm-backend-start.sh` runs
**THEN** it exits non-zero and stderr contains both "profile" and "invalid"

**GIVEN** `ACTIVE_CONFIG` points to a YAML file missing the `backend:` key
**WHEN** `bin/4lm-backend-start.sh` runs
**THEN** it exits non-zero and stderr contains both "profile" and "invalid"

**GIVEN** `BACKEND_POLL_SECS=2` and the backend stub never returns HTTP 200
**WHEN** `cmd_profile_set` runs the poll loop
**THEN** elapsed wall-clock time is ≥ 2 s and ≤ 4 s (measured via `$SECONDS`
before and after the call in the test)

**GIVEN** `4lm profile set default` is called when `default` is already the
active profile and the backend is not loaded
**WHEN** the command runs
**THEN** exit code is 0 and stderr does not contain "error:"

**GIVEN** a profile switch times out and a valid `previous-profile` file exists
and the restored backend responds to `/v1/models` within `BACKEND_POLL_SECS`
**WHEN** `cmd_profile_set` completes
**THEN** stdout contains "reverted" and exit code is 1

**GIVEN** a profile switch times out and the rollback backend also never
responds within `BACKEND_POLL_SECS`
**WHEN** `cmd_profile_set` completes
**THEN** stderr contains "warn:" and exit code is 1

**GIVEN** `cmd_upgrade` writes the temp file and `mv` completes atomically
**WHEN** the filesystem is inspected after an interrupted write (simulated by
aborting after the temp write, before `mv`)
**THEN** `requirements.txt` is either the full pre-upgrade content or the full
post-upgrade content (never zero-length or partial) — atomicity guaranteed by
`mv`

**GIVEN** a worker PID appears in log entries with `window_admissions=0`
**WHEN** `is_orphaned(pid, log_entries, 0)` is called
**THEN** it returns `True`

**GIVEN** a worker PID appears in log entries with `window_admissions=5`
**WHEN** `is_orphaned(pid, log_entries, 5)` is called
**THEN** it returns `False`

---

## Phase 2 — Onboarding & Post-Start UX

Eliminate the three silent failure modes a new user hits in the first 15 minutes.

**Changes:**

**`bin/4lm` — `cmd_start`**: Before calling `service_start` for the webui,
snapshot:

```bash
local first_run=false
[[ ! -d "${LLM_HOME}/openwebui-data" ]] && first_run=true
```

After both services are marked started:

```bash
info "WebUI: http://127.0.0.1:$(net_webui_port)"
if [[ "${first_run}" == "true" ]]; then
  info "Open it in a private window, create an account, then visit Admin → Settings → Users to promote yourself to admin."
fi
info "Run \`4lm open\` to open in browser."
```

**`install.sh` next-steps block** (around line 316): Before the
`4lm models download` step insert:

```
(default profile: ~140 GB download, 15-30 min on residential fiber — run from a reliable connection)
```

**`bin/4lm` — `cmd_doctor`**: Add model-cache check by calling
`_doctor_check_models_cached`. Define as:

```bash
_doctor_check_models_cached() {
  [[ -L "${ACTIVE_CONFIG}" ]] || return 0
  local backend
  backend="$(profile_backend "${ACTIVE_CONFIG}" 2>/dev/null || echo "mlx")"
  local found=0
  while IFS='|' read -r name _path _od; do
    if [[ "${backend}" == "ollama" ]]; then
      ollama list 2>/dev/null | grep -qF "${name}" && found=1 && break
    else
      hf_is_cached "${name}" && found=1 && break
    fi
  done < <(profile_model_entries "${ACTIVE_CONFIG}")
  if [[ "${found}" -eq 0 ]]; then
    warn "no models cached — run: 4lm models download"
  fi
}
```

If `ollama` or `hf_is_cached` prerequisites are absent, the check degrades
silently (best-effort). Call `_doctor_check_models_cached` at the end of
`cmd_doctor` before `return "${fail}"`.

**`bin/4lm` — `cmd_health`**: Replace the raw `echo` error path with
`die "wired memory ${current} MB is below threshold"`. Format the success
line as:

```bash
human_gb=$(( (current + 512) / 1024 ))
ok "GPU wired memory: ${human_gb} GB (${current} MB) — OK"
```

The formula `(current + 512) / 1024` rounds to nearest GB (integer arithmetic).

**Verification gate:** Phase complete when:
- `make check` passes.
- A bats test for `cmd_start` with stubbed `service_start`: absent
  `openwebui-data/` → stdout contains URL matching `http://127.0.0.1:[0-9]+`
  and the word "account"; present `openwebui-data/` → stdout contains URL,
  does not contain "account". Both scenarios → stdout contains
  `Run \`4lm open\``.
- A bats test for `cmd_health`: stubbed `sysctl` returning 0 → exit 1,
  stderr contains "error:". Stubbed `sysctl` returning 8192 → exit 0, stdout
  contains "GB" and "OK".

### Test Scenarios

**GIVEN** `${LLM_HOME}/openwebui-data/` does not exist
**WHEN** `4lm start` completes successfully (service_start stubbed to succeed)
**THEN** stdout contains a URL matching `http://127.0.0.1:[0-9]+` and the word "account" and `Run \`4lm open\``

**GIVEN** `${LLM_HOME}/openwebui-data/` already exists
**WHEN** `4lm start` completes successfully
**THEN** stdout contains the WebUI URL and does not contain the word "account" and does contain `Run \`4lm open\``

**GIVEN** the active profile lists model `org/repo` and neither `hf_is_cached` nor `ollama list` output contains that model
**WHEN** `4lm doctor` runs
**THEN** stderr contains "warn:" and the word "download"

**GIVEN** `sysctl iogpu.wired_limit_mb` is stubbed to return 0
**WHEN** `4lm health` runs
**THEN** exit code is 1 and stderr contains "error:"

**GIVEN** `sysctl iogpu.wired_limit_mb` is stubbed to return 8192 (above threshold)
**WHEN** `4lm health` runs
**THEN** exit code is 0 and stdout contains "GB" and "OK"

---

## Phase 3 — Error Message Consistency

Make all error output route through `die()`/`warn()` and surface human-readable
messages. No behaviour changes beyond error message format.

**Changes:**

**`bin/4lm` — `require_helpers_python`** (line ~68): Replace:

```bash
echo "error: helpers venv missing" >&2; exit 1
```

with:

```bash
die "helpers venv missing — run: make install"
```

**`bin/4lm` — `cmd_profile_set` rollback paths**: Replace all `echo >&2` calls
with `warn` or `die` as appropriate:
- No-exit messages (e.g. "WARN: rollback kickstart failed"): use `warn`.
- Terminal-error messages (e.g. "Profile switch failed and no previous profile"):
  use `die`.

**`bin/4lm` — `cmd_expose` refusal**: Replace `echo >&2 + exit 1` (line ~871)
with `die "pass --confirm to expose on LAN"`.

**`bin/4lm` — `service_stop` "not loaded"** (line ~263): Replace any
error-styled output with `info "already stopped"` on stdout. Redirect
`launchctl` stderr to `/dev/null` in this branch.

**`bin/4lm_helpers.py` — `cmd_outdated`** (`urllib.error.URLError` handler,
line ~441): Replace:

```python
except urllib.error.URLError as e:
    print(f"error: could not reach PyPI: {e}", file=sys.stderr)
    return 1
```

with:

```python
except (urllib.error.URLError, OSError) as e:
    print(f"could not reach PyPI ({type(e).__name__})", file=sys.stderr)
    return 1
```

**`bin/4lm_helpers.py` — `cmd_diag`** (`except (urllib.error.URLError, OSError)`
handler, line ~316): Replace the `reason = getattr(e, "reason", str(e))` display
with:

```python
except (urllib.error.URLError, OSError) as e:
    print(f"could not reach backend ({type(e).__name__})", file=sys.stderr)
```

Do not surface raw `errno` strings or Python tracebacks in user-visible output.

**Verification gate:** Phase complete when:
- `make check` passes.
- `grep -n 'echo.*>&2' bin/4lm` excluding lines that define `die()`/`warn()`/
  `ok()`/`info()` returns zero matches.
- A bats test: `LLM_HELPERS_PYTHON=/nonexistent 4lm <any-command>` → stderr
  contains "error:" and "make install", exit 1.

### Test Scenarios

**GIVEN** `LLM_HELPERS_PYTHON` points to a non-existent path
**WHEN** any command invoking `require_helpers_python` runs
**THEN** stderr contains "error:" and "make install" and exit code is 1

**GIVEN** `4lm expose lan` is called without `--confirm`
**WHEN** the command runs
**THEN** exit code is 1 and stderr contains "error:" (not a raw echo line without prefix)

**GIVEN** `grep -n 'echo.*>&2' bin/4lm` is run excluding helper definition lines
**WHEN** the search completes
**THEN** zero matches are returned

**GIVEN** the Python helper encounters a socket error reaching PyPI
**WHEN** the error is printed
**THEN** stderr contains "could not reach PyPI (" and does not contain a raw Python traceback or errno string

**GIVEN** `4lm profile set` is given a profile that fails validation
**WHEN** the error fires
**THEN** stderr contains exactly one line starting with "error:" and no raw Python exception class is surfaced on stderr

---

## Phase 4 — `4lm diag` Implementation Gap

Wire in the already-implemented `print_clients` function and trim documentation
to match actual output.

**Changes:**

**`bin/4lm` — `cmd_diag`** (lines ~408-412): Add before the Python helper call:

```bash
print_clients "$(net_backend_port)" "Backend"
print_clients "$(net_webui_port)" "WebUI"
```

**`bin/4lm_helpers.py` — `cmd_diag` per-worker CPU/RSS stub**: Remove the stub
output block that prints per-worker CPU/RSS column headers and rows. The section
currently emits incorrect/placeholder output. See Decision Log.

**`docs/setup.md` — diag section** (lines ~208-226): Rewrite to match actual
output after Phase 4: Backend/WebUI client lists (from `print_clients`) plus
the Python helper sections (HTTP probe, in-flight inference, backend worker
processes, orphaned workers). Remove the per-worker CPU/RSS example.

**`bin/4lm` — `cmd_help` diag entry** (line ~1373): Update description to match
actual output.

**Verification gate:** Phase complete when:
- `make check` passes.
- A bats test with stubbed `net_backend_port` / `net_webui_port` and a
  netstat/lsof stub: `4lm diag` stdout contains "Backend" and at least one
  client address.
- `docs/setup.md` diag section documents only sections that appear in actual
  `4lm diag` output (verified by running `4lm diag` and diffing section names).
- `bin/4lm_helpers.py` diag output does not contain any per-worker CPU or RSS
  column header.

### Test Scenarios

**GIVEN** the backend service is listening (stubbed lsof/netstat returns one connection)
**WHEN** `4lm diag` runs
**THEN** stdout contains "Backend" and at least one client address

**GIVEN** the WebUI service is listening (stubbed lsof/netstat returns one connection)
**WHEN** `4lm diag` runs
**THEN** stdout contains "WebUI" and at least one client address

**GIVEN** `docs/setup.md` diag section lists output section names S1..Sn
**WHEN** `4lm diag` is run and its stdout is captured
**THEN** every section name in S1..Sn appears verbatim in the captured output

**GIVEN** `bin/4lm_helpers.py` diag output is captured
**WHEN** the output is inspected
**THEN** it does not contain any per-worker CPU or RSS column header

---

## Phase 5 — Help Surface & Destructive-Operation Guards

Fix discoverability gaps and prevent accidental destructive actions.

**Changes:**

**`bin/4lm` — `cmd_help`** (lines ~1358-1362): Add:

```
models cleanup [--confirm]   Remove cached models not referenced in any profile
```

**`bin/4lm` — `cmd_models_clean`** (line ~1142): Append `--yes` to the `hf cache prune` invocation:

```bash
hf cache prune --yes
```

**`bin/4lm` — `cmd_models_rm`**: Add `--confirm` flag parsed via `while case`:

```bash
local confirm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) confirm=true ;;
    *) repo="$1" ;;
  esac
  shift
done
if [[ "${confirm}" != "true" ]]; then
  printf 'Pass --confirm to remove: %s\n' "${repo}"
  exit 0
fi
```

**`bin/4lm` — `cmd_uninstall`**: Add `--confirm` flag:

```bash
local confirm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) confirm=true ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
if [[ "${confirm}" != "true" ]]; then
  printf 'Would remove:\n'
  printf '  %s\n' \
    "${LLM_HOME}" \
    "${HOME}/.local/bin/4lm" \
    "${HOME}/Library/LaunchAgents/com.4lm.backend.plist" \
    "${HOME}/Library/LaunchAgents/com.4lm.webui.plist" \
    "/usr/local/etc/newsyslog.d/4lm.conf"
  exit 0
fi
```

**`bin/4lm` — `cmd_expose`**: Replace positional `$2` check with:

```bash
local confirm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) confirm=true ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
```

**`bin/4lm` — `cmd_profile_list`**: After the profile enumeration loop, if no
`.yaml` files were printed:

```bash
printf 'No profiles found in %s — run: make install\n' "${PROFILES_DIR}"
```

**`bin/4lm_helpers.py` — `cmd_models_list`**: After building the Rich table, if
the table has zero data rows:

```python
if table.row_count == 0:
    console.print("No cached models found.")
    return 0
```

**`docs/setup.md` + `README.md`**: Update LAN exposure security sections:
- `WEBUI_REGISTRATION_ENABLED=false` and `DEFAULT_USER_ROLE=pending` apply in
  all modes (not LAN-only).
- Remove the "first-user race" risk bullet.

**Verification gate:** Phase complete when:
- `make check` passes.
- `4lm models rm org/repo` without `--confirm` → exit 0, stdout contains
  "--confirm" and "org/repo", cache unmodified.
- `4lm models rm org/repo --confirm` → invokes removal with correct repo.
- `4lm uninstall` without `--confirm` → exit 0, `~/.local/bin/4lm` not removed,
  stdout lists `~/.4lm` path.
- `4lm expose lan extraneous` → exit 1, stderr contains "error:" and "unknown argument".
- `4lm expose lan --confirm` → proceeds (flag order independent).
- `4lm profile list` on empty profiles dir → stdout contains "No profiles" and "make install".
- `4lm help` output contains a line for `models cleanup`.
- `hf cache prune` invocation captured via stub includes `--yes`.

### Test Scenarios

**GIVEN** `4lm models rm org/repo` is called without `--confirm`
**WHEN** the command runs
**THEN** exit code is 0 and stdout contains "--confirm" and "org/repo" and the cache is unmodified

**GIVEN** `4lm models rm org/repo --confirm` is called
**WHEN** the command runs
**THEN** the removal command is invoked with the correct repo argument

**GIVEN** `4lm uninstall` is called without `--confirm`
**WHEN** the command runs
**THEN** exit code is 0 and `~/.local/bin/4lm` still exists and stdout lists at least `~/.4lm`

**GIVEN** `4lm expose lan extraneous-arg` is called
**WHEN** the command runs with the flag-based parser
**THEN** exit code is 1 and stderr contains "error:" and "unknown argument"

**GIVEN** `4lm expose lan --confirm` is called
**WHEN** the command runs
**THEN** `network.yaml` is updated to `mode: lan` and exit code is 0

**GIVEN** `4lm expose lan --confirm extraneous` is called
**WHEN** the command runs (flag parsing is a single left-to-right pass)
**THEN** exit code is 1 and stderr contains "error:" and "unknown argument" for `extraneous`; LAN mode is NOT applied because the command aborts on the unknown argument

**GIVEN** `PROFILES_DIR` contains no `.yaml` files
**WHEN** `4lm profile list` runs
**THEN** stdout contains "No profiles" and "make install"

**GIVEN** `4lm help` output is captured
**WHEN** the output is inspected
**THEN** it contains a line matching `models cleanup`

**GIVEN** `4lm models clean` is invoked with a stub capturing `hf` invocations
**WHEN** the `hf cache prune` command is constructed
**THEN** the invocation includes `--yes`

---

## Phase 6 — WebUI Start Script Test Coverage

Add bats tests for `bin/4lm-webui-start.sh` covering the security-critical
invariants that currently have zero test coverage.

**Changes:**

**`tests/helpers/open-webui`** (new stub, `chmod +x`):

```bash
#!/usr/bin/env bash
LOG_ENV="${WEBUI_ENV_LOG:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/open-webui.env}"
LOG_ARGS="${WEBUI_ARGS_LOG:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/open-webui.args}"
env > "${LOG_ENV}"
printf '%s\n' "$*" > "${LOG_ARGS}"
exit 0
```

**`tests/test_webui_start.bats`** (new file):

File header:

```bash
#!/usr/bin/env bats
# Tests for bin/4lm-webui-start.sh security invariants.

setup() {
  export HOME="${BATS_TMPDIR}/home"
  mkdir -p "${HOME}/.4lm/config" "${HOME}/.4lm/logs"
  export LLM_HOME="${HOME}/.4lm"
  export ACTIVE_CONFIG="${LLM_HOME}/config/active-profile"
  # Minimal network.yaml
  printf 'mode: local\nbackend_port: 8080\nwebui_port: 3000\n' \
    > "${LLM_HOME}/config/network.yaml"
  # Stub open-webui first on PATH
  export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"
}
```

Five test cases:

1. **Registration disabled**: Run script; assert
   `grep -qx 'WEBUI_REGISTRATION_ENABLED=false' "${BATS_TMPDIR}/open-webui.env"`.

2. **Default role pending**: Assert
   `grep -qx 'DEFAULT_USER_ROLE=pending' "${BATS_TMPDIR}/open-webui.env"`.

3. **Secret key from existing file**: Create
   `${HOME}/.4lm/config/webui_secret_key` with value `known-secret`; run
   script; assert
   `grep -qx 'WEBUI_SECRET_KEY=known-secret' "${BATS_TMPDIR}/open-webui.env"`.

4. **Secret key generated and persisted**: Remove
   `${HOME}/.4lm/config/webui_secret_key`; run script; assert env contains a
   non-empty `WEBUI_SECRET_KEY=` line; assert file was created; assert
   `stat -f %Lp "${HOME}/.4lm/config/webui_secret_key"` equals `0600`.

5. **Non-numeric port fallback**: Set `webui_port: notanumber` in
   `${LLM_HOME}/config/network.yaml`; run script; assert
   `grep -q -- '--port 3000' "${BATS_TMPDIR}/open-webui.args"`.

Secret key file path is `${HOME}/.4lm/config/webui_secret_key` (matching
`SECRET_KEY_FILE="${CONFIG_DIR}/webui_secret_key"` in the script). `stat`
assertion uses `0600` (macOS `stat -f %Lp` returns leading-zero octal form).

**Verification gate:** Phase complete when:
- `make test` passes including the new bats file.
- All 5 scenarios are green.
- `grep 'WEBUI_REGISTRATION_ENABLED\|DEFAULT_USER_ROLE\|WEBUI_SECRET_KEY' tests/test_webui_start.bats` shows coverage of each invariant.

### Test Scenarios

**GIVEN** `bin/4lm-webui-start.sh` is executed with a valid `network.yaml` and
`HOME` set to a sandbox directory with `${HOME}/.4lm/config/` pre-created
**WHEN** the `open-webui` stub intercepts execution
**THEN** `${BATS_TMPDIR}/open-webui.env` contains `WEBUI_REGISTRATION_ENABLED=false`

**GIVEN** the same setup
**WHEN** the stub captures the environment
**THEN** `${BATS_TMPDIR}/open-webui.env` contains `DEFAULT_USER_ROLE=pending`

**GIVEN** `${HOME}/.4lm/config/webui_secret_key` does not exist
**WHEN** `bin/4lm-webui-start.sh` runs
**THEN** a non-empty `WEBUI_SECRET_KEY=` line is present in the captured env AND
`${HOME}/.4lm/config/webui_secret_key` is created with permissions `0600`
(verified via `stat -f %Lp` returning `0600` on macOS)

**GIVEN** `${HOME}/.4lm/config/webui_secret_key` already exists with value `known-secret`
**WHEN** `bin/4lm-webui-start.sh` runs
**THEN** `${BATS_TMPDIR}/open-webui.env` contains `WEBUI_SECRET_KEY=known-secret` (no regeneration)

**GIVEN** `network.yaml` contains `webui_port: notanumber`
**WHEN** `bin/4lm-webui-start.sh` runs
**THEN** `${BATS_TMPDIR}/open-webui.args` contains `--port 3000` and stderr
contains "WARN:" and "invalid"

---

## Decision Log

**Phased remediation vs. single-commit sweep**: A single commit touching all
findings would be hard to review and impossible to bisect. Phases are ordered
by blast radius: correctness bugs first, then UX, then cosmetics, then coverage.

**Profile validation extraction**: Three options: (a) source `bin/4lm` (sources
all 1400 lines — not acceptable in a launchd entry point), (b) extract
`validate_profile` + `profile_backend` into `bin/4lm-lib.sh` (cleaner but
larger refactor), (c) inline a minimal validator using shell primitives only —
no `python3`, no shared lib. Chose (c). Checks `backend:` and `models:` key
presence via `grep`, which covers the correctness bug with minimum scope change.
The `python3 -c "import yaml..."` approach from the original SDD draft was
rejected: `python3` is not guaranteed in the launchd PATH, and the existing
script already avoids it for all other checks.

**Per-worker CPU/RSS in `4lm diag`**: Option A: implement via `ps -o pid,%cpu,rss,etime`
(no new deps, macOS-compatible). Option B: remove the stub section and trim
documentation. Chose Option B (trim docs). The stub currently emits incorrect
output and `ps`-based collection adds code complexity with uncertain output
format. Trimming docs is a smaller, safer change; the TCP client listing
(already implemented via `print_clients`) is the high-value addition in Phase 4.

**`expose lan` exit code after refusal**: The guidance path (missing `--confirm`)
exits 1. Changing to exit 0 risks breaking scripts that rely on the current
behaviour. Exit 1 is preserved; only the message style changes from raw echo to
`die` (`error:` prefix). The inconsistency with `models rm` (exit 0 on missing
`--confirm`) is intentional: `expose lan` is an active guard for a
security-sensitive operation; `models rm` is a guard for a
destructive-but-recoverable operation.

**`cmd_uninstall` interactive fallback**: An interactive `read` prompt is harder
to test and unusable in pipelines. The `--confirm` flag pattern is chosen,
consistent with `expose` and `models cleanup`. Interactive prompt is explicitly
out of scope.

**`expose lan --confirm extraneous` flag ordering**: The flag parser processes
arguments left-to-right in a single pass. If `--confirm` precedes `extraneous`,
`--confirm` is set but the parser then hits `extraneous` and calls `die`. LAN
mode is never applied in this case. This is the correct behaviour — all
arguments must be valid for the command to execute.

**`stat -f %Lp` returns `0600` on macOS**: macOS `stat -f %Lp` returns
leading-zero octal (e.g. `0600`). The bats assertion must compare against
`0600`, not `600`.

## Open Decisions

None.

## Out of Scope

- New CLI features or commands not already present in the codebase.
- Changing `info()` from stdout to stderr (broader interface change; may break
  existing scripts and tests).
- Machine-readable `--json` output flag (LOW severity; substantial scope).
- Alias documentation in `cmd_help` (LOW severity; cosmetic).
- Profile schema validation for undocumented keys like `on_demand_idle_timeout`.
- Python `recommendations` output formatting changes (separate from this review).
- Extraction of `bin/4lm-lib.sh` shared library (deferred; inline validator is
  sufficient for Phase 1).
- Interactive `read` prompt for `cmd_uninstall` (only `--confirm` flag required).
- Implementing per-worker CPU/RSS in `4lm diag` via `ps` (deferred; see Decision
  Log).
