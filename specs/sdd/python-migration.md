# SDD: Partial Bash → Python Migration

Status: Draft
Created: 2026-05-07

## Overview

`bin/4lm` is a 1671-line bash script that has hit its complexity ceiling: data-heavy commands use multi-line awk for YAML parsing, curl for HTTP, and manual `printf` for table formatting. One command (`cmd_recommend`) already embeds 100+ lines of Python as a heredoc — a sign the seam already exists. This SDD establishes a clean, incremental bash/Python split before anticipated growth (more commands, more model sources, LAN-aware health checks) makes the split harder to draw.

## Context & Constraints

- **Stack:** Bash (main CLI), Python 3.12 (runtime, already a hard dep via Brewfile `python@3.12`), bats (tests), shellcheck + shfmt (lint)
- **No venv in repo** today — Python deps (mlx-openai-server, open-webui, huggingface_hub) are installed via pipx into per-app venvs
- **Homebrew python@3.12 is PEP 668 externally-managed** — `pip install` on the system python is blocked; a dedicated venv is required
- **bats test suite stubs `python3` in PATH** (`tests/helpers/python3`) — the new Python module must use a different interpreter path to avoid stub collisions
- **install.sh copies `bin/` scripts** to `~/.4lm/bin/` — any new Python module placed in `bin/` is automatically installed
- **Conventional commits, shellcheck-clean, no Co-Authored-By Claude**

## Requirements

1. The system shall maintain a single Python helper module at `bin/4lm_helpers.py`, invoked by `bin/4lm` via a dedicated venv interpreter at `~/.4lm/venv/bin/python`.
2. The system shall create and own a venv at `~/.4lm/venv/` with `rich` installed; `install.sh` shall create it and `uninstall.sh` shall remove it.
3. The system shall not alter the external CLI interface of any migrated command — arguments, output format, and exit codes remain identical.
4. The system shall keep process-orchestration logic (start/stop/restart/expose/profile-set/health) in bash and migrate data-heavy logic (recommend/models-list/diag/outdated-query) to Python.
5. The system shall cover all Python commands with pytest tests in `tests/python/`; existing bats tests shall continue to pass unchanged.
6. The `make check` target shall include a `py_compile` syntax check for `4lm_helpers.py`; the `make test` target shall run pytest after bats.
7. The Python module shall accept a subcommand as its first positional argument and dispatch to the corresponding function.
8. The `outdated` command's query phase shall support a `--porcelain` flag that prints machine-readable JSON so bash can parse and act on the results without re-running the check.

## Architecture

### Interpreter path

```
~/.4lm/venv/bin/python   ← owned by 4lm, not subject to PEP 668 or bats python3 stub
```

Bash references it as:
```bash
readonly HELPERS_PYTHON="${LLM_HOME}/venv/bin/python"
readonly HELPERS_PY="${LLM_HOME}/bin/4lm_helpers.py"
```

### Module dispatch

```
bin/4lm_helpers.py
  └── main() → argparse dispatcher
        ├── recommend   <rec_file> <lm_file> <active_paths> <limit>
        ├── models-list <profiles_dir> <hf_cache_dir>
        ├── diag        <log_file> <backend_port>
        └── outdated    [--porcelain] <repo_dir>
```

Each subcommand is a standalone function; `rich.Console` handles all output.

### Bash/Python boundary

| Stays in bash | Migrates to Python |
|---|---|
| `start` / `stop` / `restart` / `expose` | `recommend` (heredoc → module) |
| `profile set` (symlink swap + poll loop) | `models list` |
| `service_start` / `service_stop` / launchctl | `diag` |
| `health` (9 lines, trivial) | `outdated` (query phase) |
| `install.sh` / `uninstall.sh` | `upgrade` (deferred) |

### Testing split

- **bats** — orchestration (start/stop/profile/expose): unchanged
- **pytest** — Python commands: `tests/python/test_recommend.py`, `tests/python/test_models_list.py`, `tests/python/test_diag.py`, `tests/python/test_outdated.py`

## File & Module Structure

| Path | Change | Description |
|---|---|---|
| `bin/4lm_helpers.py` | **Create** | Python CLI dispatcher with all migrated command logic |
| `bin/4lm` | **Modify** | Replace heredoc in `cmd_recommend`; reduce `cmd_models_list`, `cmd_diag`, `cmd_outdated` to delegation calls |
| `install.sh` | **Modify** | Add venv creation block + `rich` install after existing pipx block |
| `uninstall.sh` | **Modify** | Add `rm -rf "${LLM_HOME}/venv"` |
| `Makefile` | **Modify** | Extend `syntax` target (py_compile); extend `test` target (pytest) |
| `tests/python/__init__.py` | **Create** | Empty, marks pytest package |
| `tests/python/test_smoke.py` | **Create** | Import + version smoke test |
| `tests/python/test_recommend.py` | **Create** | Unit tests for normalize(), scoring, table rendering |
| `tests/python/test_models_list.py` | **Create** | Unit tests for YAML parsing, dedup, cache detection |
| `tests/python/test_diag.py` | **Create** | Unit tests for log parsing, in-flight request counting |
| `tests/python/test_outdated.py` | **Create** | Unit tests for version comparison, porcelain output |

