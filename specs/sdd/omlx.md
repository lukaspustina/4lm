# SDD: omlx as the primary MLX backend (and opt-in autostart)

Status: Phase 1 Complete
Original: specs/sdd/omlx.md
Refined: 2026-05-09

## Overview

Replace `mlx-openai-server` with `omlx` (github.com/jundot/omlx) as 4lm's
primary MLX backend while preserving `mlx_lm` and `ollama` as the second and
third backends. Add an opt-in `4lm autostart` subcommand so services can
launch at user login while preserving the existing operator-control philosophy
(no autostart by default, LAN-confirm gate, single config channel).

## Context & Constraints

- Stack: bash (`bin/4lm`, ~1,551 lines), small Python helper (`bin/4lm_helpers.py`),
  bats tests, GitHub Actions CI (shellcheck / shfmt / plutil / xmllint / bats).
- Conventions: `set -euo pipefail`, shellcheck-clean, shfmt-formatted, `__HOME__`
  placeholder in plists.
- Hardware target: M5 Max, 128 GB unified memory, macOS 15+ (omlx requires Sequoia).
- `backend:` today accepts `mlx | mlx_lm | ollama`. Phase 1 adds `omlx`. Phase 3
  drops `mlx`.
- Deliberate no-autostart launchd model: plists in `~/.4lm/launchd/`, not
  `~/Library/LaunchAgents/`. Phase 4 adds opt-in symlink-based LaunchAgent.
- Single config channel via `~/.4lm/config/network.yaml`. `4lm expose lan --confirm`
  is the LAN gate.
- Python pinned to 3.12 via pipx (mlx-openai-server constraint, removed in Phase 3).
- Writable subtrees: `~/.4lm/cache/`, `~/.4lm/runtime/`, `~/.4lm/logs/`.
- `~/.omlx/` is omlx's native config directory. 4lm only writes `settings.json`
  there; admin-panel-driven changes are not reconciled.
- omlx pinned version: start from `0.3.8`; implementer may bump to the newest stable
  release available at implementation time and records the chosen version in
  `requirements.txt`.
- YAML parsing: line-oriented `grep`/`awk` only (no `yq`, no Python in bash).
  JSON emitted via `jq` (already in Brewfile). HF sha resolved via existing
  `hf_local_sha()` at `bin/4lm:146`, reading `refs/main`.
- Stderr policy: in `bin/4lm` only `die`/`warn` may write to stderr — enforced by
  `tests/test_4lm_dispatch.bats:144`'s `grep -c 'echo.*>&2' = 2` assertion. In
  `bin/4lm-backend-start.sh`, use the existing
  `echo "[$(date -Iseconds)] FATAL: <msg>" >&2; exit <code>` pattern;
  `die`/`warn` are not available there (file cannot source `bin/4lm`, see line 47).
- Existing timestamp convention: `date -Iseconds` (local time with offset suffix,
  e.g. `2026-05-09T09:40:00+02:00`). No UTC timestamps anywhere.
- Lockfile uses `mkdir` + pid-file; cleanup uses `rm -rf` because the lock directory
  is non-empty (contains `pid` file) by the time the trap fires.
- `validate_profile()` uses `warn "$message"; return 1` throughout — it must not
  call `die`. The `warn:` prefix is used in `validate_profile()` output; `error:`
  prefix is used in `render_omlx_settings()` and `bin/4lm-backend-start.sh` output.
- This SDD supersedes neither `specs/sdd/4lm-rework.md` nor
  `specs/sdd/ollama-backend.md`; it builds on them.

## Architecture

```
       ┌─────────────────── 4lm CLI (operator) ───────────────────┐
       │  start / stop / status / health / logs / expose          │
       │  profile set <name>   (atomic, rollback)                 │
       │  autostart enable|disable|status   (NEW, opt-in)         │
       │  code / opencode                                         │
       └────────────────────────────┬─────────────────────────────┘
                                    │ launchctl bootstrap
                                    ▼
       ┌─────────────────── ~/.4lm/launchd/ plists ───────────────┐
       │  com.4lm.backend                           │
       │  com.4lm.webui                             │
       └────────────┬───────────────────────┬─────────────────────┘
                    │                       │
                    ▼                       ▼
            ┌──────────────┐        ┌──────────────┐
            │ omlx | mlx_lm│        │  open-webui  │
            │ | ollama     │        │   :3000      │
            │  :8000       │        │              │
            └──────────────┘        └──────────────┘
```

**Engine choice is per profile:**
- `omlx` — multi-model in one process, paged + tiered KV cache, continuous
  batching, DFlash speculative decoding for Qwen, Anthropic + OpenAI APIs.
- `mlx_lm` — Apple's official `python -m mlx_lm server`, single model, no
  wrapper between you and upstream.
- `ollama` — GGUF / llama.cpp ecosystem, different model coverage.

**Config surfaces and precedence for omlx:**
- `~/.4lm/config/network.yaml`: provides `--host` and `--port` (highest
  precedence, passed as CLI flags to `omlx serve`).
- `omlx:` block in profile YAML: provides `--max-process-memory`,
  `--max-model-memory`, `--hot-cache-max-size`, `--paged-ssd-cache-dir`,
  `--max-concurrent-requests` (all passed as CLI flags to `omlx serve`).
- `~/.omlx/settings.json`: provides per-model fields (`served_model_name`,
  `pin`, `ttl`, `model_type`, `chat_template_kwargs`, `sampling`). This file
  is a derived runtime artifact rendered from the active profile YAML by
  `render_omlx_settings()` in `bin/4lm`. CLI flags take precedence over
  settings.json where both exist.
- Profile YAML is the single source of truth. `~/.omlx/settings.json` is
  never edited by hand.

## Requirements

1. The system shall accept `backend: omlx` as a fourth valid value in profile
   YAML (Phase 1), alongside `mlx | mlx_lm | ollama`.

2. `profile_backend()` at `bin/4lm:221-234` shall be extended to echo `omlx`
   when the profile YAML contains `backend: omlx`. This is a Phase 1
   prerequisite: without it, `validate_profile()` calls `profile_backend()`
   first and returns non-zero, masking all omlx-specific validation. The four
   callers at lines 437, 1079, 1238, and 1313 that fall back to `|| echo "mlx"`
   will otherwise silently misclassify omlx profiles. (`run_outdated_check`,
   `_doctor_check_models_cached`, `cmd_models_download`, `cmd_models_cleanup`).

3. `validate_profile(yaml_path)` in `bin/4lm` shall accept `backend: omlx`
   profiles with required top-level keys `backend` and `models`, and optional
   `omlx:` block. An absent `omlx:` block is valid; no CLI flags beyond
   `--host`/`--port` are passed and omlx uses its built-in defaults.
   `validate_profile()` uses `warn "$message"; return 1` throughout — it must
   not call `die`.

4. `validate_profile(yaml_path)` shall validate each entry in `models:` for
   required fields `model_path` (string) and `served_model_name` (string), and
   optional fields `pin` (bool), `ttl` (int or null), `model_type` (one of
   `lm` | `vlm`), `chat_template_kwargs` (dict), `sampling` (dict). Validation
   rules:
   - `ttl:` is valid when: the key is absent, the value is the literal string
     `null`, or `[[ "$val" =~ ^[0-9]+$ ]]`. Any other value causes
     `validate_profile()` to exit non-zero naming `ttl` as invalid.
   - `model_path` shall match `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`
     (HuggingFace `org/repo` format). Non-matching values cause
     `validate_profile()` to exit non-zero naming `model_path` as invalid.
   - `model_type`, when present, must be exactly `lm` or `vlm`. Any other
     value causes `validate_profile()` to exit non-zero naming `model_type` as
     invalid.
   - Per-entry field extraction shall use stateful awk block-scanning anchored
     on `- model_path:`. A new `- model_path:` line or EOF terminates the
     previous block. `profile_model_entries()` at `bin/4lm:169` is a
     *pattern reference* for awk block-scanning; each new function writes its
     own awk block extracting the fields it needs. Do not call
     `profile_model_entries()` directly.

