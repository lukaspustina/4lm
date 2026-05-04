# SDD: Ollama Backend Support

Status: Ready for Implementation
Original: specs/sdd/ollama-backend.md
Refined: 2026-05-04

## Overview

4lm currently hard-wires `mlx-openai-server` as its only backend. This SDD adds `backend: ollama` as a profile-level key, letting any profile elect Ollama as the inference daemon instead of mlx-openai-server. Because Ollama exposes the same OpenAI-compatible `/v1/` API on the same stable port, no client reconfiguration (OpenCode, Open WebUI) is required. The primary motivation is Gemma-4 support while mlx-openai-server's Gemma-4 bugs are unresolved upstream.

## Context & Constraints

- **Stack**: Bash scripts, launchd plists, bats test suite (macOS Apple Silicon only).
- **All scripts**: `set -euo pipefail`, `shellcheck`-clean, `shfmt`-formatted.
- **Single backend per profile**: Profiles elect exactly one backend (`mlx` or `ollama`). No concurrent backends, no routing proxy.
- **Stable port**: The backend port (default 8000) does not change when switching between backends. Ollama is bound via `OLLAMA_HOST=<host>:<port>`.
- **No new plists**: The existing `com.4lm.backend` plist calls `4lm-backend-start.sh`, which already reads the active profile. No new launchd services are needed.
- **No client reconfiguration**: Ollama's `/v1/` endpoint is used (not the native Ollama API). `ENABLE_OLLAMA_API=False` in the WebUI start script stays unchanged.
- **`model_path` is overloaded**: For Ollama profiles, `model_path:` holds the Ollama pull tag (e.g. `gemma4:27b`). This is the same YAML field used by mlx profiles for HuggingFace repo IDs. The `served_model_name:` field provides the API alias in both cases. The `profile_model_entries()` awk parser needs no changes.
- **`4lm-backend-start.sh` cannot source `bin/4lm`**: Backend detection in the start script duplicates the two-line grep/awk from `profile_backend()` inline. This is intentional — the start script is a standalone launchd entry point.
- **Conventional commits**, no `Co-Authored-By: Claude`, subject ≤ 72 chars.

## Architecture

```
4lm profile set <name>
  └─ cmd_profile_set()
       ├─ validate_profile()   ← backend-aware (R2–R4)
       ├─ writes active-profile symlink
       └─ kickstart 4lm-backend-start.sh
            ├─ reads backend: from active profile (inline grep/awk)
            ├─ [mlx]    exec mlx-openai-server launch --config ...
            └─ [ollama] OLLAMA_HOST=<host>:<port> exec ollama serve

4lm models download
  └─ cmd_models_download()
       ├─ [per mlx profile]    _hf_download_with_progress <model_path>
       └─ [per ollama profile]  ollama pull <model_path>
```

Health-poll after kickstart (`GET /v1/models`) is unchanged — both Ollama and mlx-openai-server implement this endpoint. If `ollama serve` exits before the 30 s poll completes, the existing timeout/rollback path handles it identically to an mlx crash.

## Requirements

