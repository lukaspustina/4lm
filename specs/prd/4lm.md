# PRD: 4lm — Local LLM Control Plane

**Status**: Living
**Created**: 2026-05-12
**Refined**: 2026-05-12
**Retroactive**: Yes — documents the shipped product at v0.6.0; reverse-engineered from `specs/done/sdd/4lm-rework-2026-05-09.md`, README, CLAUDE.md, and the four other done SDDs.

---

## Problem

Running multiple local LLMs on a personal Apple Silicon Mac involves juggling a backend inference server, a WebUI, a TUI client, ~140 GB of model weights, network bind modes, GPU/wired-memory limits, sudoers entries, and log rotation. Wiring this with raw `pip`, `brew services`, and ad-hoc shell aliases produces fragile state: services that auto-start before coffee and pin 70 GB to wired memory, models that crash-loop in `KeepAlive` after a profile edit, accidental `0.0.0.0` binds, config drift between profile YAMLs and OpenWebUI's database, and `pip` installs that conflict with PEP 668. The operator ends up administering the stack instead of using it.

## Users

**Primary persona** — a senior engineer running a personal LLM stack on Apple Silicon (MacBook Pro M5 Max, 128 GB unified memory, macOS 15.x). Comfortable with shell, launchd, and Python venvs. Wants the stack to behave like `brew services`: one CLI, predictable lifecycle, no surprises after reboot, no accidental network exposure. Single-user, single-host, single login session — operator and admin are the same person.

## Use Cases

1. **Daily start** — operator opens a terminal after reboot, runs `4lm start`, waits ~30 s, then `4lm opencode` for a TUI session or `http://localhost:3000` for the WebUI.
2. **Profile switch mid-session** — operator working in chat mode needs the coding-tuned profile; runs `4lm profile set mlx-coding` and the backend swaps within 30 s or rolls back automatically.
3. **LAN exposure for a second device** — operator wants to query the stack from an iPad on the same network; runs `4lm expose lan --confirm` once, the WebUI gets a persistent secret key, registration is locked.
4. **Crash investigation** — backend is respawn-throttled; `4lm status` shows `respawning, last exit 1, restarts: 3`; `4lm logs backend` tails the merged log; `4lm restart backend` after the fix.
5. **Bootstrap from clone** — operator on a fresh Mac runs `make bootstrap && make install && make models && 4lm start` to reach a working stack without writing any glue.
6. **Update sweep** — operator notices `open-webui` released a new version on PyPI; runs `4lm outdated` and sees one pending bump in the `python` channel; runs `4lm upgrade python open-webui`; the venv is updated and the WebUI service restarts.
7. **Stop before sleep** — operator runs `4lm stop` at end of day; after reboot the stack is gone until the operator decides to bring it back.

## Goals

G1: After every reboot, no `com.4lm.*` agent is loaded — `launchctl print gui/$(id -u)/com.4lm.backend` returns non-zero until the operator runs `4lm start`.

G2: `4lm profile set <valid-name>` completes in under 30 s with the new models reachable at `/v1/models`, or rolls back the `active-profile` symlink and returns the previous profile to running state within an additional 30 s, in 100% of attempts.

G3: `4lm start` returns and both services report `running` in `4lm status` within 60 s on a MacBook Pro M5 Max (128 GB, macOS 15.x), with models already in the local cache and the `default.yaml` profile (Ollama backend) active. First-token latency from cold model load is excluded — that is bounded by Ollama, not 4lm. `4lm health` gates the wired-memory precondition (see AC9).

G4: Zero incidents of accidental `0.0.0.0` bind — every LAN exposure requires explicit `--confirm`; without it the command exits 1 and `network.yaml` is unchanged.

G5: `make install` is idempotent — running it twice in a row on an already-installed system produces zero writes outside `~/.4lm/logs/` and exits 0.

G6: A fresh operator can go from `git clone` completion to both services `running` in `4lm status` and the WebUI reachable at `http://localhost:3000` in under 30 minutes, using only `README.md` and `docs/setup.md`. Excludes `make models` (network-bound; ~140 GB download).

