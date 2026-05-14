# Setup

This is the operator runbook for getting `4lm` from a fresh clone to a working
local LLM stack on Apple Silicon.

## Requirements

- macOS, Apple Silicon (`uname -m` must report `arm64`)
- Homebrew, then `make bootstrap` (installs Python 3.12, pipx, shellcheck,
  shfmt, bats-core from `Brewfile` and runs `pipx ensurepath`)
- ~140 GB free disk for model weights

> mlx-openai-server 1.8.1 requires Python `>=3.11,<3.13`, so install.sh
> creates pipx venvs with `python3.12` even if your system default is newer.

## Step 1 — Install

```sh
make install
```

The installer is idempotent and will:

- Copy scripts, plists, profiles into `~/.4lm/`
- Seed `~/.4lm/config/network.yaml` (mode: local) on first run
- Symlink `~/.local/bin/4lm` → `~/.4lm/bin/4lm`
- `pipx install` each pinned package from `requirements.txt` using `python3.12`
- Write `/etc/sudoers.d/4lm-stack` (validated via `visudo -c`, mode 0440,
  root:wheel-owned) so the backend wrapper can call sysctl without a TTY
- Set `iogpu.wired_limit_mb=98304` via sudo if currently lower
- `sudo tee /etc/newsyslog.d/4lm.conf` for log rotation

You'll see one or two sudo prompts during step 1. None on subsequent runs.

It will **not** start any services and will **not** copy plists to
`~/Library/LaunchAgents/`. Plists are stored in `~/.4lm/launchd/` so launchd
does not auto-start them at login.

### Backend-only install (headless LAN inference server)

If this Mac will only serve `/v1/*` to other hosts on the LAN — no local
WebUI browsing, no `opencode` TUI — install the backend layer only:

```sh
./install.sh --backend-only
# or
make install BACKEND_ONLY=1
```

The flag skips: `open-webui` pipx package, `4lm-webui-start.sh` wrapper,
the webui launchd plist, the `webui.log` newsyslog rotation entry,
`~/.config/opencode/opencode.jsonc`, and the `Brewfile-tui` (which only
contains `opencode`). `make bootstrap BACKEND_ONLY=1` skips `Brewfile-tui`
during dev-tool bootstrap as well.

After install, expose the backend on the LAN:

```sh
4lm start
4lm expose lan --confirm
```

On the **consumer host** (different machine), point a self-installed
OpenWebUI or `opencode` at the headless server's `/v1` endpoint:

```sh
OPENAI_API_BASE_URL=http://<headless-host>:8000/v1
```

Re-running `./install.sh --backend-only` over an existing full install
is non-destructive — it leaves existing WebUI artifacts in place and
prints `WebUI artifacts found; not managed in backend-only mode.`
Conversely, re-running `./install.sh` (no flag) over a backend-only
install upgrades to full.

> §Sudoers: the literal in `/etc/sudoers.d/4lm-stack` must match the
> wrapper's invocation exactly:
> `lukas ALL=(root) NOPASSWD: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304`.
> install.sh writes this verbatim. Don't hand-edit the file.

## Step 2 — Pre-download model weights

`mlx-openai-server` will pull on demand, but a 30+ GB model on residential
fiber is 10-15 minutes of "is it broken or working?". Pre-pull all profile
models in one shot:

```sh
make models           # download/update every model in config/profiles/
make models-list      # see what's cached
make models-clean     # prune orphaned revisions
make models-rm MODEL=<repo>   # remove one specific model
```

Cache lives at `~/.cache/huggingface/hub/` (~140 GB for the default profile).

## Step 3 — Start

```sh
4lm start         # bootstrap and start backend + webui
4lm status        # see service state
4lm health        # verify wired memory limit
```

After reboot, services are stopped. Run `4lm start` to bring them back.

## Step 4 — Open WebUI first user

Open the WebUI in private browsing **immediately** and register your account.
`DEFAULT_USER_ROLE` is set to `pending`, so you must explicitly promote yourself
to admin from the WebUI admin panel after registering. Until then the account
has no privileges.

