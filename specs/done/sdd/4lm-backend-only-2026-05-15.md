# SDD: 4lm — Backend-Only Install Mode

**Status**: Done
**Finished**: 2026-05-15
**Created**: 2026-05-14
**Refined**: 2026-05-14
**Original**: specs/sdd/4lm-backend-only.md
**PRD**: [`specs/prd/4lm-backend-only.md`](../prd/4lm-backend-only.md)

---

## Overview

Add a `--backend-only` install mode that strips WebUI (`open-webui` pipx tree, `4lm-webui-start.sh`, the webui plist, newsyslog webui rotation) and OpenCode (`opencode` Homebrew formula, `~/.config/opencode/opencode.jsonc` seed) from the install. The runtime CLI (`bin/4lm`) gates webui- and opencode-targeted dispatch on plist/wrapper existence so explicit commands error cleanly while `all`-targets and `status` silently skip absent components. Mode is selected at install time via `./install.sh --backend-only` (or `make install BACKEND_ONLY=1`); install state is read at runtime from disk artifacts, not from a marker file or config field.

## Context & Constraints

- **Stack**: bash 5.x scripts (`bin/4lm`, `bin/4lm-backend-start.sh`, `bin/4lm-webui-start.sh`, `install.sh`, `uninstall.sh`); launchd plists with `__HOME__` placeholder; Python helpers via pipx (`omlx`, `huggingface_hub`, `open-webui`); test harness is `bats-core` with stubbed binaries under `tests/helpers/`.
- **Conventions (from CLAUDE.md)**: `set -euo pipefail`; `shellcheck` clean; `shfmt -i 2 -ci`; canonical plists in `~/.4lm/launchd/`, never `~/Library/LaunchAgents/`; no env-var override for bind mode; idempotent installer.
- **Existing runtime gating pattern**: `bin/4lm` already dispatches `start|stop|restart|autostart|logs|open` over a fixed `{backend, webui, all}` token set; this SDD adds a probe layer in front of that dispatch.
- **Existing CI**: `.github/workflows/ci.yml` runs a single `macos-latest` job invoking `brew bundle --file=Brewfile` then `make check`.
- **Active SDD overlap**: `specs/sdd/webui-tools-and-mcp.md` is adding more webui surface (admin-token, MCPO plist). Those artifacts become part of the optional webui layer and must respect the same plist-existence probe; this SDD documents the contract so the other SDD's phases 4–7 inherit it without re-deciding.
- **Phase independence**: Phase 1 is not independently shippable — `bin/4lm` helpers added in Phase 1 are intentionally unwired until Phase 3. Phases 1–3 must land together as a batch; Phase 4 (CI matrix + docs) is independently mergeable after Phase 3. The Phase 3 commit message must call out the 1–3 batch explicitly.
- **`install.sh` argument parsing**: `install.sh` currently has no argument parsing (no `$@`, no `case`/`while` loop). Phase 2 adds a `while`/`case` argv loop from scratch following the `set -euo pipefail` convention.
- **`opencode` in test harness**: `tests/helpers/opencode` does not yet exist. Phase 1 creates it. Because the stub is always present in the harness PATH after Phase 1, `opencode_installed` in tests distinguishes "present vs. absent" only via the config file check, not the binary check. No `skip_if_no_opencode` helper is required — opencode is always "binary-present" in the test harness; tests exercise the config-file-absent branch directly.

## Architecture

```
INSTALL TIME                          RUNTIME
                                      ┌───────────────────────────────────┐
./install.sh [--backend-only]         │ ~/.4lm/launchd/                   │
       │                              │   com.4lm.backend.  │
       │                              │     plist  ← always               │
       │       full:                  │   com.4lm.webui.    │
       │   ┌─── copy webui plist,     │     plist  ← present iff full     │
       │   │    install open-webui,   └───────────────────────────────────┘
       │   │    Brewfile-tui, seed                       │
       │   │    opencode config,                         ▼
       │   │    newsyslog webui line          bin/4lm dispatch:
       └───┤                                  webui_installed() → probes ${WEBUI_PLIST}
           │   backend-only:                  opencode_installed() → command -v + cfg
           │   skip all of the above          require_component <name> → error path
           ▼                                  all-iteration skips absent
       Backend layer always installed         status omits absent fields
                                              doctor skips absent probes
```

The install-time variant and the runtime probe layer are independent — `bin/4lm`'s gating reads disk state, not flags. `webui_secret_key` is owned exclusively by `bin/4lm-webui-start.sh` (line 12 of that script); it is absent on backend-only installs because `4lm-webui-start.sh` itself is not installed, so `cmd_expose` naturally satisfies PRD AC14 without any extra guard.

## Requirements

R1: `install.sh` shall accept `--backend-only` as a CLI flag at any position in argv. Flag parsing shall be implemented as a `while`/`case` loop added from scratch; no existing parsing pattern is reused.

R2: `install.sh --backend-only` shall filter the `open-webui` line out of the in-memory list derived from `requirements.txt` before iterating through pipx. The on-disk `requirements.txt` shall not be modified.

R3: `install.sh --backend-only` shall skip copying `bin/4lm-webui-start.sh` to `~/.4lm/bin/`.

R4: `install.sh --backend-only` shall skip installing `launchd/com.4lm.webui.plist` to `~/.4lm/launchd/`.

R5: `install.sh --backend-only` shall skip appending the `${HOME}/.4lm/logs/webui.log` rotation entry to `/etc/newsyslog.d/4lm.conf`. The newsyslog block in `install.sh` shall be refactored into two separate `sudo tee -a` appends: one unconditional append for `backend.log`, and one append for `webui.log` only when not in backend-only mode. The header comment line `# logfilename [owner:group] mode count size when flags` is written only by the unconditional backend `sudo tee -a` block, gated by `[[ ! -f "${NEWSYSLOG_CONF}" ]]` so a re-run does not produce a duplicate header. The webui block writes only the rotation entry (no header). Each append is independently guarded by a grep check before writing (see R9). The original single `sudo tee` call that writes both lines together shall be replaced by this two-block structure.

