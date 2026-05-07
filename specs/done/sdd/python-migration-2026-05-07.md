# SDD: Partial Bash → Python Migration

Status: Ready for Implementation
Original: specs/sdd/python-migration.md
Refined: 2026-05-07

## Overview

`bin/4lm` is a 1671-line bash script that has hit its complexity ceiling: data-heavy commands use multi-line awk for YAML parsing, curl for HTTP, and manual `printf` for table formatting. One command (`cmd_recommend`) already embeds 100+ lines of Python as a heredoc — a sign the seam already exists. This SDD establishes a clean, incremental bash/Python split by extracting four data-heavy commands (`recommend`, `models-list`, `diag`, `outdated`) into `bin/4lm_helpers.py`, a single Python module invoked via a dedicated venv.

## Context & Constraints

- **Stack:** Bash (main CLI), Python 3.12 (runtime, already a hard dep via Brewfile `python@3.12`), bats (tests), shellcheck + shfmt (lint). Python 3.13 cannot be used: `mlx-openai-server` declares `python_requires=">=3.11,<3.13"`.
- **No venv in repo today** — Python deps (mlx-openai-server, open-webui, huggingface_hub) are installed via pipx into per-app venvs. `requirements.txt` tracks these pipx-managed app deps only. Venv deps (`rich`, `pyyaml`, `pytest`) live in `requirements-helpers.txt` and must not be added to `requirements.txt`.
- **Homebrew python@3.12 is PEP 668 externally-managed** — `pip install` on the system python is blocked; a dedicated venv is required.
- **bats test suite stubs `python3` in PATH** (`tests/helpers/python3`) — the new Python module must use a different interpreter path (`~/.4lm/venv/bin/python`) to avoid stub collisions.
- **install.sh copies `bin/` scripts** to `~/.4lm/bin/` via an explicit loop (`for script in 4lm 4lm-backend-start.sh 4lm-webui-start.sh`). `4lm_helpers.py` is not automatically included; Phase 1 explicitly extends this loop.
- **Conventional commits, shellcheck-clean, no Co-Authored-By Claude**

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

`active_paths` is a comma-separated string of active profile model paths (e.g. `"mlx-community/Foo,mlx-community/Bar"`). An empty string means no active profile. Each subcommand is a standalone function; `rich.Console` handles all output except `--porcelain` JSON, which is written to stdout via `print()`.

### Bash/Python boundary

| Stays in bash | Migrates to Python |
|---|---|
| `start` / `stop` / `restart` / `expose` | `recommend` (heredoc → module) |
| `profile set` (symlink swap + poll loop) | `models-list` |
| `service_start` / `service_stop` / launchctl | `diag` (log analysis portion) |
| `health` (9 lines, trivial) | `outdated` (query phase) |
| `cmd_diag` live client probe (`print_clients`), pgrep/ps | |
| `install.sh` / `uninstall.sh` | |
| `cmd_upgrade` action phase (brew, pipx, hf) | |

### Testing split

- **bats** — orchestration (start/stop/profile/expose): unchanged. New bats tests for migrated commands that exercise the happy path must set `4LM_HELPERS_PYTHON` to the venv python path. Bash wrappers honour this env var override for test isolation (see `tests/helpers/setup.bash`).
- **pytest** — Python commands: `tests/python/test_recommend.py`, `tests/python/test_models_list.py`, `tests/python/test_diag.py`, `tests/python/test_outdated.py`

## Requirements

1. The system shall maintain a single Python helper module at `bin/4lm_helpers.py`, invoked by `bin/4lm` via the venv interpreter at `~/.4lm/venv/bin/python`.
2. The system shall create and own a venv at `~/.4lm/venv/`; `install.sh` shall create it via `pip install -r requirements-helpers.txt` and `uninstall.sh` shall remove it. `requirements-helpers.txt` is the single source of truth for venv dep versions — both `install.sh` and `4lm outdated` read from it.
3. The system shall not alter the external CLI interface of any migrated command — arguments and exit codes remain identical. Rich ANSI styling is acceptable in interactive (TTY) output; piped/non-TTY output must be byte-compatible with the pre-migration output.
4. The system shall keep process-orchestration logic (start/stop/restart/expose/profile-set/health) in bash and migrate data-heavy logic (recommend/models-list/diag log analysis/outdated query phase) to Python.
5. The system shall cover all Python commands with pytest tests in `tests/python/`; existing bats tests shall continue to pass unchanged.
6. The `make check` target shall include a `py_compile` syntax check for `4lm_helpers.py` using the system `python3` (syntax only — no imports). The `make test` target shall run pytest via `${HELPERS_PYTHON}` after bats, skipping with a notice (not `|| true`) when `${HELPERS_PYTHON}` does not exist.
7. The Python module shall accept a subcommand as its first positional argument and dispatch to the corresponding function via `argparse`.
8. The `outdated` command's query phase shall support a `--porcelain` flag that prints machine-readable JSON so bash in `cmd_upgrade` can parse results without re-running the check. `--porcelain` is a subcommand-level flag added via `parser_outdated.add_argument('--porcelain', action='store_true')` in the `outdated` subparser.
9. When `~/.4lm/venv/bin/python` does not exist, `bin/4lm` shall print `FATAL: venv missing — run ./install.sh` to stderr and exit 1 before any dispatch call that uses `HELPERS_PYTHON`.
10. When `${HELPERS_PYTHON} ${HELPERS_PY} <cmd>` exits non-zero, `bin/4lm` shall propagate the exit code unmodified (consistent with `set -euo pipefail`).
11. Bash wrappers for migrated commands shall honour a `4LM_HELPERS_PYTHON` environment variable override for the interpreter path, falling back to `HELPERS_PYTHON`. This allows bats tests to substitute a controlled interpreter without modifying the installed venv.

