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
config/profiles/           # default (ollama) / mlx-coding / mlx-knowledge / exp-* YAMLs
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

## omlx path probe

Phase 1 manual probe result (2026-05): omlx **does not** accept absolute HF
snapshot paths in `model_settings.json`. Setting `model_path` to an absolute
snapshot dir and starting `omlx serve --model-dir <empty>` returns no models
from `/v1/models`. The staging layer (`stage_omlx_model_dir()` +
`~/.4lm/runtime/<profile>/models/`) is therefore permanent; the TODO comment
in `stage_omlx_model_dir()` remains as documentation of the probe outcome.

See `specs/sdd/4lm-rework.md` for the rework SDD that this repo state
implements.
