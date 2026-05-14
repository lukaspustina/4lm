# PRD: 4lm — Backend-Only Install Mode

**Status**: Ready for Design
**Created**: 2026-05-14
**Refined**: 2026-05-14
**Original**: specs/prd/4lm-backend-only.md
**Parent PRD**: [`specs/prd/4lm.md`](./4lm.md) — this PRD extends the shipped product at v0.6.0 with an install variant.

---

## Problem

Installing 4lm on a Mac that will only act as an LLM inference server for other hosts on the LAN still forces the operator to install WebUI (`open-webui` pipx tree, hundreds of MB) and OpenCode (Homebrew formula + seeded config). Every path through `install.sh`, `Makefile`, `requirements.txt`, and `Brewfile` assumes a full single-host workstation. The operator wanting a pure `/v1/*` server on the LAN has to surgery the installer by hand or live with dead components. This is a capability gap, not just install friction: there is no supported way today to provision a 4lm host as a dedicated LAN inference backend.

## Users

**Primary persona** — the senior engineer described in the parent `4lm.md` PRD (Apple Silicon, MacBook Pro M5 Max, comfortable with shell, launchd, pipx). For this feature, that operator now operates two installs: a full install on their workstation, and a headless backend-only install on a second Mac dedicated to LAN inference. The other LAN hosts (Mac/Linux running their own OpenWebUI, `opencode`, or scripts against `/v1/*`) are systems, not human personas.

## Use Cases

1. **Headless install on a second Mac** — operator SSHes into the dedicated Mac and runs `./install.sh --backend-only`. The installer skips `open-webui`, the WebUI plist, `4lm-webui-start.sh`, the `opencode` Homebrew formula, and the opencode config seed. Operator then runs `4lm start` and `4lm expose lan --confirm`; the backend serves `/v1/*` on `0.0.0.0:8000`. Running `4lm status` shows only the backend block; no WebUI block appears.

2. **Consumer host points OpenWebUI at the headless server** — operator SSHes into the headless Mac, runs `4lm start`, then on their workstation sets `OPENAI_API_BASE_URL=http://<headless>:8000/v1` in the user-installed OpenWebUI settings. Operator submits a prompt in the WebUI; it routes to the headless backend. The headless Mac's `4lm status` shows the backend running; no WebUI block appears because none was installed.

3. **Consumer host runs opencode against the headless server** — operator configures `opencode` on their workstation with the LAN URL of the headless backend. The headless Mac has no `opencode` installed; `4lm opencode` on it exits 1 with `WebUI not installed (re-run ./install.sh to enable)` (the same dispatch-time error as any other absent component). The consumer workstation manages opencode independently.

## Goals

G1: `./install.sh --backend-only` (and `make install BACKEND_ONLY=1`) produces zero optional artifacts. After a clean backend-only install, none of the following exist: `~/.4lm/launchd/com.4lm.webui.plist`, `~/.4lm/bin/4lm-webui-start.sh`, the `open-webui` pipx package (`pipx list --short | grep -q '^open-webui'` returns non-zero), the `opencode` Homebrew formula (`brew list opencode` returns non-zero), `~/.config/opencode/opencode.jsonc`, and no line containing `webui.log` in `/etc/newsyslog.d/4lm.conf`. Verifiable by file/binary inventory.

G2: Backend behavior is byte-identical between full and backend-only installs. The existing bats coverage of `start`, `stop`, `status`, `profile {list|set|current}`, `expose`, and the OpenAI-compatible `/v1/*` API passes unchanged on a backend-only install.

G3: Backend-only install footprint is **≥ 200 MB smaller on disk** and the install completes **≥ 30 s faster** on a warm pipx/brew cache than a full install, on a MacBook Pro M5 Max. (Network-bound model downloads excluded. This bound is a design target, not CI-enforced — verification is manual on the reference machine.)