## File & Module Structure

| Path | Change | Description |
|---|---|---|
| `bin/4lm_helpers.py` | **Create** | Python CLI dispatcher with all migrated command logic |
| `bin/4lm` | **Modify** | Add `HELPERS_PYTHON`/`HELPERS_PY` constants and `require_helpers_python`; replace heredoc in `cmd_recommend`; reduce `cmd_models_list`, `cmd_diag`, `cmd_outdated` to delegation calls; honour `4LM_HELPERS_PYTHON` override |
| `requirements-helpers.txt` | **Create** | Venv dep list with floor+ceiling pins; read by both `install.sh` and `4lm outdated` |
| `install.sh` | **Modify** | Extend script copy loop to include `4lm_helpers.py`; add venv creation + `pip install -r requirements-helpers.txt` after existing pipx block |
| `uninstall.sh` | **Modify** | Add `rm -rf "${LLM_HOME}/venv"` before directory removal |
| `Makefile` | **Modify** | Add `HELPERS_PYTHON` variable; extend `syntax` target with `py_compile` line; extend `test` target with conditional pytest |
| `tests/python/__init__.py` | **Create** | Empty, marks pytest package |
| `tests/python/conftest.py` | **Create** | Session-scoped fixture that loads `bin/4lm_helpers.py` via `importlib.util.spec_from_file_location` and exposes the module as `helpers`; shared by all pytest files |
| `tests/python/test_smoke.py` | **Create** | Import module via conftest fixture; assert `--help` invocation exits 0 |
| `tests/python/test_recommend.py` | **Create** | Unit tests for `normalize()`, scoring, table rendering, active-profile marking |
| `tests/python/test_models_list.py` | **Create** | Unit tests for YAML parsing, dedup, cache detection |
| `tests/python/test_diag.py` | **Create** | Unit tests for log parsing, in-flight request counting, orphan detection |
| `tests/python/test_outdated.py` | **Create** | Unit tests for version comparison, porcelain output, network-error handling |
| `tests/python/fixtures/rec.json` | **Create** | 10-model ranked recommendation fixture |
| `tests/python/fixtures/lm.json` | **Create** | Community benchmark fixture matching rec.json model names |
| `tests/python/fixtures/backend.log` | **Create** | Log fixture with 3 admission events, 2 completion events, and one orphan worker PID |
| `tests/python/fixtures/profile_a.yaml` | **Create** | Profile YAML listing two models (one shared with profile_b) |
| `tests/python/fixtures/profile_b.yaml` | **Create** | Profile YAML listing one model shared with profile_a |
| `tests/helpers/setup.bash` | **Modify** | Add `export 4LM_HELPERS_PYTHON="${LLM_HOME}/venv/bin/python"` so bats tests that invoke migrated commands use the real venv; document the override convention |

## Data Models

### `recommend` subcommand

```python
# CLI: recommend <rec_file> <lm_file> <active_paths> <limit>
# rec_file: path to JSON file — {"models": [{"name": str, "score": float, ...}], ...}
# lm_file: path to JSON file — {"benchmarks": [{"model": {"hfId": str}, "tokSOut": float,
#           "hardware": {"chipVariant": str, ...}}, ...]}
# active_paths: comma-separated str of active model paths, or "" if none
#   (source: awk '/^[[:space:]]*-[[:space:]]*model_path:/{printf "%s,", $NF}' in bin/4lm)
# limit: int — max rows to display; active-profile models shown below if outside top-N

def normalize(name: str) -> str:
    """Strip org prefix, then iteratively strip known suffixes (case-insensitive).
    Suffixes stripped (in any order, repeat until stable):
      '-instruct', '-it', '-mlx', '-4bit', '-8bit', '-q4', '-q8',
      '-fp8', '-bf16', '-gguf', '-mxfp4', '-nvfp4', '-awq', '-gptq'
    Example: 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit' → 'qwen2.5-coder-32b'
    Example: 'mlx-community/Llama-3.1-8B-Instruct-8bit' → 'llama-3.1-8b'
    This is a semantic-equivalent rewrite of the normalize() function in the
    existing heredoc (bin/4lm lines 1494–1507); the heredoc is the behavioral
    reference, not source text to copy verbatim."""
```

Exit codes: 0 on success; 1 if `rec_file` or `lm_file` is missing or unreadable.

### `models-list` subcommand

```python
# CLI: models-list <profiles_dir> <hf_cache_dir>
# profiles_dir: path to directory containing *.yaml profile files
# hf_cache_dir: path to HF cache root (default: ~/.cache/huggingface)
#
# Output columns: Model, Backend, Profiles, Cached
# Cached column values: '✓' if cached, '—' if not cached
#
# Cache detection (mirrors hf_is_cached() in bin/4lm lines 132–142):
#   cache_dir = <hf_cache_dir>/hub/models--<org>--<name>/
#   Condition 1: <cache_dir>/refs/main exists (refs/main alone is insufficient —
#                partial downloads leave it behind with only metadata files)
#   Condition 2: <cache_dir>/blobs/ directory total size ≥ 1 GB (1073741824 bytes)
#   Both conditions must be true for Cached = '✓'
#
# Dedup: each model path appears exactly once even if listed in multiple profiles.
#
# Unreferenced section: after the profile-referenced table, query:
#   - `hf cache list --format agent` (if hf is on PATH) for HF models not in any profile
#   - `ollama list` (if ollama is on PATH) for ollama models not in any profile
#   Display these as additional rows with dim styling, Profiles column = "(unreferenced)"
#   This mirrors cmd_models_list bash behavior at bin/4lm lines 1187–1208.
```