1. The system shall accept an optional top-level `backend: mlx | ollama` key in profile YAMLs. Absence defaults to `mlx`.
2. `validate_profile` shall accept Ollama profiles with only `model_path:` and `served_model_name:` per model entry — `context_length:`, `tool_call_parser:`, `model_type:`, and `on_demand:` are not required for `ollama` profiles; extra fields are tolerated.
3. `validate_profile` shall reject profiles with an unrecognised `backend:` value, exiting 1 with stderr: `unknown backend '<value>' in <yaml_path>`.
4. `validate_profile` shall continue to require `context_length:` (positive integer) and valid `tool_call_parser:` values for all `mlx` profiles (existing rules unchanged).
5. `4lm-backend-start.sh` shall read `backend:` from the active profile and start either `mlx-openai-server launch` (existing behaviour) or `ollama serve` (with `OLLAMA_HOST` set).
6. The wired-memory limit sysctl shall only be applied for `mlx` profiles.
7. `4lm models download` (no-arg form) shall dispatch to `hf download` for mlx-backend models and `ollama pull` for ollama-backend models, processing every profile in `~/.4lm/config/profiles/`. Each unique `model_path` per backend type is processed exactly once.
8. `4lm models download <repo> [<repo>...]` (explicit-arg form) shall remain HF-only. Users must invoke `ollama pull` directly for Ollama models; passing any arg containing `:` (Ollama tag heuristic) prints `error: explicit download is HF-only; use: ollama pull <tag>` and exits 1.
9. The `make models` target shall perform the same backend-aware dispatch as R7.
10. `4lm models list` shall annotate each profile name with its backend type (e.g. `(mlx)` or `(ollama)`) and shall not query the HuggingFace cache for Ollama model entries; instead it shall show `~` in the cache-path column.
11. `4lm doctor` shall report whether the `ollama` binary is available: `ok` if found, `warn` if absent. Exit code remains 0 in both cases. The check must not set `fail=1` (ollama is optional).
12. `install.sh` shall migrate the `mlx-active` symlink to `active-profile` and the `mlx-previous` file to `previous-profile` on existing installations, then remove the old names.
13. `install.sh` shall warn (not fail) if the `ollama` binary is absent, printing: `warn: ollama not found — needed only for profiles with backend: ollama` and `    Install: brew install ollama`.
14. The repo shall include `config/profiles/ollama-gemma4.yaml` as a reference Ollama profile (see Data Models).
15. Profile switching between backends (mlx → ollama and back) shall use the existing kickstart/rollback mechanism unchanged. Cross-backend rollback is verified manually only (no bats scenario feasible without a live launchd).
16. `run_outdated_check()` shall skip HuggingFace freshness checks for profiles whose `profile_backend()` returns `ollama`. The existing flat-awk pass (lines 497–523) must be rewritten as a per-profile loop before the guard can be applied.

## File & Module Structure

| File | Change |
|------|--------|
| `bin/4lm` | Add `profile_backend()`; update `validate_profile()`, `cmd_models_download()`, `cmd_models_list()`, `run_outdated_check()`, `cmd_doctor()`; rename `ACTIVE_CONFIG` / `PREVIOUS_PROFILE_FILE` constants; fix one hardcoded `mlx-active` reference in `cmd_recommend` |
| `bin/4lm-backend-start.sh` | Rename `ACTIVE_CONFIG` constant; add inline backend detection; gate wired-memory sysctl; add Ollama launch branch; update file header comment |
| `install.sh` | Add symlink migration block (before step 5); update `ACTIVE` variable; add Ollama binary detection warning |
| `Makefile` | Delete `MODELS` variable (line 10); rewrite `models` target with per-profile backend dispatch |
| `config/profiles/ollama-gemma4.yaml` | New reference profile |
| `docs/profile-schema.md` | Document `backend:` key and Ollama model format |
| `tests/test_profile_state_machine.bats` | Update symlink names (Phase 1); add Ollama validation cases (Phase 2); add model download cases (Phase 4) |
| `tests/test_4lm_dispatch.bats` | Update `mlx-active` → `active-profile` and `mlx-previous` → `previous-profile` in `setup()` and test bodies (Phase 1) |
| `tests/test_backend_start.bats` | New file for Phase 3 test cases |
| `tests/helpers/ollama` | New stub: records args to `${OLLAMA_LOG:-$BATS_TMPDIR/ollama-calls}`, exits `${OLLAMA_STUB_EXIT:-0}` |
| `tests/helpers/hf` | New stub: records args to `${HF_LOG:-$BATS_TMPDIR/hf-calls}`, exits `${HF_STUB_EXIT:-0}` (Phase 4) |
| `tests/helpers/sysctl` | New stub: records args to `${SYSCTL_LOG:-$BATS_TMPDIR/sysctl-calls}`, exits 0 (Phase 3) |

## Data Models

### Profile YAML — Ollama backend

```yaml
# config/profiles/ollama-gemma4.yaml
backend: ollama

models:
  - model_path: gemma4:27b          # Ollama pull tag
    served_model_name: gemma4-27b   # OpenAI API model alias
```

mlx-specific fields (`model_type`, `tool_call_parser`, `reasoning_parser`, `context_length`, `on_demand`) are absent and not required.

### `profile_backend()` function signature

