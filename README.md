# 4lm — Local LLM control plane for Apple Silicon

One MacBook. One command. Two models, two daemons, zero Docker.

`4lm` runs Ollama (default backend), `open-webui` (frontend), and
`opencode` (TUI client) under launchd, controlled by a single CLI.
Designed for a single engineer who wants their LLM stack to act like
`brew services` — except with profile switching, atomic rollback, and a
network-exposure command that refuses to bind to `0.0.0.0` without
`--confirm`. MLX profiles (`mlx-coding`, `mlx-knowledge`) are available
for Apple Silicon acceleration when Ollama's overhead matters.

## What this is

- **One CLI for the whole stack.** `4lm start | stop | status | logs |
  profile set <name> | expose lan | opencode`. No tab-juggling, no
  systemd cosplay.
- **Profile-based model management.** The default profile runs two
  Ollama models (coder + chat); MLX profiles offer additional slots.
  Profiles switch atomically: validates the new profile, swaps the
  active symlink, polls `/v1/models` for 30 s, rolls back the symlink
  and restarts on failure.
- **launchd, but quiet.** Plists live in `~/.4lm/launchd/` — not
  `~/Library/LaunchAgents/`. After every reboot the stack is stopped.
  You start it when you want it.
- **`expose lan` is two-factor.** Refuses without `--confirm`. Security
  hardening applies in all modes: persistent `WEBUI_SECRET_KEY` (mode 0600),
  `WEBUI_REGISTRATION_ENABLED=false`, `DEFAULT_USER_ROLE=pending`.
  Tailscale is still the better answer.
- **Honest health check.** `4lm health` exits 1 if
  `iogpu.wired_limit_mb` is below the threshold the 80B-class models
  actually need.
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
make bootstrap    # brew: shellcheck, shfmt, bats-core, python@3.12, pipx, opencode
make install      # ~/.4lm/, sudoers, sysctl, pipx-installed deps, log rotation, opencode config
make models       # ~140 GB of weights from HuggingFace (idempotent; the same target updates)
4lm start         # bootstrap launchd agents
4lm opencode      # daily driver
```

After a reboot: `4lm start`. There's no autostart and that's a feature.

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

## Components

| Layer | Project | Pinned at | Lifecycle |
|---|---|---|---|
| Inference | `omlx` (primary MLX) | git (pipx) | python@3.12 venv |
| Inference | `mlx_lm` (upstream MLX) | via omlx venv | co-installed with omlx |
| Inference | `ollama` (GGUF/llama.cpp) | homebrew | brew formula |
| Web UI | `open-webui` | 0.9.2 (pipx) | python@3.12 venv |
| HF cache CLI | `huggingface_hub[cli]` | 1.13.0 (pipx) | python@3.12 venv |
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
│   └── profiles/                default.yaml, mlx-coding.yaml, mlx-knowledge.yaml, exp-*.yaml
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

## Documentation

- [`docs/setup.md`](docs/setup.md) — operator runbook (sudoers, troubleshooting, model pulls)
- [`docs/profile-schema.md`](docs/profile-schema.md) — YAML key reference for all backends
- [`specs/sdd/4lm-rework.md`](specs/sdd/4lm-rework.md) — the design doc this repo implements
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
