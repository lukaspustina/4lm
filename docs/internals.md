# Internals

Background for contributors: inventories, measurements and the reasoning behind rules that
`CLAUDE.md` states in one line.

## Repo layout

```
bin/                       # 4lm, launchd wrapper scripts, and 4lm_helpers.py
launchd/                   # plist templates with __HOME__ placeholder
config/profiles/           # lean (64 GB) / mid (128 GB) / default (256 GB) via omlx + ollama smoke-test YAML
config/network.example.yaml
config/opencode.example.jsonc  # template seeded into ~/.config/opencode/
docs/                      # setup runbook, profile schema reference, autostart, this file
tests/                     # bats suite (helpers/ has launchctl + curl stubs), tests/python/
.github/workflows/         # macOS CI: shellcheck, shfmt, plutil, xmllint, bats; matrix runs default + backend-only
install.sh                 # idempotent installer; --backend-only skips WebUI + opencode
uninstall.sh               # full removal (services, ~/.4lm, newsyslog)
requirements.txt           # pinned open-webui, huggingface_hub[cli]; omlx from git
requirements-helpers.txt   # 4lm_helpers.py runtime deps (rich, pyyaml, pytest)
Brewfile                   # core: shellcheck, shfmt, bats-core, jq, python@3.12, pipx, llmfit, ollama
Brewfile-tui               # TUI extras: opencode (skipped when BACKEND_ONLY=1)
justfile                   # bootstrap / install / uninstall / models* / check / lint / fmt / test / ci*
specs/sdd/                 # active SDDs; completed work archived under specs/done/sdd/
```

## Commands

| Task | Command |
|---|---|
| Bootstrap dev tools | `just bootstrap` (Brewfile + Brewfile-tui + `pipx ensurepath`; `BACKEND_ONLY=1` skips TUI) |
| Install / re-install | `just install` (or `./bin/4lm install` / `./install.sh`; `BACKEND_ONLY=1` / `--backend-only` skips WebUI + opencode) |
| Daemon install / removal | `sudo ./bin/4lm install --daemon <user>` · `sudo 4lm uninstall --daemon --confirm` |
| Full uninstall | `just uninstall` (or `./uninstall.sh`) — removes ~/.4lm |
| Pre-download models | `just models [profile]` (idempotent; `models-list`, `models-clean`, `models-rm`) — CLI: `4lm model download [--profile <name>]` |
| Start / stop | `4lm start` / `4lm stop` |
| Status | `4lm` (alias for `4lm status`; `--json` for machine-readable) |
| Switch profile | `4lm profile set <name>` |
| Toggle LAN exposure | `4lm expose lan --confirm` |
| OpenCode TUI | `4lm opencode` (alias `4lm code`) |
| Login autostart | `4lm autostart enable\|disable\|status [backend\|webui\|all]` |
| Sanity sweep | `4lm doctor` (prereqs + smoke-test); `4lm diag` (live clients, inflight work) |
| Measure models | `4lm bench [model…] [--context] [--json]` (omlx admin bench API) |
| Sub keys | `4lm key create <name>` / `list` / `revoke <name>` (omlx admin API on loopback) |
| Update probes | `4lm outdated` (PyPI / brew / HF); `4lm upgrade [brew\|models\|python]` to apply |
| Model picks | `4lm model recommend [<use-case>]` (uses `llmfit` + localmaxxing benchmarks) |
| Run all checks | `just check` |
| Run tests | `just test` (requires `bats-core`) |
| Mirror CI matrix locally | `just ci` (runs `ci-default` + `ci-backend-only`) |

## Daemon mode: pieces

`install.sh --service` runs as an existing account, and root adds
`/Library/LaunchDaemons/com.4lm.backend.plist` (`UserName`), a root-owned `/usr/local/bin/4lm` and
`/etc/newsyslog.d/4lm-daemon.conf`. The CLI switches on the system plist's presence
(`DAEMON_PLIST`, `FOURLM_DAEMON_PLIST` in tests; `tests/helpers/setup.bash` points it at a missing
file so the suite stays in GUI mode on a daemon host). The account cannot kickstart a system job,
which is why `service_kick` SIGTERMs the pid and lets `KeepAlive` respawn it.