## Step 5 — Open WebUI model configuration

OWUI ships built-in tools (`search_web`, `fetch_url`, `execute_code`, etc.)
that models can call autonomously during chat. Two conditions must both hold
for `search_web` and `fetch_url` to be offered to a model:

1. **Function Calling = Native** in the model's OWUI record — without this,
   OWUI never calls `get_builtin_tools()` at all.
2. **Web Search enabled as a default feature** — OWUI only includes the web
   tools when `features.web_search = true` in the chat request. The frontend
   sends this automatically when the web-search globe is ON, and the globe
   defaults to ON only when the model record has `defaultFeatureIds` including
   `web_search`.

**Prerequisite:** Web search provider must be configured first (Admin Panel →
Settings → RAG → Web Search). DuckDuckGo requires no API key.

For each model in the active profile, create or update its OWUI record:

1. OWUI → **Workspace → Models** → find the model or click **New Model**
2. If creating: set base model to the model's `served_model_name` from the profile YAML
3. **Capabilities** → enable **Web Search**
4. **Advanced Parameters** → Function Calling → **Native**
5. **Default Features** → enable **Web Search**
6. Save

Apply to: `qwen3-coder-next`, `gemma4-31b` (default/ollama profile). Apply to
any MLX profile models that have `enable_auto_tool_choice: true` as well.

## Step 6 — OpenCode TUI

`make bootstrap` installs the homebrew/core `opencode` formula (anomalyco's
distribution; sst/opencode no longer exists). `make install` seeds
`~/.config/opencode/opencode.jsonc` from `config/opencode.example.jsonc` if
absent — pre-wired with provider `mlx-4lm` pointing at
`http://127.0.0.1:8000/v1` and the three default-profile models.

```sh
4lm opencode                     # cwd as project
4lm opencode ~/projects/foo      # specific project
4lm opencode run "fix lint"      # one-shot, no TUI
4lm code                         # alias
```

The wrapper checks the backend with a 1 s curl before exec'ing opencode; if
the backend isn't responding it warns but still runs (so `opencode providers`,
`opencode models`, etc. work without a live backend).

To customise (different models, additional providers like Z.ai or Anthropic),
edit `~/.config/opencode/opencode.jsonc` directly — install.sh leaves it alone
on subsequent runs.

## Profiles

A "profile" is one YAML in `config/profiles/` (installed to
`~/.4lm/config/profiles/`). It declares the backend (`ollama`, `mlx`, or
`mlx_lm`) and the models to load. The active profile is selected via the
`~/.4lm/config/active-profile` symlink; switch atomically with
`4lm profile set <name>`.

### `default` (the daily driver — Ollama)

Two models via the Ollama backend:

| Model | Purpose | Size |
|---|---|---|
| Qwen3-Coder-Next (q4_K_M) | Code / tool calling | ~52 GB |
| Gemma 4 31B Dense | Chat / reasoning / multimodal | ~20 GB |

Both load on demand and stay resident as long as memory permits. On 128 GB
unified memory both fit simultaneously with headroom for KV cache. Gemma 4
runs via Ollama because its RotatingKVCache / sliding-window attention
architecture is incompatible with the mlx backends (GPU stream thread-local
bug, upstream unresolved as of 2026-05).

### `mlx-coding`

Single model via mlx-openai-server: Qwen3-Coder-Next at 32k context.

**Use when**: you want the raw MLX path for the coder model (lower latency
on this model, no Ollama overhead). Gemma 4 is not available.

### `mlx-knowledge`

Single model via mlx-openai-server: Qwen3.6-27B at 128k context with
thinking disabled (`qwen3-no-think.jinja` template).

**Use when**: long-form synthesis over a large corpus — Obsidian vault
analysis, document RAG over big inputs.

### Experimental profiles

