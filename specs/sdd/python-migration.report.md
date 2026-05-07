# SDD Implementation Report: python-migration

**Date**: 2026-05-07
**Phases run**: 1, 2, 3, 4, 5
**Overall status**: all-shipped

| Phase | Title | Status | Commit |
|-------|-------|--------|--------|
| 1 | Foundation: venv, skeleton, build wiring | shipped | 69b9bb8 |
| 2 | Extract cmd_recommend heredoc | shipped | b0a5c34 |
| 3 | Migrate cmd_models_list | shipped | 792abf3 |
| 4 | Migrate cmd_diag | shipped | 290e4c4 |
| 5 | Migrate outdated query phase | shipped | 27df933 |

---

## Phase 1: Foundation

**Status**: shipped  
**Commit**: 69b9bb8

### What shipped
- `bin/4lm_helpers.py` — argparse dispatcher with `hello` smoke-test subcommand
- `requirements-helpers.txt` — floor+ceiling pins: `rich>=13.9,<14`, `pyyaml>=6.0,<7`, `pytest>=9.0,<10`
- `install.sh` — venv creation block using `${PIPX_PYTHON}` (avoids PEP 668); copies `4lm_helpers.py` to `~/.4lm/bin/`
- `uninstall.sh` — removes `~/.4lm/venv`
- `Makefile` — `syntax` target includes `py_compile`; `test` target runs pytest via `$(HELPERS_PYTHON)` with graceful skip
- `bin/4lm` — `HELPERS_PYTHON`, `HELPERS_PY` constants; `require_helpers_python()` guard
- `tests/python/conftest.py` — `helpers` session fixture importing module directly
- `tests/helpers/python3` and `tests/helpers/python3.12` stubs — extended to create minimal venv structure for bats tests

### Key decisions
- Used `LLM_HELPERS_PYTHON` env var (not `4LM_HELPERS_PYTHON` — bash vars can't start with digits)
- Used `${PIPX_PYTHON}` for venv creation so bats test stubs intercept correctly
- Bats tests with skip guards: `[[ -x "${LLM_HELPERS_PYTHON:-}" ]] || skip "venv not installed"`
- `tests/helpers/setup.bash` captures `_REAL_4LM_VENV` before HOME sandbox override

---

## Phase 2: Extract cmd_recommend heredoc

**Status**: shipped  
**Commit**: b0a5c34

### What shipped
- `bin/4lm_helpers.py` — `normalize()`, `_build_lm_index()`, `_community_str()`, `cmd_recommend()` with `rich.Table`
- `bin/4lm` — `cmd_recommend()` reduced to 3-line Python call; 117-line heredoc removed
- `tests/python/fixtures/rec.json`, `lm.json` — test fixtures
- `tests/python/test_recommend.py` — 7 unit tests

### Key decisions
- `normalize()` at module level (not nested) so tests can call it directly
- `active_paths` passed as comma-separated string from bash (no shell array serialization)

---

## Phase 3: Migrate cmd_models_list

**Status**: shipped  
**Commit**: 792abf3

### What shipped
- `bin/4lm_helpers.py` — `_hf_is_cached()`, `cmd_models_list()` with PyYAML + `rich.Table`
- `bin/4lm` — `cmd_models_list()` reduced to 3-line Python call; 70 lines removed
- `tests/python/fixtures/profile_a.yaml`, `profile_b.yaml` — yaml profile fixtures
- `tests/python/test_models_list.py` — 6 unit tests

### Key decisions
- Non-mlx backends annotated in Profiles column: `"profile (mlx_lm)"` to preserve bats assertion compat (`*(mlx_lm)*`)
- `_hf_is_cached()` replicates the bash `hf_is_cached()` two-condition check (refs/main + blobs ≥ 1 GiB)

---

## Phase 4: Migrate cmd_diag

**Status**: shipped  
**Commit**: 290e4c4

### What shipped
- `bin/4lm_helpers.py` — `cmd_diag()` with urllib HTTP probe + `re`-based log analysis
- `bin/4lm` — `cmd_diag()` reduced to 3-line Python call; 90 lines removed
- `tests/python/fixtures/backend.log` — static fixture (worker pid only, no admits → orphan test)
- `tests/python/test_diag.py` — 7 integration tests including ephemeral HTTP server

### Key decisions
- Orphan detection: `orphaned = worker_pids if (worker_pids and not all_admit_uids) else set()`
- `test_inflight_one_remaining` generates log content dynamically (relative timestamps) so it doesn't become stale
- HTTP probe test uses `http.server.HTTPServer` on an ephemeral port to avoid flakiness

---

## Phase 5: Migrate outdated query phase

**Status**: shipped  
**Commit**: 27df933

### What shipped
- `bin/4lm_helpers.py` — `_parse_req_file()`, `cmd_outdated()` with PyPI urllib + brew subprocess
- `bin/4lm` — `cmd_outdated()` calls Python helper for Python+Brew; HF models check stays in bash via `run_outdated_check "models"`
- `Brewfile` — added `jq` (for future porcelain consumers in bash upgrade flow)
- `tests/python/test_outdated.py` — 10 tests covering parse, porcelain, human mode, error paths

### Key decisions
- `_parse_req_file()` handles `==X.Y.Z` and `>=X.Y,<Z` formats; unknown formats skipped silently
- `--porcelain` flag outputs `{"python": [...], "helpers": [...], "brew": [...]}` JSON
- `cmd_upgrade()` in bash unchanged — still uses `run_outdated_check` directly (upgrade migration deferred)
- Fixed pre-existing `test_recommend_five_rows_in_top` row-detection heuristic (title "4lm Recommendations" starts with digit '4')

---

## Manual Test Plan

1. **Install the venv**
   ```
   make install
   ```
   Expected: `ok  venv created at ~/.4lm/venv`, `ok  helpers deps installed from requirements-helpers.txt`

2. **Smoke-test the helper**
   ```
   4lm_helpers hello
   ```
   Expected: `hello from 4lm_helpers`

3. **Model recommendations**
   ```
   4lm recommend
   ```
   Expected: rich table showing top models with Score, Mem, tps*, Community columns; `*` markers for active profile models

4. **Models list**
   ```
   4lm models list
   ```
   Expected: rich table with Model, Backend, Profiles, Cached columns; non-mlx profiles show `(mlx_lm)` / `(ollama)` annotation

5. **Diagnostics** (backend running)
   ```
   4lm diag
   ```
   Expected: `Backend` section shows OK with latency; `In-flight inference` section; `Backend worker processes` section

6. **Diagnostics** (backend stopped)
   ```
   4lm diag
   ```
   Expected: `Backend` section shows `unreachable`

7. **Outdated check** (all current)
   ```
   4lm outdated
   ```
   Expected: tables for Python and Homebrew sections; `Everything up to date.` summary

8. **Outdated check** (porcelain)
   ```
   ~/.4lm/venv/bin/python ~/.4lm/bin/4lm_helpers.py outdated --porcelain .
   ```
   Expected: JSON `{"python": [...], "helpers": [...], "brew": [...]}`

9. **Full check suite**
   ```
   make check
   ```
   Expected: 52 bats tests pass, 30 pytest tests pass

---

## Deferred Items

- `cmd_upgrade()` bash integration with porcelain JSON: currently `run_outdated_check` (bash) still drives upgrade. Migration path: call `cmd_outdated --porcelain` and parse with `jq` to populate `OUTDATED_PY`/`OUTDATED_BREW` arrays, keep HF in bash.
- `run_outdated_check` Python channel is duplicated with the Python `cmd_outdated`. Clean up once `cmd_upgrade` is migrated.