```bash
# Returns "mlx" (default) or "ollama".
# Exits 1 with stderr if backend value is unrecognised.
profile_backend() {
  local yaml="$1"
  local val
  val="$(grep '^backend:' "${yaml}" 2>/dev/null | awk '{print $2}' | tr -d "\"'")"
  case "${val}" in
    ollama) echo "ollama" ;;
    mlx | "") echo "mlx" ;;
    *)
      echo "unknown backend '${val}' in ${yaml}" >&2
      return 1
      ;;
  esac
}
```

### `cmd_models_download()` no-arg dispatch loop

```bash
local seen_mlx="" seen_ollama=""
for profile_yaml in "${PROFILES_DIR}"/*.yaml; do
  [[ -f "${profile_yaml}" ]] || continue
  local backend
  backend="$(profile_backend "${profile_yaml}" 2>/dev/null || echo "mlx")"
  while IFS='|' read -r _served model_path _od; do
    [[ -z "${model_path}" ]] && continue
    if [[ "${backend}" == "ollama" ]]; then
      grep -qxF "${model_path}" <<<"${seen_ollama}" && continue
      seen_ollama="${seen_ollama}${model_path}"$'\n'
      info "ollama pull ${model_path}…"
      ollama pull "${model_path}" || die "ollama pull failed: ${model_path}"
    else
      grep -qxF "${model_path}" <<<"${seen_mlx}" && continue
      seen_mlx="${seen_mlx}${model_path}"$'\n'
      _hf_download_with_progress "${model_path}"
    fi
  done < <(profile_model_entries "${profile_yaml}")
done
```

Note: `_od` is the third field from `profile_model_entries()` — the on-demand flag (`permanent` or `on_demand`). It is not used in the download loop.

### `run_outdated_check()` models section rewrite (lines 497–523)

The existing single-pass awk glob must be replaced with a per-profile loop:

```bash
# Collect HF repos from mlx profiles only.
repos=""
for _p in "${repo}"/config/profiles/*.yaml; do
  [[ -f "${_p}" ]] || continue
  _be="$(profile_backend "${_p}" 2>/dev/null || echo "mlx")"
  [[ "${_be}" == "mlx" ]] || continue
  _r="$(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $3}' "${_p}")"
  [[ -n "${_r}" ]] && repos="${repos}${_r}"$'\n'
done
repos="$(sort -u <<<"${repos}")"
```

The rest of the `run_outdated_check()` models section (HF API calls) is unchanged.

## Configuration

| Key | Location | Type | Default | Notes |
|-----|----------|------|---------|-------|
| `backend:` | profile YAML (top-level) | string | `mlx` | Accepted values: `mlx`, `ollama` |
| `OLLAMA_HOST` | env var set in `4lm-backend-start.sh` | `host:port` | — | Set to `${BIND_HOST}:${NET_PORT}`; `0.0.0.0` is valid for LAN mode |
| `OLLAMA_STUB_EXIT` | env var for tests | integer | `0` | Controls exit code of `tests/helpers/ollama` stub |
| `OLLAMA_LOG` | env var for tests | path | `$BATS_TMPDIR/ollama-calls` | Overrides log path in `tests/helpers/ollama` stub |
| `HF_STUB_EXIT` | env var for tests | integer | `0` | Controls exit code of `tests/helpers/hf` stub |
| `HF_LOG` | env var for tests | path | `$BATS_TMPDIR/hf-calls` | Overrides log path in `tests/helpers/hf` stub |
| `SYSCTL_LOG` | env var for tests | path | `$BATS_TMPDIR/sysctl-calls` | Overrides log path in `tests/helpers/sysctl` stub |

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---------|---------|-----------|--------------|
| Unknown `backend:` value | `profile_backend()` called on profile with e.g. `backend: llamacpp` | Return 1 | `unknown backend 'llamacpp' in <path>` on stderr |
| `ollama` binary absent at start | `4lm-backend-start.sh` with ollama profile, binary not in PATH | Exit 127 | `FATAL: ollama not found in PATH — Install: brew install ollama` |
| `ollama pull` failure | `cmd_models_download()` | `die` (exits 1) | `ollama pull failed: <model_path>` |
| Explicit-arg with Ollama tag | `4lm models download gemma4:27b` (arg contains `:`) | Exit 1 | `error: explicit download is HF-only; use: ollama pull <tag>` |
| `ollama serve` exits before poll | Health poll in `cmd_profile_set()` times out | Rollback to previous profile; kickstart previous backend | `WARN: rollback kickstart failed — backend may be in unknown state` (existing message) |
| `ollama` absent at install | `install.sh` `command -v ollama` check | Continue; warn; do not set `fail=1` | `warn: ollama not found — needed only for profiles with backend: ollama` + hint |