5. `render_omlx_settings(yaml_path, output_path)` in `bin/4lm` shall read the
   profile at `yaml_path` and write the per-model settings to `output_path` in
   the JSON structure omlx expects (see Data Models). It shall:
   - Run `mkdir -p ~/.omlx/` before writing.
   - Extract profile fields with awk block-scanning anchored on `- model_path:`;
     a new `- model_path:` line or EOF terminates the previous block (same awk
     pattern reference as Req 4). Emit JSON with `jq`. Python is not used in
     this function.
   - Pass awk-extracted bool strings (e.g. `pin: true`) via `--argjson` in jq
     so `true`/`false` emit as JSON booleans, not quoted strings.
   - Emit one `jq` object per model entry containing only present fields
     (`ttl: null` in YAML emits `"ttl": null` in JSON; an absent `ttl:` key
     emits nothing; empty dicts `{}` for `chat_template_kwargs` or `sampling`
     are omitted).
   - Exit non-zero with a descriptive error message if `models:` is empty or a
     required per-model field is missing.
   - Exit non-zero with `error: cannot write settings: <path>: <errno>` if the
     output file cannot be written (disk full, directory not writable).
   - All stderr output goes through `die`/`warn`; no direct `echo … >&2` in
     `bin/4lm`.

6. `bin/4lm` shall call `render_omlx_settings "$yaml" ~/.omlx/settings.json`
   inside `4lm profile set` before invoking `launchctl bootstrap`. Failure of
   `render_omlx_settings()` triggers rollback (see Req 9).

7. The system shall propagate `~/.4lm/config/network.yaml` host and port to
   omlx via `--host` and `--port` flags in `bin/4lm-backend-start.sh`,
   identical to the current mlx-openai-server pattern.

8. `bin/4lm-backend-start.sh` shall pass `omlx:` block fields to `omlx serve`
   as CLI flags:
   - `max_process_memory` → `--max-process-memory`
   - `max_model_memory` → `--max-model-memory`
   - `hot_cache_max_size` → `--hot-cache-max-size`
   - `paged_ssd_cache_dir` → `--paged-ssd-cache-dir`
   - `max_concurrent_requests` → `--max-concurrent-requests`

   Fields absent from the YAML are omitted (not passed as empty strings).
   `paged_ssd_cache_dir` shall be tilde-expanded via `${val/#\~/$HOME}` (no
   `eval`) into `${expanded}`, then validated with two sequential checks:
   1. Component check (path-traversal prevention): if `${expanded}` contains
      `/../`, starts with `../`, or ends with `/..`, exit non-zero.
   2. Regex check: `[[ "${expanded}" =~ ^[a-zA-Z0-9_./-]+$ ]]` or exit non-zero.
   Both checks use the existing
   `echo "[$(date -Iseconds)] FATAL: invalid paged_ssd_cache_dir value: ${val}" >&2; exit 78`
   pattern. Values failing either check cause exit non-zero.
   `max_process_memory` and `max_model_memory` accept any non-empty string
   (passed as-is; no format validation). The `omlx:` block is extracted using a
   standalone awk one-liner (same block-scanning pattern as `bin/4lm`);
   `bin/4lm-backend-start.sh` cannot source `bin/4lm` (see comment at line 47).
   In `bin/4lm-backend-start.sh`, stderr output uses the existing
   `echo "[$(date -Iseconds)] FATAL: <msg>" >&2; exit <code>` pattern; `die`/`warn`
   are not available there.

9. `4lm profile set` shall preserve atomic rollback semantics:
   1. Validate new profile via `validate_profile()`.
   2. Save prior symlink target.
   3. Call `render_omlx_settings "$yaml" ~/.omlx/settings.json` (omlx profiles only).
   4. Call `stage_omlx_model_dir()` (omlx profiles only).
   5. Swap the `active-profile` symlink.
   6. Kickstart the backend service.
   7. Poll `/v1/models` for 30 s.

   Any failure at steps 1–4 (before `launchctl bootstrap`) triggers rollback
   to the prior symlink and kickstarts on the prior config. Poll timeout at
   step 7 triggers the same rollback. `log_rollback_event()` is called
   whenever rollback is triggered. `4lm profile set` exits non-zero in all
   rollback cases.

   The existing poll-timeout rollback block in `cmd_profile_set()` (currently
   `bin/4lm:879–910`) shall also call
   `log_rollback_event(prior, attempted, poll_timeout)` immediately before
   invoking the rollback restoration. This applies to all backends, not just
   omlx.

10. A lockfile at `~/.4lm/runtime/profile.lock` shall be acquired for the
    duration of `4lm profile set`. GNU `flock` is not used (not available on
    macOS without Homebrew). `mkdir` is atomic on APFS/HFS+. Full lockfile
    implementation:
    ```bash
    if ! mkdir ~/.4lm/runtime/profile.lock 2>/dev/null; then
      _lock_pid="$(cat ~/.4lm/runtime/profile.lock/pid 2>/dev/null || true)"
      if [[ -n "${_lock_pid}" ]] && ! kill -0 "${_lock_pid}" 2>/dev/null; then
        rm -rf ~/.4lm/runtime/profile.lock 2>/dev/null || true
        mkdir ~/.4lm/runtime/profile.lock || die 'profile set already in progress'
      else
        die 'profile set already in progress'
      fi
    fi
    echo "$$" > ~/.4lm/runtime/profile.lock/pid
    trap 'rm -rf ~/.4lm/runtime/profile.lock 2>/dev/null || true' EXIT
    ```
    `rm -rf` is used (not `rmdir`) because the lock directory contains a `pid`
    file by the time the trap fires; `rmdir` only removes empty directories and
    would silently no-op, leaving a stale lock. `rm -rf` on the fixed path
    `~/.4lm/runtime/profile.lock` (no user-controlled segments) is safe.
    `$$` is the shell PID of the `4lm profile set` invocation. A stale lockfile
    (left by a crashed prior invocation) is detected by reading `pid` and calling
    `kill -0`; if the PID is not live, the lock directory is removed and re-created.

11. `stage_omlx_model_dir(profile_name, yaml_path)` in `bin/4lm` shall, for
    each model in the active omlx profile:
    - Run `mkdir -p ~/.4lm/runtime/<profile_name>/models/` as the first step.
    - Resolve the HF snapshot SHA by calling the existing `hf_local_sha(repo_id)`
      helper (reads `~/.cache/huggingface/hub/models--<slug>/refs/main`).
    - Build new symlinks in a temporary directory (`mktemp -d`) first; on
      success, use `find ~/.4lm/runtime/<profile_name>/models/ -maxdepth 1 -type l -delete`
      to remove old symlinks, then `mv` the new ones into place. This prevents
      leaving an empty model dir on partial failure.
    - On failure, `rm -rf` the temp dir before returning non-zero.
    - Create a symlink at
      `~/.4lm/runtime/<profile_name>/models/<served_model_name>` pointing to
      `~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<sha>/`.
    - Apply the same `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` format check on
      `model_path` as defense-in-depth (identical to Req 4).
    - Exit non-zero with `error: HF model not found: <path>` if `refs/main` is
      absent or the resolved `snapshots/<sha>/` directory does not exist (no
      automatic download).
    - Add `# TODO(phase2-probe): remove if omlx accepts absolute HF snapshot paths`
      at the top of the function body.
    - All stderr output goes through `die`/`warn`; no direct `echo … >&2` in
      `bin/4lm`.

12. `install.sh` shall:
    - Run `pipx install omlx==<pinned>`.
    - Create `~/.4lm/cache/omlx/` (idempotent).
    - Create `~/.4lm/runtime/` (idempotent) — required so the lockfile `mkdir`
      in Req 10 has a parent directory on fresh installs.
    - Create `~/.omlx/` with mode 0700 (idempotent).
    - Not remove `mlx-openai-server` (that happens in Phase 3).

13. Phase 2 shall migrate `config/profiles/default.yaml`, `mlx-coding.yaml`,
    `mlx-knowledge.yaml`, and `exp-mlx-full.yaml` from their current backends
    to `backend: omlx` after operator-verified adequate omlx uptime with no
    regressions. "Adequate uptime" is operator-judged (not code-tracked);
    the minimum signal is: the launchctl service shows `state = running` per
    `launchctl print` with no `profile set` rollback triggered since the
    `active-profile` symlink was last written, and all bats tests are green.

14. Phase 2 shall remove the "Gemma 4 forces ollama" caveat from `default.yaml`
    and `CLAUDE.md` once Gemma 4 31B has been verified to run on omlx without
    crash. "Crash" is defined as: omlx process exits non-zero OR
    `~/.omlx/logs/server.log` contains the string `BatchRotatingKVCache`.
    This is a manual verification gate requiring a 32k-token request (Req 25).

15. Phase 3 shall remove `mlx-openai-server` from `install.sh`,
    `requirements.txt`, `validate_profile()` in `bin/4lm`, and
    `bin/4lm-backend-start.sh`. The merge gate is operator-triggered after
    `4lm doctor phase3-ready` exits 0 / prints `green` (Req 28).

