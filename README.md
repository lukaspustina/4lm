# 4lm — Local LLM control plane for Apple Silicon

One MacBook. One command. A full Qwen3 stack, two daemons, zero Docker.

`4lm` runs `omlx` (MLX backend, default), `open-webui` (frontend), and
`opencode` (TUI client) under launchd, controlled by a single CLI.
Designed for a single engineer who wants their LLM stack to act like
`brew services` — except with profile switching, atomic rollback, and a
network-exposure command that refuses to bind to `0.0.0.0` without
`--confirm`. An `ollama` profile is bundled as a GGUF smoke test;
`mlx-coding` and `mlx-knowledge` are focused single-purpose tiers.

## What this is

- **One CLI for the whole stack.** `4lm start | stop | status | logs |
  profile set <name> | expose lan | opencode`. No tab-juggling, no
  systemd cosplay.
- **Profile-based model management.** The default profile runs the full
  Qwen3 stack on `omlx` — coder, chat, embedder, reranker, vision — all
  served from one process. Profiles switch atomically: validates the new
  profile, swaps the active symlink, polls `/v1/models` for 30 s, rolls
  back the symlink and restarts on failure.
- **launchd, but quiet.** Plists live in `~/.4lm/launchd/` — not
  `~/Library/LaunchAgents/`. After every reboot the stack is stopped.
  You start it when you want it, or opt in via `4lm autostart enable`.
- **`expose lan` is two-factor.** Refuses without `--confirm`. Security
  hardening applies in all modes: persistent `WEBUI_SECRET_KEY` (mode 0600),
  `WEBUI_REGISTRATION_ENABLED=false`, `DEFAULT_USER_ROLE=pending`.
  Tailscale is still the better answer.
- **WebUI is preconfigured for daily use.** DuckDuckGo web search, Pyodide
  code interpreter, personal memory, follow-up + autocomplete suggestions,
  and file-upload RAG — all on by default. RAG embeddings are served by the
  same omlx backend (`mlx-community/Qwen3-Embedding-8B-4bit-DWQ`, exposed
  as `qwen3-embedding`), so file upload works fully offline.
- **Honest sanity sweep.** `4lm doctor` checks prereqs and smoke-tests
  inference if the backend is running; `4lm diag` surfaces live clients,
  in-flight work, and top CPU consumers. The wired-memory threshold for
  80B-class models is enforced at install time via `iogpu.wired_limit_mb`.
- **Idempotent installer.** `make install` writes the sudoers rule the
  backend wrapper needs, sets the wired-memory limit, seeds
  `network.yaml` and `~/.config/opencode/opencode.jsonc`, hooks up
  `newsyslog`, and pipx-installs each dep into a `python@3.12` venv —
  every step is a no-op on the second run.

## What this isn't

- Not a multi-user server. Single-user, single-host, single login session.
- Not a Docker or pip-into-system-Python project. PEP 668 is honoured
  via pipx; Python 3.12 is pinned for compatibility with the MLX ecosystem.
- Not auto-starting. After reboot you run `4lm start`. On purpose — a
  70 GB working set is not something you want sneaking onto the wired
  memory list before you've made coffee.

## TL;DR

```sh
make bootstrap    # brew core: shellcheck, shfmt, bats-core, jq, python@3.12, pipx, llmfit, ollama (+ opencode via Brewfile-tui)
make install      # ~/.4lm/, sudoers, sysctl, pipx-installed deps, log rotation, opencode config
make models       # ~140 GB of weights from HuggingFace (idempotent; the same target updates)
4lm start         # bootstrap launchd agents
4lm opencode      # daily driver
```

After a reboot: `4lm start`. There's no autostart and that's a feature.

### Backend-only install (headless LAN server)

Use `--backend-only` to provision this Mac as a pure `/v1/*` inference
server for other hosts on the LAN — no WebUI, no `opencode`:

```sh
./install.sh --backend-only && 4lm start && 4lm expose lan --confirm
```

Skips `open-webui` (pipx), the webui plist, the webui wrapper, the
`opencode` brew formula, and the seeded opencode config.
`make bootstrap BACKEND_ONLY=1` and `make install BACKEND_ONLY=1` are
the env-var equivalents. See [`docs/setup.md`](docs/setup.md) for the
consumer-host wiring (`OPENAI_API_BASE_URL`).

## Architecture

```
                       4lm  (single control command)
                              │ bootstrap / bootout / kickstart
                              ▼
        ┌──────────────────────────────────┐    ┌──────────────────────────────────┐
        │ com.4lm.backend    │    │ com.4lm.webui      │
        │   omlx | mlx_lm | ollama        │    │   open-webui serve               │
        │   :8000 (OpenAI API)             │←───│   :3000 (Web UI)                 │
        └──────────────────────────────────┘    └──────────────────────────────────┘
                  ▲                                ▲
                  │ HTTP                           │ HTTP (browser)
            ┌─────┴────┐                     ┌─────┴────┐
            │ OpenCode │                     │  Safari  │
            │   TUI    │                     │  Chrome  │
            └──────────┘                     └──────────┘
```

