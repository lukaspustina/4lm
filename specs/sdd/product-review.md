# SDD: Product Review Remediation

Status: Draft
Created: 2026-05-07

## Overview

A structured product review of the 4lm CLI (run 2026-05-07) surfaced findings
across six quality lenses. This SDD captures all HIGH and impactful MEDIUM
issues as requirements and organises them into independently shippable phases.
The work is purely remediation — no new user-facing features are added.

## Context & Constraints

- **Stack**: Bash (`bin/4lm`, ~1410 lines), Python helpers (`bin/4lm_helpers.py`),
  bats test suite (`tests/*.bats`), pytest suite (`tests/python/`).
- **Conventions**: `set -euo pipefail`; shellcheck clean; shfmt formatted;
  conventional commit prefixes; no `Co-Authored-By` lines.
- **Error helpers**: `die()` → `error:` prefix → stderr → exit 1.
  `warn()` → `warn:` prefix → stderr. `ok()` / `info()` → stdout.
  All user-visible error paths must route through these; raw `echo >&2` is
  reserved for the helper definitions themselves.
- **Tests**: every changed behaviour needs a bats or pytest test;
  `make check` must pass after each phase.
- **Atomic writes**: prefer `tmp + mv` over in-place `sed -i` for files that
  must survive an interrupted write.

## Requirements

1. The system shall call `validate_profile` on the active profile before
   launching the backend in `bin/4lm-backend-start.sh`.
2. `BACKEND_POLL_SECS` shall control elapsed seconds, not iteration count;
   the worst-case wait shall equal the configured value.
3. After a profile-switch rollback, the system shall poll `/v1/models` on the
   restored backend before reporting success or failure to the user.
4. Switching to the currently active profile (same name) shall succeed silently
   if the backend is not loaded, and succeed normally if it is — it shall never
   produce a "no previous profile to revert to" fatal error.
5. `bin/4lm-webui-start.sh` shall validate that `WEBUI_PORT` and
   `BACKEND_PORT` are numeric (falling back to defaults on invalid values),
   matching the guard already present in `bin/4lm`'s `net_webui_port()`.
6. `cmd_upgrade` shall write `requirements.txt` atomically (temp file + `mv`)
   so an interrupted upgrade cannot leave the file partially overwritten.
7. `4lm start` shall print the WebUI URL and a one-line account-setup hint on
   first start (when the `openwebui-data/` directory does not yet exist), and
   the WebUI URL on all subsequent successful starts.
8. `install.sh` next-steps output shall state the approximate model download
   size and time cost before the `4lm models download` step.
9. `4lm doctor` shall check that at least one model referenced by the active
   profile is present in the HuggingFace or Ollama cache and warn if none are.
10. `4lm health` success output shall display wired memory in human-readable
    form (GB, rounded) in addition to the raw MB value, and `die()` shall be
    used for the below-threshold path.
11. `require_helpers_python` shall use `die()` instead of a raw `echo >&2 +
    exit 1`, matching the standard error style.
12. The rollback error paths in `cmd_profile_set` shall use `die()` and `warn()`
    (not raw `echo >&2`) for all user-visible messages.
13. `4lm diag` shall execute `print_clients()` for both backend and webui ports
    and display the results as a section of its output.
14. The `4lm diag` help entry and `docs/setup.md` diag section shall accurately
    describe what the command outputs — no more, no less.
15. `4lm models cleanup` shall appear in `cmd_help`.
16. `4lm models clean` (prune) shall pass `--yes` to `hf cache prune` so it is
    safe to run non-interactively and from scripts.
17. `4lm models rm` shall require `--confirm` or interactive confirmation before
    permanently deleting a cached model.
18. `4lm uninstall` shall require `--confirm` or print a confirmation prompt
    before executing.
19. `4lm expose`'s `--confirm` flag shall be parsed via a `while case` loop
    (not positional `$2`), matching the pattern used by `models cleanup`.
20. Empty-state messages shall be shown for `4lm profile list` (when no profiles
    exist) and for `4lm models list` (when no models are cached).
21. `bin/4lm-webui-start.sh` security invariants (`WEBUI_REGISTRATION_ENABLED`,
    `WEBUI_SECRET_KEY`, `DEFAULT_USER_ROLE`) shall have bats test coverage.