G7: `make check` on `macos-latest` CI passes on every PR; the bats suite covers install idempotency, plist substitution, command dispatch, and the profile-switch state machine as enumerated in `tests/`.

## Acceptance Criteria

AC1: `4lm` with no arguments prints the same output as `4lm status`.

AC2: Every subcommand documented in the README (`start`, `stop`, `restart`, `status`, `health`, `logs`, `profile {list|set|current}`, `expose`, `doctor`, `diag`, `outdated`, `upgrade`, `autostart {enable|disable|status}`, `opencode`/`code`, `open`, `uninstall`) is dispatched by `bin/4lm`. Deterministic subcommands — those whose preconditions are fully satisfied by the test harness stubs in `tests/helpers/` (`start`, `stop`, `status`, `profile list`, `profile current`, `expose`, `autostart status`, `opencode`, `open`) — exit 0 in the bats suite. Network-bound subcommands (`outdated`, `upgrade`) are exercised as dispatch tests only; behaviour is covered by AC18.

AC3: After `4lm stop` and a reboot (simulated by `launchctl bootout` of all `com.4lm.*` labels), no process is bound to `:8000` or `:3000`.

AC4: `4lm profile set <name>` with malformed YAML exits 1 before any symlink swap, and `4lm profile current` still reports the previous profile.

AC5: `4lm profile set <name>` polls `/v1/models` every 1 s for up to 30 s; on timeout it restores the `active-profile` symlink, kickstarts the backend with the previous profile, and exits 1 with `Profile switch failed; reverted to <previous>` on stderr.

AC6: `4lm profile set` with input failing `^[a-zA-Z0-9_-]{1,64}$` exits 1 with `invalid profile name: <input>` before any filesystem operation.

AC7: `4lm expose lan` without `--confirm` exits 1, prints the risk message, and leaves `network.yaml` unchanged.

AC8: `4lm expose lan --confirm` writes `mode: lan`, restarts only services whose `launchctl print gui/$(id -u)/<label>` shows `state = running` at the time of the command, and ensures `~/.4lm/config/webui_secret_key` exists with mode 0600. `WEBUI_REGISTRATION_ENABLED=false` is set on the WebUI process.

AC9: `4lm health` reads `iogpu.wired_limit_mb` via `/usr/sbin/sysctl -n` and exits 1 if below 98304, with a remediation message pointing at `docs/setup.md §Sudoers`. (Prerequisites G3 — health gates the wired-memory condition that the 60 s startup bound assumes.)

AC10: `4lm status` parses `launchctl print` output and shows per-service running state, last exit code, last exit reason, and restart count.

AC11: `4lm logs` uses `tail -F` (follows rotated files) and defaults to `backend` when no target is specified.

AC12: launchd plists installed by `install.sh` live in `~/.4lm/launchd/` and never in `~/Library/LaunchAgents/`.

AC13: Plist `Umask=0077` ensures log files created at runtime are mode 0600.

AC14: `make install` re-run on a working install produces byte-identical content under `~/.4lm/` (excluding `~/.4lm/logs/`, `~/.4lm/openwebui-data/`, and `~/.4lm/runtime/`), byte-identical plists in `~/.4lm/launchd/`, and an unchanged `~/.local/bin/4lm` symlink target.

AC15: WebUI starts with `DEFAULT_USER_ROLE=pending`, `ENABLE_MEMORIES=true`, `ENABLE_RAG_WEB_SEARCH=true` (`RAG_WEB_SEARCH_ENGINE=duckduckgo`), `ENABLE_CODE_INTERPRETER=true` (`CODE_INTERPRETER_ENGINE=pyodide`), and RAG embeddings via the local omlx `qwen3-embedding` model. Follow-up and autocomplete suggestion env vars are set on WebUI launch; persistence into `webui.db` is best-effort (PersistentConfig applies only on first init).

AC16: `4lm opencode` (alias `4lm code`) seeds `~/.config/opencode/opencode.jsonc` from `config/opencode.example.jsonc` on first run and launches the OpenCode TUI bound to `http://127.0.0.1:8000/v1`.