16. Phase 3 `validate_profile()` shall exit non-zero with the message
    `warn: backend 'mlx' is no longer supported; use 'omlx'` when given a
    profile with `backend: mlx`.

17. Phase 3 shall preserve `backend: mlx_lm` and `backend: ollama` unchanged.

18. Phase 3 shall update `bin/4lm-backend-start.sh`'s `mlx_lm` Python
    interpreter discovery (currently at lines 93–111) to replace the
    mlx-openai-server-based lookup with
    `~/.local/pipx/venvs/omlx/bin/python3` (omlx co-installs `mlx_lm`).
    The fallback error message shall drop the mlx-openai-server reference and
    name omlx instead.

19. Phase 4 shall add subcommand `4lm autostart {enable|disable|status}
    [backend|webui]`. The argument `backend` maps to plist label
    `com.4lm.backend`; `webui` maps to
    `com.4lm.webui`. If no service argument is given for
    `enable`/`disable`, the subcommand defaults to `backend` silently (no
    warning printed, behavior identical to specifying `backend` explicitly).
    With no subcommand (`4lm autostart` bare), print
    `error: usage: 4lm autostart {enable|disable|status} [backend|webui]`
    and exit non-zero.

20. `4lm autostart enable <service>` shall:
    - Check that `~/.4lm/launchd/<label>.plist` exists; exit non-zero with
      `error: source plist not found: <path>` if missing.
    - If the symlink `~/Library/LaunchAgents/<label>.plist` already exists and
      `readlink` returns the correct source plist path, exit 0 (idempotent).
    - Otherwise, create or replace the symlink atomically:
      `ln -sfn ~/.4lm/launchd/<label>.plist ~/Library/LaunchAgents/<label>.plist`.
      `ln -sfn` replaces an existing symlink in a single syscall (APFS-atomic,
      no TOCTOU window); use it for both the "does not exist" and "wrong target"
      cases.
    - Run `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`.
    - If `launchctl bootstrap` fails, remove the just-created symlink and exit
      non-zero with the launchctl error message.

21. `4lm autostart disable <service>` shall run
    `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`
    (no error if not loaded) and remove the symlink
    `~/Library/LaunchAgents/<label>.plist`. The source plist
    `~/.4lm/launchd/<label>.plist` shall not be touched.

22. `4lm autostart status` shall be read-only: no file writes, no launchctl
    mutations. Output format: one line per service, `<service>  <enabled|disabled>`,
    where service names are `backend` and `webui`. Exit 0 always. "Enabled"
    means the LaunchAgents symlink exists.

23. Phase 4 launchd plist templates (`launchd/com.4lm.backend.plist`,
    `launchd/com.4lm.webui.plist`) shall include:
    ```xml
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    ```
    `RunAtLoad` is intentional for both the manual `4lm start` path and the
    autostart login path; the behavior is identical in both cases. These keys
    become effective for persistent restart behavior only when the plist is
    registered in `~/Library/LaunchAgents/`. When bootstrapped manually via
    `4lm start`, `4lm stop` calls `launchctl bootout` which removes the
    supervision context entirely, so KeepAlive does not activate for
    manually-managed services. Add a comment in the plist diff noting this
    Phase 1 gap (plists used from Phase 1 without these keys).

24. `uninstall.sh` shall, for each label in
    `{com.4lm.backend, com.4lm.webui}`:
    - Run `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`
      (no error if not loaded).
    - Remove `~/Library/LaunchAgents/<label>.plist` if present.
    This is idempotent on systems that never enabled autostart.

25. The system shall not introduce a dependency on `brew services` or the omlx
    `.app` bundle. omlx is installed via pipx only.

26. The Gemma 4 31B 32k-token test (Req 14, Phase 2) and the Phase 4 reboot
    startup test are manual verification gates. They are not CI criteria.

27. `log_rollback_event(prior_profile, attempted_profile, reason)` in `bin/4lm`
    shall append a single tab-separated line to
    `~/.4lm/logs/profile-rollback.log` whenever rollback is triggered.
    Format: `<timestamp>\t<prior_profile>\t<attempted_profile>\t<reason>`,
    where `<timestamp>` is `date -Iseconds` output (local time with offset
    suffix, e.g. `2026-05-09T09:40:00+02:00`), and `<reason>` is one of:
    `validate | render_settings | stage_models | kickstart | poll_timeout`.
    - If `~/.4lm/logs/` is absent at call time, create it with mode 0755
      before writing.
    - The log file is created on first append with mode 0644. Use the idiom:
      `[[ -f "$log" ]] || { touch "$log"; chmod 0644 "$log"; }` before the
      append.
    - No log entry is written on successful profile set.
    - All stderr output goes through `die`/`warn`; no direct `echo … >&2` in
      `bin/4lm`.

28. `4lm doctor phase3-ready` shall be dispatched via `cmd_doctor "$@"` with
    the following guard as the first statement of `cmd_doctor()`:
    ```bash
    cmd_doctor() {
      if [[ "${1:-}" == "phase3-ready" ]]; then
        cmd_doctor_phase3_ready
        return
      fi
      # ... existing doctor logic
    }
    ```
    Without this guard, the full doctor preamble runs before any phase3-ready
    logic. Dispatch change in `bin/4lm`: change line ~1533 from
    `doctor) cmd_doctor ;;` to `doctor) cmd_doctor "$@" ;;`.
    Update `cmd_help()` (at `bin/4lm:1484`) to show `4lm doctor [phase3-ready]`
    instead of `4lm doctor` with no args.

    `cmd_doctor_phase3_ready()` is a read-only check. It exits 0 and prints
    `green: no rollback events since <timestamp>` when ALL of:
    - (a) `~/.4lm/logs/profile-rollback.log` is absent, empty, or its latest
      entry has a timestamp older than the mtime of
      `~/.4lm/config/active-profile`.
    - (b) The active profile's `backend:` value is `omlx` (read from the
      symlink target of `~/.4lm/config/active-profile`).

    It exits 1 and prints `red: <reason>` otherwise. `<reason>` names which
    condition failed; if condition (a) failed, it includes the offending log
    line. The mtime comparison shall use `stat -f %m <path>` (epoch seconds)
    on the symlink itself (not the target; intent is to track when `profile set`
    last ran, which writes the symlink), and `date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts" +%s`
    to convert the log-line timestamp to epoch. All stderr output goes through
    `die`/`warn`.

## File & Module Structure