22. `docs/setup.md` LAN exposure risk description shall be updated to reflect
    that `WEBUI_REGISTRATION_ENABLED=false` is always active (not LAN-only),
    removing the stale "first-user race" risk entry.
23. `README.md` security posture description for `expose lan` shall be corrected
    to state that registration lock and `DEFAULT_USER_ROLE=pending` apply in
    all modes, not only LAN mode.

## Implementation Phases

## Phase 1 — Correctness & Safety

Fix bugs that silently mis-behave or produce incorrect output regardless of UX
polish.

### Changes

- **`bin/4lm-backend-start.sh`**: source `bin/4lm` (or extract `validate_profile`
  and `profile_backend` into a shared `bin/4lm-lib.sh`) and call
  `validate_profile "${ACTIVE_PROFILE_PATH}"` before constructing the launch
  arguments. Exit non-zero with a clear message on failure.
- **`bin/4lm` – poll loop** (`cmd_profile_set`, lines 831-839): replace the
  `seq 1 $BACKEND_POLL_SECS` + `sleep 1` loop with an elapsed-time loop using
  `$SECONDS` or `date +%s`. Each iteration: `curl --max-time 1 …`; if failed,
  `sleep 1`; check elapsed ≥ threshold and break. The loop may run at most
  `$BACKEND_POLL_SECS` elapsed seconds. Update the variable name comment to
  reflect the corrected semantics.
- **`bin/4lm` – rollback poll** (`cmd_profile_set`, lines 843-855): after
  `launchctl kickstart` restores the old profile, run the same elapsed-time
  poll (budget: `$BACKEND_POLL_SECS` seconds). On poll success: print restored
  message and exit 1 (switch failed, old profile live). On poll failure: print
  a `warn` that the old backend did not respond and exit 1.
- **`bin/4lm` – same-name switch** (lines 819, 851-853): when `name == previous`
  or `previous` is empty, skip writing `previous-profile`; if the backend times
  out during a same-name kickstart, exit 1 with a specific message rather than
  hitting the "no previous profile" branch.
- **`bin/4lm-webui-start.sh`**: add numeric guards for `WEBUI_PORT` and
  `BACKEND_PORT` matching the pattern in `net_webui_port()`.
- **`bin/4lm` – atomic requirements.txt bump** (`cmd_upgrade`, line 661): write
  to `${repo}/requirements.txt.tmp`, then `mv` over the original. Use a `trap`
  to remove the temp file on error.
- **`bin/4lm_helpers.py` – orphan-worker detection**: invert the condition at
  line 377 so workers are flagged orphaned when they appear in the log but have
  no corresponding in-flight admissions in the reporting window.

Phase complete when: `make check` passes; `test_profile_state_machine.bats`
covers same-name switch, rollback-poll success, and rollback-poll failure
scenarios; a new bats test validates that `4lm-backend-start.sh` exits non-zero
on an invalid active profile; manual verification that a 2-second
`BACKEND_POLL_SECS` budget takes ≤ 3 seconds actual elapsed.

### Test Scenarios

**GIVEN** `bin/4lm-backend-start.sh` is invoked with an active profile that
has a missing `context_length`  
**WHEN** the script runs  
**THEN** it exits non-zero with a message containing "profile" and "validation"

**GIVEN** `BACKEND_POLL_SECS=2` is set  
**WHEN** the backend never responds and `cmd_profile_set` runs the poll loop  
**THEN** total elapsed time is between 2 s and 3 s (not 4 s+)

**GIVEN** `4lm profile set default` is called when `default` is already active  
**WHEN** the backend is not loaded  
**THEN** the command succeeds (exit 0) without printing a fatal error

**GIVEN** profile switch times out and a valid previous profile exists  
**WHEN** rollback kickstart succeeds and `/v1/models` responds within poll budget  
**THEN** output contains "reverted" and exit code is 1

**GIVEN** `cmd_upgrade` is interrupted mid-write of `requirements.txt`  
**WHEN** the process is killed during the `mv` atomic swap  
**THEN** `requirements.txt` is either fully old or fully new, never partial

---

## Phase 2 — Onboarding & Post-Start UX

Eliminate the three silent failure modes a new user hits in the first 15 minutes.

### Changes