### `diag` subcommand

```python
# CLI: diag <log_file> <backend_port>
# log_file: path to backend.log (may not exist → exit 0 with "no log data" notice)
# backend_port: int (passed as str, converted in function)
#
# HTTP probe: GET http://127.0.0.1:<backend_port>/v1/models
#   timeout: 3 seconds (urllib.request.urlopen timeout)
#   on success: record response_time_ms and len(data["data"]) as model_count
#   on urllib.error.URLError / OSError: mark backend as unreachable with reason
#   output label: "Backend"
#   success line: "http://127.0.0.1:<port>/v1/models — OK (<ms>ms, <n> models loaded)"
#   failure line: "http://127.0.0.1:<port>/v1/models — unreachable: <reason>"
#
# Log line patterns (mlx-openai-server format):
#   admission:  lines matching r'BatchScheduler admitted uid=(\w+)'  → uid
#   completion: lines matching r'BatchScheduler.*uid=(\w+).*finished' → uid
#   worker:     lines matching r'worker pid=(\d+)'                   → pid
#
# Sections emitted (exact labels, in this order):
#   "Backend"
#   "In-flight inference (admitted, not yet finished, last 10 min)"
#   "Backend worker processes"
#   "Orphaned workers"   — only if orphans detected
#
# in_flight = uids admitted (last 10 min) with no matching finished line
# orphan = worker pid present in log with zero admission events ever for that pid
#         (orphan is defined per-pid across the full log, not per time window)
# If log file is absent or has zero bytes: print "No log data found at <path>", exit 0.
#
# Output: rich.Console.print with the section labels above (not rich.Panel).
# Tests use Console(file=io.StringIO(), highlight=False) to suppress ANSI in assertions.
```

### `outdated` subcommand

```python
# CLI: outdated [--porcelain] <repo_dir>
# repo_dir: path to repo root; requirements.txt is at <repo_dir>/requirements.txt
#
# Installed version: extracted from the pinned version in each requirements file.
#   Supported pin formats: '==X.Y.Z', '>=X.Y,<Z' (uses lower bound as installed).
#   Non-parseable lines are skipped with a warning to stderr.
#   Extras are stripped before PyPI lookup: 'huggingface_hub[cli]' → 'huggingface_hub'
#
# Checks:
#   python: each package in <repo_dir>/requirements.txt compared against PyPI JSON API
#           Source label: "pipx" — upgraded via 'pipx upgrade <pkg>'
#   helpers: each package in <repo_dir>/requirements-helpers.txt compared against PyPI
#           Source label: "venv" — upgraded by editing requirements-helpers.txt and
#           re-running install.sh
#   Both files use the same PyPI check logic: GET https://pypi.org/pypi/<pkg>/json
#   brew:   `brew outdated --json` (one bulk call) parsed for formulae matching
#           lines extracted from <repo_dir>/Brewfile via regex ^brew "([^"]+)"
#           (cask and tap lines excluded).
#           NOTE: this switches from per-formula verbose calls to --json bulk.
#           Human output changes: up-to-date formulae no longer print a '✓' row;
#           only outdated formulae appear in human output. Accepted behavior delta.
#   models: not included (HF SHA comparison deferred out of scope)
#
# Porcelain JSON schema (stdout, exit 0):
# {
#   "python":  [{"pkg": str, "installed": str, "latest": str, "source": "pipx"}],
#   "helpers": [{"pkg": str, "installed": str, "latest": str, "source": "venv"}],
#   "brew":    [{"formula": str, "installed": str, "latest": str}]
# }
# Only outdated packages are included in the arrays (empty arrays = all current).
#
# Human output: two rich.Tables — "Python (pipx)" and "Helpers (venv)" — then brew.
# Each table has columns: Package, Installed, Latest.
# Network error (PyPI): print to stderr, exit 1.
# brew failure: print to stderr, exit 1.
```

## Configuration

No new configuration keys. The venv path is derived from `LLM_HOME` (already set in `bin/4lm`):

```bash
readonly HELPERS_PYTHON="${4LM_HELPERS_PYTHON:-${LLM_HOME}/venv/bin/python}"
readonly HELPERS_PY="${LLM_HOME}/bin/4lm_helpers.py"
```

The `4LM_HELPERS_PYTHON` env var override allows bats tests to substitute a controlled interpreter.

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| Venv missing | `HELPERS_PYTHON` path does not exist at dispatch time | `bin/4lm` prints to stderr, exits 1 | `FATAL: venv missing — run ./install.sh` |
| Python subcommand exits non-zero | `${HELPERS_PYTHON} ${HELPERS_PY} <cmd>` returns non-zero | `set -euo pipefail` propagates exit code unmodified | Python module's own stderr output (rich or plain) |
| `diag` log absent or empty | `<log_file>` does not exist or has zero bytes | exits 0, prints notice | `No log data found at <path>` |
| `diag` backend unreachable | `GET /v1/models` raises `urllib.error.URLError` or times out after 3s | exits 0, prints failure line in Backend section | `http://127.0.0.1:<port>/v1/models — unreachable: <reason>` |
| `models-list` empty profiles dir | No `*.yaml` files in `<profiles_dir>` | exits 0, prints empty table with headers | Column headers `Model`, `Backend`, `Profiles`, `Cached` with zero rows |
| `models-list` invalid YAML | A `*.yaml` file fails `yaml.safe_load` | exits non-zero, message to stderr | `error: failed to parse <filename>: <reason>` |
| `outdated` PyPI network error | HTTP request raises `urllib.error.URLError` | exits 1, message to stderr | `error: could not reach PyPI: <reason>` |
| `outdated` `brew outdated` failure | `brew` not in PATH or exits non-zero | exits 1, message to stderr | `error: brew outdated failed: <reason>` |
| `recommend` missing input file | `rec_file` or `lm_file` path does not exist | exits 1, message to stderr | `error: file not found: <path>` |

