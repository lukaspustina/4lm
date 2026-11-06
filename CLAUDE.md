# 4lm — Local LLM Control Plane

Single-command control plane for one engineer's local LLM stack on Apple Silicon. Two shapes share
one CLI, one profile system, one set of security defaults: **workstation** (`omlx` + `open-webui` +
`opencode`) and **appliance** (`./install.sh --backend-only`: headless `/v1/*` server for the LAN).
Pitch: `README.md`. Layout, command table, measurements and background: `docs/internals.md`.
Model selection and architecture rationale: `specs/done/sdd/4lm-rework-2026-05-09.md` — read it
before changing the model set, the backend choice or the activation model. Checks: `just check`.

## Rules

- Bash scripts start with `set -euo pipefail`.
- `4lm bench` unloads and reloads models: run it deliberately, load/unload cycles are an IOGPU panic trigger.
- Never open the omlx dashboard over the LAN: its login sends the main key in clear text (`SECURITY.md`).
- Plists live in `~/.4lm/launchd/`, never `~/Library/LaunchAgents/`; `4lm start`/`stop` bootstrap/bootout them, and only `4lm autostart enable` symlinks into `~/Library/LaunchAgents/`. After reboot services are stopped unless autostart is on.
- Plist templates carry the `__HOME__` placeholder, substituted by `install.sh`.
- `~/.4lm/config/network.yaml` is the single network config channel (`local` → `127.0.0.1`, `lan` → `0.0.0.0`), switched only by `4lm expose <mode> --confirm`. Never add an env-var override: the friction is a security feature.
- Profile YAMLs are validated by `validate_profile` in `bin/4lm`; schema in `docs/profile-schema.md`.
- `install.sh` §4 copies a profile into `~/.4lm/config/profiles/` only when absent, so a repo profile change never reaches an installed machine: adopt it with an explicit `cp` and re-issue `4lm profile set <name>`.
- `4lm profile set` is atomic with rollback (30 s `/v1/models` poll); a same-name re-issue re-renders and re-stages without a full stop/start.

## Daemon mode

`sudo <checkout>/bin/4lm install --daemon <user>` (`daemon_install`) is the third shape.

- Root never touches the account's files: root runs only `start`/`stop`/`restart` (`daemon_dispatch`), every other command `exec`s as the account. Never add a root-side read of `~<user>/…`: a symlink the LAN-facing account plants would be followed by root.
- New restart sites go through `service_kick`, never `launchctl kickstart`; launchd targets use `${LAUNCHD_DOMAIN}`, never `gui/<uid>`.
- Updates run `<checkout>/bin/4lm install` (the root-owned `/usr/local/bin/4lm` has no checkout beside it); `sudo 4lm uninstall --daemon --confirm` removes the system pieces only.
- Account creation, model migration and host settings are the operator's: 4lm stays generic (public repo).

## Dual shape

`--backend-only` (or `BACKEND_ONLY=1`) skips `open-webui`, the webui plist and wrapper, `opencode` and the seeded `~/.config/opencode/opencode.jsonc`.

- `bin/4lm` probes for the webui plist on disk and treats the WebUI as absent without it; never assume the WebUI exists.
- A full re-install over backend-only upgrades cleanly; `--backend-only` over a full install does not strip WebUI artifacts.
- Every feature works in both shapes (`just ci-default` + `just ci-backend-only`) or guards its behaviour on the webui-plist probe.

## Profiles

| Profile | Backend | Resident | Fits on |
|---|---|---|---|
| `lean` | omlx | ~40 GB | 64 GB |
| `mid` | omlx | ~62 GB | 128 GB |
| `default` | omlx | ~108 GB | 256 GB |
| `ollama` | ollama | ~22 GB | 36 GB+ |

- All omlx embedders serve as `qwen3-embedding`, all rerankers as `qwen3-reranker`; no profile serves a separate vision model. Switching omlx profiles never requires reindexing knowledge bases: never change these names without an explicit migration plan.
- Changing a coder or chat `served_model_name` touches the profile YAMLs, `config/opencode.example.jsonc`, the profile tables in `README.md`, `index.md` and this file, the examples in `docs/setup.md`, and any active SDD under `specs/sdd/`. Grep for both `served_model_name` and `model_path`: they diverge in spelling.
- Each profile YAML's header comment carries rationale and memory math; update its `Last reviewed:` line when reviewing.
- `render_omlx_settings` writes only `is_pinned`, `ttl_seconds`, `max_context_window`, `mtp_enabled`, `chat_template_kwargs.reasoning_effort` and `top_k` to `~/.omlx/model_settings.json`; `model_type` is validated but never reaches omlx (it detects the type from the checkpoint).
- Whether `chat_template_kwargs` in `model_settings.json` takes effect depends on the omlx version: after an omlx bump, re-check with one timed prompt before relying on it.

## omlx and OpenWebUI

- The omlx pin is `OMLX_GIT_REF` in `install.sh` §9b, enforced by commit (`direct_url.json`), never by version string.
- omlx rejects absolute HF snapshot paths, so the staging layer (`stage_omlx_model_dir()`, `~/.4lm/runtime/<profile>/models/`) is permanent.
- `RAG_EXTERNAL_RERANKER_URL` is the full `/v1/rerank` endpoint, not a base: OpenWebUI does not append `/rerank`.
- Most OpenWebUI `ENABLE_*` / `RAG_*` / `DEFAULT_*` vars are PersistentConfig, copied into `webui.db` on first init only; afterwards the admin UI wins unless `ENABLE_PERSISTENT_CONFIG=False`.