- **`bin/4lm` – `cmd_start`**: after both services are marked started, detect a
  first-run state by checking whether `${LLM_HOME}/openwebui-data/` is absent.
  On first run: print the WebUI URL + `"Open it in a private window, create an
  account, then visit Admin → Settings → Users to promote yourself to admin."`
  On subsequent starts: print the WebUI URL only. Always print: `"Run \`4lm
  open\` to open in browser."` — `bin/4lm:1026-1037`.
- **`install.sh` next-steps block** (lines 316-327): insert a note before the
  `4lm models download` step: `"(~140 GB download, 15-30 min on residential
  fiber — run from a reliable connection)"`.
- **`bin/4lm` – `cmd_doctor`**: add a model-cache check. For each model in the
  active profile, call `hf_is_cached` / the Ollama equivalent. If none are
  cached: `warn "no models cached — run: 4lm models download"`.
- **`bin/4lm` – `cmd_health`**: replace the raw `echo` error path with `die()`.
  Format the success output as `"GPU wired memory: ${human_gb} GB (${current}
  MB) — OK"`.

Phase complete when: `make check` passes; `test_4lm_dispatch.bats` covers the
first-run URL hint; manual verification of `4lm start` output on a clean
`openwebui-data/` directory and after it exists.

### Test Scenarios

**GIVEN** `openwebui-data/` does not exist  
**WHEN** `4lm start` completes  
**THEN** stdout contains the WebUI URL and the word "account"

**GIVEN** `openwebui-data/` already exists  
**WHEN** `4lm start` completes  
**THEN** stdout contains the WebUI URL but not "account"

**GIVEN** no models are cached for the active profile  
**WHEN** `4lm doctor` runs  
**THEN** output contains "warn" and "models download"

**GIVEN** `iogpu.wired_limit_mb` returns 0  
**WHEN** `4lm health` runs  
**THEN** the process exits 1 and the error message is styled with `error:` prefix

---

## Phase 3 — Error Message Consistency

Make all error output route through `die()`/`warn()` and surface human-readable
messages.

### Changes

- **`bin/4lm` – `require_helpers_python`** (line 68): replace raw `echo >&2 +
  exit 1` with `die "helpers venv missing — run: make install"`.
- **`bin/4lm` – `cmd_profile_set` rollback paths** (lines 846, 849, 810):
  replace raw `echo >&2` with `warn` or `die` as appropriate.
- **`bin/4lm` – `profile_backend`** (line 224): use `die` (or keep return 1 and
  ensure all callers surface the error through `die`).
- **`bin/4lm` – `cmd_expose` refusal** (line 871): replace raw `echo >&2 + exit
  1` with `die`.
- **`bin/4lm` – `service_stop` "not loaded"** (line 263): change from `info` to
  a neutral message that reads as informational (keep stdout; rephrase to
  "already stopped" to avoid implying an action occurred).
- **`bin/4lm_helpers.py`** (lines 215, 436): wrap exception strings in a
  human-readable prefix; do not surface raw Python exception class names or
  socket-level errno strings. Pattern: `f"could not reach PyPI ({type(e).__name__})"`.
- **`bin/4lm` – `expose lan` confirmation message**: rewrite as a neutral
  informational message, not an error-styled `die`. Consider using `info` and
  exiting 0 to indicate "guidance given, no error occurred" — or keep exit 1
  but use `warn` styling.

Phase complete when: `make check` passes; grep for `echo.*>&2` outside the
`die()`/`warn()` helper definitions returns zero results; a bats test confirms
`require_helpers_python` exits with the `error:` prefix.

### Test Scenarios

**GIVEN** the helpers venv is absent (`LLM_HELPERS_PYTHON=/nonexistent`)  
**WHEN** a command that calls `require_helpers_python` runs  
**THEN** stderr contains `"error:"` and the process exits 1

**GIVEN** `4lm profile set bad-profile` is called with an invalid YAML  
**WHEN** validation fails  
**THEN** stderr contains exactly one `error:` prefixed line plus the specific
validation reason; no duplicate messages

**GIVEN** `4lm expose lan` is called without `--confirm`  
**WHEN** the command runs  
**THEN** exit code is 1 and output follows `warn:`/`error:` styling (not raw echo)

---

## Phase 4 — `4lm diag` Implementation Gap

Bring the implementation in line with documentation, or update documentation
to match reality. Decision: **implement the missing output** (TCP client
listing) and update docs for the parts still not implemented (top CPU / per-
worker detailed stats).

