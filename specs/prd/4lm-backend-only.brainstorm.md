# PRD Brainstorm: 4lm-backend-only

Generated: 2026-05-14
Status: Brief (input to /prd)

## Problem

Today, installing 4lm on a Mac that will only act as an LLM inference server for other hosts on the LAN still forces the operator to install WebUI (`open-webui` pipx tree, hundreds of MB) and OpenCode (Homebrew formula + seeded config). These client components are unused on a headless server, but every path through `install.sh`, `Makefile`, `requirements.txt`, and `Brewfile` assumes a full single-host workstation. The operator wanting a pure `/v1/*` server on the LAN has to surgery the installer by hand or live with dead components. This is a capability gap, not just install friction: there is no supported way today to provision a 4lm host as a dedicated LAN inference backend.

## Users

**Primary persona** — the same senior engineer described in the parent `4lm.md` PRD (Apple Silicon, MacBook Pro M5 Max, comfortable with shell, launchd, pipx). For this feature, that operator now operates two installs: a full install on their workstation, and a headless backend-only install on a second Mac dedicated to LAN inference. The other LAN hosts (Mac/Linux running their own OpenWebUI, `opencode`, or scripts against `/v1/*`) are systems, not human personas.

## Use Cases

1. **Headless install on a second Mac.** Operator runs `./install.sh --backend-only` on a dedicated Mac. The installer skips `open-webui`, the WebUI plist, `4lm-webui-start.sh`, the `opencode` Homebrew formula, and the opencode config seed. After `4lm start` and `4lm expose lan --confirm`, the backend serves `/v1/*` on `0.0.0.0:8000`.
2. **Consumer host points OpenWebUI at the headless server.** On a separate machine, a user-installed OpenWebUI is configured with `OPENAI_API_BASE_URL=http://<headless-server>:8000/v1`. The headless 4lm install has no WebUI of its own; the consumer's OpenWebUI handles UI concerns.
3. **Consumer host runs opencode against the headless server.** On a separate machine, `opencode` is configured with the LAN URL of the headless server. The headless server's `4lm opencode` command is N/A there (no opencode installed locally); the consumer manages opencode independently.

## Goals

G1: `./install.sh --backend-only` (and `make install BACKEND_ONLY=1`) produces zero optional artifacts. None of the following exist after a clean backend-only install: `~/.4lm/launchd/com.4lm.webui.plist`, `~/.4lm/bin/4lm-webui-start.sh`, the `open-webui` pipx package, the `opencode` Homebrew formula, `~/.config/opencode/opencode.jsonc`, the `webui.log` line in `/etc/newsyslog.d/4lm.conf`. Verifiable by file/binary inventory.

G2: Backend behavior is byte-identical between full and backend-only installs. The existing bats coverage of `start`, `stop`, `status`, `profile {list|set|current}`, `expose`, and the OpenAI-compatible `/v1/*` API passes unchanged on a backend-only install.

G3: Backend-only install footprint is **≥ 200 MB smaller on disk** and the install completes **≥ 30 s faster** on a warm pipx/brew cache than a full install, on a MacBook Pro M5 Max. (Network-bound model downloads excluded.)

G4: `bin/4lm` cleanly handles missing optional components. `4lm {start|stop|restart|logs|open} webui` exits 1 with an actionable error pointing at `./install.sh`. `4lm {start|stop|restart|autostart} all` only acts on components whose plist exists; absent components are silently skipped from the `all` set. `4lm status` omits the WebUI block entirely. `4lm doctor` skips webui/opencode checks when their plists/wrappers are absent. No silent no-ops on explicit webui commands.

G5: CI on `macos-latest` runs `make check` as a matrix job — once with default install, once with `BACKEND_ONLY=1` — and both modes stay green on every PR.

## Non-Goals

NG1: **Per-component flags** (`--no-webui`, `--no-opencode`). Single `--backend-only` switch only. *Rationale:* YAGNI — the use case is binary (full client machine vs. headless server).

NG2: **Runtime toggle without re-install** (e.g., `4lm component disable webui`). Install state is install-time. *Rationale:* `install.sh` is already idempotent; a runtime toggle adds state without solving a real problem.

NG3: **A future `4lm component {install|remove}` subcommand.** *Rationale:* re-running `install.sh` covers the upgrade path; granular runtime surgery is over-engineering for a personal stack.

NG4: **Different profile defaults in backend-only mode.** Backend behavior is identical — same profiles, same models, same defaults. Backend-only is purely about absence of WebUI/OpenCode.

NG5: **Auto-switch network mode to LAN on `--backend-only`.** `network.yaml` still defaults to `mode: local`; operator runs `4lm expose lan --confirm` explicitly. *Rationale:* the two-step exposure is the security contract regardless of intended use.

NG6: **Separate auth/firewall layer for the headless server.** No auth, mTLS, or firewall config added. Operator relies on Tailscale / host firewall / VLAN, as today. Same security model as the parent PRD.

NG7: **Hybrid "installed but disabled" state for WebUI.** No `enabled: false` config knob. Absence = not installed. *Rationale:* avoids tri-state confusion.

NG8: **Multi-host clustering, load-balancing, shared model cache.** Same non-goal as the parent PRD.

## Functional Surface

**Trigger model:** manual install-time flag.