AC17: `make models` downloads every model identified by a `model_path` or `embedding_model_path` key in all profile YAMLs under `config/profiles/`, and is idempotent (no re-downloads when caches are populated). `make models-clean` prunes orphaned revisions; `make models-rm MODEL=foo/bar` removes one repo.

AC18: `4lm outdated` enumerates pending bumps across three channels — `python` (requirements.txt + PyPI), `brew` (Homebrew formulae), `models` (HuggingFace revisions) — and prints `Everything up to date.` when nothing is pending. `4lm upgrade [channel] [name...]` applies them; valid channels are `brew | models | python | all`; supplying an item name without a channel exits 1 with a usage message; nothing pending in the requested channel exits 0 with `Nothing to upgrade in channel '<channel>'.`

AC19: `bin/4lm-backend-start.sh` invokes `sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304`; on non-zero exit it prints a warning and continues startup (the wired-memory limit is best-effort at runtime; `4lm health` is the gate).

AC20: All bash scripts pass `shellcheck` clean and are formatted by `shfmt -i 2 -ci`. All plists pass `plutil -lint` and `xmllint --noout`.

AC21: `4lm autostart enable [backend|webui|all]` creates a symlink in `~/Library/LaunchAgents/` pointing to the plist in `~/.4lm/launchd/`, so launchd loads the service on every login. `4lm autostart disable [target]` removes the symlink and boots out the service. `4lm autostart status` reports per-service enabled/disabled.

AC22: The `README.md §TL;DR` sequence (`make bootstrap && make install && make models && 4lm start`) completes from `git clone` completion to `4lm status` showing both services `running` with one sudo password prompt for the newsyslog sudoers seed; all other 4lm-owned operations proceed non-interactively. (Anchors G6 sequence; the 30-minute bound is a design target, not CI-enforced — network and download speed are excluded.)

## Scope

- Single CLI (`4lm`) controlling the entire stack: `start`, `stop`, `restart`, `status`, `health`, `logs`, `profile`, `expose`, `doctor`, `diag`, `outdated`, `upgrade`, `autostart`, `opencode`, `open`, `uninstall`.
- Three backend choices selected per profile YAML: `omlx` (primary MLX, multi-model, paged KV cache), `mlx_lm` (single-model upstream MLX), `ollama` (default, GGUF/Metal via Homebrew).
- Atomic profile switching with bounded rollback (30 s poll + 30 s restore).
- Network exposure as a deliberate two-step action; `127.0.0.1` by default, `0.0.0.0` only via `4lm expose lan --confirm`.
- launchd activation that survives reboot in a stopped state.
- Preconfigured OpenWebUI: memory, DuckDuckGo web search, Pyodide code interpreter, follow-up + autocomplete suggestions (best-effort via PersistentConfig), file-upload RAG with local embeddings.
- OpenCode TUI integration: `4lm opencode` launches the daily-driver client wired to the local backend.
- Idempotent installer with three sudo-touch points (sysctl wired-memory, newsyslog rotation, sudoers seed) — one prompt, then no-ops.
- `bats` smoke suite and `macos-latest` CI on every PR via `make check`.

## Non-Goals

- **Multi-user support** — labels, paths, and sudoers entries are personal-stack-scoped. Adding multi-user changes too many assumptions to justify on a single-engineer tool.
- **Auto-start on login *by default*** — after install and every reboot, services are stopped until the operator runs `4lm start`. A 70 GB working set should never sneak onto the wired-memory list before coffee. `4lm autostart enable [target]` is the documented opt-in for operators who explicitly want services loaded on every boot.
- **Cloud fallback providers** — Z.ai, Kimi, Claude, Gemini provider tokens are out of scope; the WebUI can be pointed at remote endpoints by hand if needed.
- **Multi-host clustering** — single-node only; no inference offload, no shared model cache.
- **Docker / docker-compose** — Docker-for-Mac halves MLX throughput; native launchd is the only supported activation.
- **Replacing the inference backends** — the three supported backends (omlx, mlx_lm, ollama) are fixed; the seam is the OpenAI-compatible API, not the engine.
- **Backup of `openwebui-data/`** — operator already runs Restic/Borg against `$HOME`; layering another backup hook would duplicate coverage.
- **env-var overrides for bind mode** (e.g. `LLM_BACKEND_HOST=0.0.0.0`) — `network.yaml` via `4lm expose` is the only channel. No escape hatches.
- **Pip-into-system-Python** — PEP 668 is honoured via `pipx`; Python 3.12 is pinned for MLX compatibility.
- **A SwiftBar / menubar plugin** — out of scope; the CLI is the only supported interface; a menubar plugin adds maintenance surface with no current demand.