G4: `bin/4lm` cleanly handles missing optional components. `4lm {start|stop|restart|logs|open} webui` exits 1 with an actionable error pointing at `./install.sh`. `4lm {start|stop|restart|autostart} all` only acts on components whose plist exists; absent components are silently skipped from the `all` set. `4lm status` omits the WebUI block entirely. `4lm doctor` skips webui/opencode probes when their plists/wrappers are absent. No silent no-ops on explicit webui commands.

G5: CI on `macos-latest` runs `make check` as a matrix job — once with default install, once with `BACKEND_ONLY=1` — and both modes stay green on every PR.

## Acceptance Criteria

AC1: `./install.sh --backend-only` and `make install BACKEND_ONLY=1` produce a clean install with none of the following on disk: `~/.4lm/launchd/com.4lm.webui.plist`, `~/.4lm/bin/4lm-webui-start.sh`, the `open-webui` pipx package (`pipx list --short | grep -q '^open-webui'` returns non-zero), the `opencode` Homebrew formula (`brew list opencode` returns non-zero), `~/.config/opencode/opencode.jsonc`, and no line containing `webui.log` in `/etc/newsyslog.d/4lm.conf`.

AC2: `install.sh --backend-only` filters the `open-webui` line from the in-memory pipx install list before iterating. The on-disk `requirements.txt` is unchanged.

AC3: `Brewfile` is split into two files. `Brewfile` contains the dev and core entries present before this change, minus `opencode`. `Brewfile-tui` (new file) contains `opencode`. No other entries are added or removed from either file.

AC4: `make bootstrap` (no flag) runs `brew bundle` against both `Brewfile` and `Brewfile-tui`. `make bootstrap BACKEND_ONLY=1` runs `brew bundle` against `Brewfile` only. `./install.sh --backend-only` does not invoke `brew bundle` against `Brewfile-tui` and does not install `opencode`.

AC5: `bin/4lm` probes `~/.4lm/launchd/com.4lm.webui.plist` existence before dispatching any webui-targeted command. No marker file is written by `install.sh`; no config field in `network.yaml` gates the behavior.

AC6: On a backend-only install, `4lm start webui`, `4lm stop webui`, `4lm restart webui`, `4lm logs webui`, `4lm open webui`, `4lm opencode`, and `4lm code` each exit 1 and print `WebUI not installed (re-run ./install.sh to enable)` to stderr. Help text in `bin/4lm` remains static and always lists `[backend|webui|all]`; the dispatch-time error is the only disambiguation.

AC7: On a backend-only install, `4lm autostart enable webui` and `4lm autostart disable webui` follow AC6.

AC8: On a backend-only install, `4lm start all`, `4lm stop all`, `4lm restart all`, `4lm autostart enable all`, and `4lm autostart disable all` only act on components whose plist exists. Absent components are silently skipped from the `all` set; the command exits 0 when all remaining components succeed, and exits non-zero if any present component operation fails with the per-component error printed to stderr.

AC9: On a backend-only install, `4lm status` (and `4lm` with no args) omits the WebUI block entirely in both text and JSON output. The backend block format is unchanged.

AC10: On a backend-only install, `4lm doctor` skips the webui and opencode probes when their plists/wrappers are absent. No "missing" failure is reported for intentionally absent components. The backend probes are unchanged.

AC11: Re-running `./install.sh --backend-only` over an existing full install is non-destructive: the existing `open-webui` pipx package, the webui plist in `~/.4lm/launchd/`, and `~/.4lm/bin/4lm-webui-start.sh` remain in place. `install.sh` prints `WebUI artifacts found; not managed in backend-only mode.` to stdout and proceeds with the backend layer.

AC12: Re-running `./install.sh` (no flag) over an existing backend-only install installs `open-webui` via pipx, copies the webui wrapper and plist, runs `brew bundle` against `Brewfile-tui`, seeds `~/.config/opencode/opencode.jsonc`, and appends the `webui.log` entry to `/etc/newsyslog.d/4lm.conf` only if that line is not already present (guarded by a grep check; no duplicate lines are written). Subsequent re-runs are idempotent (no further writes).