## Installed profiles: drift

Since 2026-08-18 the installer prints a drift warning with the `diff` and `cp` commands when a repo
profile differs from the installed copy; the check below it reports profiles present under `~/.4lm`
that no longer exist in the repo.

## Profile switching

`4lm profile set <name>` validates the YAML, saves the previous profile name, swaps the symlink,
kickstarts the backend, and polls `/v1/models` for 30 s. On timeout it restores the previous symlink
and kickstarts again. A same-name re-issue re-renders `~/.omlx/model_settings.json` and re-stages
`~/.4lm/runtime/<profile>/models/` before kickstarting, so YAML edits propagate without a full
stop/start.

## Profiles

Each profile YAML carries a header comment with slot-by-slot rationale, memory math, when-to-use
and assumptions-to-validate. The VLM chat/main model reads images (`qwen3.8-27b` in `mid`,
`qwen3.8-flash-next` in `default`; `lean` has none). Backends: `omlx` (vLLM-style MLX, multi-model,
paged KV cache), `mlx_lm` (`python -m mlx_lm server`, single-model upstream), `ollama`
(llama.cpp/Metal).

## OpenWebUI feature toggles

`bin/4lm-webui-start.sh` exports a baseline of feature env vars for Claude-Desktop-style behaviour
on first launch:

- Memory (`ENABLE_MEMORIES`)
- DuckDuckGo web search (`ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=duckduckgo`)
- Pyodide code interpreter (`ENABLE_CODE_INTERPRETER`, `CODE_INTERPRETER_ENGINE=pyodide`)
- Follow-up + autocomplete suggestions
- RAG embeddings via omlx (`RAG_EMBEDDING_ENGINE=openai`, `RAG_EMBEDDING_MODEL=qwen3-embedding`,
  pointed at the local `:8000/v1`)
- RAG hybrid search + reranker via omlx (`ENABLE_RAG_HYBRID_SEARCH=True`,
  `RAG_RERANKING_ENGINE=external`, `RAG_EXTERNAL_RERANKER_URL` at the local `/v1/rerank`,
  `RAG_RERANKING_MODEL=qwen3-reranker`). omlx serves `POST /v1/rerank` in Cohere/Jina-compatible
  shape; OpenWebUI's `external` engine (verified in `open_webui/retrieval/models/external.py`)
  speaks that contract directly.

## Chat-template defaults by omlx version

On 0.6.0 (measured 2026-08-17, Qwen3.8-27B) `chat_template_kwargs` in `model_settings.json` had no
effect; on omlx main `f0d8428a` (measured 2026-09-29, Qwen3.8-Flash-Next) and on v0.7.0
(2026-10-02: the profile default produced the same output as an explicit `medium` in the request,
`xhigh` a different one) it does, so the profile field `reasoning_effort` renders it. A request's
own `chat_template_kwargs` still wins.

## omlx pin

pip records the resolved commit in the installed package's `direct_url.json`
(`vcs_info.commit_id`), and the installer force-reinstalls whenever that differs from
`OMLX_GIT_REF` or is missing. The version string cannot carry the pin: pipx drops the ref, and
commits between releases report the same version (main after `0.7.0rc1` still says `0.7.0rc1`).
The tests stub `jq`, so §9b reads the JSON with `grep`.

## omlx path probe

Phase 1 manual probe (2026-05): omlx does not accept absolute HF snapshot paths in
`model_settings.json`. Setting `model_path` to an absolute snapshot dir and starting
`omlx serve --model-dir <empty>` returns no models from `/v1/models`. The staging layer
(`stage_omlx_model_dir()` + `~/.4lm/runtime/<profile>/models/`) is therefore permanent; the TODO
comment in `stage_omlx_model_dir()` documents the probe outcome.