## Constraints

### Platform
- macOS, Apple Silicon only. `install.sh` verifies `uname -m == arm64` and aborts otherwise.
- launchd user agents only — no system daemons, no LaunchDaemons.
- Bash 5.x; scripts pass `shellcheck` clean and are formatted by `shfmt -i 2 -ci`.
- Python 3.12 pinned (MLX ecosystem). Deps installed via `pipx` into per-tool venvs.

### Hardware
- MacBook Pro M5 Max, 128 GB unified memory, macOS 15.x; ~96 GB usable wired-memory budget.
- `iogpu.wired_limit_mb=98304` required; sudoers rule for `sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304` must be in place.

### Security
- No auth in front of the inference backend — operator must keep it on `127.0.0.1` or behind Tailscale / host firewall.
- **Unconditional hardening (all bind modes)**: `DEFAULT_USER_ROLE=pending` on WebUI; profile name validated against `^[a-zA-Z0-9_-]{1,64}$` before any path construction; launchd plists carry `Umask=0077`; log files mode 0600.
- **LAN-mode-only hardening**: persistent `WEBUI_SECRET_KEY` (mode 0600) generated by `4lm-webui-start.sh` on first `lan`-mode start; `WEBUI_REGISTRATION_ENABLED=false`.

### Lifecycle
- Canonical plists live in `~/.4lm/launchd/`; `4lm autostart enable` adds a symlink in `~/Library/LaunchAgents/` pointing to them — the canonical file never lives there.
- Single network-config channel: `~/.4lm/config/network.yaml`.
- Profile switch is atomic with bounded rollback (30 s poll + 30 s restore).

### Inference & API
- Backend choice is per-profile: `omlx` (multi-model, paged KV cache), `mlx_lm` (single-model), `ollama` (default).
- The OpenAI-compatible API on `:8000/v1` is the only seam between backend and consumers (WebUI, OpenCode, scripts).
- omlx does not accept absolute HF snapshot paths in `model_settings.json` (Phase 1 probe, 2026-05). A per-profile staging layer at `~/.4lm/runtime/<profile>/models/` is permanent.

## Dependencies

- `omlx` (vLLM-style MLX inference server, installed from git via `pipx`).
- `mlx_lm` (upstream MLX server, co-installed in the omlx venv).
- `ollama` (Homebrew formula, default backend).
- `open-webui` (`pipx`, 0.9.2).
- `huggingface_hub[cli]` (`pipx`, 1.13.0).
- `opencode` (Homebrew formula).
- `python@3.12` (Homebrew formula; pinned for MLX compatibility).
- macOS launchd, `newsyslog`, `sysctl` (`iogpu.wired_limit_mb`).
- Development: `shellcheck`, `shfmt`, `bats-core`, `pipx` (all via `Brewfile`).

## Decision Log