| Path | Phase | Change |
|---|---|---|
| `bin/4lm` | 1, 3, 4 | Phase 1: extend `profile_backend()` (lines 221–234) to echo `omlx` for `backend: omlx` profiles (prerequisite first); extend `validate_profile()` for omlx schema and per-model fields (Reqs 3–4); add `render_omlx_settings(yaml_path, output_path)` (Req 5); add `stage_omlx_model_dir(profile_name, yaml_path)` (Req 11); add `log_rollback_event(prior, attempted, reason)` (Req 27); add lockfile logic in `4lm profile set` (Req 10); wire existing poll-timeout rollback to `log_rollback_event()` (Req 9); change `doctor) cmd_doctor ;;` to `doctor) cmd_doctor "$@" ;;`; add `cmd_doctor_phase3_ready()` with `cmd_doctor()` guard (Req 28); update `cmd_help()` to show `4lm doctor [phase3-ready]`. Phase 3: remove `mlx` branch from `validate_profile()`; add unsupported error for `backend: mlx`. Phase 4: add `cmd_autostart()`; add dispatch entry for `autostart` |
| `bin/4lm-backend-start.sh` | 1, 3 | Phase 1: add `omlx` branch with `omlx serve …` and flag-passing (Req 8). Phase 3: drop `mlx` branch; replace mlx-openai-server-based Python discovery for `mlx_lm` with `~/.local/pipx/venvs/omlx/bin/python3` (Req 18) |
| `install.sh` | 1, 3 | Phase 1: `pipx install omlx==<pinned>`; create `~/.4lm/cache/omlx/`, `~/.4lm/runtime/`, and `~/.omlx/` (mode 0700). Phase 3: drop `pipx install mlx-openai-server` |
| `uninstall.sh` | 3, 4 | Phase 3: idempotent removal of mlx-openai-server pipx env; `rm -f ~/.omlx/settings.json && rmdir ~/.omlx/ 2>/dev/null \|\| true`. Phase 4: bootout + remove `~/Library/LaunchAgents/` symlinks before deleting source plists |
| `requirements.txt` | 1, 3 | Phase 1: add `omlx==<pinned>`. Phase 3: drop `mlx-openai-server` |
| `Makefile` | — | No change |
| `Brewfile` | — | No change (omlx is pipx-installed) |
| `config/profiles/omlx-coding.yaml` | 1 | New — `backend: omlx`, `omlx:` block absent (omlx built-in defaults), `models:` list: `mlx-community/Qwen3-Coder-Next-4bit` as `qwen3-coder-next` (pinned, lm), `mlx-community/bge-m3` as `bge-m3` (ttl 600, lm) |
| `config/profiles/default.yaml` | 2 | Migrate `backend:` to `omlx`; remove Gemma-4 ollama caveat |
| `config/profiles/mlx-coding.yaml` | 2 | Migrate `backend:` to `omlx` |
| `config/profiles/mlx-knowledge.yaml` | 2 | Migrate `backend:` to `omlx` |
| `config/profiles/exp-mlx-full.yaml` | 2 | Migrate `backend:` to `omlx` |
| `config/profiles/exp-mlxlm-gemma4.yaml` | — | Untouched (mlx_lm reference) |
| `launchd/com.4lm.backend.plist` | 4 | Add `RunAtLoad`, `KeepAlive`, `ThrottleInterval` keys; add comment noting these keys were absent in Phases 1–3 |
| `launchd/com.4lm.webui.plist` | 4 | Same plist additions |
| `docs/profile-schema.md` | 1, 3 | Phase 1: add omlx section. Phase 3: drop `backend: mlx` (mlx-openai-server) section |
| `CLAUDE.md` | 2, 3, 4 | Phase 2: drop Gemma-4 caveat; add `## omlx path probe` section with Phase 1 probe result. Phase 3: update backend list to `omlx \| mlx_lm \| ollama`. Phase 4: replace "no autostart" paragraph with "autostart is opt-in via `4lm autostart enable`" |
| `README.md` | 2, 4 | Phase 2: update architecture diagram (omlx in place of mlx-openai-server). Phase 4: add autostart paragraph |
| `~/.4lm/config/active-profile` | — | Existing symlink (set by `install.sh`, updated by `4lm profile set`). No change to convention; used in Req 28 |
| `tests/test_profile_state_machine.bats` | 1, 2 | Add omlx profile state machine cases; assert rollback path appends to `~/.4lm/logs/profile-rollback.log`. Fixture YAMLs provided as inline heredocs |
| `tests/test_doctor_phase3_ready.bats` | 1, 3 | New. Phase 1: green path (absent log + valid omlx active profile) and basic dispatch guard (`4lm doctor phase3-ready` routes to `cmd_doctor_phase3_ready()`). Phase 3: add red-path cases — rollback log entry newer than symlink mtime, and active backend is `ollama`. Red-path test cases that exercise log-vs-mtime comparison and `ollama` check require Phase 3 code; mark them pending/skip until Phase 3 merges |
| `tests/test_backend_start.bats` | 1, 3 | Phase 1: add omlx start branch assertions (host/port propagation, present omlx: flags passed, absent omlx: block → no optional flags); Phase 3: drop mlx assertions |
| `tests/test_install.bats` | 1, 3 | Phase 1: update for omlx pipx install + cache dir. Phase 3: assert mlx-openai-server absent from pipx calls |
| `tests/test_4lm_dispatch.bats` | 4 | Add autostart dispatch cases |
| `tests/test_autostart.bats` | 4 | New — enable/disable/status idempotency, symlink presence, partial-enabled state. Fixture plists provided as inline heredocs |
| `tests/helpers/launchctl` | — | No change. Existing stub records all calls to `${LAUNCHCTL_LOG}` and exits 0; Phase 4 tests grep the existing log |

## Data Models

### Profile YAML — `backend: omlx`

The `server:` block is absent. Host and port come exclusively from
`~/.4lm/config/network.yaml` at runtime (see Req 7); there is no lower-
precedence fallback in the profile YAML.

```yaml
backend: omlx

omlx:                    # optional block; absent means use omlx built-in defaults
  max_process_memory: "80%"      # any non-empty string; passed as-is to --max-process-memory
  max_model_memory: "100GB"      # any non-empty string; passed as-is to --max-model-memory
  hot_cache_max_size: "20%"
  paged_ssd_cache_dir: "~/.4lm/cache/omlx"
  max_concurrent_requests: 8

models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit   # required: HF org/repo
    served_model_name: qwen3-coder-next                # required: alias in /v1/models
    model_type: lm                                     # optional: lm | vlm (default: lm)
    pin: true                                          # optional bool (default: false)
    ttl: null                                          # optional int seconds | null
    chat_template_kwargs: {}                           # optional dict; omitted from JSON when {}
    sampling: {}                                       # optional dict; omitted from JSON when {}

  - model_path: mlx-community/bge-m3
    served_model_name: bge-m3
    model_type: lm
    pin: false
    ttl: 600
```

Note: `model_type: lm` is used for `bge-m3` (reranker/embedding model). omlx
uses `lm` for all non-visual models including embeddings and rerankers. If omlx
introduces a distinct `reranker` type, update the allowed-values list in Req 4
and `validate_profile()` accordingly.

### `~/.omlx/settings.json` — rendered by `render_omlx_settings()`

omlx reads per-model configuration from this file. Each profile `models:`
entry maps to one element of the top-level `models` array. Optional fields
absent from the YAML entry are omitted from the JSON object for that model
(not written as null/empty), so omlx uses its own defaults. `ttl: null` in
YAML emits `"ttl": null` in JSON. A missing `ttl:` key emits nothing. Empty
dicts (`{}`) for `chat_template_kwargs` or `sampling` are omitted. Bool values
(`pin: true`/`pin: false`) are emitted as JSON booleans (not quoted strings)
via `--argjson` in jq.

```json
{
  "models": [
    {
      "served_model_name": "qwen3-coder-next",
      "pin": true,
      "ttl": null,
      "model_type": "lm"
    },
    {
      "served_model_name": "bge-m3",
      "pin": false,
      "ttl": 600,
      "model_type": "lm"
    }
  ]
}
```

### Bash function signatures

```bash
# bin/4lm

# Extended (Phase 1): echo backend value from YAML; now handles omlx.
profile_backend(yaml_path)   # existing function at lines 221–234

# Validate profile YAML schema; calls warn + return 1 on error (not die).
validate_profile(yaml_path)

# Render ~/.omlx/settings.json from profile YAML.
# Per-model fields extracted with awk block-scanning anchored on "- model_path:";
# new "- model_path:" line or EOF terminates the previous block.
# JSON emitted with jq; booleans via --argjson. No Python. No direct echo >&2.
# Runs mkdir -p ~/.omlx/ before writing.
render_omlx_settings(yaml_path, output_path)

# Populate ~/.4lm/runtime/<profile_name>/models/ with HF snapshot symlinks.
# First step: mkdir -p the model dir.
# Builds in mktemp dir; swaps atomically. rm -rf temp dir on failure.
# Reads SHA via hf_local_sha(). Exits non-zero on missing HF cache. No direct echo >&2.
stage_omlx_model_dir(profile_name, yaml_path)

# Append one rollback event line to ~/.4lm/logs/profile-rollback.log.
# Creates log with mode 0644 on first write.
# Timestamp: date -Iseconds (local time). No direct echo >&2.
log_rollback_event(prior_profile, attempted_profile, reason)

# Dispatch autostart enable|disable|status [backend|webui].
# Bare "4lm autostart" prints usage and exits non-zero.
cmd_autostart()

# Read-only phase-3 readiness reporter.
# Exits 0 + "green: ..." or 1 + "red: ...".
# Called from cmd_doctor() when arg[1] == "phase3-ready".
# stat -f %m on the symlink itself (not target). No direct echo >&2.
cmd_doctor_phase3_ready()

# bin/4lm-backend-start.sh
# (no new functions; omlx branch added inline; omlx: block read via standalone awk;
#  stderr via existing echo "[$(date -Iseconds)] FATAL: …" >&2; exit <code> pattern)
```

### HuggingFace cache path convention

Source path for `stage_omlx_model_dir()` symlinks:

```
~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<sha>/
```