The backend is the source of truth. WebUI is a stateless frontend
proxying to it. OpenCode talks directly to `:8000/v1`. None of them
know or care about each other; the OpenAI-compatible API is the seam.

In `--backend-only` mode (see TL;DR), the WebUI block above is absent on
disk — `bin/4lm` probes for the plist and treats the layer as not
installed. Consumer hosts on the LAN run their own OpenWebUI / opencode
against the backend's `:8000/v1`.

## Components

| Layer | Project | Pinned at | Lifecycle |
|---|---|---|---|
| Inference | `omlx` (primary MLX) | git (pipx) | python@3.12 venv |
| Inference | `mlx_lm` (upstream MLX) | via omlx venv | co-installed with omlx |
| Inference | `ollama` (GGUF/llama.cpp) | homebrew | brew formula |
| Web UI | `open-webui` | 0.9.2 (pipx) | python@3.12 venv |
| HF cache CLI | `huggingface_hub[cli]` | 1.14.0 (pipx) | python@3.12 venv |
| TUI client | `opencode` | homebrew/core | brew formula |
| Daemons | launchd user agents | — | `launchctl bootstrap` via `4lm start` |
| Config | profiles + `network.yaml` | — | atomic profile switch with rollback |

## Common operations

```sh
# Profile switching (atomic, validated, rollback on failure)
4lm profile list
4lm profile set mlx-coding

# Check for newer versions across PyPI / Homebrew / HuggingFace
4lm outdated

# Apply updates across all channels
4lm upgrade                     # everything pending
4lm upgrade brew                # all pending Homebrew
4lm upgrade brew opencode       # just one formula
4lm upgrade models              # all pending HF model repos
4lm upgrade models org/repo     # just one repo
4lm upgrade python              # bump requirements.txt + pipx reinstall

# Review Python bumps before committing
git diff requirements.txt && git add requirements.txt && git commit -m "chore(deps): bump ..."

# After a crash
4lm logs backend
4lm restart backend

# Sanity sweep (prereqs: sudoers, plists, CLI binaries)
4lm doctor

# Why are the fans on? (live clients, recent inference, top CPU consumers)
4lm diag

# Models
make models                     # download/update everything in config/profiles/
make models-list                # what's in ~/.cache/huggingface/hub/
make models-clean               # prune orphaned revisions
make models-rm MODEL=foo/bar    # remove one specific repo

# Network exposure (refuses without --confirm)
4lm expose lan --confirm        # 0.0.0.0
4lm expose local --confirm      # 127.0.0.1

# Removal
4lm uninstall                   # bootout + remove ~/.local/bin/4lm (keeps ~/.4lm/)
make uninstall                  # full: bootout, ~/.4lm/, sudoers/newsyslog, pipx packages
```

## File layout

```
~/.4lm/
├── bin/                         control + wrappers (called by launchd)
├── launchd/                     com.4lm.{backend,webui}.plist
├── config/
│   ├── active-profile           symlink → profiles/<active>.yaml
│   ├── previous-profile         plain text, used for rollback
│   ├── network.yaml             bind mode + ports
│   ├── webui_secret_key         mode 0600, generated on first lan-mode start
│   └── profiles/                lean.yaml, default.yaml, max-100gb.yaml, mlx-coding.yaml, mlx-knowledge.yaml, ollama.yaml
├── logs/                        backend.log, webui.log (merged stdout+stderr)
└── openwebui-data/              Open WebUI database, settings, RAG index

~/.local/bin/4lm                 symlink to ~/.4lm/bin/4lm
~/.config/opencode/opencode.jsonc  seeded by install.sh from the repo template
/etc/sudoers.d/4lm-stack         NOPASSWD for the backend's sysctl call
/etc/newsyslog.d/4lm.conf        log rotation (10 MB, 7 generations, gzipped)
```

## Model history

### v0.1.x — Initial model set

| Slot | Model | Role |
|---|---|---|
| Build | `mlx-community/GLM-4.7-Flash-8bit` | Fast code edits, low-latency tool calls |
| Plan/Knowledge | `unsloth/Qwen3.6-35B-A3B-MLX-8bit` | Architecture reasoning, vault synthesis |
| Heavy (on-demand) | `LibraxisAI/gpt-oss-120b-mlx-mxfp4` | Deep reasoning, on-demand |

### v0.2.0 — Qwen3 thinking-loop fix

**Problem.** Both GLM-4.7-Flash and Qwen3.6-35B-A3B have `reasoning_parser`
entries in the mlx-openai-server profile, which tells the server to use the
thinking-mode chat template and extract `<think>` blocks. In agentic sessions
(OpenCode multi-step edits, tool call chains) both models looped indefinitely
inside their reasoning output — GLM with token-level repetition, Qwen3 with
deliberation cycles that never resolved.

Root cause: the Qwen3 Jinja chat template defaults `enable_thinking` to `true`
unless the request explicitly passes `enable_thinking=false` inside a
`chat_template_kwargs` object. OpenCode's `@ai-sdk/openai-compatible` provider
cannot send nested objects this way — it puts all model options at the top
level of the request body, where mlx-openai-server ignores them as unknown
fields.