## Implementation Phases

## Phase 1 — Foundation

Establish the venv, install `rich`, `pyyaml`, and `pytest`, wire `4lm_helpers.py` skeleton into the build and install chain. No behavior change to any `4lm` command.

**Changes:**

- `install.sh`: extend the script copy loop to include `4lm_helpers.py`:
  ```bash
  for script in 4lm 4lm-backend-start.sh 4lm-webui-start.sh 4lm_helpers.py; do
    cp "${SOURCE_DIR}/bin/${script}" "${LLM_HOME}/bin/${script}"
    chmod 755 "${LLM_HOME}/bin/${script}"
  done
  ```
  After the existing pipx block, create the venv and install from the requirements file:
  ```bash
  python3 -m venv "${LLM_HOME}/venv"
  "${LLM_HOME}/venv/bin/pip" install --quiet -r "${REPO_DIR}/requirements-helpers.txt"
  ```

- `uninstall.sh`: add `rm -rf "${LLM_HOME}/venv"` before directory removal.

- `bin/4lm_helpers.py`: skeleton with `argparse` dispatcher that exits 0 on `--help` and exits 2 (argparse default) on unknown subcommand. No subcommands yet. The module shall be importable with no side effects.

- `bin/4lm`: add near top (not yet used by any command):
  ```bash
  readonly HELPERS_PYTHON="${4LM_HELPERS_PYTHON:-${LLM_HOME}/venv/bin/python}"
  readonly HELPERS_PY="${LLM_HOME}/bin/4lm_helpers.py"
  ```
  Add venv guard function:
  ```bash
  require_helpers_python() {
    if [[ ! -x "${HELPERS_PYTHON}" ]]; then
      echo "FATAL: venv missing — run ./install.sh" >&2
      exit 1
    fi
  }
  ```

- `Makefile`:
  - Add near top alongside `SCRIPTS`:
    ```makefile
    HELPERS_PYTHON := $(HOME)/.4lm/venv/bin/python
    ```
  - `syntax` target: append a new command line after the existing bash loop:
    ```makefile
    syntax: ## bash -n and py_compile on all scripts
    	@for f in $(SCRIPTS); do bash -n $$f && echo "OK   $$f"; done
    	python3 -m py_compile bin/4lm_helpers.py && echo "OK   bin/4lm_helpers.py"
    ```
    Note: `4lm_helpers.py` is NOT added to `SCRIPTS` (which is bash-only and fed to shellcheck/shfmt). The `py_compile` line uses system `python3` — syntax check does not need deps.
  - `test` target: add conditional pytest after bats:
    ```makefile
    test: ## Run bats suite + pytest (if venv installed)
    	bats tests/
    	@if [ -x "$(HELPERS_PYTHON)" ]; then \
    	  $(HELPERS_PYTHON) -m pytest tests/python/ -q; \
    	else \
    	  echo "skip: pytest — venv not installed (run make install)"; \
    	fi
    ```

- `tests/python/__init__.py`: empty file.

- `tests/python/conftest.py`:
  ```python
  import importlib.util
  from pathlib import Path
  import pytest

  @pytest.fixture(scope="session")
  def helpers():
      """Load bin/4lm_helpers.py once per session via importlib."""
      spec = importlib.util.spec_from_file_location(
          "helpers",
          Path(__file__).parents[2] / "bin" / "4lm_helpers.py",
      )
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      return mod
  ```

- `tests/python/test_smoke.py`:
  ```python
  import subprocess, sys
  from pathlib import Path

  HELPERS = Path(__file__).parents[2] / "bin" / "4lm_helpers.py"

  def test_help_exits_zero():
      result = subprocess.run(
          [sys.executable, str(HELPERS), "--help"],
          capture_output=True,
      )
      assert result.returncode == 0
  ```

- `tests/helpers/setup.bash`: add documentation comment and export:
  ```bash
  # 4LM_HELPERS_PYTHON: override the venv python for bats tests that invoke
  # migrated commands. Bash wrappers honour this variable over HELPERS_PYTHON.
  export 4LM_HELPERS_PYTHON="${HOME}/.4lm/venv/bin/python"
  ```

**Phase complete when:** `make check` passes with zero errors; `./install.sh` creates `~/.4lm/venv/` with `rich`, `pyyaml`, and `pytest` importable; `pytest tests/python/test_smoke.py` passes.

**CI note:** CI does not pre-install the venv. `make test` in CI always exercises the skip path and exits 0. Local dev with venv installed runs pytest.

### Test Scenarios

- GIVEN `install.sh` runs on a machine where `~/.4lm/` does not yet exist WHEN `install.sh` completes with exit 0 THEN `~/.4lm/venv/bin/python -c "import rich, yaml, pytest"` exits 0.

- GIVEN the venv exists and `4lm_helpers.py` is installed WHEN `~/.4lm/venv/bin/python ~/.4lm/bin/4lm_helpers.py --help` is run THEN exit code is 0.

- GIVEN the repo working tree WHEN `make check` is run THEN `python3 -m py_compile bin/4lm_helpers.py` exits 0 and all existing bats tests pass.

- GIVEN `~/.4lm/venv/bin/python` does not exist WHEN `make test` is run THEN bats tests run and complete; the pytest step prints `skip: pytest — venv not installed` and make exits 0.