### Changes

- **`bin/4lm` – `cmd_diag`** (lines 408-412): call `print_clients
  "$(net_backend_port)" "Backend"` and `print_clients "$(net_webui_port)"
  "WebUI"` before delegating to the Python helper. The `print_clients` function
  already exists and works correctly.
- **`bin/4lm_helpers.py` – diag worker section** (lines 367-371): either
  implement real per-worker stats via `ps -o pid,%cpu,rss,etime` (matching the
  documented output example) or remove the section and its documentation entry.
  If implementing: add a comment noting that `psutil` is not available in the
  helpers venv and the `ps` approach must be used.
- **`docs/setup.md` – diag section** (lines 208-226): update to match exactly
  what the command now outputs.
- **`bin/4lm` – `cmd_help` diag entry** (line 1373): update description to match
  actual output.

Phase complete when: `make check` passes; running `4lm diag` (with a running
backend) shows the TCP client section; `docs/setup.md` and `cmd_help` match
what the command produces.

### Test Scenarios

**GIVEN** the backend is loaded and running  
**WHEN** `4lm diag` runs  
**THEN** output contains a line matching "Backend clients" (from `print_clients`)

**GIVEN** `docs/setup.md` diag section is read  
**WHEN** compared against actual `4lm diag` output  
**THEN** every documented output section exists in the actual output

---

## Phase 5 — Help Surface & Destructive-Operation Guards

Fix discoverability gaps and prevent accidental destructive actions.

### Changes

- **`bin/4lm` – `cmd_help`** (lines 1358-1362): add `models cleanup [--confirm]`
  with description "Remove cached models not referenced in any profile".
- **`bin/4lm` – `cmd_models_clean`** (line 1142): pass `--yes` to `hf cache
  prune` so the command is non-interactive.
- **`bin/4lm` – `cmd_models_rm`**: add a `--confirm` flag; without it, print
  "Pass --confirm to remove: <repo>" and exit 0.
- **`bin/4lm` – `cmd_uninstall`**: add a `--confirm` flag (or interactive `read`
  prompt as a fallback). Without `--confirm`, print what would be removed and
  exit 0.
- **`bin/4lm` – `cmd_expose`**: change `--confirm` from positional `$2` to a
  `while case` loop parser, consistent with `cmd_models_cleanup`. This is a
  pure refactor with identical external behaviour.
- **`bin/4lm` – `cmd_profile list`**: print a hint when no profiles are found:
  `"No profiles found in ${PROFILES_DIR} — run: make install"`.
- **`bin/4lm_helpers.py` – models list empty state**: print a message when the
  rich table would have zero data rows.
- **`docs/setup.md` + `README.md`**: correct the LAN exposure security section
  to state that `WEBUI_REGISTRATION_ENABLED=false` and `DEFAULT_USER_ROLE=pending`
  are always active; remove the "first-user race" risk bullet.

Phase complete when: `make check` passes; `4lm models rm <repo>` without
`--confirm` exits 0 with an explanatory message; `4lm uninstall` without
`--confirm` does not remove anything; `4lm expose lan blah` no longer silently
ignores unknown arguments; `4lm profile list` on an empty directory shows the
hint.

### Test Scenarios

**GIVEN** `4lm models rm org/repo` is called without `--confirm`  
**WHEN** the command runs  
**THEN** exit code is 0 and nothing is deleted; output contains "--confirm"

**GIVEN** `4lm uninstall` is called without `--confirm`  
**WHEN** the command runs  
**THEN** exit code is 0; `~/.local/bin/4lm` is not removed; output describes
what would be removed

**GIVEN** `PROFILES_DIR` exists but contains no `.yaml` files  
**WHEN** `4lm profile list` runs  
**THEN** stdout contains "No profiles" and a "make install" hint

**GIVEN** `4lm expose lan extraneous-arg --confirm` is called  
**WHEN** the command runs  
**THEN** the `--confirm` flag is recognised regardless of argument order (since
positional parsing is replaced by flag parsing)

---

## Phase 6 — WebUI Start Script Test Coverage

Add bats tests for `bin/4lm-webui-start.sh` covering the security-critical
invariants that currently have zero test coverage.

### Changes