`<org>` and `<repo>` are derived from `model_path` by replacing `/` with `--`
(e.g. `mlx-community/Qwen3-Coder-Next-4bit` →
`models--mlx-community--Qwen3-Coder-Next-4bit`). `<sha>` is resolved by
calling `hf_local_sha(repo_id)` which reads
`~/.cache/huggingface/hub/models--<slug>/refs/main`. Multiple snapshots can
coexist; lexicographic-last is not used. If `refs/main` is absent or the
resolved `snapshots/<sha>/` does not exist, `stage_omlx_model_dir()` exits
non-zero with `error: HF model not found: <path>`.

Symlink created:
```
~/.4lm/runtime/<profile_name>/models/<served_model_name>
  → ~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<sha>/
```

## API Contracts

### HTTP endpoints consumed (omlx server at `:8000`)

| Endpoint | Method | Used by | Purpose |
|---|---|---|---|
| `/v1/models` | GET | `4lm profile set` (poll loop), `4lm health` | Confirm model aliases are loaded |
| `/v1/chat/completions` | POST | (external callers) | OpenAI-compatible inference |

### CLI subcommand surface

| Subcommand | Args | Effect |
|---|---|---|
| `4lm autostart enable <service>` | `service ∈ {backend, webui}` (default: `backend` silently) | Create LaunchAgents symlink via `ln -sfn`, bootstrap; remove symlink and exit non-zero if bootstrap fails |
| `4lm autostart disable <service>` | `service ∈ {backend, webui}` (default: `backend` silently) | Bootout, remove symlink |
| `4lm autostart status` | (none) | Print `backend  enabled\|disabled` and `webui  enabled\|disabled`; exit 0; no mutations |
| `4lm autostart` (bare) | (none) | Print usage error and exit non-zero |
| `4lm doctor phase3-ready` | (none) | Read-only readiness reporter; exit 0 + `green: ...` when ready, exit 1 + `red: <reason>` otherwise |

Label mapping:
- `backend` → `com.4lm.backend`
- `webui` → `com.4lm.webui`

## Configuration

### Autostart plist additions

Added to both `launchd/com.4lm.backend.plist` and
`launchd/com.4lm.webui.plist` in Phase 4:

```xml
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
```

`RunAtLoad` is intentional for both the manual `4lm start` path and the
autostart login path. KeepAlive persistent-restart behavior only activates
when the plist is registered in `~/Library/LaunchAgents/` (via
`4lm autostart enable`). When bootstrapped manually via `4lm start`,
`4lm stop` calls `launchctl bootout` which removes the supervision context
entirely. These keys are absent from the Phase 1–3 plists — this is a known
gap noted by a comment in the Phase 4 plist diff.

### `~/.4lm/cache/omlx/`

Created by `install.sh` in Phase 1 (idempotent). Passed to omlx via
`--paged-ssd-cache-dir` when `paged_ssd_cache_dir` is set in the `omlx:`
profile block.

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| `backend: omlx` profile missing `models:` | `validate_profile()` | Exit non-zero | `warn: backend omlx requires 'models:' key` |
| Per-model `ttl:` is not int or null | `validate_profile()` | Exit non-zero | `warn: model '<name>' field 'ttl' must be integer or null` |
| Per-model `model_path` or `served_model_name` absent | `validate_profile()` | Exit non-zero | `warn: model entry missing required field '<field>'` |
| `model_path` fails `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` | `validate_profile()` | Exit non-zero | `warn: model '<name>' field 'model_path' is invalid` |
| `model_type` present but not `lm` or `vlm` | `validate_profile()` | Exit non-zero | `warn: model '<name>' field 'model_type' must be 'lm' or 'vlm'` |
| `render_omlx_settings()` called with empty models list | `4lm profile set` (omlx path) | Rollback to prior profile; exit non-zero | `error: no models defined in profile` |
| Cannot write `output_path` (disk full, dir not writable) | `render_omlx_settings()` | Exit non-zero; rollback triggered | `error: cannot write settings: <path>: <errno>` |
| `paged_ssd_cache_dir` contains `..` component | `bin/4lm-backend-start.sh` | Exit non-zero | `[<timestamp>] FATAL: invalid paged_ssd_cache_dir value: <value>` |
| `paged_ssd_cache_dir` fails regex `^[a-zA-Z0-9_./-]+$` | `bin/4lm-backend-start.sh` | Exit non-zero | `[<timestamp>] FATAL: invalid paged_ssd_cache_dir value: <value>` |
| HF `refs/main` absent or snapshot dir missing | `stage_omlx_model_dir()` | Exit non-zero; rollback triggered | `error: HF model not found: <path>` |
| `/v1/models` poll timeout (30 s) | `4lm profile set` | Restore prior symlink, kickstart prior config, log rollback event (`poll_timeout`), exit non-zero | `error: profile set timed out; rolled back to <prior>` |
| Concurrent `4lm profile set` | Second invocation | Exit non-zero immediately | `error: profile set already in progress` |
| `4lm autostart enable` with missing source plist | `cmd_autostart enable` | Exit non-zero | `error: source plist not found: <path>` |
| `launchctl bootstrap` fails during `4lm autostart enable` | `cmd_autostart enable` | Remove just-created symlink, exit non-zero | launchctl error message |
| `4lm autostart` called bare (no subcommand) | `cmd_autostart` | Exit non-zero | `error: usage: 4lm autostart {enable\|disable\|status} [backend\|webui]` |
| `backend: mlx` in profile (Phase 3+) | `validate_profile()` | Exit non-zero | `warn: backend 'mlx' is no longer supported; use 'omlx'` |

## Implementation Phases

## Phase 1 — Add `backend: omlx` alongside existing three

Add omlx as a fourth backend value. Existing profiles are unchanged.
mlx-openai-server remains installed. The new `omlx-coding.yaml` profile
validates omlx on the real workload.

Changes:
- `bin/4lm`: extend `profile_backend()` (lines 221–234) to echo `omlx` for
  `backend: omlx` profiles (prerequisite — must be first change in this file);
  extend `validate_profile()` for omlx schema and per-model fields including
  `model_type` validation; add `render_omlx_settings()` with `--argjson` for
  booleans; add `stage_omlx_model_dir()` with `mkdir -p` of model dir as first
  step, atomic temp-dir swap, `rm -rf` temp dir on failure, and
  `find … -maxdepth 1 -type l -delete` cleanup; add `log_rollback_event()` with
  touch+chmod idiom for log file creation; add lockfile logic using `rm -rf` for
  cleanup; wire existing poll-timeout rollback (lines 879–910) to call
  `log_rollback_event()`; change `doctor) cmd_doctor ;;` to
  `doctor) cmd_doctor "$@" ;;`; add `cmd_doctor_phase3_ready()` with
  `cmd_doctor()` guard; update `cmd_help()` to show `4lm doctor [phase3-ready]`.
- `bin/4lm-backend-start.sh`: add `omlx` branch with standalone awk one-liner
  to extract `omlx:` block fields; pass `--host`, `--port`, and optional flags;
  validate `paged_ssd_cache_dir` with component check then regex check; use
  existing `echo "[$(date -Iseconds)] FATAL: …" >&2; exit <code>` pattern.
- `install.sh`: `pipx install omlx==<pinned>`; create `~/.4lm/cache/omlx/`,
  `~/.4lm/runtime/`, and `~/.omlx/` (mode 0700) (all idempotent).
- `requirements.txt`: add `omlx==<pinned>`.
- `config/profiles/omlx-coding.yaml`: new profile (`backend: omlx`, `omlx:`
  block absent, `models:` list with `qwen3-coder-next` pinned and `bge-m3`
  with ttl 600).
- `docs/profile-schema.md`: add omlx section.
- bats tests with inline fixture heredocs.

Phase complete when:
- `validate_profile omlx-coding.yaml` exits 0.
- `validate_profile` exits non-zero on all five invalid fixture variants
  (missing `models:`, bad `ttl`, missing `model_path`, invalid `model_path`
  format, invalid `model_type`).
- `4lm profile set omlx-coding` writes `~/.omlx/settings.json` with correct
  fields.
- `GET /v1/models` returns an entry with `id: qwen3-coder-next`.
- `4lm expose lan --confirm` with `network.yaml mode: lan` results in omlx
  started with `--host 0.0.0.0`.
- A failed `render_omlx_settings()` during `4lm profile set` appends one line
  to `~/.4lm/logs/profile-rollback.log` ending with `\trender_settings`.
- A second concurrent `4lm profile set` while the lockfile is held exits
  non-zero (bats assertion).
- `make test` exits 0 with no regressions.
- **Manual gate:** Operator-verified adequate omlx uptime as active backend
  (service in `state = running` per `launchctl print`) with no rollback
  triggered and all bats tests green. Required before starting Phase 2.