| Considered | Decision | Reason |
|---|---|---|
| Auto-start services at login | Manual `4lm start` only | A 70 GB working set should never sneak onto the wired-memory list before the operator decides. |
| Multi-user support | Single user only | Labels, paths, sudoers entries are simpler when personal-scoped; no current second user. |
| Docker / docker-compose | Native launchd | Docker-for-Mac halves MLX throughput. |
| `LLM_BACKEND_HOST=0.0.0.0` env override | `4lm expose lan --confirm` only | YAGNI; single config channel is simpler; no automation consumer; `--confirm` is the security gate. |
| `LLM_ALLOW_PUBLIC_BIND=1` bypass | Removed | YAGNI; single-user stack; untestable code path. |
| Auto-promote first WebUI user to admin | `DEFAULT_USER_ROLE=pending` | `admin` makes every new user admin, not just the first. Explicit promotion is safer. |
| Block WebUI startup on backend readiness | Start WebUI immediately | WebUI surfaces "no models" at request time; the wait was dead weight. |
| Python control plane | Bash | Fewer dependencies on macOS; launchd interaction is shell-native. |
| Pip-install into system Python | `pipx` into `python@3.12` venvs | PEP 668; per-tool isolation prevents one bad bump from breaking the stack. |
| Separate `.out`/`.err` log files per service | Merged `.log` | Simplifies rotation config and tailing; errors appear in context with stdout. |
| User-space log rotation via launchd `StandardOutPath` size limits | `/etc/newsyslog.d/4lm.conf` via single sudo prompt | macOS-native; `StandardOutPath` has no size cap support. |
| Store plists in `~/Library/LaunchAgents/` | `~/.4lm/launchd/` | Only way to prevent launchd from auto-loading at login. |
| Just `bootstrap`/`bootout` for autostart | Ship `4lm autostart {enable\|disable\|status}` | Operator opt-in for login-load is more discoverable than manual launchd editing; symlinks in `~/Library/LaunchAgents/` keep the canonical plist in `~/.4lm/launchd/`. |
| Use omlx with absolute HF snapshot paths | Per-profile staging at `~/.4lm/runtime/<profile>/models/` | Phase 1 probe showed omlx ignores absolute paths in `model_settings.json`; staging is permanent. |
| Validate profiles at backend startup | Validate before activation | Backend would crash-loop in `KeepAlive` until throttled; pre-activation validation is strictly safer. |
| Single inference backend | Three locked-in choices (omlx / mlx_lm / ollama) | OpenAI-compatible seam isolates consumers from backend churn; each backend has a distinct sweet spot. |
| Primary MLX server = `mlx-openai-server` (as specified in the original rework SDD) | `omlx` | omlx is a vLLM-style multi-model MLX server with paged KV cache; `mlx-openai-server` is single-model and lacks paged cache. The OpenAI-compatible seam on `:8000/v1` is unchanged, so consumers (WebUI, OpenCode) did not need changes. |
| Ship without CI | `macos-latest` workflow on every PR | Manual `make check` is not enough; bash regressions are silent until they bite. |
| Bring-your-own OpenWebUI feature config | Preconfigure memory / RAG / web search / code interpreter / suggestions on first launch | `ENABLE_*` vars are PersistentConfig — only honoured on first init — so we set them as the operator would, otherwise the WebUI ships dull and the operator has to dig through admin pages. |
| Default backend = omlx | Default backend = ollama | Ollama has lower setup friction, fewer model-load gotchas, and is the right default for the "I just want it to work" path; MLX profiles are opt-in. |

## Open Decisions

None. The product is shipping at v0.6.0; new product decisions land via new PRDs.

## References

- [`specs/done/sdd/4lm-rework-2026-05-09.md`](../done/sdd/4lm-rework-2026-05-09.md) — the rework design doc that defined the current shape.
- [`specs/done/sdd/omlx-2026-05-09.md`](../done/sdd/omlx-2026-05-09.md) — omlx backend integration.
- [`specs/done/sdd/ollama-backend-2026-05-09.md`](../done/sdd/ollama-backend-2026-05-09.md) — Ollama as the default backend.
- [`specs/done/sdd/python-migration-2026-05-07.md`](../done/sdd/python-migration-2026-05-07.md) — `pipx` + `python@3.12` migration.
- [`specs/done/sdd/product-review-2026-05-07.md`](../done/sdd/product-review-2026-05-07.md) — product-review pass that produced shipping polish.
- [`docs/setup.md`](../../docs/setup.md) — operator runbook (sudoers, troubleshooting, model pulls).
- [`docs/profile-schema.md`](../../docs/profile-schema.md) — YAML key reference for all three backends.
- [`CLAUDE.md`](../../CLAUDE.md) — orientation for AI assistants working in this repo.
- [`README.md`](../../README.md) — user-facing overview.