- GIVEN `~/.4lm/venv/bin/python` does not exist and `bin/4lm` dispatches a command that calls `require_helpers_python` WHEN the command runs THEN stderr contains `FATAL: venv missing — run ./install.sh` and exit code is 1.

---

## Phase 2 — Extract `cmd_recommend` Heredoc

Semantic-equivalent rewrite of the existing 100-line Python heredoc from `cmd_recommend` into `4lm_helpers.py recommend`. Zero behavior change. The heredoc logic is the behavioral reference; `rich.Table` replaces the manual `printf` formatting.

**Changes:**

- `bin/4lm_helpers.py`: add `recommend(args)` function. The `normalize()` helper is a module-level function (callable from tests). Implementation mirrors the heredoc at `bin/4lm` lines 1494–1507 exactly: strip org prefix, lowercase, then iteratively strip suffixes `['-instruct', '-it', '-mlx', '-4bit', '-8bit', '-q4', '-q8', '-fp8', '-bf16', '-gguf', '-mxfp4', '-nvfp4', '-awq', '-gptq']` until stable.

  Active-profile cross-reference: split `args.active_paths` on `','`, normalize each, build a set `active_norms`. For each ranked model, if `normalize(model['name'])` is in `active_norms` and the rank > `limit`, collect it into an `active_outside_top` list and display below the top-N table with a labeled separator line.

  Exit codes: 0 on success; 1 if `rec_file` or `lm_file` is missing or unreadable.

- `bin/4lm` `cmd_recommend()`: replace the `python3 - <<'PYEOF' ... PYEOF` block with:
  ```bash
  require_helpers_python
  "${HELPERS_PYTHON}" "${HELPERS_PY}" recommend \
    "${rec_tmpfile}" "${lm_tmpfile}" "${active_paths}" "${limit}"
  ```

- `tests/python/fixtures/rec.json`: 10-model ranked list fixture with `{"models": [...]}` schema, model names matching the mlx-community naming convention.
- `tests/python/fixtures/lm.json`: community benchmark fixture with `{"benchmarks": [...]}` matching rec.json model names.
- `tests/python/test_recommend.py`: uses `helpers` fixture from conftest; calls `helpers.normalize(...)` and `helpers.recommend(...)` directly.

**Phase complete when:** `make check` passes; `pytest tests/python/test_recommend.py` passes; `4lm recommend` exits 0 on valid input and exits 1 on missing input file.

### Test Scenarios

- GIVEN fixture `rec.json` with 10 models and `lm.json` with community benchmarks and `active_paths=""` and `limit=5` WHEN `4lm_helpers.py recommend rec.json lm.json "" 5` is run THEN stdout contains exactly 5 data rows (excluding header and any active-profile section) and exit code is 0.

- GIVEN `normalize("mlx-community/Qwen2.5-Coder-32B-Instruct-4bit")` is called THEN return value is `"qwen2.5-coder-32b"`.

- GIVEN `normalize("mlx-community/Llama-3.1-8B-Instruct-8bit")` is called THEN return value is `"llama-3.1-8b"`.

- GIVEN a fixture where the active profile contains a model ranked #8 and limit=5 WHEN `recommend` is called THEN the top-5 rows appear first, followed by a labeled separator, followed by the rank-8 model.

- GIVEN `rec.json` does not exist WHEN `4lm_helpers.py recommend missing.json lm.json "" 5` is run THEN exit code is 1 and stderr is non-empty.

---

## Phase 3 — Migrate `cmd_models_list`

Replace `cmd_models_list` (70 lines, awk YAML parsing + printf tables) with a Python subcommand. `pyyaml` is already installed from Phase 1.

**Changes:**

- `bin/4lm_helpers.py`: add `models_list(args)`. Parse all `*.yaml` files in `args.profiles_dir` with `yaml.safe_load`. Deduplicate by model path. For each unique model path, check cache using the two-condition logic from `hf_is_cached()` in `bin/4lm` lines 132–142:
  1. `<hf_cache_dir>/hub/models--<org>--<name>/refs/main` exists.
  2. `<hf_cache_dir>/hub/models--<org>--<name>/blobs/` total size ≥ 1 073 741 824 bytes (1 GB).
  Both conditions required; `refs/main` alone is insufficient (partial downloads leave it behind).

  Emit a `rich.Table` with exact column names: `Model`, `Backend`, `Profiles`, `Cached`. Cached column: `✓` if both conditions met, `—` otherwise.

  After the profile-referenced table, populate an unreferenced section:
  - If `hf` is on PATH, run `hf cache list --format agent` and collect `model/*` entries not in the seen-models set; display with dim styling and Profiles = `(unreferenced)`.
  - If `ollama` is on PATH, run `ollama list` and collect model names not in the seen-models set; display with dim styling and Profiles = `(unreferenced)`.
  This mirrors `cmd_models_list` bash behavior at `bin/4lm` lines 1187–1208.

  On YAML parse failure: exit non-zero with `error: failed to parse <filename>: <reason>` to stderr.

- `bin/4lm` `cmd_models_list()`: reduce to:
  ```bash
  require_helpers_python
  "${HELPERS_PYTHON}" "${HELPERS_PY}" models-list \
    "${PROFILES_DIR}" "${HF_HOME:-${HOME}/.cache/huggingface}"
  ```

- `tests/python/fixtures/profile_a.yaml`: profile listing two models (one shared with profile_b).
- `tests/python/fixtures/profile_b.yaml`: profile listing one model shared with profile_a.
- `tests/python/test_models_list.py`: uses tmp directories for cache path construction; uses `helpers` fixture from conftest.