AC13: `./uninstall.sh` runs to completion with exit 0 on both modes. No new behavior — existing iteration over component labels is a no-op on absent webui artifacts.

AC14: On a backend-only install, `4lm expose lan --confirm` writes `mode: lan` to `network.yaml` and restarts only the backend service (whose plist exists). It does not attempt to create or reference `~/.4lm/config/webui_secret_key`.

AC15: GitHub Actions `macos-latest` runs `make check` as a matrix job over `{default, BACKEND_ONLY=1}`. Both must pass on every PR.

AC16: On a backend-only install, the existing bats coverage of `start`, `stop`, `status`, `profile {list|set|current}`, `expose`, and `/v1/*` passes unchanged. Tests that require a WebUI fixture are skipped via a new `skip_if_no_webui` helper in `tests/helpers/` rather than failed.

## Scope

- One install-time flag (`--backend-only` on `install.sh`; `BACKEND_ONLY=1` env var on `make install` and `make bootstrap`) that strips WebUI and OpenCode artifacts from the install.
- `Brewfile` split into `Brewfile` (dev + core) and `Brewfile-tui` (`opencode`).
- `bin/4lm` runtime gating by plist existence: webui-targeted commands error explicitly when absent; `all` targets and `status` silently skip absent components.
- `4lm doctor` and `4lm expose` probes follow the same plist-existence gating.
- Non-destructive re-install in either direction: re-running `install.sh --backend-only` over a full install leaves WebUI alone; re-running `install.sh` over a backend-only install upgrades to full.
- CI matrix on `macos-latest` covering both modes via `make check`.
- New `skip_if_no_webui` helper in `tests/helpers/` to keep the existing bats suite green on backend-only.
- `README.md` and `docs/setup.md` updated with a backend-only section containing at minimum: the `--backend-only` flag, the two-command quickstart (`./install.sh --backend-only && 4lm expose lan --confirm`), and a consumer-side `OPENAI_API_BASE_URL` example.

## Non-Goals

- **Per-component flags** (`--no-webui`, `--no-opencode`) — single `--backend-only` switch only. YAGNI: the use case is binary (full client machine vs. headless server).
- **Runtime toggle without re-install** (e.g., `4lm component disable webui`) — install state is install-time. `install.sh` is already idempotent; a runtime toggle adds state without solving a real problem.
- **A future `4lm component {install|remove}` subcommand** — re-running `install.sh` covers the upgrade path; granular runtime surgery is over-engineering for a personal stack.
- **Different profile defaults in backend-only mode** — backend behavior is identical; same profiles, same models, same defaults. Backend-only is purely about absence of WebUI/OpenCode.
- **Auto-switch network mode to LAN on `--backend-only`** — `network.yaml` still defaults to `mode: local`; operator runs `4lm expose lan --confirm` explicitly. The two-step exposure is the security contract regardless of intended use.
- **Separate auth/firewall layer for the headless server** — no auth, mTLS, or firewall config added. Operator relies on Tailscale / host firewall / VLAN, as today. Same security model as the parent PRD.
- **Hybrid "installed but disabled" state for WebUI** — no `enabled: false` config knob. Absence = not installed. Avoids tri-state confusion.
- **Multi-host clustering, load-balancing, shared model cache** — same non-goal as the parent PRD.

## Constraints

### Platform
- macOS, Apple Silicon only (inherited from parent PRD).
- Bash 5.x; scripts pass `shellcheck` clean and are formatted by `shfmt -i 2 -ci`.
- Python 3.12 via `pipx` for backend pipx deps.

### Lifecycle
- Canonical plists live in `~/.4lm/launchd/`; symlinks in `~/Library/LaunchAgents/` only via `4lm autostart enable` (inherited).
- Idempotency: parent PRD G5 / AC14 still hold — re-running `install.sh --backend-only` produces zero writes outside `~/.4lm/logs/`.
- Plist `Umask=0077`; log files mode 0600 (inherited).

