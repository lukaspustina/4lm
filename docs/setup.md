# Setup

This is the operator runbook for getting `4lm` from a fresh clone to a working
local LLM stack on Apple Silicon.

## Requirements

- macOS, Apple Silicon (`uname -m` must report `arm64`)
- Homebrew, then `just bootstrap` (installs Python 3.12, pipx, shellcheck,
  shfmt, bats-core from `Brewfile` and runs `pipx ensurepath`)
- ~140 GB free disk for model weights

> Python 3.12 is pinned for compatibility with the MLX ecosystem
> (mlx, mlx-lm, omlx). install.sh creates pipx venvs with `python3.12`
> even if your system default is newer.

## Step 1 — Install

```sh
just install
```

The installer is idempotent and will:

- Copy scripts, plists, profiles into `~/.4lm/`
- Seed `~/.4lm/config/network.yaml` (mode: local) on first run
- Symlink `~/.local/bin/4lm` → `~/.4lm/bin/4lm`
- `pipx install` each pinned package from `requirements.txt` using `python3.12`
- Remove a legacy `/etc/sudoers.d/4lm-stack` left by installs before 2026-09
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
just install BACKEND_ONLY=1
```

The flag skips: `open-webui` pipx package, `4lm-webui-start.sh` wrapper,
the webui launchd plist, the `webui.log` newsyslog rotation entry,
`~/.config/opencode/opencode.jsonc`, and the `Brewfile-tui` (which only
contains `opencode`). `just bootstrap BACKEND_ONLY=1` skips `Brewfile-tui`
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

## Step 2 — Pre-download model weights

`omlx` will pull on demand, but a 30+ GB model on residential fiber is
10-15 minutes of "is it broken or working?". Pre-pull all profile models
in one shot:

```sh
just models           # download/update every model in config/profiles/
just models lean      # … or only one profile's models
just models-list      # see what's cached
just models-clean     # prune orphaned revisions
just models-rm MODEL=<repo>   # remove one specific model
```

Cache lives at `~/.cache/huggingface/hub/` (~140 GB for the default profile).

## Step 3 — Start

```sh
4lm start         # bootstrap and start backend + webui
4lm status        # see service state
4lm doctor        # prereq + smoke-test sweep (binaries, profile, inference)
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

Apply to the default profile's coder and chat models: `qwen3-coder-next`
and `qwen3.8-27b`. (The embedder, reranker, and vision models are wired
via WebUI env vars rather than per-model records.) Apply the same to any
other profile models that have `enable_auto_tool_choice: true`.

## Step 6 — OpenCode TUI

`just bootstrap` installs the homebrew/core `opencode` formula (anomalyco's
distribution; sst/opencode no longer exists). `just install` seeds
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
`~/.4lm/config/profiles/`). It declares the backend (`omlx`, `mlx_lm`,
or `ollama`) and the models to load. The active profile is selected via
the `~/.4lm/config/active-profile` symlink; switch atomically with
`4lm profile set <name>`.