**Phase complete when:** `make check` passes; `pytest tests/python/test_models_list.py` passes; `4lm models list` exits 0 and output contains column names `Model`, `Backend`, `Profiles`, `Cached`.

### Test Scenarios

- GIVEN two fixture profile YAMLs both listing model path `mlx-community/Foo` WHEN `4lm_helpers.py models-list <profiles_dir> <hf_cache_dir>` is run THEN `mlx-community/Foo` appears exactly once in stdout.

- GIVEN a fixture HF cache directory where `<hf_cache_dir>/hub/models--mlx-community--Foo/refs/main` exists AND `blobs/` total size ≥ 1 GB WHEN `models-list` is run THEN the Cached column for that row shows `✓`.

- GIVEN a fixture where `refs/main` exists but `blobs/` total size < 1 GB (partial download) WHEN `models-list` is run THEN the Cached column shows `—` and exit code is 0.

- GIVEN a model path not present in the HF cache at all WHEN `models-list` is run THEN the Cached column shows `—` and exit code is 0.

- GIVEN no `*.yaml` files exist in the profiles directory WHEN `models-list` is run THEN exit code is 0 and stdout contains column headers `Model`, `Backend`, `Profiles`, `Cached` with zero data rows.

- GIVEN a profile YAML with a syntax error WHEN `models-list` is run THEN exit code is non-zero and stderr contains the filename.

---

## Phase 4 — Migrate `cmd_diag`

Extract the log analysis portion of `cmd_diag` into a Python subcommand, and add a live HTTP probe of the backend. The pgrep/ps process listing and GPU/CPU snapshots remain in bash.

**Changes:**

- `bin/4lm_helpers.py`: add `diag(args)`.

  **HTTP probe** (runs before log analysis, always):
  - `import time, urllib.request, urllib.error, json`
  - Record `t0 = time.time()`; call `urllib.request.urlopen(f"http://127.0.0.1:{args.backend_port}/v1/models", timeout=3)`
  - On success: parse response JSON, `model_count = len(data["data"])`, `ms = int((time.time()-t0)*1000)`; print `f"http://127.0.0.1:{args.backend_port}/v1/models — OK ({ms}ms, {model_count} models loaded)"`
  - On `urllib.error.URLError` or `OSError`: print `f"http://127.0.0.1:{args.backend_port}/v1/models — unreachable: {e.reason}"` (exit 0 — diagnostic output, not an error condition)

  **Log analysis** (runs after probe):
  Parse backend log with `re` using these exact patterns:
  - Admission: `r'BatchScheduler admitted uid=(\w+)'` → uid
  - Completion: `r'BatchScheduler.*uid=(\w+).*finished'` → uid
  - Worker: `r'worker pid=(\d+)'` → pid

  Compute in-flight: collect admission uids in the last 10 minutes (compare timestamp prefix to `datetime.now() - timedelta(minutes=10)`); subtract uids with matching completion events.

  Compute orphans: worker pids present in the log with zero admission events ever recorded for that pid across the full log.

  If log file is absent or has zero bytes: print `No log data found at <path>` (skip log sections, still run the HTTP probe).

  Emit output using `rich.Console.print` (not `rich.Panel`) with these exact section labels in order:
  1. `"Backend"`
  2. `"In-flight inference (admitted, not yet finished, last 10 min)"`
  3. `"Backend worker processes"`
  4. `"Orphaned workers"` (only if orphans detected)

  Tests use `Console(file=io.StringIO(), highlight=False)` to suppress ANSI in output assertions.

- `bin/4lm` `cmd_diag()`: call Python for the log analysis section; keep live client probe, pgrep/ps, and GPU/CPU sections in bash:
  ```bash
  require_helpers_python
  "${HELPERS_PYTHON}" "${HELPERS_PY}" diag \
    "${LOG_DIR}/backend.log" "$(net_backend_port)"
  ```

- `tests/python/fixtures/backend.log`: log fixture with 3 admission events (`BatchScheduler admitted uid=`), 2 completion events (`BatchScheduler ... finished`), and one `worker pid=` line with a PID that has no corresponding admission event.
- `tests/python/test_diag.py`: uses `helpers` fixture from conftest; passes log fixture path and a dummy port.

**Phase complete when:** `make check` passes; `pytest tests/python/test_diag.py` passes; `4lm diag` output contains section label `In-flight inference (admitted, not yet finished, last 10 min)`.

### Test Scenarios

- GIVEN a fixture log file with 3 `BatchScheduler admitted uid=` lines (all within last 10 min) and 2 matching `BatchScheduler ... finished` lines WHEN `4lm_helpers.py diag <log_file> <port>` is run THEN stdout contains the integer `1` in the in-flight section and exit code is 0.

- GIVEN a fixture log file containing `worker pid=99999` with no `BatchScheduler admitted uid=` event anywhere in the log WHEN `diag` is run THEN stdout contains `99999` in the `Orphaned workers` section.

- GIVEN a fixture log file where all admitted uids have matching finished lines WHEN `diag` is run THEN the `Orphaned workers` section is absent and exit code is 0.

- GIVEN the log file path does not exist WHEN `diag` is run THEN exit code is 0 and stdout contains `No log data found at` followed by the path.

- GIVEN an empty log file (zero bytes) WHEN `diag` is run THEN exit code is 0 and stdout contains `No log data found at` followed by the path.

- GIVEN a mock HTTP server listening on `<backend_port>` that returns `{"data": [{"id": "m1"}, {"id": "m2"}]}` WHEN `diag` is run THEN stdout contains `OK` and `2 models loaded` in the `Backend` section and exit code is 0.