### Security
- All bind-mode hardening clauses from the parent PRD apply to the backend in backend-only mode (profile-name regex `^[a-zA-Z0-9_-]{1,64}$`, plist Umask, log mode, `--confirm` gate on `expose lan`).
- LAN-mode WebUI hardening (`WEBUI_SECRET_KEY`, `WEBUI_REGISTRATION_ENABLED=false`) is N/A in backend-only mode — there is no WebUI to harden. `4lm expose lan --confirm` must not attempt to create `webui_secret_key` (see AC14).

### Performance
- Backend-only install footprint ≥ 200 MB smaller on disk than full install on the same host.
- Backend-only install completes ≥ 30 s faster than full install on warm pipx/brew cache.
- These are design targets verified manually on the reference machine (MacBook Pro M5 Max); not CI-enforced.

### CI
- GitHub Actions `macos-latest` runs `make check` as a matrix job over `{default, BACKEND_ONLY=1}`. Both must pass on every PR.

### Distribution
- Git clone + `make install`. No PyPI, no Homebrew tap (inherited).

## Dependencies

All dependencies are inherited from the parent PRD's Dependencies section. Backend-only mode is a subset: `omlx`, `mlx_lm`, `ollama`, `huggingface_hub[cli]`, `python@3.12`, macOS launchd / `newsyslog` / `sysctl`. Full mode additionally pulls `open-webui` and `opencode`.

## Decision Log

| Considered | Decision | Reason |
|---|---|---|
| Per-component flags (`--no-webui`, `--no-opencode`) | Single `--backend-only` flag | YAGNI; the use case is binary (full client vs. headless server). |
| Runtime toggle (`4lm component disable webui`) | Install-time flag only | `install.sh` is idempotent; runtime toggle adds state without solving a real problem. |
| Auto-promote network mode to LAN on `--backend-only` | Keep default `mode: local`; require explicit `4lm expose lan --confirm` | Two-step exposure is the security contract regardless of intended use. |
| Marker file at `~/.4lm/.backend-only` | Plist-existence probe | Disk state of the plist is the source of truth; one less thing to keep in sync. |
| Config field in `network.yaml` (e.g. `components: { webui: false }`) | Plist-existence probe | Avoids tri-state confusion; install state shouldn't live in runtime config. |
| Hybrid "installed but disabled" state for WebUI | Absence = not installed | Avoids tri-state confusion; matches parent PRD's "single channel" ethos. |
| Dynamic help text adapting to installed components | Static help text; dispatch-time error disambiguates | Single source of truth; removes a runtime branch with no user-visible benefit. |
| Destructive `./install.sh --backend-only` (strip WebUI from a full install) | Non-destructive (leaves existing WebUI alone, prints notice) | Don't surprise the operator; `uninstall.sh` is the destructive path. |
| Single `Brewfile` (ignore `opencode` line when backend-only) | Split: `Brewfile` (dev+core) + `Brewfile-tui` (`opencode`) | `brew bundle` honors the file it's pointed at; clean separation, no runtime filtering. |
| Auto-detect missing binaries (probe `open-webui` in PATH) | Plist existence probe | Avoids accidental detection of user-installed-elsewhere `open-webui`; ties detection to 4lm-managed artifacts only. |
| Separate auth/firewall layer for the headless server | Inherit parent security model | YAGNI; Tailscale / VLAN / host firewall is the operator's responsibility. |

## Open Decisions

None.

## References

- [`specs/prd/4lm.md`](./4lm.md) — parent PRD this feature extends.
- [`specs/prd/4lm-backend-only.brainstorm.md`](./4lm-backend-only.brainstorm.md) — brainstorm artifact this PRD was synthesized from.
- [`specs/done/sdd/4lm-rework-2026-05-09.md`](../done/sdd/4lm-rework-2026-05-09.md) — current installer + runtime architecture.
- [`README.md`](../../README.md) — user-facing overview.
- [`CLAUDE.md`](../../CLAUDE.md) — orientation for AI assistants working in this repo.