---

## Implementation Phases

## Phase 1 — Symlink rename: `mlx-active` → `active-profile`

Rename the two runtime state files everywhere and migrate existing installations. This is a prerequisite for all subsequent phases.

**Changes:**

`bin/4lm` (lines 22-23):
```bash
readonly ACTIVE_CONFIG="${CONFIG_DIR}/active-profile"
readonly PREVIOUS_PROFILE_FILE="${CONFIG_DIR}/previous-profile"
```
Also fix the one hardcoded `"${CONFIG_DIR}/mlx-active"` string in `cmd_recommend` (around line 1207) → `"${ACTIVE_CONFIG}"`.

`bin/4lm-backend-start.sh` (line 11):
```bash
readonly ACTIVE_CONFIG="${CONFIG_DIR}/active-profile"
```

`install.sh` — add migration block immediately before the existing "Active profile default" block (step 5, around line 105):
```bash
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
```
Then update the `ACTIVE=` line immediately following: `ACTIVE="${CONFIG_DIR}/active-profile"`.

`tests/test_profile_state_machine.bats` and `tests/test_4lm_dispatch.bats`: replace every occurrence of `mlx-active` with `active-profile` and every `mlx-previous` with `previous-profile`.

**Phase complete when:** `make check` passes; `4lm profile set default` creates `~/.4lm/config/active-profile`; `install.sh` on an existing install migrates old names and exits 0.

### Test Scenarios

GIVEN an existing install where `~/.4lm/config/mlx-active` symlink points to `default.yaml`
WHEN `install.sh` is run
THEN `~/.4lm/config/active-profile` symlink points to `default.yaml`; `mlx-active` is absent; exit code is 0

GIVEN an existing install where `~/.4lm/config/mlx-previous` contains `coding-only`
WHEN `install.sh` is run
THEN `~/.4lm/config/previous-profile` contains `coding-only`; `mlx-previous` is absent; exit code is 0

GIVEN a fresh install (neither `mlx-active` nor `active-profile` exists)
WHEN `install.sh` is run
THEN `active-profile` symlink points to `default.yaml`; no `mlx-active` exists; exit code is 0

GIVEN the active profile is `default`
WHEN `4lm profile set coding-only` is run
THEN `~/.4lm/config/active-profile` symlink points to `coding-only.yaml`; `~/.4lm/config/previous-profile` contains `default`

GIVEN all modified files
WHEN `make check` runs shellcheck and shfmt
THEN exit code is 0 with no warnings

---

## Phase 2 — Profile schema + `validate_profile` backend awareness

Add the `backend:` key to the YAML schema. Make `validate_profile()` branch on it. Add the reference Ollama profile and test stubs.

**Changes:**

`bin/4lm` — add `profile_backend()` immediately after `profile_model_entries()` (after line 157). See Data Models for the exact implementation.

`bin/4lm` — rewrite `validate_profile()` (lines 706-756):
1. Call `profile_backend "${yaml_path}"` → `backend`. Return 1 on unknown value.
2. Check `models:` key present and ≥1 `model_path:` entry (both backends).
3. Verify `model_path` count == `served_model_name` count (both backends).
4. **mlx only**: verify `context_length` count == `model_path` count; check `tool_call_parser` enum values against the existing `allowed_parsers` whitelist (line 744 of `bin/4lm` — preserve this string verbatim).
5. **ollama**: no additional field requirements beyond steps 2–3.

`config/profiles/ollama-gemma4.yaml` — new file (see Data Models for content).

`tests/helpers/ollama` — new stub:
```bash
#!/usr/bin/env bash
LOG="${OLLAMA_LOG:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/ollama-calls}"
echo "$*" >> "${LOG}"
exit "${OLLAMA_STUB_EXIT:-0}"
```

`tests/test_profile_state_machine.bats` — add the test cases listed in Test Scenarios below.