### Test Scenarios

- GIVEN a profile YAML with `backend: omlx`, valid `models:` list, and `omlx:`
  block WHEN `validate_profile` runs THEN it exits 0.
- GIVEN a profile YAML with `backend: omlx` and `omlx:` block absent WHEN
  `validate_profile` runs THEN it exits 0 (absent block is valid).
- GIVEN a profile YAML with `backend: omlx` and `models:` key absent WHEN
  `validate_profile` runs THEN it exits non-zero and stderr contains `models`.
- GIVEN a profile YAML with `backend: omlx` and a model entry where `ttl: "ten"`
  WHEN `validate_profile` runs THEN it exits non-zero and stderr contains `ttl`.
- GIVEN a profile YAML with `backend: omlx` and a model entry missing `model_path`
  WHEN `validate_profile` runs THEN it exits non-zero and stderr contains `model_path`.
- GIVEN a profile YAML with `backend: omlx` and `model_path: ../bad/path` WHEN
  `validate_profile` runs THEN it exits non-zero and stderr names `model_path` as
  invalid.
- GIVEN a profile YAML with a model entry where `model_type: embedding` WHEN
  `validate_profile` runs THEN it exits non-zero and stderr contains `model_type`.
- GIVEN `install.sh` runs WHEN it completes THEN the pipx call log contains `omlx`,
  `~/.4lm/cache/omlx/` exists, `~/.4lm/runtime/` exists, and `~/.omlx/` exists with
  mode 0700.
- GIVEN a valid omlx profile is active WHEN `4lm profile set omlx-coding` completes
  THEN `~/.omlx/settings.json` exists and: `pin: true` in YAML emits `"pin": true`
  (JSON boolean, not quoted string); `ttl: null` in YAML emits `"ttl": null` in JSON;
  an absent `ttl:` key emits no `ttl` field; empty dicts for
  `chat_template_kwargs`/`sampling` are absent from the JSON.
- GIVEN `network.yaml` has `mode: lan` WHEN `4lm expose lan --confirm` runs THEN
  omlx is invoked with `--host 0.0.0.0`.
- GIVEN `network.yaml` has `mode: local` WHEN `4lm start` runs THEN omlx is invoked
  with `--host 127.0.0.1`.
- GIVEN `omlx:` block with `max_process_memory: "80%"` is present WHEN
  `bin/4lm-backend-start.sh` runs THEN omlx is invoked with `--max-process-memory 80%`.
- GIVEN `omlx:` block is absent from the active profile WHEN `bin/4lm-backend-start.sh`
  runs THEN the omlx invocation contains none of `--max-process-memory`,
  `--max-model-memory`, `--hot-cache-max-size`, `--paged-ssd-cache-dir`,
  `--max-concurrent-requests`.
- GIVEN `paged_ssd_cache_dir: "~/.4lm/cache/omlx"` in the profile WHEN
  `bin/4lm-backend-start.sh` runs THEN omlx is invoked with
  `--paged-ssd-cache-dir /Users/<user>/.4lm/cache/omlx` (tilde expanded, not literal `~`).
- GIVEN `paged_ssd_cache_dir: "/tmp/x;rm -rf ~"` WHEN `bin/4lm-backend-start.sh`
  runs THEN it exits non-zero and output contains `invalid paged_ssd_cache_dir`.
- GIVEN `paged_ssd_cache_dir: "/valid/../../etc"` WHEN `bin/4lm-backend-start.sh`
  runs THEN it exits non-zero and output contains `invalid paged_ssd_cache_dir`
  (path-traversal component check).
- GIVEN `render_omlx_settings()` exits non-zero during `4lm profile set` WHEN
  rollback executes THEN `~/.4lm/logs/profile-rollback.log` contains exactly one
  new line matching `<date -Iseconds>\t<prior>\t<attempted>\trender_settings`.
- GIVEN two concurrent invocations of `4lm profile set` WHEN the second is launched
  while the first holds the lockfile THEN the second exits non-zero with output
  containing `already in progress`.
- GIVEN a stale lockfile whose `pid` file contains a non-live PID WHEN
  `4lm profile set` starts THEN the stale lock is removed (`rm -rf`) and the
  command proceeds normally.
- GIVEN all existing bats fixtures WHEN `make test` runs THEN it exits 0.
- **Manual probe (Phase 1 integration):** Set `model_path` in
  `~/.omlx/settings.json` to an absolute HF snapshot path and start
  `omlx serve --model-dir <empty>`. If `/v1/models` returns the configured alias,
  omlx accepts absolute paths; file a Phase 2 cleanup task to drop
  `stage_omlx_model_dir()` and `~/.4lm/runtime/<profile>/models/`. If not, retain
  the staging layer permanently. Document the result in `CLAUDE.md`
  `## omlx path probe` before merging Phase 2.
- **Manual:** Cold-tier KV restore — send a 4k-token prompt, restart backend, send
  same prompt; second TTFT < 50% of first. Not a CI criterion.
- **Manual:** Concurrent batching — four 200-token completions fired concurrently
  show aggregate throughput > 4× single-request sequential. Not a CI criterion.

## Phase 2 — Migrate existing MLX profiles

Migrate `default.yaml`, `mlx-coding.yaml`, `mlx-knowledge.yaml`,
`exp-mlx-full.yaml` to `backend: omlx`. Drop the "Gemma 4 forces ollama"
caveat after manual 32k-token Gemma 4 verification (Req 14). Update
`CLAUDE.md` and `README.md`. Phase 2 CI gate is `make test` only; the
uptime-and-stability signal is operator-owned (Req 13).

Phase 4 may be branched and worked concurrently with Phase 2, or after it.
Phase 4 must not merge before Phase 2 is merged. Phase 3 is independent of
Phase 4; merge order for 3 and 4 is operator choice.

Changes:
- `config/profiles/default.yaml`, `mlx-coding.yaml`, `mlx-knowledge.yaml`,
  `exp-mlx-full.yaml`: change `backend:` to `omlx`; add `omlx:` block and
  `models:` list as appropriate.
- `CLAUDE.md`: drop Gemma-4 caveat; add `## omlx path probe` section with
  Phase 1 probe result.
- `README.md`: update architecture diagram (omlx in place of mlx-openai-server).

Phase complete when:
- All four migrated profiles pass `validate_profile`.
- `/v1/models` poll timeout triggers rollback: prior symlink restored, backend
  kickstarted on prior config, `4lm profile set` exits non-zero (bats stub asserts).
- `CLAUDE.md` contains no references to `RotatingKVCache` or
  `Gemma 4 forces ollama`.
- `make test` exits 0.
- **Manual gate:** `4lm profile set default` brings up all configured aliases in
  `/v1/models` within 30 s. Not a bats criterion (curl stub returns immediately).
- **Manual gate:** Gemma 4 31B 32k-token request completes without omlx process
  exiting non-zero and `~/.omlx/logs/server.log` contains no `BatchRotatingKVCache`
  string. Required before removing the Gemma-4 caveat.

### Test Scenarios

- GIVEN each of `default.yaml`, `mlx-coding.yaml`, `mlx-knowledge.yaml`,
  `exp-mlx-full.yaml` updated to `backend: omlx` WHEN `validate_profile <name>`
  runs for each THEN all four exit 0.
- GIVEN the curl stub returns no `/v1/models` response within 30 s WHEN
  `4lm profile set default` poll timeout fires THEN the prior profile symlink is
  restored, backend is kickstarted on prior config, and `4lm profile set` exits
  non-zero.
- GIVEN `CLAUDE.md` after Phase 2 migration WHEN grepped for `RotatingKVCache`
  THEN no matches are found.
- GIVEN `CLAUDE.md` after Phase 2 migration WHEN grepped for `Gemma 4 forces ollama`
  THEN no matches are found.
- GIVEN `make test` on the Phase 2 codebase WHEN run THEN it exits 0.
- **Manual:** Gemma 4 31B 32k-token request completes without crash (defined in
  Req 14).

## Phase 3 — Remove mlx-openai-server entirely

Drop the `mlx` backend value from validators, start scripts, `install.sh`,
`requirements.txt`, and docs. Replace the mlx-openai-server-based Python
discovery for `mlx_lm` with the omlx pipx venv. Remove `~/.omlx/settings.json`
(and `~/.omlx/` if then empty) from `uninstall.sh`. Gate: `4lm doctor
phase3-ready` exits 0 / prints `green` (Req 28). The operator owns timing.