**Configuration surface:** CLI flag on `install.sh` (`--backend-only`); env var on Makefile targets (`BACKEND_ONLY=1`, applies to `make install` and `make bootstrap`).

### FR1 — Install path

- FR1.1 `./install.sh --backend-only` and `make install BACKEND_ONLY=1` skip installing `open-webui` (filter the line from `requirements.txt` before iterating through pipx).
- FR1.2 Same flag skips copying `bin/4lm-webui-start.sh` into `~/.4lm/bin/`.
- FR1.3 Same flag skips installing `launchd/com.4lm.webui.plist` into `~/.4lm/launchd/`.
- FR1.4 Same flag skips appending the `webui.log` rotation entry to `/etc/newsyslog.d/4lm.conf` (only backend log rotation is configured).
- FR1.5 Same flag skips seeding `config/opencode.example.jsonc` to `~/.config/opencode/opencode.jsonc`.

### FR2 — Brewfile split

- FR2.1 `Brewfile` contains dev + core only: `shellcheck`, `shfmt`, `bats-core`, `python@3.12`, `pipx`.
- FR2.2 New `Brewfile-tui` contains `opencode`.
- FR2.3 `make bootstrap` (no flag) runs `brew bundle` against both files. `make bootstrap BACKEND_ONLY=1` runs only against `Brewfile`.
- FR2.4 `./install.sh --backend-only` does not invoke `brew bundle` against `Brewfile-tui`.

### FR3 — Runtime gating in `bin/4lm`

- FR3.1 `bin/4lm` probes `~/.4lm/launchd/com.4lm.webui.plist` existence before dispatching any webui-targeted command. (No marker file, no config field — disk state is the source of truth.)
- FR3.2 `4lm {start|stop|restart} webui` on a backend-only install exits 1 with `WebUI not installed (re-run ./install.sh to enable)` on stderr.
- FR3.3 `4lm {start|stop|restart} all` only acts on components whose plist exists; missing components are silently skipped from the `all` set.
- FR3.4 `4lm autostart {enable|disable} webui` follows FR3.2; `4lm autostart {enable|disable} all` follows FR3.3.
- FR3.5 `4lm logs webui` and `4lm open webui` follow FR3.2.
- FR3.6 `4lm status` omits the WebUI block entirely when the plist is absent (both text and JSON output).
- FR3.7 `4lm doctor` skips webui/opencode checks when their plists/wrappers are absent — no "missing" failures for intentionally absent components.
- FR3.8 Help text in `bin/4lm` is static — always shows `[backend|webui|all]`. The runtime error message disambiguates.

### FR4 — Mode transitions

- FR4.1 Re-running `./install.sh --backend-only` over an existing full install is non-destructive: existing `open-webui` pipx package, webui plist, and webui wrapper stay in place. `install.sh` prints a one-line notice that WebUI artifacts were found and are not being managed in backend-only mode.
- FR4.2 Re-running `./install.sh` (no flag) over an existing backend-only install adds the WebUI + OpenCode layers (installs `open-webui`, copies the webui wrapper + plist, runs `brew bundle` against `Brewfile-tui`, seeds opencode config, appends the newsyslog webui line). Idempotent on subsequent runs.
- FR4.3 `./uninstall.sh` needs no new behavior — it already tolerates missing webui plists/services (existing iteration over labels is a no-op on absent artifacts).

## Constraints

### Platform (inherited)
- macOS, Apple Silicon only.
- Bash 5.x; scripts pass `shellcheck` clean and are formatted by `shfmt -i 2 -ci`.
- Python 3.12 via `pipx` for backend pipx deps.

### Lifecycle (inherited)
- Canonical plists in `~/.4lm/launchd/`; symlinks in `~/Library/LaunchAgents/` only via `4lm autostart enable`.
- Idempotency: parent PRD G5 / AC14 still hold — re-running `install.sh --backend-only` produces zero writes outside `~/.4lm/logs/`.
- Plist `Umask=0077`; log files mode 0600.

### Security (inherited)
- All bind-mode hardening clauses from the parent PRD apply to the backend in backend-only mode (profile-name regex, plist Umask, log mode, `--confirm` gate on `expose lan`).
- LAN-mode WebUI hardening (`WEBUI_SECRET_KEY`, `WEBUI_REGISTRATION_ENABLED=false`) is N/A in backend-only mode — there is no WebUI to harden.

### Performance (new)
- Backend-only install footprint ≥ 200 MB smaller on disk than full install on the same host.
- Backend-only install completes ≥ 30 s faster than full install on a warm pipx/brew cache.

### CI (new)
- GitHub Actions `macos-latest` runs `make check` as a matrix job over `[default, BACKEND_ONLY=1]`. Both must stay green on every PR.

### Distribution (inherited)
- Git clone + `make install`. No PyPI, no Homebrew tap.

## Open Decisions

None.

## References

- [`specs/prd/4lm.md`](./4lm.md) — parent PRD this feature extends.
- [`specs/done/sdd/4lm-rework-2026-05-09.md`](../done/sdd/4lm-rework-2026-05-09.md) — current installer + runtime architecture.
- [`README.md`](../../README.md) — user-facing overview.
- [`CLAUDE.md`](../../CLAUDE.md) — orientation for AI assistants.