## Implementation Phases

## Phase 1 — Foundation

Establish the venv, install `rich`, wire `4lm_helpers.py` skeleton into the build and install chain. No behavior change to any `4lm` command.

**Changes:**
- `install.sh`: after existing pipx block, create venv and install rich:
  ```bash
  python3 -m venv "${LLM_HOME}/venv"
  "${LLM_HOME}/venv/bin/pip" install --quiet rich
  cp "${REPO_DIR}/bin/4lm_helpers.py" "${LLM_HOME}/bin/4lm_helpers.py"
  ```
- `uninstall.sh`: add `rm -rf "${LLM_HOME}/venv"` before directory removal
- `bin/4lm_helpers.py`: skeleton with `argparse`, a `version` subcommand, and `HELPERS_PYTHON` / `HELPERS_PY` constants stubbed out
- `bin/4lm`: add `HELPERS_PYTHON` and `HELPERS_PY` constants near top (not yet used by any command)
- `Makefile`: `syntax` target gains `python3 -m py_compile bin/4lm_helpers.py`; `test` target gains `${HELPERS_PYTHON} -m pytest tests/python/ -q 2>/dev/null || true` (graceful skip until pytest is installed)
- `tests/python/__init__.py` + `tests/python/test_smoke.py`: import module, assert version string

**Phase complete when:** `make check` passes; `./install.sh` creates `~/.4lm/venv/`; `~/.4lm/venv/bin/python bin/4lm_helpers.py version` prints a version string.

### Test Scenarios

GIVEN a fresh install  
WHEN `install.sh` runs  
THEN `~/.4lm/venv/bin/python` exists and `import rich` succeeds within it

GIVEN the repo  
WHEN `make check` runs  
THEN py_compile reports no syntax errors and bats tests all pass

---

## Phase 2 — Extract `cmd_recommend` Heredoc

Mechanical extraction of the existing 100-line Python heredoc from `cmd_recommend` into `4lm_helpers.py recommend`. Zero behavior change.

**Changes:**
- `bin/4lm_helpers.py`: add `recommend(args)` function containing the exact heredoc logic, ported line-for-line, then refactored to use `rich.Table` for table output
- `bin/4lm` `cmd_recommend()`: replace the `python3 - <<'PYEOF' ... PYEOF` block with:
  ```bash
  "${HELPERS_PYTHON}" "${HELPERS_PY}" recommend \
    "${rec_tmpfile}" "${lm_tmpfile}" "${active_paths}" "${limit}"
  ```
- `tests/python/test_recommend.py`: unit tests for `normalize()`, `community_str()`, active-profile marker logic, display-limit cap; use fixture JSON files in `tests/python/fixtures/`

**Phase complete when:** `make check` passes; `4lm recommend` output is visually identical to pre-migration output; pytest covers normalize() edge cases and active-profile marking.

### Test Scenarios

GIVEN a fixture `rec.json` with 10 models and `lm.json` with community benchmarks  
WHEN `recommend` is called with limit=5  
THEN exactly 5 rows are printed plus any active-profile extras

GIVEN a model name `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`  
WHEN `normalize()` is called  
THEN it returns `qwen2.5-coder-32b`

GIVEN an active profile containing a model ranked #8  
WHEN `recommend` is called with limit=5  
THEN the top-5 rows appear first and the active model appears in an "active profile" section below

---

## Phase 3 — Migrate `cmd_models_list`

Replace `cmd_models_list` (70 lines, awk YAML parsing + printf tables) with a Python subcommand.

**Changes:**
- `bin/4lm_helpers.py`: add `models_list(args)` — parse profile YAMLs with `PyYAML` (add to venv install in install.sh: `pip install --quiet rich pyyaml`), deduplicate entries, check HF/Ollama cache status, emit `rich.Table`
- `bin/4lm` `cmd_models_list()`: reduce to argument wrangling + `"${HELPERS_PYTHON}" "${HELPERS_PY}" models-list "${PROFILES_DIR}" "${HF_HOME:-${HOME}/.cache/huggingface}"`
- `tests/python/test_models_list.py`: fixture profile YAMLs, assert dedup, assert cache status column values

**Phase complete when:** `make check` passes; `4lm models list` output matches pre-migration output; pytest covers dedup and missing-cache cases.

### Test Scenarios

