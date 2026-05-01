# 4lm — Local LLM control plane for Apple Silicon

One MacBook. One command. Three model slots, two daemons, zero Docker.

`4lm` runs `mlx-openai-server` (backend), `open-webui` (frontend), and
`opencode` (TUI client) under launchd, controlled by a single CLI.
Designed for a single engineer who wants their LLM stack to act like
`brew services` — except with profile switching, atomic rollback, and a
network-exposure command that refuses to bind to `0.0.0.0` without
`--confirm`.

## What this is

- **One CLI for the whole stack.** `4lm start | stop | status | logs |
  profile set <name> | expose lan | opencode`. No tab-juggling, no
  systemd cosplay.
- **Three model slots, one YAML.** Build / Plan-Knowledge /
  Heavy-Reasoning, switched atomically: validates the new profile,
  swaps the active symlink, polls `/v1/models` for 30 s, rolls back
  the symlink and restarts on failure.
- **launchd, but quiet.** Plists live in `~/.4lm/launchd/` — not
  `~/Library/LaunchAgents/`. After every reboot the stack is stopped.
  You start it when you want it.
- **`expose lan` is two-factor.** Refuses without `--confirm`, prints
  the threat model, and on confirmation generates a persistent
  `WEBUI_SECRET_KEY` (mode 0600), forces
  `WEBUI_REGISTRATION_ENABLED=false`, and pins
  `DEFAULT_USER_ROLE=pending`. Tailscale is still the better answer.
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
  via pipx; Python 3.12 is pinned because mlx-openai-server still
  requires `<3.13`.
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
        │   mlx-openai-server              │    │   open-webui serve               │
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
| Inference | `mlx-openai-server` | 1.8.0 (pipx) | python@3.12 venv |
| Web UI | `open-webui` | 0.9.2 (pipx) | python@3.12 venv |
| HF cache CLI | `huggingface_hub[cli]` | 1.12.0 (pipx) | python@3.12 venv |
| TUI client | `opencode` | homebrew/core | brew formula |
| Daemons | launchd user agents | — | `launchctl bootstrap` via `4lm start` |
| Config | profiles + `network.yaml` | — | atomic profile switch with rollback |

`mlx-openai-server` 1.7.x→1.8.x added KV-cache quantization, continuous
batching, and disk-backed prompt KV cache. The `<3.13` Python pin still
applies, hence `python@3.12` in the Brewfile.

## Common operations

```sh
# Profile switching (atomic, validated, rollback on failure)
4lm profile list
4lm profile set coding-only

# Check for newer versions across PyPI / Homebrew / HuggingFace
4lm outdated

# Apply updates (Python channel is report-only by design)
4lm upgrade                     # everything pending
4lm upgrade brew                # all pending Homebrew
4lm upgrade brew opencode       # just one formula
4lm upgrade models              # all pending HF model repos
4lm upgrade models org/repo     # just one repo

# Bump a pinned Python dep
$EDITOR requirements.txt        # change pkg==X.Y.Z
make install                    # detects drift, force-reinstalls via pipx

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
│   ├── mlx-active               symlink → profiles/<active>.yaml
│   ├── mlx-previous             plain text, used for rollback
│   ├── network.yaml             bind mode + ports
│   ├── webui_secret_key         mode 0600, generated on first lan-mode start
│   └── profiles/                default.yaml, coding-only.yaml, knowledge-only.yaml
├── logs/                        backend.log, webui.log (merged stdout+stderr)
└── openwebui-data/              Open WebUI database, settings, RAG index

~/.local/bin/4lm                 symlink to ~/.4lm/bin/4lm
~/.config/opencode/opencode.jsonc  seeded by install.sh from the repo template
/etc/sudoers.d/4lm-stack         NOPASSWD for the backend's sysctl call
/etc/newsyslog.d/4lm.conf        log rotation (10 MB, 7 generations, gzipped)
```

## Documentation

- [`docs/setup.md`](docs/setup.md) — operator runbook (sudoers, troubleshooting, model pulls)
- [`docs/profile-schema.md`](docs/profile-schema.md) — YAML key reference for `mlx-openai-server`
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
