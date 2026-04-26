# Setup

This is the operator runbook for getting `4lm` from a fresh clone to a working
local LLM stack on Apple Silicon.

## Requirements

- macOS, Apple Silicon (`uname -m` must report `arm64`)
- Homebrew, then `make bootstrap` (installs Python 3.12, pipx, shellcheck,
  shfmt, bats-core from `Brewfile` and runs `pipx ensurepath`)
- ~140 GB free disk for model weights

> mlx-openai-server 1.7.1 requires Python `>=3.11,<3.13`, so install.sh
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

## Step 5 — OpenCode TUI

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

## Network exposure

Default bind is `127.0.0.1`. To expose to your LAN:

```sh
4lm expose lan --confirm
```

Without `--confirm` the command refuses and prints the risk summary. With
`--confirm` it writes `mode: lan` to `~/.4lm/config/network.yaml`, generates
`~/.4lm/config/webui_secret_key` (mode 0600) on first webui start, sets
`WEBUI_REGISTRATION_ENABLED=false`, and restarts running services.

Better than `lan`: bind to `127.0.0.1` and use Tailscale or another VPN that
provides authentication.

## Troubleshooting

### "Why are the fans on?" — finding the workload

`4lm diag` is the live-traffic view. It prints, in order:

- **Backend / WebUI clients** — established TCP connections to `:8000`
  and `:3000`, with client process name and PID. An OpenCode session
  shows as `opencode pid=… 127.0.0.1:NNNN→:8000`. Browser tabs show as
  `com.apple.WebKit.Networking → :3000`.
- **Last 5 finished inference requests** with timestamp, uid,
  finish_reason, generated tokens.
- **In-flight inference** — admits in the last 10 min without a
  matching finish. A non-empty list here means a request is still
  generating (or stuck).
- **Backend worker processes** — master + each `multiprocessing.spawn`
  worker, with %CPU, RSS in GB, etime. This is the section that catches
  the wedged-scheduler scenario.
- **Top CPU consumers** system-wide.
- A copy-paste line for `sudo powermetrics --samplers gpu_power` (out
  of `diag` because it needs sudo and prints a lot).

`4lm doctor` is the *static* sweep (prereqs, file paths, sudoers,
binaries on PATH). `4lm diag` is the *runtime* sweep. Use `doctor`
after install, `diag` when something feels off.

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