- GIVEN no process listening on `<backend_port>` WHEN `diag` is run THEN stdout contains `unreachable` in the `Backend` section and exit code is 0 (diagnostic, not failure).

---

## Phase 5 — Migrate `outdated` Query Phase

Extract the query logic from `run_outdated_check` into a Python subcommand. `cmd_upgrade`'s action logic remains in bash; the `--porcelain` flag provides the data bridge between them.

**Changes:**

- `bin/4lm_helpers.py`: add `outdated(args)`. The subparser registers `--porcelain` via `parser_outdated.add_argument('--porcelain', action='store_true')`.

  Implementation:

  Helper `_parse_req_file(path) -> list[tuple[str, str]]`: reads a requirements file and returns `[(pkg_name, installed_version)]`. Parsing rules:
  - Skip blank lines and `#` comments.
  - Strip extras: `huggingface_hub[cli]` → `huggingface_hub`.
  - `==X.Y.Z` pin → installed = `X.Y.Z`.
  - `>=X.Y,<Z` pin → installed = lower bound `X.Y` (the pinned floor).
  - Any other format → print warning to stderr, skip.

  1. Call `_parse_req_file("<repo_dir>/requirements.txt")` → `python_pkgs` (source: `"pipx"`).
  2. Call `_parse_req_file("<repo_dir>/requirements-helpers.txt")` → `helpers_pkgs` (source: `"venv"`).
  3. For each pkg in both lists: GET `https://pypi.org/pypi/<pkg>/json` via `urllib.request.urlopen(url, timeout=10)`; parse `.info.version` as `latest`. If `latest != installed`, record as outdated.
  4. Run `brew outdated --json` via `subprocess.run(["brew", "outdated", "--json"], capture_output=True, text=True, check=False)`. Parse `data["formulae"]`; filter by Brewfile formulae (regex `^brew "([^"]+)"`). Map: `installed = item["installed_versions"][-1]`, `latest = item["current_version"]`.
  5. On `--porcelain`: emit JSON `{"python": [...], "helpers": [...], "brew": [...]}` to stdout with only outdated entries; exit 0.
  6. On human mode: emit separate `rich.Table` for each non-empty section: "Python (pipx)" and "Helpers (venv)" with columns `Package`, `Installed`, `Latest`; then brew table. Up-to-date items not shown.
  7. On `urllib.error.URLError`: write `error: could not reach PyPI: <reason>` to stderr; exit 1.
  8. On brew subprocess failure (`returncode != 0`): write `error: brew outdated failed: <stderr>` to stderr; exit 1.

- `bin/4lm` `cmd_outdated()`: replace existing query logic with:
  ```bash
  require_helpers_python
  "${HELPERS_PYTHON}" "${HELPERS_PY}" outdated "${REPO_DIR}"
  ```

- `bin/4lm` `cmd_upgrade()`: call Python with `--porcelain`, capture JSON, parse with `jq`:
  ```bash
  require_helpers_python
  porcelain=$("${HELPERS_PYTHON}" "${HELPERS_PY}" outdated --porcelain "${REPO_DIR}")
  # parse $porcelain with jq into local arrays for existing action logic
  # e.g.: mapfile -t OUTDATED_PY   < <(jq -r '.python[]  | "\(.pkg)|\(.installed)|\(.latest)"' <<<"${porcelain}")
  #       mapfile -t OUTDATED_BREW < <(jq -r '.brew[].formula' <<<"${porcelain}")
  # helpers (venv) are not auto-upgraded by cmd_upgrade; user must edit
  # requirements-helpers.txt and re-run install.sh. Print a notice if non-empty:
  # helpers_count=$(jq '.helpers | length' <<<"${porcelain}")
  # [[ "${helpers_count}" -gt 0 ]] && warn "venv deps outdated — update requirements-helpers.txt and re-run install.sh"
  ```

- `tests/python/test_outdated.py`: mock HTTP via `unittest.mock.patch('urllib.request.urlopen', ...)`; mock `subprocess.run` for `brew outdated --json`; use `helpers` fixture from conftest.

**Phase complete when:** `make check` passes; `pytest tests/python/test_outdated.py` passes; `4lm outdated --porcelain` emits valid JSON matching the Data Models schema; `4lm upgrade` processes the porcelain output and runs the same brew/pipx action logic as before.

### Test Scenarios

- GIVEN `requirements.txt` with `mlx-openai-server==1.8.0` and a mocked PyPI response returning `1.8.1` WHEN `4lm_helpers.py outdated --porcelain <repo_dir>` is run THEN stdout is valid JSON where `json["python"][0]` equals `{"pkg": "mlx-openai-server", "installed": "1.8.0", "latest": "1.8.1"}` and exit code is 0.

- GIVEN all packages at their latest versions (mocked) WHEN `4lm_helpers.py outdated --porcelain <repo_dir>` is run THEN stdout is `{"python": [], "brew": []}` and exit code is 0.

- GIVEN all packages at latest versions WHEN `4lm_helpers.py outdated <repo_dir>` is run without `--porcelain` THEN exit code is 0 and stdout contains no arrow characters (`→` or `->`).

- GIVEN the PyPI HTTP call raises `urllib.error.URLError` WHEN `outdated` runs THEN exit code is 1 and stderr starts with `error: could not reach PyPI:`.

- GIVEN `brew outdated --json` exits non-zero WHEN `outdated` runs THEN exit code is 1 and stderr starts with `error: brew outdated failed:`.

