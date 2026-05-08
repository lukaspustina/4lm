# 4lm — Local LLM Control Plane

Personal local-LLM stack for Apple Silicon: `mlx-openai-server` (backend) +
`open-webui` (frontend) + `opencode` (TUI client), managed by launchd and
controlled by a single `4lm` command.

Model selection and the layered architecture rationale live in
`specs/sdd/4lm-rework.md` (the SDD this repo implements). Read that before
changing the model set, the backend choice, or the activation model.

## Repo layout

```
bin/                       # 4lm and the two launchd wrapper scripts
launchd/                   # plist templates with __HOME__ placeholder
config/profiles/           # default (ollama) / mlx-coding / mlx-knowledge / exp-* YAMLs
config/network.example.yaml
config/opencode.example.jsonc  # template seeded into ~/.config/opencode/
docs/                      # setup runbook + profile schema reference
tests/                     # bats suite (helpers/ has launchctl + curl stubs)
.github/workflows/         # macOS CI: shellcheck, shfmt, plutil, xmllint, bats
install.sh                 # idempotent installer (no bootstrap, no migration)
uninstall.sh               # full removal (services, ~/.4lm, newsyslog)
requirements.txt           # pinned mlx-openai-server, open-webui, huggingface_hub[cli]
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
| Health check | `4lm health` |
| Switch profile | `4lm profile set <name>` |
| Toggle LAN exposure | `4lm expose lan --confirm` |
| OpenCode TUI | `4lm opencode` (alias `4lm code`) |
| Run all checks | `make check` |
| Run tests | `make test` (requires `bats-core`) |

## Activation model

Plists live in `~/.4lm/launchd/` (NOT `~/Library/LaunchAgents/`). launchd
does not scan `~/.4lm/launchd/`, so services do **not** auto-start at login.
`4lm start` calls `launchctl bootstrap`, `4lm stop` calls `launchctl bootout`.
After reboot everything is stopped.

## Network exposure

`~/.4lm/config/network.yaml` is the single config channel. `mode: local`
binds to `127.0.0.1`; `mode: lan` binds to `0.0.0.0`. Switching is done only
via `4lm expose <mode> [--confirm]`. There are no env-var overrides.

## Profile switching is atomic with rollback

`4lm profile set <name>` validates the YAML, saves the previous profile name,
swaps the symlink, kickstarts the backend, and polls `/v1/models` for 30 s.
On timeout it restores the previous symlink and kickstarts again.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck` clean, formatted by `shfmt`.
- Plists: `__HOME__` placeholder, substituted by `install.sh`.
- Profile YAMLs validated by `validate_profile` in `bin/4lm`. Schema reference
  in `docs/profile-schema.md`. Three backends: `mlx` (mlx-openai-server,
  multi-model), `mlx_lm` (python -m mlx_lm server, single-model, no wrapper
  bugs), `ollama` (llama.cpp/Metal).
- No `Co-Authored-By: Claude` lines in commits.
- Conventional-commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`,
  `test:`. Subject under 72 characters.

See `specs/sdd/4lm-rework.md` for the rework SDD that this repo state
implements.