Changes:
- `bin/4lm`: remove `mlx` branch from `validate_profile()`; add
  `warn: backend 'mlx' is no longer supported; use 'omlx'` for legacy profiles.
- `bin/4lm-backend-start.sh`: drop `mlx` branch; replace mlx-openai-server
  Python discovery with `~/.local/pipx/venvs/omlx/bin/python3` for `mlx_lm`.
- `install.sh`: drop `pipx install mlx-openai-server`.
- `requirements.txt`: drop `mlx-openai-server`.
- `uninstall.sh`: idempotent removal of mlx-openai-server pipx env;
  `rm -f ~/.omlx/settings.json && rmdir ~/.omlx/ 2>/dev/null || true`.
- `docs/profile-schema.md`: drop `backend: mlx` section.
- `CLAUDE.md`: update backend list to `omlx | mlx_lm | ollama`.

Phase complete when:
- `validate_profile` exits non-zero with message naming `mlx` as no longer
  supported when given a legacy `backend: mlx` profile.
- `make install` on a machine that previously had mlx-openai-server does not
  reinstall it (bats stub asserts the pipx call is absent from install log).
- `bin/4lm` contains no occurrences of the string `mlx-openai-server` (grep
  assertion).
- `docs/profile-schema.md` contains no `backend: mlx` (mlx-openai-server) section.
- `CLAUDE.md` backend list reads `omlx | mlx_lm | ollama`.
- `make uninstall` leaves no `~/.omlx/settings.json` (bats assertion).
- `make check && make test` exit 0.
- **Operator gate:** `4lm doctor phase3-ready` exits 0 with `green` output.

### Test Scenarios

- GIVEN a profile YAML with `backend: mlx` (legacy value) WHEN `validate_profile`
  runs THEN it exits non-zero and stderr contains both `mlx` and `no longer
  supported`.
- GIVEN `make install` on Phase 3 codebase WHEN it completes THEN the pipx stub
  call log does not contain `mlx-openai-server` and does contain `omlx`.
- GIVEN `bin/4lm` after Phase 3 WHEN grepped for `mlx-openai-server` THEN no
  matches are found.
- GIVEN `docs/profile-schema.md` after Phase 3 WHEN grepped for `backend: mlx`
  THEN no matches are found.
- GIVEN `CLAUDE.md` after Phase 3 WHEN grepped for the backend list THEN it reads
  `omlx | mlx_lm | ollama`.
- GIVEN `~/.4lm/logs/profile-rollback.log` is absent and the active profile has
  `backend: omlx` WHEN `4lm doctor phase3-ready` runs THEN it exits 0 and stdout
  starts with `green`.
- GIVEN `~/.4lm/logs/profile-rollback.log` contains one entry whose timestamp is
  newer than the `active-profile` symlink mtime WHEN `4lm doctor phase3-ready` runs
  THEN it exits 1 and stdout starts with `red` and contains the offending log line.
- GIVEN the active profile has `backend: ollama` WHEN `4lm doctor phase3-ready` runs
  THEN it exits 1 and stdout contains `red` naming the active backend.
- GIVEN `make uninstall` on Phase 3 codebase WHEN it completes THEN
  `~/.omlx/settings.json` does not exist.
- GIVEN `make check && make test` on Phase 3 codebase WHEN run THEN both exit 0.

## Phase 4 — Opt-in autostart

Add `4lm autostart {enable|disable|status} [backend|webui]` subcommand. Add
`RunAtLoad`, `KeepAlive`, `ThrottleInterval` to plist templates. Update
`uninstall.sh` for LaunchAgents cleanup. Inline autostart docs into `README.md`
(no `docs/autostart.md` file). May be branched from Phase 2 and worked
concurrently; must not merge before Phase 2.

Changes:
- `bin/4lm`: add `cmd_autostart()` and dispatch entry for `autostart`.
- `launchd/com.4lm.backend.plist`: add `RunAtLoad`, `KeepAlive`,
  `ThrottleInterval` keys; add comment noting these were absent in Phases 1–3.
- `launchd/com.4lm.webui.plist`: same plist additions.
- `uninstall.sh`: bootout + remove `~/Library/LaunchAgents/` symlinks before
  deleting source plists.
- `README.md`: add autostart paragraph.
- `CLAUDE.md`: replace "no autostart" paragraph with "autostart is opt-in via
  `4lm autostart enable`".

Phase complete when:
- `4lm autostart status` exits 0, makes no file writes or launchctl mutations,
  and lists both services.
- `4lm autostart enable backend` creates the correct LaunchAgents symlink.
- `4lm autostart enable backend` run twice exits 0 and leaves symlink unchanged
  (idempotent).
- `4lm autostart disable backend` removes the LaunchAgents symlink without
  touching the source plist.
- `make uninstall` on a machine with autostart enabled removes both LaunchAgents
  symlinks.
- `make uninstall` on a machine that never enabled autostart exits 0 (idempotent).
- Only `backend` autostart enabled → status shows `backend  enabled`,
  `webui  disabled`.
- `README.md` contains an autostart paragraph.
- `make test` exits 0.
- **Manual gate:** After reboot, omlx serves on port 8000 within 30 s of
  `launchctl print gui/$(id -u)/com.4lm.backend` showing
  `state = running`. KeepAlive: `launchctl kill SIGKILL` on the service is
  followed by auto-restart within 15 s. Not CI criteria.

### Test Scenarios

- GIVEN autostart has never been enabled WHEN `4lm autostart status` runs THEN it
  exits 0, produces no file writes or launchctl mutations (launchctl log is empty
  for this invocation), and output contains `backend  disabled` and
  `webui  disabled`.
- GIVEN `~/.4lm/launchd/com.4lm.backend.plist` exists WHEN
  `4lm autostart enable backend` completes THEN
  `~/Library/LaunchAgents/com.4lm.backend.plist` is a symlink to
  `~/.4lm/launchd/com.4lm.backend.plist` and the launchctl log
  contains `bootstrap`.
- GIVEN `4lm autostart enable backend` was already run WHEN run again THEN it exits
  0 and the symlink target is unchanged.
- GIVEN `~/.4lm/launchd/com.4lm.backend.plist` does not exist WHEN
  `4lm autostart enable backend` runs THEN it exits non-zero and output contains
  `source plist not found`.
- GIVEN launchctl bootstrap fails (stub returns non-zero) WHEN `4lm autostart enable
  backend` completes THEN `~/Library/LaunchAgents/com.4lm.backend.plist`
  does not exist and the command exits non-zero.
- GIVEN the LaunchAgents symlink exists but points to a wrong target WHEN
  `4lm autostart enable backend` runs THEN the symlink is replaced (via `ln -sfn`)
  with the correct target and the command exits 0.
- GIVEN `4lm autostart enable` is called with no service argument WHEN it completes
  THEN behavior is identical to `4lm autostart enable backend` (symlink created,
  bootstrap called, no warning printed).
- GIVEN backend autostart is enabled WHEN `4lm autostart disable backend` completes
  THEN `~/Library/LaunchAgents/com.4lm.backend.plist` does not exist
  and `~/.4lm/launchd/com.4lm.backend.plist` still exists.
- GIVEN only backend autostart is enabled WHEN `4lm autostart status` runs THEN
  output contains `backend  enabled` and `webui  disabled`.
- GIVEN backend autostart is enabled WHEN `make uninstall` runs THEN the LaunchAgents
  symlink is absent after completion and the launchctl log shows bootout was called
  before symlink removal.
- GIVEN autostart was never enabled WHEN `make uninstall` runs THEN it exits 0.
- GIVEN Phase 4 codebase WHEN `make test` runs THEN it exits 0.
- **Manual:** After reboot, `launchctl print gui/$(id -u)/com.4lm.backend`
  shows `state = running` within 30 s of user session open.
- **Manual:** `launchctl kill SIGKILL` against service → service restarts within 15 s.

## Decision Log

- **Reject: abandon 4lm in favor of `brew services start omlx`.** Three operational
  policies (opt-in autostart, LAN-confirm gate, single source-controlled config
  channel) are not delivered by `brew services`. Custom plist machinery already
  required for env / host / log / settings.json absorbs the marginal cost.
- **Reject: rename `mlx` → `omlx` in-place without a transition phase.** Phase 1
  introduces `omlx` as a new value; Phase 2 migrates YAMLs; Phase 3 retires `mlx`.
  Avoids debugging migration and engine adoption simultaneously.
