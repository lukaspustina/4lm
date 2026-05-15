# 4lm — Local LLM Control Plane

Personal local-LLM stack for Apple Silicon: `omlx` (MLX backend) +
`open-webui` (frontend) + `opencode` (TUI client), managed by launchd and
controlled by a single `4lm` command.

Model selection and the layered architecture rationale live in
`specs/sdd/4lm-rework.md` (the SDD this repo implements). Read that before
changing the model set, the backend choice, or the activation model.

## Repo layout

```
bin/                       # 4lm and the two launchd wrapper scripts
launchd/                   # plist templates with __HOME__ placeholder
config/profiles/           # lean / default / max-100gb (omlx, Qwen3 stack) + mlx-coding / mlx-knowledge / exp-* YAMLs
config/network.example.yaml
config/opencode.example.jsonc  # template seeded into ~/.config/opencode/
docs/                      # setup runbook + profile schema reference
tests/                     # bats suite (helpers/ has launchctl + curl stubs)
.github/workflows/         # macOS CI: shellcheck, shfmt, plutil, xmllint, bats
install.sh                 # idempotent installer (no bootstrap, no migration)
uninstall.sh               # full removal (services, ~/.4lm, newsyslog)
requirements.txt           # pinned open-webui, huggingface_hub[cli]; omlx from git
Brewfile                   # shellcheck, shfmt, bats-core, python@3.12, pipx, opencode
Makefile                   # bootstrap / install / uninstall / models* / check / lint / fmt / test
specs/sdd/                 # active SDDs (4lm-rework.md is the rework spec)
```

## Key commands

| Task | Command |
|---|---|
| Bootstrap dev tools | `make bootstrap` (runs Brewfile + `pipx ensurepath`) |
| Install / re-install | `make install` (or `./install.sh`) |
| Full uninstall | `make uninstall` (or `./uninstall.sh`) — removes ~/.4lm |
| Pre-download models | `make models` (idempotent; `models-list`, `models-clean`, `models-rm`) — CLI: `4lm model download` |
| Start everything | `4lm start` |
| Stop everything | `4lm stop` |
| Status | `4lm` (alias for `4lm status`) |
| Switch profile | `4lm profile set <name>` |
| Toggle LAN exposure | `4lm expose lan --confirm` |
| OpenCode TUI | `4lm opencode` (alias `4lm code`) |
| Run all checks | `make check` |
| Run tests | `make test` (requires `bats-core`) |

## Activation model

Plists live in `~/.4lm/launchd/` (NOT `~/Library/LaunchAgents/`). Services do
**not** auto-start at login by default; opt in via `4lm autostart enable`.
`4lm start` calls `launchctl bootstrap`, `4lm stop` calls `launchctl bootout`.
After reboot, services stopped unless autostart is enabled.

## Network exposure

`~/.4lm/config/network.yaml` is the single config channel. `mode: local`
binds to `127.0.0.1`; `mode: lan` binds to `0.0.0.0`. Switching is done only
via `4lm expose <mode> [--confirm]`. There are no env-var overrides.

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

## Three-tier profile stack

The Qwen3-family stack ships as three profiles with a shared embedder so
knowledge bases stay valid across switches:

| Tier | Coder | Chat | Embed | Rerank | Vision | Steady |
|---|---|---|---|---|---|---|
| `lean` | Qwen3-Coder-30B-A3B | Qwen3.6-35B-A3B | Qwen3-Embedding-8B | Qwen3-Reranker-0.6B | — | ~41 GB |
| `default` | Qwen3-Coder-Next (80B) | Qwen3.6-35B-A3B | Qwen3-Embedding-8B | Qwen3-Reranker-0.6B | Qwen3-VL-8B | ~65 GB |
| `max-100gb` | Qwen3-Coder-Next (80B) | Qwen3-Next-80B-A3B | Qwen3-Embedding-8B | Qwen3-Reranker-4B | Qwen3-VL-8B | ~92 GB |

All embedders are the same model under `served_model_name: qwen3-embedding`,
all rerankers are `qwen3-reranker`, vision is `qwen3-vl-8b`. Switching
profiles never requires reindexing knowledge bases.

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

See `specs/sdd/4lm-rework.md` for the rework SDD that this repo state
implements.
