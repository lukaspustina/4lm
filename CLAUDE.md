# 4lm — Local LLM Control Plane

**Thesis.** Single-command control plane for one engineer's local LLM
stack on Apple Silicon. Two first-class deployment shapes —
**workstation** (full stack: `omlx` + `open-webui` + `opencode`) and
**appliance** (`./install.sh --backend-only`: headless `/v1/*` server
for the LAN) — share one CLI, one profile system, one set of security
defaults.

The user-facing pitch lives in [`README.md`](README.md). This file is
the working orientation for contributors and AI assistants.

Model selection and the layered architecture rationale live in the
archived rework SDD at `specs/done/sdd/4lm-rework-2026-05-09.md`. Read it
before changing the model set, the backend choice, or the activation model.

## Repo layout

```
bin/                       # 4lm, launchd wrapper scripts, and 4lm_helpers.py
launchd/                   # plist templates with __HOME__ placeholder
config/profiles/           # lean / default / max-100gb (Qwen3 stack via omlx) + mlx-coding / mlx-knowledge / ollama YAMLs
config/network.example.yaml
config/opencode.example.jsonc  # template seeded into ~/.config/opencode/
docs/                      # setup runbook + profile schema reference
tests/                     # bats suite (helpers/ has launchctl + curl stubs)
.github/workflows/         # macOS CI: shellcheck, shfmt, plutil, xmllint, bats; matrix runs default + backend-only
install.sh                 # idempotent installer; --backend-only skips WebUI + opencode
uninstall.sh               # full removal (services, ~/.4lm, newsyslog)
requirements.txt           # pinned open-webui, huggingface_hub[cli]; omlx from git
requirements-helpers.txt   # 4lm_helpers.py runtime deps (rich, pyyaml, pytest)
Brewfile                   # core: shellcheck, shfmt, bats-core, jq, python@3.12, pipx, llmfit, ollama
Brewfile-tui               # TUI extras: opencode (skipped when BACKEND_ONLY=1)
Makefile                   # bootstrap / install / uninstall / models* / check / lint / fmt / test / ci / ci-default / ci-backend-only
specs/sdd/                 # active SDDs (webui-tools-and-mcp.md); completed work archived under specs/done/sdd/
```

## Key commands

| Task | Command |
|---|---|
| Bootstrap dev tools | `make bootstrap` (Brewfile + Brewfile-tui + `pipx ensurepath`; `BACKEND_ONLY=1` skips TUI) |
| Install / re-install | `make install` (or `./install.sh`; `BACKEND_ONLY=1` / `--backend-only` skips WebUI + opencode) |
| Full uninstall | `make uninstall` (or `./uninstall.sh`) — removes ~/.4lm |
| Pre-download models | `make models` (idempotent; `models-list`, `models-clean`, `models-rm`) — CLI: `4lm model download` |
| Start everything | `4lm start` |
| Stop everything | `4lm stop` |
| Status | `4lm` (alias for `4lm status`; `--json` for machine-readable) |
| Switch profile | `4lm profile set <name>` |
| Toggle LAN exposure | `4lm expose lan --confirm` |
| OpenCode TUI | `4lm opencode` (alias `4lm code`) |
| Login autostart | `4lm autostart enable\|disable\|status [backend\|webui\|all]` |
| Sanity sweep | `4lm doctor` (prereqs + smoke-test); `4lm diag` (live clients, inflight work) |
| Update probes | `4lm outdated` (PyPI / brew / HF); `4lm upgrade [brew\|models\|python]` to apply |
| Model picks | `4lm model recommend [<use-case>]` (uses `llmfit` + localmaxxing benchmarks) |
| Run all checks | `make check` |
| Run tests | `make test` (requires `bats-core`) |
| Mirror CI matrix locally | `make ci` (runs `ci-default` + `ci-backend-only`) |

## Activation model

Plists live in `~/.4lm/launchd/` (NOT `~/Library/LaunchAgents/`) → launchd
never discovers them automatically. `4lm start` / `stop` call `launchctl
bootstrap` / `bootout`. Autostart at login is opt-in via `4lm autostart
enable`, which symlinks the plist into `~/Library/LaunchAgents/`. After
reboot, services are stopped unless autostart is enabled.

## Network exposure

`~/.4lm/config/network.yaml` is the **single** config channel. `mode: local`
binds to `127.0.0.1`; `mode: lan` binds to `0.0.0.0`. Switching is done
only via `4lm expose <mode> --confirm`. No env-var overrides exist or
should be added — the deliberate friction is a security feature.

## Dual-shape conventions

`./install.sh --backend-only` (or `make install BACKEND_ONLY=1`) skips
`open-webui` (pipx), the webui plist, the webui wrapper, the `opencode`
brew formula, and the seeded `~/.config/opencode/opencode.jsonc`. The
contract this imposes:

- `bin/4lm` **probes for the webui plist on disk** and treats the WebUI
  layer as not installed when absent (status output, autostart targets,
  `4lm doctor` checks all adapt). Never assume the WebUI exists.
- Re-running the full installer over a backend-only install **upgrades**
  cleanly to full; re-running `--backend-only` over a full install **does
  not strip** existing WebUI artifacts. Tests for these invariants live
  in the bats suite.
- The CI matrix runs both legs (`make ci-default` + `make ci-backend-only`);
  any new feature must work in both shapes or guard its behavior on the
  webui-plist probe.

## Profile switching is atomic with rollback

`4lm profile set <name>` validates the YAML, saves the previous profile name,
swaps the symlink, kickstarts the backend, and polls `/v1/models` for 30 s.
On timeout it restores the previous symlink and kickstarts again.

Same-name re-issue (e.g. after editing the active profile YAML) re-renders
`~/.omlx/model_settings.json` and re-stages `~/.4lm/runtime/<profile>/models/`
before kickstarting, so YAML edits propagate without a full stop/start.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck` clean, formatted by `shfmt`.
- Plists: `__HOME__` placeholder, substituted by `install.sh`.
- Profile YAMLs validated by `validate_profile` in `bin/4lm`. Schema reference
  in `docs/profile-schema.md`. Three backends: `omlx` (vLLM-style MLX,
  multi-model, paged KV cache), `mlx_lm` (python -m mlx_lm server,
  single-model upstream), `ollama` (llama.cpp/Metal).
- No `Co-Authored-By: Claude` lines in commits.
- Conventional-commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`,
  `test:`. Subject under 72 characters.

## Profile lineup (quick reference)

Full table with use-cases, fits-on, and memory math lives in
[`README.md`](README.md). Contributor-relevant constraints:

| Profile | Backend | Steady |
|---|---|---|
| `lean` | omlx | ~40 GB |
| `default` | omlx | ~65 GB |
| `max-100gb` | omlx | ~92 GB |
| `mlx-coding` | omlx | ~42 GB |
| `mlx-knowledge` | omlx | ~23 GB |
| `ollama` | ollama | ~22 GB |

All omlx embedders share `served_model_name: qwen3-embedding`, all omlx
rerankers share `qwen3-reranker`, vision is `qwen3-vl-8b`. **Switching
between omlx profiles never requires reindexing knowledge bases — do
not change these served-model names without an explicit migration
plan.** Each YAML carries an extensive header comment with slot-by-slot
rationale, memory math, when-to-use, and assumptions-to-validate;
review periodically and update the `Last reviewed:` line.

## OpenWebUI feature toggles

`bin/4lm-webui-start.sh` exports a baseline of feature env vars to give the
WebUI Claude-Desktop-style behavior on first launch:

- Memory (`ENABLE_MEMORIES`)
- DuckDuckGo web search (`ENABLE_RAG_WEB_SEARCH`, `RAG_WEB_SEARCH_ENGINE=duckduckgo`)
- Pyodide code interpreter (`ENABLE_CODE_INTERPRETER`, `CODE_INTERPRETER_ENGINE=pyodide`)
- Follow-up + autocomplete suggestions
- RAG embeddings via omlx (`RAG_EMBEDDING_ENGINE=openai`,
  `RAG_EMBEDDING_MODEL=qwen3-embedding`, pointed at the local `:8000/v1`)
- RAG hybrid search + reranker via omlx (`ENABLE_RAG_HYBRID_SEARCH=True`,
  `RAG_RERANKING_ENGINE=external`, `RAG_EXTERNAL_RERANKER_URL` points at
  the local `/v1/rerank`, `RAG_RERANKING_MODEL=qwen3-reranker`). omlx
  serves `POST /v1/rerank` in Cohere/Jina-compatible shape;
  OpenWebUI's `external` engine (verified in `open_webui/retrieval/
  models/external.py`) speaks that contract directly. **The URL is the
  full endpoint**, not a base — OpenWebUI does not append `/rerank`.

Most `ENABLE_*` / `RAG_*` / `DEFAULT_*` vars in OpenWebUI are PersistentConfig:
copied into `webui.db` on first init only. After that the admin UI is the
source of truth — changing the env value won't override the DB. Set
`ENABLE_PERSISTENT_CONFIG=False` to make env vars authoritative every start
(at the cost of disabling all admin-UI persistence).

## omlx path probe

Phase 1 manual probe result (2026-05): omlx **does not** accept absolute HF
snapshot paths in `model_settings.json`. Setting `model_path` to an absolute
snapshot dir and starting `omlx serve --model-dir <empty>` returns no models
from `/v1/models`. The staging layer (`stage_omlx_model_dir()` +
`~/.4lm/runtime/<profile>/models/`) is therefore permanent; the TODO comment
in `stage_omlx_model_dir()` remains as documentation of the probe outcome.

See `specs/done/sdd/4lm-rework-2026-05-09.md` for the archived rework SDD
that this repo state implements.