GIVEN two profiles both referencing the same model path  
WHEN `models-list` runs  
THEN the model appears exactly once in the output

GIVEN a model path present in the HF cache  
WHEN `models-list` runs  
THEN its Cached column shows a checkmark

---

## Phase 4 — Migrate `cmd_diag`

Replace `cmd_diag` (106 lines, multi-line awk log parsing + orphan detection) with a Python subcommand.

**Changes:**
- `bin/4lm_helpers.py`: add `diag(args)` — parse backend log with `re`, track in-flight requests (admission/completion events), detect orphan workers, emit `rich.Panel` sections
- `bin/4lm` `cmd_diag()`: reduce to `"${HELPERS_PYTHON}" "${HELPERS_PY}" diag "${LOG_DIR}/backend.log" "$(net_backend_port)"`
- `tests/python/test_diag.py`: fixture log snippets, assert in-flight count, assert orphan detection

**Phase complete when:** `make check` passes; `4lm diag` output matches pre-migration output.

### Test Scenarios

GIVEN a log with 3 admission events and 2 completion events  
WHEN `diag` runs  
THEN in-flight count = 1

GIVEN a log with a worker process that has no corresponding admission event  
WHEN `diag` runs  
THEN that worker is flagged as orphan

---

## Phase 5 — Migrate `outdated` Query Phase

Extract the query logic from `run_outdated_check` into a Python subcommand. Leave `cmd_upgrade`'s action logic in bash for now.

**Changes:**
- `bin/4lm_helpers.py`: add `outdated(args)` — check PyPI versions, brew outdated, HF SHA comparison; support `--porcelain` flag to emit JSON (`{"python": [...], "brew": [...], "models": [...]}`)
- `bin/4lm` `cmd_outdated()`: call Python, render output; `cmd_upgrade()`: call Python with `--porcelain`, parse JSON into local arrays, then proceed with existing upgrade action logic
- `tests/python/test_outdated.py`: mock HTTP responses, assert version comparison, assert porcelain JSON schema

**Phase complete when:** `make check` passes; `4lm outdated` and `4lm upgrade` produce identical behavior.

### Test Scenarios

GIVEN a requirements.txt with `mlx-openai-server==1.8.0` and PyPI latest is `1.8.1`  
WHEN `outdated --porcelain` runs  
THEN JSON output contains `{"python": [{"pkg": "mlx-openai-server", "installed": "1.8.0", "latest": "1.8.1"}]}`

GIVEN all packages are up to date  
WHEN `outdated` runs  
THEN exit code is 0 and no update arrows are printed

## Decision Log

| Decision | Alternatives Considered | Reason Rejected |
|---|---|---|
| Dedicated venv at `~/.4lm/venv/` | System python3 (Homebrew) | PEP 668 blocks pip install; bats `python3` stub would intercept calls |
| Dedicated venv at `~/.4lm/venv/` | pipx inject into existing app venv | Fragile coupling to mlx-openai-server venv lifecycle |
| Dedicated venv at `~/.4lm/venv/` | `pyproject.toml` + `pipx install -e .` | Installed scripts land in `~/.local/bin/`, not `~/.4lm/bin/`; adds packaging overhead |
| Bash stays as entry point / dispatcher | Full Python CLI (Click/Typer) with bash shim | Flag-day rewrite; bats tests would need full replacement; launchctl orchestration is genuinely simpler in bash |
| Single `bin/4lm_helpers.py` file | Package under `lib/4lm/` | Overkill for current scale; single file is simpler to copy in install.sh |
| `cmd_upgrade` action logic deferred to Phase 5+ | Migrate upgrade fully in Phase 5 | Upgrade shares mutable bash arrays with outdated check; porcelain bridge pattern must be proven first |
| `rich` as the only Python dep added now | `tabulate`, `click`, `typer` | `rich` covers tables, panels, colors, and progress in one dep; others would need to be combined |

## Open Decisions

1. **PyYAML vs ruamel.yaml for profile parsing** — PyYAML is simpler (one dep, stdlib-like API); ruamel.yaml preserves comments and round-trips cleanly. Impact: if profiles ever need to be written back by Python code, ruamel is necessary; for read-only parsing PyYAML suffices.

## Out of Scope

- Rewriting `install.sh` or `uninstall.sh` in Python
- Migrating `start`, `stop`, `restart`, `expose`, `health`, `profile set` — these are process-orchestration commands where bash is idiomatic
- Migrating `cmd_upgrade`'s action phase (brew upgrade, pipx reinstall, hf download) — deferred past Phase 5
- Introducing a `pyproject.toml` or making `4lm_helpers.py` installable as a package
- Adding type annotations or mypy to the Python module (can be added later)
- Replacing bats tests with pytest for bash-orchestration coverage