| Profile | Purpose |
|---|---|
| `exp-mlx-full` | Tracks mlx-openai-server fix for Gemma 4 (both models on MLX when fixed) |
| `exp-mlxlm-gemma4` | Tracks mlx_lm fix for Gemma 4 (single model, different runtime path) |

These are broken until the upstream Stream(gpu,1) bug is resolved.

### When to switch

```sh
4lm profile list                    # see installed profiles
4lm profile current                 # see active
4lm profile set mlx-coding          # atomic, validated, rolls back on failure
```

Switching restarts the backend (~30-60 s cold load). Profile schema
reference: [`profile-schema.md`](profile-schema.md). To customise:
edit `~/.4lm/config/profiles/<name>.yaml` directly — `install.sh`
won't overwrite a profile that already exists.

## Network exposure

Default bind is `127.0.0.1`. To expose to your LAN:

```sh
4lm expose lan --confirm
```

Without `--confirm` the command refuses. With `--confirm` it writes
`mode: lan` to `~/.4lm/config/network.yaml` and restarts running services.

Security hardening applied in all modes (not LAN-only):
- `WEBUI_REGISTRATION_ENABLED=false` — no new accounts can register after setup
- `DEFAULT_USER_ROLE=pending` — new accounts have no privileges until promoted
- `WEBUI_SECRET_KEY` persisted to `~/.4lm/config/webui_secret_key` (mode 0600)

Better than `lan`: bind to `127.0.0.1` and use Tailscale or another VPN that
provides authentication.

## Troubleshooting

### "Why are the fans on?" — finding the workload

`4lm diag` is the live-traffic view. It prints, in order:

- **Backend clients** — established TCP connections to the backend port,
  with client process name and PID.
- **WebUI clients** — established TCP connections to the WebUI port.
- **In-flight inference** — admits in the last 10 min without a
  matching finish. A non-empty list here means a request is still
  generating (or stuck).
- **Backend worker processes** — PIDs seen in the backend log.
- **Orphaned workers** — worker PIDs that appear in the log but have
  received zero admitted requests in the current session.

`4lm doctor` is the *static* sweep (prereqs, file paths, sudoers,
binaries on PATH). `4lm diag` is the *runtime* sweep. Use `doctor`
after install, `diag` when something feels off.

### OpenCode / WebUI output loops on the same sentence

Symptom: model output cycles two or three sentences verbatim. Classic
`repetition_penalty=1.0` failure mode, especially with Qwen3.6.

The OpenAI API spec has no `repetition_penalty` field — clients can only
pass `frequency_penalty` / `presence_penalty`. mlx-openai-server's default
is 1.0 (off). The fix is server-side: `bin/4lm-backend-start.sh` passes
`--repetition-penalty 1.05` to the launch invocation. If you've edited
the wrapper and removed it, restore it; if 1.05 isn't enough for a
particularly stubborn model, raise to 1.10 (don't go above 1.15 — output
quality starts dropping).

```sh
# Verify penalty is on the running master's argv
ps -o command= -p "$(pgrep -f 'mlx-openai-server launch' | head -1)" \
  | tr ' ' '\n' | grep -A1 repetition-penalty
```

### `[metal::malloc] Resource limit (NNN) exceeded` (HTTP 500 to client)

Symptom: OpenCode or WebUI gets a 500 with the message
`Failed to generate text stream: [metal::malloc] Resource limit (NNN) exceeded.`
where `NNN` is the size MLX failed to allocate (typically a KV-cache
slab, ~hundreds of MB).

This is **wired-memory exhaustion**, not the wedged-1.8.0 bug. After a
long session with the `default` profile, two things grow inside the
wired pool:

- **KV cache** per ongoing conversation — `cache_key_len` in the
  backend log climbs every turn (visible in `4lm diag` → "Last 5
  finished").
- **Disk-backed prompt cache** (1.8.0 feature) keeps recent slabs
  resident even after a request finishes.

Once the workers + caches + macOS itself fill the 96 GB wired-pool cap
(`iogpu.wired_limit_mb=98304`), Metal refuses the next allocation and
the request fails fast.

First-aid:

```sh
4lm restart backend     # clears worker state, KV cache, disk-backed cache
```

Cold reload is 30-60 s. Subsequent prompts rebuild caches on demand.

If it recurs within minutes (not hours), tune one of:

1. **Switch to a single-model MLX profile** to reduce memory pressure:
   `4lm profile set mlx-coding` or `4lm profile set mlx-knowledge`.
2. **Drop context_length** in an MLX profile. Edit the relevant entry in
   `~/.4lm/config/profiles/<name>.yaml`, then `4lm profile set <name>`
   to apply with rollback. (The default Ollama profile has no
   `context_length` key — Ollama manages context internally.)
3. **Raise `iogpu.wired_limit_mb`** if you're willing to give MLX more
   of the 128 GB. Going past ~104 GB (107520) starts crowding macOS
   itself. The sudoers rule pins exactly `98304`, so if you change the
   value, also update `/etc/sudoers.d/4lm-stack` and the wrapper's
   call.

If it recurs only after long sessions (every few hours): treat as
normal cache-growth wear — `4lm restart backend` periodically, or
`4lm stop backend` overnight so the cache resets daily.

### Worker burning CPU with no in-flight requests

Symptom in `4lm diag`:

```
In-flight inference (admitted, not yet finished, last 10 min)
  (none)

Backend worker processes
  master pid=XXXXX  0.0% CPU,   0.6 GB RSS, etime …
  worker pid=YYYYY 44.0% CPU,  33.0 GB RSS, etime …    ← stuck
```

`mlx-openai-server` 1.8.0 has been observed to leave a worker spinning
on Metal command-encoder dispatches after the last request finishes
(seen 2026-04-26 immediately after the 1.7.1 → 1.8.0 bump). Fix:

```sh
4lm restart backend
```

After restart, the worker should drop to `0.0% CPU` and GPU idle
residency rises to >90% (verify with the powermetrics line `4lm diag`
prints). If the issue recurs, file upstream at
<https://github.com/cubist38/mlx-openai-server/issues>.

### `4lm health` exits 1

```
iogpu.wired_limit_mb=<x> < 98304 — see docs/setup.md §Sudoers
```

Set it interactively or re-run `make install` — install.sh writes the
sudoers rule and sets the limit when its check fails. The setting persists
until reboot, after which the backend wrapper re-applies it via the sudoers
NOPASSWD entry on next start.

### `sudo: a password is required` in backend.log

Sudoers literal does not match the wrapper invocation. install.sh writes
the matching pair, so this only happens if `/etc/sudoers.d/4lm-stack` was
edited or removed. Wrapper invokes:

```
sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
```

Re-run `make install` to restore the sudoers file.

### `newsyslog: cannot open` after install

Either you cancelled the sudo prompt during install, or `/etc/newsyslog.d/`
doesn't exist. Verify with:

```sh
ls -la /etc/newsyslog.d/4lm.conf
```

If missing, re-run `install.sh` and complete the sudo prompt.

### `error: externally-managed-environment` (PEP 668)

You ran `pip install` against Homebrew's Python directly. Use `install.sh`
instead — it routes through `pipx`, which gives each tool its own venv. If
`pipx` is missing, install it first: `brew install pipx && pipx ensurepath`.

### Changing pinned package versions

The `requirements.txt` pin is intentional. To change a version, edit
`requirements.txt` (one `pkg==version` per line) and re-run `install.sh` —
the installer detects existing pipx installs and reinstalls with `--force`
when the pinned version differs. Don't `pip install --upgrade` out-of-band.

### `4lm logs backend` shows no file

The service hasn't run yet. Run `4lm start backend` first.

### "Profile switch failed; reverted to <name>"

The new profile failed to come up within 30 s. Check
`4lm logs backend` for the actual error (model path wrong, OOM, missing
weights). The active symlink and process are restored to the previous
profile.