**Fix.** `config/qwen3-no-think.jinja` is a copy of the model's Jinja template
with one logical change: the `enable_thinking` default is inverted. Instead of
activating `<think>` unless told otherwise, it skips `<think>` unless the
request explicitly passes `enable_thinking=true`. The profiles reference this
template via `chat_template_file`. `reasoning_parser: qwen3` is removed from
all Qwen3 profile entries (keeping it would re-enable the thinking template).
`default_max_tokens: 8192` and `default_repetition_penalty: 1.15` were also
added to all model entries as server-side safety nets against runaway
generation.

This state is tagged **v0.2.0**.

### v0.3.0 — Migration to Qwen3-Coder-30B-A3B + Qwen3.6-27B

**Why switch.**

| Slot | From | To | Reason |
|---|---|---|---|
| Build | GLM-4.7-Flash | `Qwen3-Coder-30B-A3B` | Coder models never emit `<think>` by design — RL-trained on SWE-bench-style execution trajectories. The Jinja workaround becomes unnecessary for this slot. Same ~3B active params and token throughput as GLM. |
| Plan/Knowledge | Qwen3.6-35B-A3B | `Qwen3.6-27B` | Dense 27B beats the MoE 35B-A3B on every benchmark: SWE-bench Verified 77.2% vs 73.4%, LiveCodeBench 83.9%, GPQA 87.8%. Dense architecture also avoids the MoE consistency drift that can appear on long agentic chains. Uses ~17 GB at 4-bit vs ~22 GB for the 35B-A3B. |

**Why the config modifications are no longer needed for Qwen3-Coder.**
The Qwen3-Coder model card states explicitly: *"Supports only non-thinking
mode — does not generate `<think></think>` blocks. `enable_thinking=False`
is no longer required."* The model was trained without a reasoning mode at
all. No template override, no parser suppression, no API parameters — it
simply never thinks.

`config/qwen3-no-think.jinja` is kept in the repo because Qwen3.6-27B in the
plan/knowledge slot still defaults to thinking mode. The template continues to
serve that slot. The `default_max_tokens` and `default_repetition_penalty`
server-side defaults remain as belt-and-suspenders for all models.

**Memory.** Apple M5 Max with 128 GB unified memory:
Qwen3-Coder-30B-A3B (~18 GB at 4-bit) + Qwen3.6-27B (~17 GB at 4-bit) =
~35 GB always-on. GPT-OSS-120B loads on-demand into the remaining ~93 GB.

### v0.4 / v0.5 — Backend pivot to omlx, autostart, single MLX backend

`mlx-openai-server` is removed; `omlx` becomes the sole MLX backend
(vLLM-style: paged KV cache, continuous batching, multi-model
EnginePool, DFlash speculative decoding). `4lm autostart enable|disable|
status` adds opt-in login autostart per service. `mlx_lm` and `ollama`
remain available as alternative backends through the profile schema.

### v0.6 — Full Qwen3 stack + lean/max-100gb tiers

The `default` profile expands from coder+chat to the full Qwen3 stack
on one omlx process: coder (Qwen3-Coder-Next 80B), chat (Qwen3.6-35B-A3B),
embedder (Qwen3-Embedding-8B), reranker (Qwen3-Reranker-0.6B), vision
(Qwen3-VL-8B). New tiers: `lean` (~40 GB working set, swaps the coder
down to 30B-A3B) and `max-100gb` (~92 GB, swaps chat up to Qwen3-Next-80B
and reranker up to 4B). All omlx profiles share `qwen3-embedding` /
`qwen3-reranker` served-model names, so knowledge bases stay valid
across profile switches.

## Documentation

- [`docs/setup.md`](docs/setup.md) — operator runbook (sudoers, troubleshooting, model pulls)
- [`docs/profile-schema.md`](docs/profile-schema.md) — YAML key reference for all backends
- [`specs/done/sdd/4lm-rework-2026-05-09.md`](specs/done/sdd/4lm-rework-2026-05-09.md) — the archived design doc this repo implements
- [`CLAUDE.md`](CLAUDE.md) — orientation for AI assistants working in this repo

## Development

```sh
make bootstrap    # one-time: Brewfile + pipx ensurepath
make lint         # shellcheck + shfmt -d
make fmt          # shfmt -w
make test         # bats tests/
make check        # everything; CI runs this on macos-latest
```

CI on every PR (`.github/workflows/ci.yml`):
`shellcheck`, `shfmt -d`, `bash -n`, `plutil -lint`, `xmllint --noout`,
profile YAML validation, bats suite — all of it driven by `make check`.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck` clean, `shfmt -i 2 -ci`.
- Plists carry `__HOME__` placeholders, substituted by `install.sh`.
- Profiles validated by `validate_profile()` in `bin/4lm` (regex name
  whitelist, schema check, parser-enum match against the upstream
  `--tool-call-parser` choices).
- Conventional-commit prefixes (`feat:`, `fix:`, `refactor:`, `chore:`,
  `docs:`, `test:`); subject ≤ 72 chars.
- No `Co-Authored-By: Claude` lines.
- Formatting-only changes ship in their own commits.