**Phase complete when:** `make check` passes including `yaml-lint`; `4lm profile set ollama-gemma4` succeeds; a profile with `backend: llamacpp` is rejected; an mlx profile without `context_length` is rejected.

### Test Scenarios

GIVEN a YAML with `backend: ollama` and models having only `model_path:` and `served_model_name:`
WHEN `validate_profile` is called
THEN it returns 0

GIVEN a YAML with `backend: ollama` and a model entry that also has `context_length: 8192`
WHEN `validate_profile` is called
THEN it returns 0 (extra keys tolerated)

GIVEN a YAML with `backend: ollama` and no `tool_call_parser` in any model entry
WHEN `validate_profile` is called
THEN it returns 0

GIVEN a YAML with `backend: llamacpp`
WHEN `validate_profile` is called
THEN it returns 1 and stderr contains "unknown backend"

GIVEN an mlx profile (no `backend:` key) where a model entry lacks `context_length:`
WHEN `validate_profile` is called
THEN it returns 1 and stderr names the missing field

GIVEN `config/profiles/ollama-gemma4.yaml` exists and passes validation (launchctl stub active)
WHEN `4lm profile set ollama-gemma4` is run
THEN `active-profile` symlink points to `ollama-gemma4.yaml`; `previous-profile` is updated; exit code is 0

---

## Phase 3 — `4lm-backend-start.sh`: Ollama launch branch

Make the backend start script dispatch to the correct binary.

**Changes:**

`bin/4lm-backend-start.sh` — after the bind-host/port block (after line 35), add backend detection:
```bash
# Detect backend type from active profile (inline; cannot source bin/4lm).
BACKEND_TYPE="mlx"
_be_val="$(grep '^backend:' "${ACTIVE_CONFIG}" 2>/dev/null \
  | awk '{print $2}' | tr -d "\"'" || true)"
case "${_be_val}" in
  ollama) BACKEND_TYPE="ollama" ;;
  mlx | "") BACKEND_TYPE="mlx" ;;
  *)
    echo "[$(date -Iseconds)] FATAL: unknown backend '${_be_val}' in ${ACTIVE_CONFIG}" >&2
    exit 78
    ;;
esac
```

Gate the wired-memory block (lines 57-65) behind `[[ "${BACKEND_TYPE}" == "mlx" ]]`.

Replace the locate + launch block with:
```bash
if [[ "${BACKEND_TYPE}" == "ollama" ]]; then
  OLLAMA_BIN="$(command -v ollama || true)"
  if [[ -z "${OLLAMA_BIN}" ]]; then
    echo "[$(date -Iseconds)] FATAL: ollama not found in PATH" >&2
    echo "  Install: brew install ollama" >&2
    exit 127
  fi
  export OLLAMA_HOST="${BIND_HOST}:${NET_PORT}"
  echo "[$(date -Iseconds)] Starting Ollama"
  echo "  binary:  ${OLLAMA_BIN}"
  echo "  profile: $(readlink "${ACTIVE_CONFIG}" 2>/dev/null || echo "${ACTIVE_CONFIG}")"
  echo "  bind:    ${OLLAMA_HOST} (mode=${NET_MODE})"
  exec "${OLLAMA_BIN}" serve
else
  # existing mlx-openai-server locate + exec block — unchanged
fi
```

`OLLAMA_HOST=0.0.0.0:${NET_PORT}` is valid and intentional for LAN mode.

Update the file header comment: "Starts the backend daemon (mlx-openai-server or Ollama) based on the active profile's `backend:` key."

`tests/helpers/sysctl` — new stub:
```bash
#!/usr/bin/env bash
LOG="${SYSCTL_LOG:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/sysctl-calls}"
echo "$*" >> "${LOG}"
exit 0
```

`tests/test_backend_start.bats` — new file. The `setup()` block must:
- `load helpers/setup` (sandboxes `$HOME`, prepends `tests/helpers/` to PATH)
- Create `${HOME}/.4lm/config/profiles/`
- Write `${HOME}/.4lm/config/network.yaml` with `mode: local` and `backend_port: 8000`
- Create `${HOME}/.4lm/config/active-profile` as a symlink to a minimal profile YAML written to `$BATS_TMPDIR`
- Ensure `sysctl`, `ollama`, and `mlx-openai-server` stubs are in PATH (via `tests/helpers/`)

