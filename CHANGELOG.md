# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, README Credits section
  — pre-release tidy for public OSS launch.

### Changed
- **BREAKING**: launchd labels renamed `com.4lm.{backend,webui}`
  → `com.4lm.{backend,webui}`. Plist files renamed accordingly. Upgrade
  path: `4lm autostart disable && 4lm stop && ./install.sh && 4lm start`
  (existing services bound to the old labels need to be bootout'd before
  the new ones take over).
- `omlx` git dependency pinned to commit `51907f08` (2026-05-14) in
  `install.sh` for reproducible installs; bump deliberately via the
  `OMLX_GIT_REF` constant.
- `config/opencode.example.jsonc` rewritten for the v0.6 default profile
  (omlx + full Qwen3 stack); removed stale `mlx-openai-server`,
  `Qwen3.6-27B`, and `exp-*` profile references.

### Fixed
- `install.sh` post-install summary referenced the removed `4lm health`
  command; now shows `4lm doctor`.

## [0.6.0] - 2026-05-09

### Added
- OpenWebUI feature baseline in `bin/4lm-webui-start.sh`: DuckDuckGo web
  search, Pyodide code interpreter, personal memory, follow-up +
  autocomplete suggestions; `WEBUI_NAME=4lm` (ee76145)
- RAG embeddings via omlx: `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`
  (served as `qwen3-embedding`) added to default and omlx-coding profiles;
  WebUI wired to `RAG_EMBEDDING_ENGINE=openai` against the local backend (ee76145)
- `4lm profile validate <name>` subcommand for standalone profile validation (dfc5946)
- `4lm status --json` flag for machine-readable status output (dfc5946)

### Changed
- omlx-coding profile: replaced gated `mlx-community/bge-m3` with
  `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` (ee76145)
- SDD work archived: 4lm-rework, ollama-backend (a66ec82, 97e5dc0)

### Fixed
- `4lm profile set` same-name path now re-renders `model_settings.json`
  and re-stages model symlinks before kickstart, so YAML edits to the
  active profile propagate without a full stop/start (ee76145)
- `4lm status --json` no longer emits invalid literal when backend field
  is set (c00b0ac)
- ollama-backend status header (a66ec82)

## [0.5.0] - 2026-05-09

### Added
- `4lm autostart enable|disable|status` subcommand for opt-in login autostart
  via LaunchAgents symlinks; `KeepAlive`+`ThrottleInterval` in plists (cd82714)
- `backend: omlx` as primary MLX backend: paged KV cache, continuous batching,
  multi-model EnginePool, DFlash speculative decoding for Qwen models (f3ea0b4)
- `4lm model purge [--confirm]` removes all cached models (HF + ollama) (a575a7c)
- `4lm model prune` (renamed from `clean`): prune stale HF snapshot revisions (a575a7c)
- `4lm uninstall --purge [--confirm]`: wipes ~/.4lm/, ~/.omlx/, all model
  caches — nothing left (a575a7c, 2f9fb00)
- `4lm status` shows active backend type, autostart state per service, and
  loaded model IDs; checks WebUI HTTP alongside backend (a575a7c, aee8134)
- omlx-coding.yaml profile: Qwen3-Coder-Next + BGE-M3 on omlx (e38a874)

### Changed
- Default MLX profiles (default, mlx-coding, mlx-knowledge) migrated from
  mlx-openai-server to `backend: omlx` (9d6ca82)
- `4lm autostart` service token renamed from `omlx` to `backend` for
  consistency with other subcommands (83207cd)
- Help text: removed stale phase3-ready, 4lm health, and mlx-openai-server
  references; clarified model prune vs cleanup vs purge (6fbfd48, b55c639)

### Removed
- `mlx-openai-server` backend (`backend: mlx` value); omlx supersedes it
  across all MLX inference use cases (c78861d)

### Fixed
- `4lm profile set` now stages omlx model-dir when same profile re-selected
  and backend is not loaded (595b6b9)
- model_settings.json written in omlx dict format; --model-dir passed to
  omlx serve (85dd1fe)
- `hf_is_cached` uses model_path not served_model_name (34d8b69)
- omlx installed from GitHub (not PyPI) (4666ad0)
- `4lm autostart enable` removes symlink on bootstrap failure (4511486)
- `4lm uninstall --purge` requires explicit `--confirm` to execute (2f9fb00)

## [0.4.0] - 2026-05-08

### Added
- `4lm doctor` runs a smoke test (`POST /v1/chat/completions`) for every model
  in `/v1/models` when the backend is running; handles thinking models via
  `completion_tokens` fallback (dd0feaa)
- `4lm status` probes backend HTTP and reports OK/unreachable (dd0feaa)
- `4lm doctor` and `4lm diag` moved into the Service Control help group (dd0feaa)

### Changed
- `_doctor_check_models_cached` reports each model individually with `ok`/`warn`
  instead of a single aggregate warning (dd0feaa)

### Fixed
- Ollama model cache check grepped `served_model_name` against `ollama list`
  output (which uses `model_path` format), causing spurious "no models cached"
  warnings — now greps `model_path` (dd0feaa)

### Removed
- `4lm health` command — GPU check absorbed into `4lm doctor`, HTTP probe
  into `4lm status` (dd0feaa)

## [0.3.0] - 2026-05-08

### Added
- Destructive-op guards for `model rm`, `cleanup`, `expose`, and `uninstall` — require `--confirm` (ccd7832)
- Onboarding UX: URL hints after start, doctor model-cache check, health output as table (faa4b37)
- `4lm diag` shows live TCP clients and in-flight inference (eb068e6)
- `backend: mlx_lm` as third backend option (`python -m mlx_lm server`) (21c832b)
- `4lm profile show` subcommand (cbbb33f)
- `4lm model cleanup` removes cached models not referenced in any profile (4a52dd4)
- `4lm model recommend` using llmfit + localmaxxing benchmarks (e035065)
- Active profile models appended below top-N in recommend output (d1e2b4a)
- Ollama backend support: `4lm model download` and `4lm model list` dispatch per backend with dedup (6be2130)
- hf-transfer enabled for faster model downloads (78eaee3)

### Fixed
- Poll loop, profile validator, port guards, atomic profile-symlink writes (c69c539)
- Consistent `error:` prefix via `die()` for all user-visible errors (047b3d3)
- WebUI secret key persisted across restarts; registration disabled in all modes (271c2f8)
- Service error propagation, dead code removal, health HTTP probe (eec1d28)
- Ollama cache check; unified outdated output into one table (3cfaa44)
- Synchronous hf download; always verify downloads, never skip based on size (3b1ac4e)

### Changed
- `4lm models` renamed to `4lm model` for consistency with `4lm profile` (c368066)
- `4lm model recommend` moved from top-level to `model` subcommand (c368066)
- Python helpers venv with rich table output for model list and recommend (792abf3)
- Profile set consolidated; ollama set as default profile (b77edb7)
- CI hardened: pinned actions, timeouts, concurrency cancel, venv cache (d2bc0b2)
