# 4lm — Local LLM control plane for Apple Silicon

[![CI](https://github.com/lukaspustina/4lm/actions/workflows/ci.yml/badge.svg)](https://github.com/lukaspustina/4lm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/lukaspustina/4lm?sort=semver)](https://github.com/lukaspustina/4lm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)
[![Platform: macOS · Apple Silicon](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Apple%20Silicon-blue)](#quickstart)

**A local LLM stack you don't have to babysit.**

Your Mac. Or a Mac in your closet. Either way, one command.
Your hardware, your data, no metered bill.

Running multiple local LLMs on Apple Silicon means juggling ~140 GB
of weights, wired-memory limits, profile YAMLs, and Open WebUI config
drift. You end up administering the stack instead of using it.

`4lm` is the CLI that refuses to let that happen.

## Two shapes

One installer, one CLI, two ways to run it.

### Workstation — your Mac IS the LLM

```sh
./install.sh           # omlx + Open WebUI + opencode TUI
4lm start
open http://localhost:3000   # register your admin account here, first
4lm opencode                 # daily driver
```

Open WebUI on `http://localhost:3000` with RAG, web search, code
interpreter, and memory wired in by default. `opencode` in your
terminal, pointed at the local `/v1`. Your laptop is the assistant.

> **Register your WebUI admin account before doing anything else.** New
> accounts default to the `pending` role with no privileges, and
> registration is locked after the first user. If you skip this and
> later run `4lm expose lan --confirm` on a network you don't fully
> control, you can lock yourself out.

### Appliance — a Mac in your closet serves the LAN

```sh
./install.sh --backend-only   # skips Open WebUI + opencode
4lm start
4lm expose lan --confirm
```

Headless OpenAI-compatible `/v1/*` API on the LAN. Other machines run
their own clients (`opencode`, Open WebUI, Continue.dev — anything that
speaks `/v1`) pointed at `http://<host>:8000`. The Mac Studio in the
closet does the inference; the Air on the couch does the typing.

> **The backend has no auth.** Anyone who can reach `:8000` on your LAN
> can call `/v1/*`. Use this on a network you trust, or front it with
> Tailscale (or another VPN that does authenticate).

## What it refuses to do

- **Never auto-starts after reboot.** A 70 GB working set should not
  sneak onto wired memory before you've made coffee. Plists live in
  `~/.4lm/launchd/` — launchd never finds them unless `4lm start`
  says so. Opt in with `4lm autostart enable` if you want it.
- **Never binds to LAN without `--confirm`.** No env-var bypass, no
  config typo, no *"I thought it was already local."* `4lm expose lan`
  is a deliberate two-step. (Tailscale is still the better answer.)
- **Never silently breaks profile switches.** `4lm profile set <name>`
  validates the YAML → swaps the active symlink → polls `/v1/models`
  for 30 s → on timeout, restores the previous symlink and re-polls.
  Bad YAML never kills the stack.
- **Never invalidates your knowledge base across profiles.** Every
  omlx profile serves the embedder as `qwen3-embedding` and the
  reranker as `qwen3-reranker`. Switch from `default` (65 GB) to
  `lean` (40 GB) to `max-100gb` (92 GB) — the same RAG index keeps
  working. Switch profiles like you switch branches.
- **Never lets you OOM silently.** `install.sh` enforces
  `iogpu.wired_limit_mb=98304` via sudoers + sysctl. `4lm doctor`
  smoke-tests inference. `4lm diag` shows what's actually running
  when the fans spin up.

## What it actually does

- **One CLI**, three backends behind one OpenAI-compatible `/v1`
  seam — `omlx` (default; vLLM-style MLX, paged KV cache, multi-model
  EnginePool), `mlx_lm` (upstream MLX, single-model), `ollama`
  (GGUF/llama.cpp). Clients don't know or care which is running.
- **Atomic profile switching with bounded rollback** (above).
- **Same-name reissue = live config reload.** Edit a profile YAML
  and re-run `4lm profile set <same-name>` — re-renders
  `model_settings.json`, re-stages model symlinks, kickstarts the
  backend. No full stop/start.
- **Open WebUI, preconfigured for daily use.** DuckDuckGo web search,
  Pyodide code interpreter, personal memory, follow-up + autocomplete
  suggestions, file-upload RAG. Embeddings + reranker served by the
  same omlx backend → no second service, no cloud calls, fully offline.
  (Most of these settings are PersistentConfig: copied into `webui.db`
  on first init only — after that the admin UI is source of truth.
  Toggles in the admin panel survive restarts; env-var changes do not.)
- **Idempotent install / upgrade / uninstall.** Every step is a
  no-op on re-run: sudoers, sysctl, newsyslog, pipx, opencode config.
  Re-running `--backend-only` over a full install does not strip the
  WebUI; re-running the full installer over `--backend-only` upgrades
  cleanly.
- **Visibility commands.** `4lm doctor` (prereqs + smoke-test
  inference), `4lm diag` (live clients, in-flight requests, top CPU
  consumers), `4lm outdated` / `4lm upgrade` (PyPI + Homebrew + HF).

## Quickstart

```sh
make bootstrap   # Brewfile + Brewfile-tui (skipped if BACKEND_ONLY=1)
                 # core: shellcheck, shfmt, bats-core, jq, python@3.12,
                 # pipx, llmfit, ollama; tui extra: opencode
make install     # ~/.4lm/, sudoers, sysctl, pipx-installed deps,
                 # log rotation, opencode config
make models      # ~140 GB from HuggingFace (idempotent; same target updates)
4lm start        # bootstrap launchd agents
4lm opencode     # daily driver (alias: 4lm code)
```

> **64 GB Macs: switch to the `lean` profile first** —
> `4lm profile set lean` before `make models`. The `default` profile
> wants 96 GB+ steady; `lean` fits in 40 GB and downloads ~80 GB instead
> of ~140 GB. `4lm doctor` will warn you if the active profile doesn't
> fit your hardware.

After a reboot: `4lm start`. There's no autostart and that's a feature.

Backend-only variant:

```sh
make bootstrap BACKEND_ONLY=1   # skips opencode brew formula
./install.sh --backend-only     # skips Open WebUI + opencode + their plists/configs
4lm start && 4lm expose lan --confirm
```

See [`docs/setup.md`](docs/setup.md) for the operator runbook,
including the `OPENAI_API_BASE_URL` wiring for consumer hosts on
the LAN.

## Profile lineup

Six profiles. The three Qwen3-stack tiers share an 8B embedder so
knowledge bases stay valid across switches.

| Profile         | Backend | Coder                   | Chat            | Embed | Rerank | Vision | Steady | Fits on |
|-----------------|---------|-------------------------|-----------------|-------|--------|--------|--------|---------|
| `lean`          | omlx    | Qwen3-Coder-30B-A3B     | Qwen3.6-35B-A3B | 8B    | 0.6B   | —      | ~40 GB | 64 GB+  |
| `default`       | omlx    | Qwen3-Coder-Next (80B)  | Qwen3.6-35B-A3B | 8B    | 0.6B   | VL-8B  | ~65 GB | 96 GB+  |
| `max-100gb`     | omlx    | Qwen3-Coder-Next (80B)  | Qwen3-Next-80B  | 8B    | 4B     | VL-8B  | ~92 GB | 128 GB  |
| `mlx-coding`    | omlx    | Qwen3-Coder-Next (80B)  | —               | —     | —      | —      | ~42 GB | 64 GB+  |
| `mlx-knowledge` | omlx    | —                       | Qwen3.6-35B-A3B | 8B    | 0.6B   | —      | ~23 GB | 36 GB+  |
| `ollama`        | ollama  | qwen3-coder-next:q4_K_M | —               | —     | —      | —      | ~22 GB | 36 GB+  |

**Memory math for `default` on a 128 GB Mac.** Qwen3-Coder-Next 80B
(~42 GB 4-bit) + Qwen3.6-35B-A3B (~12 GB) + Qwen3-Embedding-8B
(~5 GB) + Qwen3-Reranker-0.6B (~0.4 GB) + Qwen3-VL-8B (~5 GB) ≈
65 GB steady. Both 80B-class models are MoE → ~3B active params each
→ KV cache and batched decoding fit comfortably in the remaining
~33 GB of the wired-memory budget.

The everyday ladder is `lean` → `default` → `max-100gb`. `mlx-coding`
strips everything except the 80B coder so long agentic sessions get
maximum KV-cache headroom. `mlx-knowledge` is the text-only vault-
synthesis tier. `ollama` is the GGUF smoke test — switch to it
occasionally to confirm Ollama still works, then switch back.

Each profile YAML carries an extensive header comment documenting
slot-by-slot rationale, memory math, when-to-use, and
assumptions-to-validate.

## Architecture

```
                       4lm  (single control command)
                              │ bootstrap / bootout / kickstart
                              ▼
        ┌──────────────────────────────────┐    ┌──────────────────────────────────┐
        │ com.4lm.backend                  │    │ com.4lm.webui                    │
        │   omlx | mlx_lm | ollama         │    │   open-webui serve               │
        │   :8000 (OpenAI API)             │←───│   :3000 (Web UI)                 │
        └──────────────────────────────────┘    └──────────────────────────────────┘
                  ▲                                ▲
                  │ HTTP                           │ HTTP (browser)
            ┌─────┴────┐                     ┌─────┴────┐
            │ opencode │                     │  Safari  │
            │   TUI    │                     │  Chrome  │
            └──────────┘                     └──────────┘
```

The backend is the source of truth. Open WebUI is a stateless
frontend proxying to it. `opencode` talks directly to `:8000/v1`.
None of them know or care about each other → the OpenAI-compatible
API is the seam.

In `--backend-only` mode the WebUI block is absent on disk; `bin/4lm`
probes for the plist and treats the layer as not installed. Consumer
hosts on the LAN run their own clients against the backend's
`:8000/v1`.

## Common operations

```sh
# Lifecycle
4lm start | stop | restart [backend|webui|all]
4lm                                # status (alias for `4lm status`; --json for parseable)
4lm logs [backend|webui]           # tail -F

# Profiles
4lm profile list
4lm profile set <name>             # atomic, validated, rollback on failure
4lm profile show [<name>]          # YAML of active (or named) profile
4lm profile validate [--all]

# Models
make models                        # download/update everything in config/profiles/
4lm model list                     # what's loaded vs cached
4lm model recommend [<use-case>]   # top picks via llmfit + localmaxxing benchmarks

# Updates
4lm outdated                       # check PyPI / Homebrew / HF
4lm upgrade [brew|models|python]   # apply pending updates

# Diagnostics
4lm doctor                         # prereqs + smoke-test inference
4lm diag                           # live clients, in-flight inference, top CPU

# Network exposure (refuses without --confirm)
4lm expose lan --confirm
4lm expose local --confirm

# Autostart at login (off by default)
4lm autostart enable [backend|webui|all]
4lm autostart disable [backend|webui|all]
4lm autostart status

# Removal
4lm uninstall                      # bootout, remove ~/.local/bin/4lm; keep ~/.4lm/
make uninstall                     # full: bootout, ~/.4lm/, sudoers, newsyslog, pipx packages
```

Every command has `--help`.

## File layout

```
~/.4lm/
├── bin/                   control + wrappers (called by launchd)
├── launchd/               com.4lm.{backend,webui}.plist
├── config/
│   ├── active-profile     symlink → profiles/<active>.yaml
│   ├── previous-profile   plain text, used for rollback
│   ├── network.yaml       bind mode + ports (single config channel)
│   ├── webui_secret_key   mode 0600, generated on first lan-mode start
│   └── profiles/          lean / default / max-100gb / mlx-coding /
│                          mlx-knowledge / ollama YAMLs
├── logs/                  backend.log, webui.log (merged stdout+stderr)
└── openwebui-data/        Open WebUI db, settings, RAG index

~/.local/bin/4lm                   symlink to ~/.4lm/bin/4lm
~/.config/opencode/opencode.jsonc  seeded by install.sh from the repo template
/etc/sudoers.d/4lm-stack           NOPASSWD for the backend's sysctl call
/etc/newsyslog.d/4lm.conf          log rotation (10 MB, 7 generations, gzipped)
```

## What this isn't

- Not a multi-user server. Single-user, single-host, single login session.
- Not a Docker or pip-into-system-Python project. PEP 668 is honoured
  via pipx; Python 3.12 is pinned for compatibility with the MLX ecosystem.
- Not auto-starting. After reboot you run `4lm start`. On purpose.
- Not a cloud-fallback router. If the local stack fails, fall back by
  hand; 4lm does not silently route to Anthropic, OpenAI, or anyone else.

## Where this is going

Today: best Apple Silicon models, fastest local inference, a
Claude-Desktop-shaped Open WebUI in front of it. Next: tool calling
+ MCP so local models can *use* Open WebUI's tools (web search, RAG,
code interpreter, memory) instead of hallucinating them — and reach
toward Claude-Desktop feature parity. The phased roadmap lives in
[`specs/sdd/webui-tools-and-mcp.md`](specs/sdd/webui-tools-and-mcp.md).
Foundation is shipped at v0.6; agentic phases are draft.

## Development

```sh
make bootstrap    # one-time: Brewfile + Brewfile-tui + pipx ensurepath
make lint         # shellcheck + shfmt -d
make fmt          # shfmt -w
make test         # bats + pytest
make check        # everything; CI runs this on macos-latest
make ci           # mirror the CI matrix locally (default + backend-only legs)
```

CI on every PR (`.github/workflows/ci.yml`):
`shellcheck`, `shfmt -d`, `bash -n`, `plutil -lint`, `xmllint --noout`,
profile YAML validation, bats suite — both install modes — driven by
`make check`.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck` clean, `shfmt -i 2 -ci`.
- Plists carry `__HOME__` placeholders, substituted by `install.sh`.
- Profiles validated by `validate_profile()` in `bin/4lm` (regex name
  whitelist, schema check, parser-enum match against backend defaults).
- Conventional-commit prefixes (`feat:`, `fix:`, `refactor:`, `chore:`,
  `docs:`, `test:`); subject ≤ 72 chars.
- No `Co-Authored-By: Claude` lines.
- Formatting-only changes ship in their own commits.

## Model history (short)

4lm migrated through `mlx-openai-server` → `mlx_lm` → `omlx` as Apple
Silicon MLX tooling matured. The initial model set (GLM-4.7-Flash +
Qwen3.6-35B-A3B) gave way to Qwen3-Coder + Qwen3.6-27B in v0.3 after
the Qwen3 thinking-loop bug forced a custom Jinja workaround. v0.6
consolidates onto the full Qwen3 stack (coder + chat + embed + rerank
+ vision) on a single omlx process. Per-version detail and the
thinking-mode template story live in [`CHANGELOG.md`](CHANGELOG.md).

## Credits

4lm is glue around several upstream projects that do the actual heavy
lifting. Go give them stars:

- [**omlx**](https://github.com/jundot/omlx) — vLLM-style MLX inference
  server with paged KV cache, continuous batching, and multi-model
  EnginePool. Primary backend.
- [**mlx_lm**](https://github.com/ml-explore/mlx-lm) — Apple's reference
  MLX language-model library. Alternative single-model backend.
- [**Ollama**](https://github.com/ollama/ollama) — llama.cpp + Metal
  GGUF serving. Smoke-test backend.
- [**Open WebUI**](https://github.com/open-webui/open-webui) — the
  frontend. Without their PersistentConfig surface this stack would be
  half the experience.
- [**opencode**](https://github.com/sst/opencode) — the TUI client.
- [**Qwen team @ Alibaba**](https://github.com/QwenLM) — the model
  family carrying the default profile (Qwen3-Coder, Qwen3.6,
  Qwen3-Embedding, Qwen3-Reranker, Qwen3-VL). Apache-2.0 licensed.
- [**llmfit**](https://github.com/lukaspustina/llmfit) +
  [**localmaxxing.com**](https://localmaxxing.com) — hardware-fit
  scoring and community benchmarks used by `4lm model recommend`.

## License

[MIT](LICENSE).

## Documentation

- [`docs/setup.md`](docs/setup.md) — operator runbook (sudoers, troubleshooting, model pulls, LAN client wiring)
- [`docs/profile-schema.md`](docs/profile-schema.md) — YAML key reference for all backends
- [`docs/autostart.md`](docs/autostart.md) — opt-in login autostart mechanics
- [`specs/sdd/webui-tools-and-mcp.md`](specs/sdd/webui-tools-and-mcp.md) — active SDD for tool calling + MCP
- [`specs/done/sdd/4lm-rework-2026-05-09.md`](specs/done/sdd/4lm-rework-2026-05-09.md) — archived design doc this repo implements
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — dev setup, commit style, PR checklist
- [`SECURITY.md`](SECURITY.md) — threat model + vulnerability reporting
- [`CLAUDE.md`](CLAUDE.md) — orientation for AI assistants working in this repo