**Phase complete when:** With an Ollama profile active, `4lm start` launches `ollama serve` on port 8000; with an mlx profile active, behaviour is identical to today. `make check` passes.

### Test Scenarios

All cases go in `tests/test_backend_start.bats`. Uses `load helpers/setup` (no `.bash` extension).

GIVEN `active-profile` points to a profile with `backend: ollama` and the `ollama` stub is in PATH
WHEN `4lm-backend-start.sh` is executed
THEN `$BATS_TMPDIR/ollama-calls` records `serve`; `OLLAMA_HOST` is `127.0.0.1:8000`; `$BATS_TMPDIR/sysctl-calls` does not exist or is empty

GIVEN `active-profile` points to a profile with no `backend:` key and the mlx stub is in PATH
WHEN `4lm-backend-start.sh` is executed
THEN the mlx stub is invoked with `launch --config ...`; `$BATS_TMPDIR/sysctl-calls` contains at least one entry

GIVEN `active-profile` points to an ollama profile and `ollama` is absent from PATH
WHEN `4lm-backend-start.sh` is executed
THEN exit code is 127 and stderr contains "FATAL: ollama not found"

GIVEN `active-profile` points to an ollama profile and `network.yaml` sets `mode: lan`
WHEN `4lm-backend-start.sh` is executed
THEN `OLLAMA_HOST` is `0.0.0.0:8000`

---

## Phase 4 — Backend-aware model download

Make `4lm models download` and `make models` dispatch per backend. Fix `cmd_models_list()`, `run_outdated_check()`, and `cmd_doctor()`.

**Changes:**

`bin/4lm` — `cmd_models_download()`: replace the all-profiles awk pass with the loop in Data Models. The explicit-arg path (`$# > 0`) gains an early check: if any arg contains `:`, print the HF-only error and exit 1.

`bin/4lm` — `run_outdated_check()`: rewrite the models section (lines 497–523) from a single flat awk glob into a per-profile loop. See Data Models for the exact implementation. The rest of the function is unchanged.

`bin/4lm` — `cmd_models_list()`: call `profile_backend` in the per-profile display loop and append `(mlx)` or `(ollama)` to the profile name. In the inner model loop, for `ollama` backend skip `hf_is_cached` and print `~` in the cache-path column.

`bin/4lm` — `cmd_doctor()`: after the existing required-binary checks, add the Ollama check. Do not set `fail=1` — ollama is an optional binary:
```bash
if command -v ollama >/dev/null 2>&1; then
  ok "ollama: $(command -v ollama)"
else
  warn "ollama not in PATH (optional — only needed for backend: ollama profiles)"
fi
```

`Makefile`: delete the `MODELS :=` variable (line 10). Rewrite the `models` target (recipes use `bash` via the existing `SHELL := /bin/bash` setting):
```makefile
models: ## Download/update all models in config/profiles/ (backend-aware, idempotent)
	@for yaml in config/profiles/*.yaml; do \
	  backend=$$(awk '/^backend:/{print $$2}' "$$yaml"); \
	  backend=$${backend:-mlx}; \
	  while IFS= read -r model; do \
	    [ -z "$$model" ] && continue; \
	    if [ "$$backend" = "ollama" ]; then \
	      echo "→ ollama pull $$model"; ollama pull "$$model"; \
	    else \
	      echo "→ hf download $$model"; hf download "$$model"; \
	    fi; \
	  done < <(awk '/^[[:space:]]*-[[:space:]]*model_path:/{print $$NF}' "$$yaml"); \
	done
```

`tests/helpers/hf` — new stub:
```bash
#!/usr/bin/env bash
LOG="${HF_LOG:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/hf-calls}"
echo "$*" >> "${LOG}"
exit "${HF_STUB_EXIT:-0}"
```

Add model download and list tests to `tests/test_profile_state_machine.bats`.

**Phase complete when:** `4lm models download` logs `hf download` for mlx models and `ollama pull` for Ollama models; `make models` does the same; `4lm models list` shows `(ollama)` for Ollama profiles; `make check` passes.

### Test Scenarios