Four profiles ship with the repo: one per memory class plus the Ollama smoke
test. The full table — models per profile, resident RAM, fits-on hardware —
lives in the
[README](../README.md#profile-lineup). Profile YAML headers carry per-slot
rationale, memory math, when-to-use, and assumptions-to-validate.

### When to switch

| Situation | Profile |
|---|---|
| 256 GB Mac | `default` |
| 128 GB Mac | `mid` |
| 64 GB Mac, or a small fallback on a bigger one | `lean` |
| GGUF smoke test (confirm Ollama still works) | `ollama` |

The installer activates the matching profile on first install; later
re-installs keep whatever is active.

```sh
4lm profile list                 # installed profiles
4lm profile current              # active
4lm profile set <name>           # atomic, validated, rolls back on failure
4lm profile show [<name>]        # print profile YAML
```

Switching restarts the backend (~30-60 s cold load). All omlx profiles
share the same embedder served-name (`qwen3-embedding`) and reranker
(`qwen3-reranker`), so RAG indexes stay valid across switches.

**Same-name re-issue is a live config reload.** After editing
`~/.4lm/config/profiles/<active>.yaml`, run `4lm profile set <active>`
to re-render `~/.omlx/model_settings.json`, re-stage model symlinks,
and kickstart the backend — no full stop/start.

Profile schema reference: [`profile-schema.md`](profile-schema.md). To
customise: edit `~/.4lm/config/profiles/<name>.yaml` directly —
`install.sh` won't overwrite a profile that already exists.

## Running a large model on a shared machine

When the resident model set takes most of the RAM and the Mac is also a
desktop or runs a VM, macOS — not omlx — sets the ceiling. Under memory
pressure its jetsam mechanism SIGKILLs the **largest** process, whatever its
priority, and omlx's memory guard only counts Metal allocations, not page
cache, hot cache or Python heap. In practice the
ceiling sits well below RAM, and well below the omlx guard.

- Budget everything omlx keeps resident (all pinned models plus any
  `hot_cache_max_size`) well below RAM minus VM limit minus ~20 GiB for macOS
  and the desktop.
- Pin the models and give them no TTL. Loading and unloading ~100 GB models
  is where omlx takes its emergency-reclaim path and where IOGPU panics have
  been reported.
- Don't pull large checkpoints (`hf download`) while a big set is resident:
  the download fills page cache and eats the free disk that macOS needs to
  grow swap.
- Cap omlx's SSD KV cache with `paged_ssd_cache_max_size` — its `auto` default
  claims half the free disk.
- Exclude `~/.cache/huggingface` and `~/.omlx` from Time Machine
  (`tmutil addexclusion`) and Spotlight, so backups don't read hundreds of GB
  through the page cache.
- Leave `iogpu.wired_limit_mb` at its default. Raising it adds no memory; it
  only lets the GPU wire more of what macOS itself needs.

## Network exposure

Default bind is `127.0.0.1`. To expose to your LAN:

```sh
4lm expose lan --confirm
```

Without `--confirm` the command refuses. With `--confirm` it writes
`mode: lan` to `~/.4lm/config/network.yaml` and restarts running services.
It also refuses when `~/.4lm/config/api-key` is missing, or when the active
profile's backend is not omlx — ollama and `mlx_lm` cannot enforce a key, and
their wrappers exit 78 on `mode: lan`.

**API key.** The key is always on, in both modes. The backend wrapper passes
it to omlx as `OMLX_API_KEY`; Open WebUI and the seeded opencode config read
the same file. omlx writes the key into `~/.omlx/settings.json` on its next
settings save, so the wrapper keeps that file at 0600 and `4lm doctor`
checks both. An `opencode.jsonc` from before 2026-09 lacks the key; add to
`provider.4lm.options`:

```jsonc
"apiKey": "{file:~/.4lm/config/api-key}"
```

For remote clients, create a sub key per consumer in the omlx admin UI
(`http://<host>:8000/admin`). Sub keys reach `/v1/*` only, not management
endpoints, and can be revoked individually.

Security hardening applied in all modes (not LAN-only):
- `ENABLE_SIGNUP=False` — no new accounts can register after the first (admin) one
- `DEFAULT_USER_ROLE=pending` — new accounts have no privileges until promoted
- `WEBUI_SECRET_KEY` persisted to `~/.4lm/config/webui_secret_key` (mode 0600)

Better than `lan`: bind to `127.0.0.1` and use Tailscale or another VPN that
provides authentication.

## Running as a system daemon

For a headless host the backend can run as a system-domain LaunchDaemon under
a dedicated service account instead of a LaunchAgent in your login session. It
then starts at boot once the disk is unlocked, needs no GUI login, and keeps
the LAN-facing process out of your own account. Metal works from such a
daemon: a LaunchDaemon under a hidden account gets the same GPU and working
set as a GUI session. Backend only; there is no WebUI or opencode in this mode.

**Prerequisites** — 4lm does not create them:

- An account for the daemon, typically hidden and without a login shell, with
  an existing home directory it owns. 4lm installs everything there: `~/.4lm`,
  `~/.omlx`, the HF cache, the pipx venvs.
- A checkout of this repo the account can read (your own home usually is not
  readable by other accounts).
- The Homebrew tools from the `Brewfile`, installed by an admin.
- No GUI-mode 4lm on the same machine: it would hold the port, and its
  `~/.local/bin/4lm` shadows the daemon CLI in `sudo`'s `PATH`. Remove it
  **before** installing the daemon — `4lm stop && 4lm uninstall --confirm` —
  because once the daemon exists, the CLI routes everything to it.

**Install** (idempotent — re-run it to update scripts and the CLI). It runs
from the checkout, since the installed CLI has no sources:

```sh
sudo <checkout>/bin/4lm install --daemon <user>
```

As root it checks the account and its home, runs the regular backend-only
install **as the account**, writes `/Library/LaunchDaemons/com.4lm.backend.plist`
with `UserName <user>`, copies the CLI to `/usr/local/bin/4lm` (root-owned),
and adds log rotation in `/etc/newsyslog.d/4lm-daemon.conf`. It does not start
anything.

**Operate** — always `sudo 4lm <cmd>`:

| Command | Runs as | What happens |
|---|---|---|
| `start`, `stop`, `restart` | root | `launchctl bootstrap` / `bootout` / `kickstart` in the system domain |
| everything else (`status`, `profile set`, `expose`, `model …`, `doctor`, `bench`, `logs`, …) | the account | re-executed via `sudo -u <user> -H`; restarts signal the backend and launchd's `KeepAlive` respawns it |

Root never reads or writes the account's files, so a compromised backend
cannot plant a path that a root process follows. Without `sudo`, the CLI points
you at it. `autostart` does not apply: launchd loads the daemon at every boot;
`sudo 4lm stop` holds until the next one.

A typical sequence, e.g. from configuration management. The install picks the
profile by RAM; `start` stages it once its models are cached and refuses to
start otherwise. Choose another profile with `profile set <name>` after its
models are downloaded.

```sh
sudo <checkout>/bin/4lm install --daemon <user>
sudo /usr/local/bin/4lm model download --profile <name>
sudo /usr/local/bin/4lm expose lan --confirm
sudo /usr/local/bin/4lm start
sudo /usr/local/bin/4lm status
```

The API key is `<home>/.4lm/config/api-key`, readable by the account only
(`sudo -u <user> cat …`). Create consumer sub keys in the omlx admin UI after
the switch.

**Moving from a GUI install.** Move the models instead of downloading them
again, and move the **whole** `~/.cache/huggingface/hub/` directory in one
rename, then `chown -R <user>` it. Moving only the `models--*` directories
leaves dead links: current HF caches keep the files in a shared blob store
(`hub/blobs/`), and the snapshots link into it. Afterwards `sudo 4lm start`
stages the active profile from the moved cache. The account gets a new API key,
and omlx sub keys from your old `~/.omlx/settings.json` do not carry over.

**Limits.** `4lm upgrade brew` needs the admin who owns Homebrew. A changed
plist (after a re-install) takes effect after `sudo 4lm stop && sudo 4lm start`.

**Uninstall** the system pieces with `sudo 4lm uninstall --daemon --confirm`
(without `--confirm` it lists what it would remove). The account
and its home — install, config, models — stay until you remove the account.

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

`4lm doctor` is the *static* sweep (prereqs, file paths,
binaries on PATH). `4lm diag` is the *runtime* sweep. Use `doctor`
after install, `diag` when something feels off.

### OpenCode / WebUI output loops on the same sentence

Symptom: model output cycles two or three sentences verbatim. Classic
`repetition_penalty=1.0` failure mode, especially with chat models on
long contexts.

The OpenAI API spec has no `repetition_penalty` field — clients can only
pass `frequency_penalty` / `presence_penalty`. On omlx the fix is
per-model in the profile YAML — add a `sampling:` block to the affected
model entry:

```yaml
- model_path: mlx-community/Qwen3.8-27B-4bit
  served_model_name: qwen3.8-27b
  sampling:
    repetition_penalty: 1.05   # raise to 1.10 if 1.05 isn't enough
```

Then re-issue the profile (same name) to push the change live:

```sh
4lm profile set <active>
```

Don't go above 1.15 — output quality starts dropping. Check the
applied settings with:

```sh
cat ~/.omlx/model_settings.json | jq '.'
```

### `[metal::malloc] Resource limit (NNN) exceeded` (HTTP 500 to client)

Symptom: OpenCode or WebUI gets a 500 with the message
`Failed to generate text stream: [metal::malloc] Resource limit (NNN) exceeded.`
where `NNN` is the size MLX failed to allocate (typically a KV-cache
slab, ~hundreds of MB).

This is **wired-memory exhaustion**. After a long session with the
`default` profile (full Qwen3 stack — coder + chat + embed + rerank +
vision), three things grow inside the wired pool:

- **KV cache** per ongoing conversation — `cache_key_len` in the
  backend log climbs every turn (visible in `4lm diag` → "Last 5
  finished").
- **omlx paged KV cache + continuous-batching state** keeps recent
  slabs resident even after a request finishes.
- **Loaded model weights** for all five slots, pinned per profile YAML.

Once the workers + caches fill the GPU working set (the macOS default,
`recommendedMaxWorkingSetSize` — 96 GB on a 128 GB machine), Metal
refuses the next allocation and the request fails fast.

First-aid:

```sh
4lm restart backend     # clears worker state, KV cache, paged cache
```

Cold reload is 30-60 s. Subsequent prompts rebuild caches on demand.

If it recurs within minutes (not hours), tune one of:

1. **Drop to a leaner profile** to reduce the resident model set:
   `4lm profile set mid` (~62 GB) or `4lm profile set lean` (~40 GB).
2. **Cap omlx memory in the profile YAML.** Set omlx's memory guard
   ceiling in the `omlx:` block, and cap each model's prompt length:
   ```yaml
   omlx:
     memory_guard_gb: 90        # soft stop at 85 %, hard abort at 95 %
   models:
     - model_path: …
       max_context_window: 65536
   ```
   Then `4lm profile set <active>` to apply.

If it recurs only after long sessions (every few hours): treat as
normal cache-growth wear — `4lm restart backend` periodically, or
`4lm stop backend` overnight so the cache resets daily.

### Stuck worker burning CPU with no in-flight requests

Symptom in `4lm diag`:

```
In-flight inference (admitted, not yet finished, last 10 min)
  (none)

Backend worker processes
  worker pid=YYYYY 44.0% CPU,  33.0 GB RSS, etime …    ← stuck
```

Generic recovery for any backend (omlx, mlx_lm, ollama):

```sh
4lm restart backend
```

After restart the worker should drop to ~0.0% CPU and GPU idle
residency rises to >90% (verify with the powermetrics line `4lm diag`
prints). If the issue recurs reproducibly on omlx, file upstream at
<https://github.com/jundot/omlx/issues>.

### `4lm doctor` exits non-zero

`4lm doctor` runs prereq checks (binaries on PATH, profile validity) and then smoke-tests
inference against `/v1/chat/completions` for each non-embedding model
in the active profile. A non-zero exit means one of these failed —
the output names which.

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

omlx is pinned in `install.sh` itself (`OMLX_GIT_REF`, since it ships from git
rather than PyPI). Re-running the installer replaces a deviating omlx version with the pinned one:
it compares the commit pip recorded for the installed omlx with the pin, so
moving the pin is all a bump takes — even between commits that report the same
version.

### `4lm logs backend` shows no file

The service hasn't run yet. Run `4lm start backend` first.

### "Profile switch failed; reverted to <name>"

The new profile failed to come up within 30 s. Check
`4lm logs backend` for the actual error (model path wrong, OOM, missing
weights). The active symlink and process are restored to the previous
profile.
