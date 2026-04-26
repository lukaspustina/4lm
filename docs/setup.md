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

## Step 1 — Pre-download model weights

`mlx-openai-server` will pull on demand, but a 30+ GB model on residential fiber
is 10-15 minutes of "is it broken or working?". Pre-pull:

```sh
huggingface-cli download mlx-community/GLM-4.7-Flash-8bit
huggingface-cli download unsloth/Qwen3.6-35B-A3B-MLX-8bit
huggingface-cli download LibraxisAI/gpt-oss-120b-mlx-mxfp4
```

Cache lives at `~/.cache/huggingface/hub/`.

## Step 2 — Wired memory limit (Sudoers)

macOS Metal allocates GPU memory from a "wired" pool that defaults to ~70 % of
RAM. On a 128 GB Mac that's ~89 GB, which is *just* enough for two 8-bit MoE
models but breaks the moment KV cache or the on-demand 120B model loads.

Persist a higher cap and grant the backend wrapper passwordless access:

```sh
sudo /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
echo "iogpu.wired_limit_mb=98304" | sudo tee -a /etc/sysctl.conf

sudo visudo -f /etc/sudoers.d/4lm-stack
# Add (literal must match the wrapper invocation EXACTLY):
lukas ALL=(root) NOPASSWD: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
```

Without this, the backend wrapper will print
`WARN: wired_limit_mb not set — run \`4lm doctor\` for fix` and continue
with the lower cap.

`4lm health` exits 0 if the limit is met, 1 otherwise.

## Step 3 — Install

```sh
./install.sh
```

The installer is idempotent. It will:

- Migrate `~/.llm-stack/` → `~/.4lm/` if present
- Bootout any leftover `legacy.llm-*`, `legacy.4lm-*`, and `com.4lm.*` agents
- Copy scripts, plists, profiles into `~/.4lm/`
- Seed `~/.4lm/config/network.yaml` (mode: local) on first run
- `pip install -r requirements.txt`
- `sudo tee /etc/newsyslog.d/4lm.conf` for log rotation
- Symlink `~/.local/bin/4lm` → `~/.4lm/bin/4lm`

It will **not** start any services and will **not** copy plists to
`~/Library/LaunchAgents/`. Plists are stored in `~/.4lm/launchd/` so launchd
does not auto-start them at login.

## Step 4 — Start

```sh
4lm start         # bootstrap and start backend + webui
4lm status        # see service state
4lm health        # verify wired memory limit
```

After reboot, services are stopped. Run `4lm start` to bring them back.

## Step 5 — Open WebUI first user

Open the WebUI in private browsing **immediately** and register your account.
`DEFAULT_USER_ROLE` is set to `pending`, so you must explicitly promote yourself
to admin from the WebUI admin panel after registering. Until then the account
has no privileges.

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

### `4lm health` exits 1

```
iogpu.wired_limit_mb=<x> < 98304 — see docs/setup.md §Sudoers
```

You haven't completed Step 2. Either set the limit interactively
(`sudo /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304`) or add the sudoers line.

### `sudo: a password is required` in backend.log

Sudoers literal does not match the wrapper invocation. The wrapper calls:

```
sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
```

The sudoers file must list **exactly** that command path and arguments.

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