GIVEN profiles dir has one mlx profile (model path `org/ModelA`) and one ollama profile (model path `gemma4:27b`), with `hf` and `ollama` stubs in PATH
WHEN `4lm models download` is run (no args)
THEN `$BATS_TMPDIR/ollama-calls` records exactly one line `pull gemma4:27b`; `$BATS_TMPDIR/hf-calls` records exactly one line containing `org/ModelA`

GIVEN two ollama profiles both referencing `gemma4:27b`
WHEN `4lm models download` is run
THEN `$BATS_TMPDIR/ollama-calls` records exactly one line (deduplicated by model_path)

GIVEN the profiles dir includes one ollama profile
WHEN `4lm models list` is run
THEN output contains `(ollama)` for that profile; `$BATS_TMPDIR/hf-calls` does not contain the ollama model path

GIVEN `ollama` is not in PATH
WHEN `4lm doctor` is run
THEN output contains a warning about the missing binary; exit code is 0

GIVEN profiles dir has one mlx and one ollama profile, with stubs in PATH
WHEN `make models` is run
THEN `hf download` is invoked for the mlx model; `ollama pull` is invoked for the ollama model; make exits 0

GIVEN `4lm models download gemma4:27b` is run (arg contains `:`)
WHEN the command executes
THEN exit code is 1; output contains "explicit download is HF-only"

---

## Phase 5 — `install.sh` Ollama detection + docs

Non-functional polish. **Depends on Phase 1** (docs reference `active-profile`).

**Changes:**

`install.sh` — after the existing CLI/dependency checks, add:
```bash
if command -v ollama >/dev/null 2>&1; then
  ok "ollama: $(command -v ollama)"
else
  warn "ollama not found — needed only for profiles with backend: ollama"
  echo "    Install: brew install ollama"
fi
```

`docs/profile-schema.md` — add a "Top-level keys" subsection documenting `backend: mlx | ollama` (default `mlx`), note that mlx-specific model fields are optional/ignored for Ollama profiles, and show the minimal Ollama profile skeleton from Data Models.

**Phase complete when:** `install.sh` completes without error whether or not Ollama is installed; `make check` passes.

### Test Scenarios

GIVEN `ollama` is absent from PATH
WHEN `install.sh` is run
THEN exit code is 0; output contains `warn` and `brew install ollama`

GIVEN `ollama` is present in PATH (stub in place)
WHEN `install.sh` is run
THEN output contains `ok: ollama`; exit code is 0

---

## Decision Log

| Decision | Alternatives considered | Reason rejected |
|----------|------------------------|-----------------|
| Single backend per profile | Concurrent mlx + Ollama with a routing proxy | Proxy adds a third process and failure mode; aggregating `/v1/models` requires custom code; complexity far exceeds the benefit |
| `backend:` in profile YAML | `backend:` in `network.yaml` | network.yaml is about bind address/port; profiles already control everything about what models run |
| `OLLAMA_HOST` for port binding | New Ollama plist template | No new launchd service needed; `4lm-backend-start.sh` already owns the launch |
| Rename `mlx-active` → `active-profile` | Keep old names | Old names are backend-specific and misleading once Ollama is supported; migration is trivial |
| Ollama uses `/v1/` OpenAI-compat layer | Enable `ENABLE_OLLAMA_API` in WebUI | OpenAI-compat layer means zero client changes |
| Overload `model_path:` for Ollama pull tags | Add `ollama_model:` field | `model_path` is "path to obtain the model" in both cases; `served_model_name:` already provides the alias; `profile_model_entries()` needs no changes |
| Inline grep/awk in `4lm-backend-start.sh` | Extract shared `bin/4lm-lib.sh` | Start script is a standalone launchd entry point; cannot source `bin/4lm`; duplication is two lines and intentional |
| `command -v ollama` only (no fallback paths) | Multi-path fallback like mlx binary search | Ollama is a standard Homebrew package that installs to PATH; fallback paths are YAGNI |

## Open Decisions

None.

## Out of Scope

- Concurrent mlx + Ollama backends with request routing.
- Ollama-native API (`/api/chat`) exposure through WebUI (`ENABLE_OLLAMA_API`).
- Automatic `ollama pull` during `4lm profile set` (users must pre-pull via `4lm models download`).
- `4lm models rm` / `models-clean` for Ollama models.
- Support for any backend other than `mlx` and `ollama`.
- Windows or Linux support.
