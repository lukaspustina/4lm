---
layout: default
title: 4lm — Local LLM control plane for Apple Silicon
description: One command, your hardware, your data, no metered bill. Run a full local LLM stack on Apple Silicon without administering it.
---

**A local LLM stack you don't have to babysit.**

Your Mac. Or a Mac in your closet. Either way, one command.
Your hardware, your data, no metered bill.

Running multiple local LLMs on Apple Silicon means juggling ~140 GB of
weights, wired-memory limits, profile YAMLs, and Open WebUI config
drift. You end up administering the stack instead of using it.

`4lm` is the CLI that refuses to let that happen.

[Get it on GitHub](https://github.com/lukaspustina/4lm){: .btn }
[Setup runbook](https://github.com/lukaspustina/4lm/blob/main/docs/setup.md){: .btn }
[Profile schema](https://github.com/lukaspustina/4lm/blob/main/docs/profile-schema.md){: .btn }

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

## What it refuses to do

- **Never auto-starts after reboot.** A 70 GB working set should not
  sneak onto wired memory before you've made coffee. Opt in with
  `4lm autostart enable` if you want it.
- **Never binds to LAN without `--confirm`.** No env-var bypass, no
  config typo, no *"I thought it was already local."* `4lm expose lan`
  is a deliberate two-step.
- **Never silently breaks profile switches.** `4lm profile set <name>`
  validates the YAML → swaps the active symlink → polls `/v1/models`
  for 30 s → on timeout, restores the previous symlink and re-polls.
  Bad YAML never kills the stack.
- **Never invalidates your knowledge base across profiles.** Every
  omlx profile serves the embedder as `qwen3-embedding` and the
  reranker as `qwen3-reranker`. Switch tiers without reindexing.
- **Never lets you OOM silently.** `install.sh` enforces
  `iogpu.wired_limit_mb=98304` via sudoers + sysctl. `4lm doctor`
  smoke-tests inference; `4lm diag` shows what's actually running.

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

The everyday ladder is `lean` → `default` → `max-100gb`. `mlx-coding`
strips everything except the 80B coder for long agentic sessions.
`mlx-knowledge` is the text-only vault-synthesis tier. `ollama` is
the GGUF smoke test.

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
None of them know or care about each other — the OpenAI-compatible
API is the seam.

## Quickstart

```sh
make bootstrap   # Brewfile + Brewfile-tui (skipped if BACKEND_ONLY=1)
make install     # ~/.4lm/, sudoers, sysctl, pipx deps, log rotation
make models      # ~140 GB from HuggingFace (idempotent)
4lm start        # bootstrap launchd agents
4lm opencode     # daily driver
```

> **64 GB Macs: switch to the `lean` profile first** —
> `4lm profile set lean` before `make models`. `lean` fits in 40 GB
> and downloads ~80 GB instead of ~140 GB.

After a reboot: `4lm start`. There's no autostart and that's a feature.

## Where to go next

- **[README](https://github.com/lukaspustina/4lm/blob/main/README.md)** — the full pitch, command reference, file layout
- **[Setup runbook](https://github.com/lukaspustina/4lm/blob/main/docs/setup.md)** — operator details, troubleshooting, LAN client wiring
- **[Profile schema](https://github.com/lukaspustina/4lm/blob/main/docs/profile-schema.md)** — YAML key reference
- **[Autostart](https://github.com/lukaspustina/4lm/blob/main/docs/autostart.md)** — opt-in login autostart mechanics
- **[CHANGELOG](https://github.com/lukaspustina/4lm/blob/main/CHANGELOG.md)** — version history
- **[SECURITY](https://github.com/lukaspustina/4lm/blob/main/SECURITY.md)** — threat model + vulnerability reporting

[MIT licensed](https://github.com/lukaspustina/4lm/blob/main/LICENSE). Built on
[omlx](https://github.com/jundot/omlx),
[mlx_lm](https://github.com/ml-explore/mlx-lm),
[Ollama](https://github.com/ollama/ollama),
[Open WebUI](https://github.com/open-webui/open-webui),
[opencode](https://github.com/sst/opencode), and the
[Qwen3 model family](https://github.com/QwenLM).