R6: `install.sh --backend-only` shall skip seeding `config/opencode.example.jsonc` to `~/.config/opencode/opencode.jsonc`.

R7: `install.sh --backend-only` shall not invoke `brew bundle --file=Brewfile-tui`.

R8: When `install.sh --backend-only` runs and ANY of the following exist — `~/.4lm/launchd/com.4lm.webui.plist`, `~/.4lm/bin/4lm-webui-start.sh`, or the `open-webui` pipx package (detected via `pipx list --short 2>/dev/null | grep -q '^open-webui'`; if `pipx` is absent the package is treated as absent without error) — the installer shall print the constant `WEBUI_ARTIFACTS_NOTICE` to stdout exactly once, skip the entire webui artifact group (R2–R5 all skipped) without modifying any of those artifacts, and proceed with the backend layer. The presence of any one of these three artifacts triggers skipping the entire group; partial modification is not permitted. `WEBUI_ARTIFACTS_NOTICE` shall be declared `readonly WEBUI_ARTIFACTS_NOTICE="WebUI artifacts found; not managed in backend-only mode."` in `install.sh`.

R9: `install.sh` invoked without `--backend-only` over an existing backend-only install shall install `open-webui` via pipx, copy `4lm-webui-start.sh` into `~/.4lm/bin/`, install the webui plist into `~/.4lm/launchd/`, invoke `brew bundle --file=Brewfile-tui`, seed the opencode example config, and append the `webui.log` entry to `/etc/newsyslog.d/4lm.conf` only when `grep -qE '^[^#]*\.4lm/logs/webui\.log[[:space:]]' "${NEWSYSLOG_CONF}"` returns non-zero. The backend `sudo tee -a` append uses the analogous guard `grep -qE '^[^#]*\.4lm/logs/backend\.log[[:space:]]' "${NEWSYSLOG_CONF}"`. Both guards use `grep -qE`; the legacy `grep -qF` form is removed. These regexes are tighter than bare substring matches — they anchor to the actual newsyslog entry path and trailing whitespace so they do not false-match suffixed variants. No duplicate lines are written on re-runs.

R10: `Brewfile` shall contain exactly the entries currently present minus `opencode`. No other entries shall be added, removed, or reordered.

R11: `Brewfile-tui` (new file) shall contain exactly one `brew "opencode"` entry plus a leading comment line: `# Optional TUI tools — installed by 'make bootstrap' (skipped when BACKEND_ONLY=1).`

R12: `Makefile`'s `bootstrap` target shall run `brew bundle --file=Brewfile` unconditionally and additionally run `brew bundle --file=Brewfile-tui` iff the environment variable `BACKEND_ONLY` is unset or empty.

R13: `Makefile`'s `install` target shall propagate `BACKEND_ONLY=1` to `./install.sh` as `--backend-only` when the env var is set to a non-empty value.

R14: `bin/4lm` shall expose internal helpers `webui_installed()` and `opencode_installed()`. `webui_installed` returns 0 iff `"${WEBUI_PLIST}"` (the existing `readonly WEBUI_PLIST="${LAUNCHD_DIR}/${WEBUI_LABEL}.plist"` constant at line 28 of `bin/4lm`) is a regular file — it shall reference `"${WEBUI_PLIST}"` directly rather than reconstructing the path, so a future `LAUNCHD_DIR` rename keeps detection in sync automatically. `opencode_installed` returns 0 iff `command -v opencode >/dev/null 2>&1` succeeds AND `~/.config/opencode/opencode.jsonc` exists as a regular file. When `opencode_installed` returns 1 due to a missing config file despite `opencode` being in PATH, `require_component opencode` shall use the same error message as the fully absent case — no additional warning is required.

R15: `bin/4lm` shall expose an internal helper `require_component <name>`. When the named component is absent (as determined by its probe in R14), it shall write the corresponding message constant directly to stderr (bypassing `die()`, which prefixes with `${C_RED}error:${C_RST}`) so the constant value reaches stderr verbatim, then exit 1 before any side-effect. Display names are: `webui` → `WebUI`; `opencode` → `OpenCode`. If called with any name other than `webui` or `opencode`, it shall call `die 'require_component: unknown component: <name>'`. The constants shall be declared as:

```bash
readonly WEBUI_MISSING_MSG="WebUI not installed (re-run ./install.sh to enable)"
readonly OPENCODE_MISSING_MSG="OpenCode not installed (re-run ./install.sh to enable)"
```