- **Reject: kill the profile concept.** omlx's EnginePool obsoletes profile-switching
  within omlx, but profiles still express the omlx vs mlx_lm vs ollama choice —
  distinct engines, not config noise.
- **Reject: drop `mlx_lm` backend.** mlx_lm is Apple's official inference library
  with no wrapper between you and upstream. Independent value as insurance against
  omlx regressions.
- **Reject: drop `ollama` backend.** Different ecosystem (GGUF / llama.cpp / Metal),
  not an MLX safety net. Keeps for model coverage independent of omlx stability.
- **Reject: install omlx via Homebrew formula or `.app`.** Both fight 4lm's plist
  machinery and impose autostart-by-default and admin-panel-as-config. pipx gives
  4lm full control.
- **Reject: store per-model omlx settings only in `~/.omlx/settings.json`
  (admin-panel-driven).** Breaks the single-config-channel rule. Profile YAML is
  source of truth; settings.json is a derived runtime artifact.
- **Reject: LaunchDaemon for autostart.** Awkward for personal/user-scoped LLM stacks
  (no Keychain, no user env, system-path models). LaunchAgent at user login is the
  right shape.
- **Reject: per-service `KeepAlive` configurability via profile YAML.** Fixed shape
  (`true`, `ThrottleInterval=10`) is enough for a personal stack.
- **Reject: land autostart concurrent with Phase 1.** Risks debugging two new things
  at once. Phase 4 lands after Phase 2 is the validated daily driver.
- **Reject: `autostart all` argument.** Creates implicit ordering and failure
  semantics across two services. YAGNI for a two-plist personal stack.
- **Reject: `docs/autostart.md` as a separate file.** Behavior is captured in
  `4lm autostart --help` output and plist keys. Inline essentials into `README.md`.
- **Accept (resolved): `render_omlx_settings()` in `bin/4lm`, not
  `bin/4lm-backend-start.sh`.** `bin/4lm-backend-start.sh` has no functions and
  cannot be sourced from `bin/4lm` (see comment line 47). Req 9 requires
  `4lm profile set` (which runs in `bin/4lm`) to call it before kickstart.
- **Accept (resolved): retain `stage_omlx_model_dir()` in Phase 1, probe in Phase 1
  whether omlx accepts absolute HF snapshot paths.** Phase 1 includes an explicit
  integration probe. If `/v1/models` returns the alias with absolute paths, file a
  Phase 2 cleanup task to drop `stage_omlx_model_dir()`. Result documented in
  `CLAUDE.md` `## omlx path probe` section.
- **Accept (resolved): Phase 3 gated by `4lm doctor phase3-ready` reporter, not a
  calendar.** Code logs rollback events to `~/.4lm/logs/profile-rollback.log`
  (Req 27). `4lm doctor phase3-ready` (Req 28) exits 0/`green` when no rollback
  events postdate the active-profile symlink and the active backend is omlx.
- **Accept (resolved): lockfile via `mkdir` (atomic APFS/HFS+), not GNU `flock`.**
  `flock(1)` requires Homebrew on macOS. Full PID-based stale-lock detection
  specified in Req 10. Cleanup uses `rm -rf` (not `rmdir`) because the lock
  directory contains a `pid` file.
- **Accept (resolved): HF snapshot SHA via `refs/main`, not lexicographic-last.**
  Multiple snapshots can coexist; `hf_local_sha()` already exists and reads
  `refs/main`; reuse it.
- **Accept (resolved): fixture YAMLs as inline bats heredocs, not
  `tests/fixtures/*.yaml` files.** No `tests/fixtures/` directory exists; all
  existing bats tests use inline heredocs.
- **Accept (resolved): `model_path` regex validation in `validate_profile()` and
  `stage_omlx_model_dir()` (defense-in-depth).** `stage_omlx_model_dir()` constructs
  filesystem paths from `model_path`; path-traversal prevented by
  `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` check in both places.
- **Accept (resolved): `paged_ssd_cache_dir` tilde-expansion via parameter
  substitution, no `eval`.** `${val/#\~/$HOME}` expands tilde safely; path then
  validated by component check (`..` detection) followed by
  `^[a-zA-Z0-9_./-]+$` regex. Component check is first to catch traversal that
  the regex would pass.
- **Accept (resolved): omlx is single-author and pre-1.0 (`v0.3.8`, ~3 months
  old).** Risk mitigated by: (a) pinning a version, (b) keeping `mlx_lm` and
  `ollama` as alternative backends, (c) persistent SSD KV cache and Gemma-4 fixes
  deliver tangible daily wins.
- **Accept (resolved): timestamp format is `date -Iseconds` (local time with offset),
  not UTC.** Consistent with existing codebase convention. Req 27 and Req 28 both
  use `date -Iseconds`; Req 28 converts log timestamps via
  `date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts" +%s` for epoch comparison against
  `stat -f %m` on the symlink (not the target).
- **Accept (resolved): `stage_omlx_model_dir()` uses temp-dir + atomic mv swap.**
  Prevents empty model dir on partial failure. Build in `mktemp -d`, then
  `find … -maxdepth 1 -type l -delete` + `mv` on success; `rm -rf` temp dir on
  failure.
- **Accept (resolved): no launchctl stub extension needed for Phase 4 tests.**
  Existing stub records all calls to `${LAUNCHCTL_LOG}` and exits 0; Phase 4
  tests grep the existing log. No `tests/helpers/launchctl` change required.
- **Accept (resolved): `validate_profile()` uses `warn` + `return 1`, not `die`.**
  `die` calls `exit 1` and would break the rollback path. All new
  `validate_profile()` error paths follow the existing `warn; return 1` pattern.
- **Accept (resolved): `profile_backend()` extension is Phase 1 prerequisite.**
  Without it, all omlx-specific validation in `validate_profile()` is unreachable;
  the four callers (lines 437, 1079, 1238, 1313) that fall back to `|| echo "mlx"`
  silently misclassify omlx profiles.
- **Accept (resolved): `ln -sfn` for autostart symlink create/replace.** Atomic
  on APFS in a single syscall; eliminates TOCTOU window present in
  remove-then-create sequence. Fast-path idempotency check (`readlink` equals
  source) still avoids unnecessary launchctl calls.
- **Accept (resolved): `stat -f %m` targets the symlink, not the target file.**
  `stat -f %m` on a symlink on macOS returns the symlink's own mtime (not
  `stat -L` which follows to target). The intent is to track when `profile set`
  last ran (it rewrites the symlink), so symlink mtime is correct.
- **Accept (resolved): `test_doctor_phase3_ready.bats` created in Phase 1 with
  Phase 3 cases marked pending.** Green-path and dispatch-guard tests run from
  Phase 1. Red-path cases (log-vs-mtime comparison, `ollama` check) require
  Phase 3 code; they are added in Phase 1 as pending/skip and activated in Phase 3.
- **Accept (resolved): `omlx-coding.yaml` has no `omlx:` block.** Absent block is
  valid per Req 3; omlx uses built-in defaults. This simplifies the new profile and
  tests that the absent-block path works end-to-end.
- **Accept (resolved): `max_process_memory` / `max_model_memory` accept any
  non-empty string.** omlx's own parser validates the format (e.g. `80%`, `100GB`).
  Adding a duplicate regex here would diverge from omlx's accepted syntax as omlx
  evolves. Passed as-is with no format validation.

## Open Decisions

None.

## Out of Scope

- Replacing `open-webui` with omlx's `/admin/chat`. The admin chat is for
  diagnostics; open-webui remains the daily UI.
- Replacing the `opencode` integration. `4lm code` / `4lm opencode` stay as-is.
- Installing the omlx macOS `.app` or menu bar app. Conflicts with the custom
  plist + opt-in-autostart model.
- Using `brew services` for any 4lm-managed service. 4lm owns supervision.
- Exposing embeddings or rerankers as first-class 4lm CLI surface. They become
  available because they ride along inside omlx, but no new commands.
- LaunchDaemon (system-boot) autostart. LaunchAgent at user login covers the
  personal use case.
- DFlash speculative decoding configuration knobs in profile YAML. omlx
  auto-detects Qwen models and engages DFlash; per-model `dflash_max_ctx` etc.
  surface only via `~/.omlx/settings.json` if a need emerges later.
- Migrating the HuggingFace cache layout. `make models` continues to populate the
  standard HF cache.
- TurboQuant 4-bit KV cache and SpecPrefill. Both are omlx features available via
  `~/.omlx/settings.json` when needed; not surfaced in profile YAML in this SDD.