- GIVEN `requirements.txt` contains `huggingface_hub[cli]==0.24.0` and a mocked PyPI response for `huggingface_hub` returning `0.24.0` WHEN `outdated --porcelain` runs THEN `huggingface_hub` appears in `python[]` with `installed="0.24.0"` only if a newer version exists; no error for the extras syntax.

- GIVEN `requirements-helpers.txt` contains `rich>=13.9,<14` and a mocked PyPI response returning `13.10.0` WHEN `outdated --porcelain` runs THEN `rich` appears in `helpers[]` with `installed="13.9"` and `latest="13.10.0"`.

- GIVEN `requirements-helpers.txt` has an outdated dep WHEN `4lm upgrade` runs THEN stdout contains a notice `venv deps outdated — update requirements-helpers.txt and re-run install.sh` and the helpers entries are not auto-upgraded.

- GIVEN `requirements.txt` contains a line without a supported pin format WHEN `outdated` runs THEN that package is skipped and a warning is printed to stderr; exit code is 0 if remaining packages succeed.

---

## Decision Log

| Decision | Alternatives Considered | Reason Rejected |
|---|---|---|
| Dedicated venv at `~/.4lm/venv/` | System python3 (Homebrew) | PEP 668 blocks pip install; bats `python3` stub would intercept calls |
| Dedicated venv at `~/.4lm/venv/` | pipx inject into existing app venv | Fragile coupling to mlx-openai-server venv lifecycle |
| Dedicated venv at `~/.4lm/venv/` | `pyproject.toml` + `pipx install -e .` | Installed scripts land in `~/.local/bin/`, not `~/.4lm/bin/`; adds packaging overhead |
| Bash stays as entry point / dispatcher | Full Python CLI (Click/Typer) with bash shim | Flag-day rewrite; bats tests would need full replacement; launchctl orchestration is genuinely simpler in bash |
| Single `bin/4lm_helpers.py` file | Package under `lib/4lm/` | Overkill for current scale; single file is simpler to copy in install.sh |
| `cmd_upgrade` action logic deferred past Phase 5 | Migrate upgrade fully in Phase 5 | Upgrade shares mutable bash arrays with outdated check; porcelain bridge pattern must be proven first |
| `rich` as the only new Python dep | `tabulate`, `click`, `typer` | `rich` covers tables, panels, colors, and progress in one dep; others would need to be combined |
| PyYAML for profile parsing | ruamel.yaml | Profile YAMLs are read-only in this SDD; ruamel is only necessary for write-back. PyYAML is simpler. |
| All Python deps (incl. pytest) installed in Phase 1 | Install `pyyaml` in Phase 3, `pytest` via system | Splitting the `pip install` across phases means multiple edits to `install.sh`; declaring the full dep list once is simpler and idempotent |
| `rich.Console.print` for `diag` output | `rich.Panel` sections | Panels change the visual structure beyond the stated goal; plain `Console.print` with the same labels preserves output fidelity |
| Conditional pytest skip in Makefile | `|| true` | `|| true` swallows real test failures silently; venv-existence check skips only when genuinely not installed |
| `python3 -m py_compile` for syntax check | `${HELPERS_PYTHON} -m py_compile` | Syntax check does not import deps; system `python3` is sufficient and works in CI without a venv |
| `brew outdated --json` bulk call | Per-formula `brew outdated --formula --verbose <name>` | Bulk JSON is one subprocess call vs. N calls; human output format change (no `✓` rows for up-to-date formulae) is an accepted behavior delta |
| Floor+ceiling pins (`>=X.Y,<Z`) in `requirements-helpers.txt` | Exact pins (`==X.Y.Z`) | Exact pins require manual bumping for every patch release. Floor+ceiling (`rich>=13.9,<14`) allows patch updates automatically while blocking major-version API breaks. `4lm outdated` surfaces drift against the floor pin so upgrades are visible. |
| `requirements-helpers.txt` as single source of truth for venv deps | Hardcoded versions in `install.sh` | A separate file lets `4lm outdated` check venv deps against PyPI without parsing shell code; `install.sh` delegates to it via `-r`. |
| `active_paths` as comma-separated string | `--active path1 --active path2` repeated flags | Comma-separated matches the existing bash builder (`printf "%s,"` at line 1467) and consumer (`split(',')` at line 1527); changing the calling convention would require modifying both bash and the argparse interface |
| `diag` HTTP probe via `urllib` | `requests` library | `urllib` is stdlib — no extra dep; the probe is a single GET with no auth/redirect complexity |
| `diag` HTTP probe endpoint `/v1/models` | TCP-only connect probe | HTTP probe yields model count and response time, not just reachability; more useful for diagnostics |
| `diag` probe failure exits 0 | Exit non-zero when backend unreachable | `diag` is a diagnostic command; unreachable backend is expected during stop/restart and should not break scripted callers |
| `diag` migrates log analysis + HTTP probe | Migrate full `cmd_diag` including pgrep/ps and powermetrics | pgrep/ps and powermetrics are process-orchestration — they belong in bash per the architecture boundary |

## Open Decisions

None.

## Out of Scope

- Rewriting `install.sh` or `uninstall.sh` in Python
- Migrating `start`, `stop`, `restart`, `expose`, `health`, `profile set` — process-orchestration commands where bash is idiomatic
- Migrating `cmd_upgrade`'s action phase (brew upgrade, pipx reinstall, hf download) — deferred past Phase 5
- Migrating `cmd_diag`'s pgrep/ps process listing or GPU/CPU snapshots (remain in bash)
- HF SHA comparison in `outdated` — deferred (not implemented in current bash either)
- Introducing a `pyproject.toml` or making `4lm_helpers.py` installable as a package
- Adding type annotations or mypy
- Replacing bats tests with pytest for bash-orchestration coverage