Tests assert against these constants, not string literals. (See Decision Log for the deliberate divergence from PRD AC6's single error string for opencode commands.)

R16: The following subcommands shall call `require_component webui` before any side-effect when invoked with an explicit webui target: `start webui`, `stop webui`, `restart webui`, `logs webui`, `open webui`, `autostart enable webui`, `autostart disable webui`. `cmd_open` with no argument defaults `target` to `webui`; on a backend-only install the no-arg case shall call `require_component webui` identically to the explicit `open webui` case. The guard in `cmd_autostart` shall be placed in `cmd_autostart` itself before delegation to `_autostart_enable`/`_autostart_disable`, so the canonical `WEBUI_MISSING_MSG` constant (not the `die`-prefixed message) reaches stderr.

R17: The following subcommands shall call `require_component opencode` before any side-effect: `opencode`, `code`.

R18: The `start all`, `stop all`, `restart all`, `autostart enable all`, and `autostart disable all` subcommands shall iterate the static component list `{backend, webui}` and act only on components whose installation probe (R14) returns true. The no-components check is performed before entering the iteration loop: if no component probes return true (corrupted install with both plists absent), the command shall print `no components installed` to stderr and exit 1 without entering the loop. For the `autostart` path, `_autostart_pairs` (lines 1588–1597 of `bin/4lm`) hardcodes both `BACKEND_LABEL` and `WEBUI_LABEL` pairs; the plist-existence filter shall be applied inside `_autostart_pairs` (or equivalently inside its consumers `_autostart_enable`/`_autostart_disable`) so absent components are skipped there too. `_autostart_enable`'s existing `die "error: source plist not found: ${plist}"` is preserved unchanged. The plist-existence filter applied in `_autostart_pairs` prevents that `die` path from being reached for optional components; only the backend pair (always present) ever reaches `_autostart_enable` without prior filtering. If a present component's operation fails, the command shall continue with the remaining present components, print the per-component error to stderr, and exit 1 (not the component's exit code) after all present components have been iterated. If all present components succeed, the command shall exit 0.

R19: `bin/4lm status` (and no-arg invocation) shall conditionally suppress the following output when `webui_installed` returns false:

**Text mode** — suppress these three groups:
- (a) The `Autostart:` line's `webui <state>` portion (the entire line reads `Autostart: backend <state>  ·  webui <state>` today; in backend-only mode omit the `·  webui <state>` segment or omit the line entirely and print `Autostart: backend <state>`).
- (b) The `print_service_status "${WEBUI_LABEL}" "WebUI"` call.
- (c) The `WebUI` URL lines under both `localhost` and `LAN` sections.

**JSON mode** — when `webui_installed` returns false, the following fields shall be omitted (not set to `null`) from the emitted JSON: `autostart.webui`, `services.webui`, `http.webui`. The top-level structure and all other fields remain unchanged. Example shapes:

When webui is absent:
```json
{
  "profile": "default",
  "backend": "omlx",
  "network": {"mode": "local", "lan_ip": null, "backend_port": 8000, "webui_port": 3000},
  "autostart": {"backend": "disabled"},
  "services": {"backend": {"loaded": true, "running": true}},
  "http": {"backend": "ok"},
  "models": ["qwen3:8b"]
}
```

When webui is present:
```json
{
  "profile": "default",
  "backend": "omlx",
  "network": {"mode": "local", "lan_ip": null, "backend_port": 8000, "webui_port": 3000},
  "autostart": {"backend": "disabled", "webui": "disabled"},
  "services": {"backend": {"loaded": true, "running": true}, "webui": {"loaded": false, "running": false}},
  "http": {"backend": "ok", "webui": "fail"},
  "models": ["qwen3:8b"]
}
```

The `backend` block format shall be byte-identical to current behaviour in both modes.

R20: `bin/4lm doctor` shall skip webui-related probes when `webui_installed` returns false and skip the opencode-binary-in-PATH probe when `opencode_installed` returns false. The existing loop `for plist in "${BACKEND_PLIST}" "${WEBUI_PLIST}"` in `cmd_doctor` (lines 1363–1371) fires `warn "missing ${plist}"; fail=1` for any absent plist. This loop shall be restructured into two conditional checks: backend plist check is unconditional (always required); webui plist check fires only when `webui_installed` returns 0. The same conditional pattern applies to the opencode binary probe. No "missing component" failures shall be reported for components whose probes return false. `cmd_diag` (the `diag`/`diagnose` subcommand, lines 484–490) calls `print_clients "$(net_webui_port)" "WebUI"` unconditionally. On a backend-only install this call is harmless (it lists zero connections for a port with no listener) and shall not be changed — no gating is required for `cmd_diag`.

R21: `bin/4lm`'s help text shall remain static — always listing `[backend|webui|all]` and listing `opencode`/`code` subcommands — regardless of installed components. Runtime dispatch errors (R15–R17) are the only disambiguation.

R22: A new bats helper `skip_if_no_webui` shall be added to `tests/helpers/setup.bash`. It shall call `skip "webui not installed in test fixture"` when `${HOME}/.4lm/launchd/com.4lm.webui.plist` does not exist. Tests that require a webui fixture are responsible for creating this file in their `setup` block (e.g., `mkdir -p "${HOME}/.4lm/launchd" && touch "${HOME}/.4lm/launchd/com.4lm.webui.plist"`). The following existing test files shall be audited and shall call `skip_if_no_webui` at the top of each affected test body: `tests/test_webui_start.bats`, `tests/test_autostart.bats` (webui legs only), `tests/test_doctor_phase3_ready.bats`, `tests/sdd_product-review_p2_start_health.bats`, `tests/sdd_product-review_p4_diag.bats`, `tests/sdd_product-review_p5_guards.bats` (webui-dependent tests only; opencode-dependent tests in `p5_guards.bats` are not subject to `skip_if_no_webui` — the `tests/helpers/opencode` stub ensures opencode is always "binary-present" in the harness).

R23: `.github/workflows/ci.yml` shall add `strategy.matrix.install_mode: [default, backend-only]` to the `check` job (YAML key path: `jobs.check.strategy.matrix.install_mode`; job name is `check`, producing GitHub-generated names `check (default)` and `check (backend-only)`). The `Install tooling` step shall additionally run `brew bundle --file=Brewfile-tui` only when `matrix.install_mode == default`. The `make check` step shall set `BACKEND_ONLY=1` only when `matrix.install_mode == backend-only`. Both matrix legs must pass on every PR.

R24: `uninstall.sh` shall not be modified — its existing iteration over backend and webui labels already tolerates missing artifacts (verified by re-running on a backend-only install in tests).

R25: `README.md` and `docs/setup.md` shall add a "Backend-only install" section. `README.md` section shall include: the use case (headless LAN inference server), the `./install.sh --backend-only` command, the two-command quickstart (`./install.sh --backend-only && 4lm expose lan --confirm`), and an architecture-diagram note that the WebUI block is absent in backend-only mode. `docs/setup.md` section shall include: a paragraph explaining the use case, the `./install.sh --backend-only` command, and an `OPENAI_API_BASE_URL=http://<host>:8000/v1` example for consumer hosts.

_(R26 removed — see Decision Log.)_

## File & Module Structure

**New files**:
- `Brewfile-tui` — comment header line plus single `brew "opencode"` entry.
- `tests/helpers/opencode` — create as a minimal executable bash stub (`#!/usr/bin/env bash` + `exit 0`) with `chmod 755`. Provides the "binary present" half of `opencode_installed` tests in the harness; config-file presence is tested separately.
- `tests/test_brewfile_split.bats` — asserts Brewfile contents (no `opencode`), Brewfile-tui contents (exactly `opencode`), `make bootstrap` env-var honouring, and unit-tests `require_component` error path by sourcing `bin/4lm` directly.
- `tests/test_install_backend_only.bats` — integration tests for `install.sh --backend-only`: artifact absence (R2–R7), flag at arbitrary argv position (R1), pipx-list filtering (R2), non-destructive re-install (R8), grep-guarded newsyslog append (R9).
- `tests/test_4lm_component_gating.bats` — unit tests for `bin/4lm` probe helpers, `require_component`, per-subcommand error paths, `all`-target skip logic, `all`-target no-component path (R18), `status` block omission (text + JSON), `doctor` probe skipping.

**Modified files**:
- `Brewfile` — remove the `brew "opencode"` line and its preceding comment block.
- `Makefile` — `bootstrap` target adds conditional second `brew bundle`; `install` target propagates `BACKEND_ONLY=1` as `--backend-only`.
- `install.sh` — update header comment block (lines 1–19) to document `--backend-only` and the conditional steps it skips; add `while`/`case` argv loop (R1); conditional skip blocks for R2–R7; idempotent re-install (R8, R9); `readonly WEBUI_ARTIFACTS_NOTICE` constant; refactored two-block newsyslog append with `grep -qE` guards for both backend and webui lines; header comment written only by the backend block gated on `[[ ! -f "${NEWSYSLOG_CONF}" ]]`.
- `bin/4lm` — add `readonly WEBUI_MISSING_MSG` and `readonly OPENCODE_MISSING_MSG` constants; add `webui_installed`, `opencode_installed`, `require_component` helpers; gate dispatch in `cmd_start`/`cmd_stop`/`cmd_restart`/`cmd_logs`/`cmd_open`/`cmd_opencode`/`cmd_autostart`; update `cmd_status` field emission (text groups a/b/c + JSON fields); update `cmd_doctor` plist loop split; update `_autostart_pairs` for webui probe filtering.
- `tests/helpers/setup.bash` — add `skip_if_no_webui` function.
- `tests/test_webui_start.bats`, `tests/test_autostart.bats`, `tests/test_doctor_phase3_ready.bats`, `tests/sdd_product-review_p2_start_health.bats`, `tests/sdd_product-review_p4_diag.bats`, `tests/sdd_product-review_p5_guards.bats` — prepend `skip_if_no_webui` calls in webui-dependent test bodies.
- `.github/workflows/ci.yml` — add `strategy.matrix.install_mode`, conditional second `brew bundle`, conditional `BACKEND_ONLY=1` env on `make check`.
- `README.md` — add "Backend-only install" subsection; annotate architecture diagram.
- `docs/setup.md` — add "Backend-only install" subsection with `OPENAI_API_BASE_URL` consumer example.

## API Contracts

### CLI flags

| Script | Flag | Behaviour |
|---|---|---|
| `install.sh` | `--backend-only` | Accepted at any argv position via `while`/`case` loop. When present, skip R2–R7. |
| `make bootstrap` | `BACKEND_ONLY=1` (env var) | Skip `brew bundle --file=Brewfile-tui`. |
| `make install` | `BACKEND_ONLY=1` (env var) | Pass `--backend-only` to `./install.sh`. |

### Error message constants (declared `readonly` in source; asserted by name in tests)

| Constant | Value | Location |
|---|---|---|
| `readonly WEBUI_ARTIFACTS_NOTICE` | `WebUI artifacts found; not managed in backend-only mode.` | `install.sh` |
| `readonly WEBUI_MISSING_MSG` | `WebUI not installed (re-run ./install.sh to enable)` | `bin/4lm` |
| `readonly OPENCODE_MISSING_MSG` | `OpenCode not installed (re-run ./install.sh to enable)` | `bin/4lm` |

All three constants are declared `readonly` following the module-level constant convention in their respective files (`bin/4lm` lines 16–49; analogous position in `install.sh`).

### `status --json` schema

The real `cmd_status` emits a flat top-level structure. When `webui_installed` returns false the `autostart.webui`, `services.webui`, and `http.webui` fields are omitted (not nulled). All other fields retain their current shape.

When webui is absent:
```json
{
  "profile": "default",
  "backend": "omlx",
  "network": {"mode": "local", "lan_ip": null, "backend_port": 8000, "webui_port": 3000},
  "autostart": {"backend": "disabled"},
  "services": {"backend": {"loaded": true, "running": true}},
  "http": {"backend": "ok"},
  "models": ["qwen3:8b"]
}
```

When webui is present:
```json
{
  "profile": "default",
  "backend": "omlx",
  "network": {"mode": "local", "lan_ip": null, "backend_port": 8000, "webui_port": 3000},
  "autostart": {"backend": "disabled", "webui": "disabled"},
  "services": {"backend": {"loaded": true, "running": true}, "webui": {"loaded": false, "running": false}},
  "http": {"backend": "ok", "webui": "fail"},
  "models": ["qwen3:8b"]
}
```

The `"webui"` sub-keys under `autostart`, `services`, and `http` are present iff `webui_installed` returns 0. `webui_port` is always emitted (value `3000`; sourced from `net_webui_port()`), regardless of install mode, because the field belongs to the network topology block, not the service-presence block.

## Configuration

| Surface | Name | Type | Values | Default | Effect |
|---|---|---|---|---|---|
| CLI flag | `--backend-only` | bool flag | present / absent | absent | When present, `install.sh` skips webui + opencode artifacts. |
| Env var | `BACKEND_ONLY` | string | `1` (truthy) / `""` (falsy) | unset | When `1`, `make install` passes `--backend-only`; `make bootstrap` skips `Brewfile-tui`. |

No new fields in `network.yaml`. No marker files in `~/.4lm/`.

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| Webui command on backend-only install | `4lm {start\|stop\|restart\|logs\|open\|autostart enable\|autostart disable} webui` or `4lm open` (no arg) when `~/.4lm/launchd/com.4lm.webui.plist` is absent | `require_component webui` writes `WEBUI_MISSING_MSG` directly to stderr (bypassing `die`), exits 1 before any side-effect. | `WebUI not installed (re-run ./install.sh to enable)` to stderr; exit 1. |
| OpenCode command on backend-only install | `4lm opencode` or `4lm code` when `opencode_installed` returns false (binary absent or config missing) | `require_component opencode` writes `OPENCODE_MISSING_MSG` directly to stderr, exits 1. | `OpenCode not installed (re-run ./install.sh to enable)` to stderr; exit 1. |
| `all`-target partial failure | `4lm start all` (etc.) where one present component fails | Iteration continues over remaining present components; final exit code is 1. | Per-component error to stderr; commands for other present components still run. |
| `all`-target no components | `4lm start all` (etc.) where both plists are absent | No-components check fires before entering the iteration loop; exit 1 immediately. | `no components installed` to stderr; exit 1. |
| Newsyslog double-append on re-run | `./install.sh` (full mode) over a host where the `webui.log` line already exists | `grep -qE '^[^#]*\.4lm/logs/webui\.log[[:space:]]'` guard skips the append. | No diff to `/etc/newsyslog.d/4lm.conf`. |
| Non-destructive re-install notice | `./install.sh --backend-only` over an install where any webui artifact exists | R8: print `WEBUI_ARTIFACTS_NOTICE`; skip entire webui artifact group without modification. | `WebUI artifacts found; not managed in backend-only mode.` to stdout; install continues. |
| Unknown component in `require_component` | `require_component backend` or any name other than `webui`/`opencode` | `die 'require_component: unknown component: <name>'` | Error message to stderr with `die` prefix; exit 1. |
| `expose lan` on backend-only install | `4lm expose lan --confirm` when `webui_installed` returns false | `cmd_expose` writes `mode: lan`, restarts backend; `webui_secret_key` is naturally absent because `4lm-webui-start.sh` is not installed. | Normal expose output; no error. |

## Implementation Phases

## Phase 1 — Brewfile split + Makefile wiring + runtime probe helpers

Move `opencode` out of `Brewfile` into a new `Brewfile-tui`. Update `Makefile` so `bootstrap` honours `BACKEND_ONLY` (skips `Brewfile-tui`) and `install` propagates it as `--backend-only` to `install.sh`. Add `readonly WEBUI_MISSING_MSG`, `readonly OPENCODE_MISSING_MSG`, `webui_installed()`, `opencode_installed()`, and `require_component()` to `bin/4lm`. Create `tests/helpers/opencode` as a minimal executable bash stub (`#!/usr/bin/env bash` + `exit 0`; `chmod 755`). Helpers are intentionally unwired from command dispatch until Phase 3; this phase is not independently shippable.

**Files touched**: `Brewfile`, `Brewfile-tui` (new), `Makefile`, `bin/4lm` (helpers + constants only), `tests/helpers/opencode` (new), `tests/test_brewfile_split.bats` (new).

**Phase complete when**:
- `Brewfile` no longer contains `opencode`; `Brewfile-tui` contains the required comment header and exactly one `brew "opencode"` line.
- `make bootstrap` runs both `brew bundle` calls; `make bootstrap BACKEND_ONLY=1` runs only the first.
- `make install BACKEND_ONLY=1` invokes `./install.sh --backend-only` (verified by stubbing `install.sh`).
- `webui_installed`, `opencode_installed`, `require_component` exist in `bin/4lm` with `readonly WEBUI_MISSING_MSG` and `readonly OPENCODE_MISSING_MSG` constants; all pass `shellcheck` and `shfmt -d -i 2 -ci`.
- `require_component webui` exits 1 and writes `WEBUI_MISSING_MSG` verbatim to stderr (unit-tested in `test_brewfile_split.bats` by sourcing `bin/4lm` directly).
- `tests/helpers/opencode` exists, is executable, and contains `#!/usr/bin/env bash` + `exit 0`.
- New bats test `test_brewfile_split.bats` passes.
- `make check` is green.

### Test Scenarios

**GIVEN** the Phase 1 commit is checked out, **WHEN** `grep -c '^brew "opencode"' Brewfile` is run, **THEN** the count is 0.

**GIVEN** the Phase 1 commit is checked out, **WHEN** `grep -c '^brew "opencode"' Brewfile-tui` is run, **THEN** the count is 1.

**GIVEN** a stubbed `brew` recording its `--file` argument to a tmpfile, **WHEN** `make bootstrap` is run, **THEN** both `Brewfile` and `Brewfile-tui` appear in the record.

**GIVEN** the same stub, **WHEN** `make bootstrap BACKEND_ONLY=1` is run, **THEN** only `Brewfile` appears and `Brewfile-tui` does not.

**GIVEN** a stubbed `install.sh` recording argv to a tmpfile, **WHEN** `make install BACKEND_ONLY=1` is run, **THEN** `--backend-only` appears in the recorded argv.

**GIVEN** a bats harness sourcing `bin/4lm` with `HOME` pointing at a tmpdir containing no webui plist, **WHEN** `webui_installed` is called, **THEN** exit code is 1.

**GIVEN** the same harness after `mkdir -p "${HOME}/.4lm/launchd" && touch "${HOME}/.4lm/launchd/com.4lm.webui.plist"`, **WHEN** `webui_installed` is called, **THEN** exit code is 0.

**GIVEN** a harness with `opencode` absent from PATH, **WHEN** `opencode_installed` is called, **THEN** exit code is 1.

**GIVEN** a harness with `opencode` present in PATH (via `tests/helpers/opencode` stub) but `~/.config/opencode/opencode.jsonc` absent, **WHEN** `opencode_installed` is called, **THEN** exit code is 1.

**GIVEN** a bats harness sourcing `bin/4lm` with no webui plist, **WHEN** `require_component webui` is called and stderr is captured, **THEN** exit code is 1 and stderr equals `${WEBUI_MISSING_MSG}` exactly (no `error:` prefix from `die`).

**GIVEN** `bin/4lm` at Phase 1 HEAD, **WHEN** `shellcheck bin/4lm` and `shfmt -d -i 2 -ci bin/4lm` are run, **THEN** both exit 0.

---

## Phase 2 — `install.sh --backend-only` flag

Add a `while`/`case` argv loop to `install.sh` (none exists today). Update the `install.sh` header comment block (lines 1–19) to document `--backend-only` and the conditional steps it skips. Conditionally skip the open-webui pipx entry (R2), the webui wrapper copy (R3), the webui plist install (R4), the newsyslog webui line (R5), the opencode config seed (R6), and the Brewfile-tui `brew bundle` call (R7). Refactor the existing single-call newsyslog block into two guarded `sudo tee -a` appends per R5/R9: the backend block writes the header (gated on `[[ ! -f "${NEWSYSLOG_CONF}" ]]`) and its rotation entry; the webui block writes only its rotation entry. Both guards use `grep -qE`. Detect any-artifact presence for the non-destructive notice (R8); print the `WEBUI_ARTIFACTS_NOTICE` constant and skip the entire webui artifact group. Implement the `grep -qE '^[^#]*\.4lm/logs/webui\.log[[:space:]]'` idempotency guard (R9).

**Files touched**: `install.sh`, `tests/test_install_backend_only.bats` (new), possibly `tests/helpers/setup.bash` (additional stubs if needed).

**Phase complete when**:
- `install.sh` header comment block documents `--backend-only` and the conditional skips.
- `./install.sh --backend-only` in a sandboxed prefix produces zero webui/opencode artifacts (R2–R7).
- `./install.sh --backend-only` with the flag in a non-first position is treated identically to first position (R1).
- `./install.sh --backend-only` over an existing full install prints `WEBUI_ARTIFACTS_NOTICE` exactly once to stdout and leaves all webui artifacts intact.
- `./install.sh` (no flag) over an existing backend-only install adds the missing artifacts and uses the grep-guarded newsyslog append.
- `./install.sh` re-run produces zero writes outside `~/.4lm/logs/` and `~/.4lm/runtime/` (idempotency per PRD AC14 in both modes).
- `test_install_backend_only.bats` passes.
- `make check` green.

### Test Scenarios

**GIVEN** a clean sandboxed prefix with pipx/brew/launchd operations stubbed, **WHEN** `./install.sh --backend-only` is run, **THEN**: exit code is 0; `$HOME/.4lm/launchd/com.4lm.webui.plist` does not exist; `$HOME/.4lm/bin/4lm-webui-start.sh` does not exist; the pipx mock record contains no `open-webui`; the brew mock record contains no `Brewfile-tui`; `$HOME/.config/opencode/opencode.jsonc` does not exist; the stub newsyslog conf contains no `webui.log` line.

**GIVEN** the same sandboxed prefix, **WHEN** `./install.sh arg1 --backend-only` (flag in non-first position), **THEN** the output and artifact set are identical to the previous scenario.

**GIVEN** a sandboxed prefix where the webui plist pre-exists, **WHEN** `./install.sh --backend-only` is run, **THEN** stdout contains exactly the string `WebUI artifacts found; not managed in backend-only mode.`, the plist is unmodified, and exit code is 0.

**GIVEN** a sandboxed backend-only prefix (no webui artifacts), **WHEN** `./install.sh` (no flag) is run, **THEN** the webui plist, webui wrapper, `opencode.jsonc`, and a `webui.log` newsyslog line are created, and `Brewfile-tui` appears in the brew mock record.

**GIVEN** the full-install state from the previous step, **WHEN** `./install.sh` is run a second time, **THEN** the newsyslog stub contains exactly one `webui.log` line (no duplicates).

**GIVEN** any sandboxed install state, **WHEN** `./install.sh [--backend-only]` is run twice, **THEN** the second run produces byte-identical file contents under `$HOME/.4lm/` excluding `logs/` and `runtime/`.

---

## Phase 3 — `bin/4lm` runtime gating

Wire the Phase 1 probe helpers into all webui- and opencode-targeted dispatch. Add the `require_component` call to `cmd_start`, `cmd_stop`, `cmd_restart`, `cmd_logs`, `cmd_open` (including no-arg case), `cmd_opencode` (and its `code` alias), and `cmd_autostart`. Update `all`-target iteration: check for no-components before the loop; skip absent components during iteration; exit 1 with `no components installed` when both plists are absent. Update `_autostart_pairs` to filter by plist existence (preserving `_autostart_enable`'s existing `die` for the backend pair). Update `cmd_status` to suppress the three webui output groups (text) and omit the three webui JSON sub-keys when `webui_installed` returns false. Update `cmd_doctor` to split the plist loop into two conditional checks and gate the opencode probe. Add `skip_if_no_webui` helper to `tests/helpers/setup.bash` and apply it to existing webui-dependent bats tests (R22 list).

**Files touched**: `bin/4lm`, `tests/helpers/setup.bash`, `tests/test_webui_start.bats`, `tests/test_autostart.bats`, `tests/test_doctor_phase3_ready.bats`, `tests/sdd_product-review_p2_start_health.bats`, `tests/sdd_product-review_p4_diag.bats`, `tests/sdd_product-review_p5_guards.bats`, `tests/test_4lm_component_gating.bats` (new).

**Phase complete when**:
- All explicit webui-targeted commands exit 1 with `WEBUI_MISSING_MSG` on stderr when the plist is absent.
- `4lm open` (no arg) exits 1 with `WEBUI_MISSING_MSG` on stderr when webui plist is absent.
- All explicit opencode commands (`opencode`, `code`) exit 1 with `OPENCODE_MISSING_MSG` on stderr when `opencode_installed` returns false.
- `all`-target subcommands perform the no-components check before the loop; silently skip absent components during iteration; exit 0 when remaining succeed; exit 1 on present-component failure with per-component error to stderr.
- `all`-target with both plists absent exits 1 with `no components installed` to stderr (check fires before loop entry).
- `4lm status` omits the WebUI text groups (a/b/c per R19) when plist absent; `4lm status --json` omits `autostart.webui`, `services.webui`, `http.webui` and contains no `"webui"` key in those objects.
- `4lm status --json` with webui plist present contains `"webui"` sub-keys in `autostart`, `services`, and `http`.
- `4lm doctor` runs only backend probes when webui + opencode are absent; reports no missing-component failures.
- All bats tests pass, including the new gating tests and the existing webui tests now gated by `skip_if_no_webui`.

### Test Scenarios

**GIVEN** a fixture with no webui plist, **WHEN** `4lm start webui` is run, **THEN** stderr equals `${WEBUI_MISSING_MSG}` and exit code is 1.

**GIVEN** a fixture with no webui plist, **WHEN** `4lm autostart enable webui` is run, **THEN** stderr equals `${WEBUI_MISSING_MSG}` and exit code is 1.

**GIVEN** a fixture with no webui plist, **WHEN** `4lm open` (no argument) is run, **THEN** stderr equals `${WEBUI_MISSING_MSG}` and exit code is 1.

**GIVEN** a fixture with `opencode` absent from PATH, **WHEN** `4lm opencode` is run, **THEN** stderr equals `${OPENCODE_MISSING_MSG}` and exit code is 1.

**GIVEN** a fixture with backend plist present and webui plist absent, **WHEN** `4lm start all` is run with a launchctl stub that exits 0, **THEN** exit code is 0 and stderr contains no webui error.

**GIVEN** the same fixture with the backend launchctl stub returning exit 1, **WHEN** `4lm start all` is run, **THEN** stderr contains the backend error and exit code is 1.

**GIVEN** a fixture with both backend and webui plists absent, **WHEN** `4lm start all` is run, **THEN** stderr contains `no components installed` and exit code is 1 (no-components check fires before loop entry).

**GIVEN** a fixture with no webui plist, **WHEN** `4lm status` is run, **THEN** stdout does not contain the substring `webui` (case-insensitive check on the output text).

**GIVEN** a fixture with no webui plist, **WHEN** `4lm status --json` is run, **THEN** the output is valid JSON and `echo "$output" | grep -qv '"webui"'` exits 0 (no `"webui"` key present in any object).

**GIVEN** a full-install fixture (webui plist present), **WHEN** `4lm status --json` is run, **THEN** `echo "$output" | grep -q '"webui"'` exits 0 (at least one `"webui"` key is present).

**GIVEN** a fixture with no webui plist, **WHEN** `4lm doctor` is run, **THEN** exit code is 0 and stdout contains neither `open-webui not found` nor `opencode not found`.

---

## Phase 4 — CI matrix + docs

Add `strategy.matrix.install_mode: [default, backend-only]` to the `check` job in `.github/workflows/ci.yml` at key path `jobs.check.strategy.matrix.install_mode`. Conditionally run `brew bundle --file=Brewfile-tui` only on the `default` leg. Conditionally set `BACKEND_ONLY=1` on the `backend-only` leg's `make check` step. Update README and `docs/setup.md` with the backend-only section per R25.

**Files touched**: `.github/workflows/ci.yml`, `README.md`, `docs/setup.md`.

**Phase complete when**:
- `grep -c 'install_mode' .github/workflows/ci.yml` is ≥ 1 and `grep -c 'backend-only' .github/workflows/ci.yml` is ≥ 1.
- `grep 'BACKEND_ONLY' .github/workflows/ci.yml` output shows the env var conditioned on the `backend-only` matrix leg.
- README has a "Backend-only install" subsection with `--backend-only` flag reference and architecture-diagram note.
- `docs/setup.md` has a "Backend-only install" subsection; `grep 'OPENAI_API_BASE_URL' docs/setup.md` matches a line containing `8000/v1`.
- `make check BACKEND_ONLY=1` exits 0 locally with no bats test reporting FAIL.

### Test Scenarios

**GIVEN** the modified `.github/workflows/ci.yml`, **WHEN** `grep -c 'backend-only' .github/workflows/ci.yml` is run, **THEN** count is ≥ 1 and `grep -c 'install_mode' .github/workflows/ci.yml` is ≥ 1.

**GIVEN** the modified `.github/workflows/ci.yml`, **WHEN** `grep -B5 'BACKEND_ONLY' .github/workflows/ci.yml` is inspected, **THEN** the `BACKEND_ONLY=1` assignment is inside a conditional block that references `backend-only` (not unconditional).

**GIVEN** the updated `README.md`, **WHEN** `grep -c -- '--backend-only' README.md` is run, **THEN** count is ≥ 1.

**GIVEN** the updated `docs/setup.md`, **WHEN** `grep 'OPENAI_API_BASE_URL' docs/setup.md` is run, **THEN** the matching line contains `8000/v1`.

**GIVEN** `make check` run locally with `BACKEND_ONLY=1`, **WHEN** it completes, **THEN** exit code is 0 and no bats test reports FAIL.

**MANUAL**: GIVEN a PR opened against `main`, WHEN CI runs, THEN the Actions UI shows `check (default)` and `check (backend-only)` and both report green.

## Decision Log

| Considered | Decision | Reason |
|---|---|---|
| Per-component flags (`--no-webui`, `--no-opencode`) | Single `--backend-only` flag | YAGNI; use case is binary (per parent PRD NG1). |
| Runtime toggle without re-install (`4lm component disable webui`) | Install-time flag only | `install.sh` is idempotent; runtime toggle adds state without solving a real problem (PRD NG2). |
| Marker file at `~/.4lm/.backend-only` | Plist-existence probe | Disk state of the plist is already the source of truth; one less file to keep in sync. |
| Config field in `network.yaml` (`components.webui: false`) | Plist-existence probe | Avoids tri-state confusion; install state shouldn't live in runtime config. |
| Dynamic help text adapting to installed components | Static help text | Single source of truth; runtime dispatch error is enough disambiguation. |
| Destructive `./install.sh --backend-only` (strip WebUI) | Non-destructive | Don't surprise the operator; `uninstall.sh` is the destructive path. |
| Single `Brewfile`, filter `opencode` at install time | Split into `Brewfile` + `Brewfile-tui` | `brew bundle` honours the file it's pointed at; clean separation, no runtime filtering, no awk parsing of Brewfile. |
| Same error string `WebUI not installed...` for opencode commands (literal PRD AC6) | Per-component error: `OpenCode not installed...` for `opencode`/`code` | Accuracy outweighs literal fidelity. PRD AC6's intent (dispatch-time error is the only disambiguation) supports specialised messages. PRD AC6 was reconciled on 2026-05-15 to match this decision. |
| Auto-detect installed open-webui via PATH (`command -v open-webui`) | Probe the plist file instead | Avoids accidental detection of user-installed-elsewhere `open-webui`; ties detection to 4lm-managed artifacts only (matches PRD AC5). |
| Move `llmfit` and `ollama` to a separate optional file | Keep both in core `Brewfile` | `ollama` is a supported backend (default profile uses it); `llmfit` is used by `4lm recommend`. Both are part of the backend layer, not the optional client layer. |
| CI matrix runs `make install` end-to-end | CI matrix only runs `make check` with `BACKEND_ONLY` env var; install paths are exercised inside bats sandboxed prefixes | Avoids touching the CI runner's real `~/.4lm/`; bats tests already simulate install in tmpdirs via stub harness. |
| Merge `bin/4lm` helper additions into Phase 3 | Add helpers in Phase 1 (unwired), wire in Phase 3 | Brewfile split + Makefile wiring is a logical Phase 1 unit; adding helpers in the same commit keeps the `bin/4lm` diff coherent. The unwired state is explicitly documented so no dead-code confusion arises. |
| R8 check "any of three artifacts" — skip individual artifacts found | Skip entire webui artifact group when any artifact exists | Partial state (some artifacts missing) is ambiguous; treating any presence as "webui is present" avoids partial modification and operator surprise. |
| `require_component` using `die()` for error output | Write directly to stderr, bypassing `die()` | `die()` prefixes with `${C_RED}error:${C_RST}`; tests assert on bare constant value; bypassing `die` keeps the constant verbatim. (Validate-finding #1.) |
| R26 — `cmd_expose` skipping `webui_secret_key` | Removed | `webui_secret_key` is owned by `bin/4lm-webui-start.sh`, not by `cmd_expose`. The file is naturally absent on backend-only installs because `4lm-webui-start.sh` is not installed. No guard needed. (Validate-finding #9.) |
| `yq` in Phase 4 CI verification | Use `grep` instead | `yq` is not in `Brewfile` and not in the test harness; `grep` achieves the same verification with available tooling. |
| `4lm open` no-arg case on backend-only | Gate with `require_component webui` | `cmd_open` defaults target to `webui`; calling it with no arg on a backend-only install would otherwise silently open a non-existent WebUI URL. Same gate as explicit `open webui`. |
| `skip_if_no_opencode` helper for test harness | Not needed; use `tests/helpers/opencode` stub instead | The stub ensures opencode is always "binary-present" in the harness; `opencode_installed` tests exercise the config-file-absent branch directly without needing a skip helper. (Refine-A finding.) |
| R18 no-components check placement — after iterating empty list | Before entering the iteration loop | Cleaner semantics; avoids iterating an empty set just to discover nothing ran. Makes the pre-condition explicit and consistent with the Error Handling table. (Refine-A finding.) |
| `webui_port` in `status --json` — omit when webui absent | Always emit `webui_port: 3000` | The field belongs to network topology (sourced from `net_webui_port()`), not service-presence. Omitting it would break consumers that read `network.webui_port` regardless of install mode. (Validate-finding round 2, amendment 1.) |

## Open Decisions

None.

## Out of Scope

- **Per-component flags** (`--no-webui`, `--no-opencode`) — single `--backend-only` only.
- **Runtime add/remove subcommand** (`4lm component install webui`) — re-running `install.sh` is the upgrade path.
- **Different profile defaults in backend-only mode** — backend behaviour is identical.
- **Auto-switch network mode to LAN on `--backend-only`** — `4lm expose lan --confirm` is still the only channel.
- **Auth / mTLS / firewall layer for the headless server** — operator relies on Tailscale / VLAN / host firewall (parent PRD's security model).
- **Hybrid "installed but disabled" state for WebUI** — absence = not installed.
- **Multi-host clustering, load-balancing, shared model cache** — parent PRD's non-goal.
- **Changes to `uninstall.sh`** — existing iteration already tolerates missing artifacts (R24).
- **PRD AC6 string reconciliation** — done on 2026-05-15: PRD AC6 now specifies per-component messages matching the SDD/implementation.
- **`cmd_diag` webui gating** — `cmd_diag` calls `print_clients "$(net_webui_port)" "WebUI"` unconditionally; on backend-only installs this is harmless (no connections listed) and requires no change.

## References

- [`specs/prd/4lm-backend-only.md`](../prd/4lm-backend-only.md) — PRD this SDD implements.
- [`specs/prd/4lm.md`](../prd/4lm.md) — parent product PRD; this feature inherits its security model, idempotency guarantees, and non-goals.
- [`specs/sdd/webui-tools-and-mcp.md`](./webui-tools-and-mcp.md) — active SDD adding more webui surface; its artifacts join the optional layer and must respect this SDD's probe contract.
- [`specs/done/sdd/4lm-rework-2026-05-09.md`](../done/sdd/4lm-rework-2026-05-09.md) — current installer + runtime architecture this SDD modifies.
- [`CLAUDE.md`](../../CLAUDE.md) — bash conventions, plist conventions, `4lm` activation model.