- **`tests/test_webui_start.bats`** (new file): stub `open-webui` (like the
  existing `tests/helpers/mlx-openai-server` stub) to capture the environment
  it was invoked with. Test scenarios:
  1. `WEBUI_REGISTRATION_ENABLED` is set to `"false"` in the environment passed
     to `open-webui serve`.
  2. `DEFAULT_USER_ROLE` is set to `"pending"` in the environment.
  3. `WEBUI_SECRET_KEY` is set to a non-empty value when `webui_secret_key` file
     exists.
  4. `WEBUI_SECRET_KEY` is generated and persisted when `webui_secret_key` is
     absent.
  5. `WEBUI_PORT` defaults to 3000 when `network.yaml` contains a non-numeric
     port value.
- **`tests/helpers/open-webui`** (new stub): captures `$*` and env vars;
  follows the pattern of existing stubs in `tests/helpers/`.

Phase complete when: `make test` passes including the new bats file; all 5
scenarios are green; coverage of the security invariants is confirmed.

### Test Scenarios

**GIVEN** the webui start script is executed  
**WHEN** `open-webui serve` is called  
**THEN** `WEBUI_REGISTRATION_ENABLED=false` is present in its environment

**GIVEN** no `webui_secret_key` file exists  
**WHEN** the webui start script runs  
**THEN** a non-empty `WEBUI_SECRET_KEY` is set AND the file is created with
mode 0600

**GIVEN** `network.yaml` contains `webui_port: notanumber`  
**WHEN** the webui start script runs  
**THEN** `open-webui serve --port 3000` is called (default fallback applied)

---

## Decision Log

**Phased remediation vs. single-commit sweep**: A single commit touching all
findings would be hard to review and impossible to bisect. Phases are ordered
by blast radius: correctness bugs first, then UX, then cosmetics, then coverage.

**diag: implement missing output vs. update docs to match reality**: The TCP
client listing (`print_clients`) is already implemented and correct — it is
simply not wired in. Wiring it in is a one-line change with high user value.
The per-worker CPU/RSS output requires a decision: either use `ps` in the
Python helper (portable on macOS) or trim the documentation. The SDD chooses
to implement the TCP listing (Phase 4) and defers the CPU/RSS detail to an
open decision.

**`expose lan` exit code after refusal**: Current behaviour exits 1 when
`--confirm` is absent. This is a guidance path, not an error, so exiting 1 is
arguably wrong. However, changing the exit code is a behaviour change that could
break scripts. The SDD keeps exit 1 but changes the styling from raw echo to
`warn:`/`die` in Phase 3; exit-code semantics are left as-is to avoid regressions.

**`--confirm` on `uninstall`**: An interactive `read` prompt would be more
user-friendly but is harder to test and unusable in pipelines. The SDD chooses
the `--confirm` flag pattern (consistent with `expose` and `models cleanup`) and
allows interactive prompt as an optional fallback.

**Shared library extraction for profile validation**: Phase 1 requires
`validate_profile` in `4lm-backend-start.sh`. Options: (a) source the main
`bin/4lm` script (not ideal — sources all 1400 lines), (b) extract
`validate_profile` + `profile_backend` into a `bin/4lm-lib.sh` sourced by
both, (c) inline a minimal validator in the start script. Option (b) is cleanest
but is a refactor; option (c) is the minimum change. The SDD leaves this as an
open decision.

## Open Decisions

1. **Per-worker CPU/RSS in `4lm diag`**: should `cmd_diag` call `ps -o
   pid,%cpu,rss,etime` for each detected worker PID (matching `docs/setup.md`
   example output), or should the documentation be trimmed to match current
   minimal output? Impact: `ps` approach requires no new deps and works on
   macOS; trimming docs is smaller change but loses useful diagnostic info.

2. **Profile validation in `4lm-backend-start.sh`**: inline a minimal
   validator, or extract shared functions into `bin/4lm-lib.sh`? Impact:
   extraction is cleaner but touches the file structure; inline is safer for
   a targeted fix.

## Out of Scope

- New CLI features or commands not already present in the codebase.
- Changing the `info()` function from stdout to stderr (mixing is real but is a
  broader interface change that may break existing scripts and tests).
- Machine-readable `--json` output flag (LOW severity; substantial scope).
- Alias documentation in `cmd_help` (LOW severity; cosmetic).
- Profile schema validation for undocumented keys like `on_demand_idle_timeout`.
- Python `recommendations` output formatting changes (separate from this review).
