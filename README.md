# 4lm — Local LLM Stack

Personal local-LLM stack for the M5 Max running `mlx-openai-server` (backend)
and Open WebUI (frontend), managed by launchd, controlled by a single `4lm`
command.

## TL;DR

```sh
# 1. Pre-download model weights (~140 GB)
huggingface-cli download mlx-community/GLM-4.7-Flash-8bit
huggingface-cli download unsloth/Qwen3.6-35B-A3B-MLX-8bit
huggingface-cli download LibraxisAI/gpt-oss-120b-mlx-mxfp4

# 2. Wired-memory limit + sudoers (one-time, see docs/setup.md §Sudoers)
sudo /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304

# 3. Install
./install.sh

# 4. Start (does NOT auto-start at login)
4lm start

# 5. Daily life
4lm status             # see what's running
4lm logs backend       # tail backend log (uses tail -F, follows rotation)
4lm restart            # after profile or config changes
4lm stop               # shutdown
```

After a reboot, services are **stopped**. Run `4lm start` to bring them up.

## Activation model

Plists live in `~/.4lm/launchd/` — **not** `~/Library/LaunchAgents/`. launchd
does not scan that path, so services never auto-start at login. `4lm start`
calls `launchctl bootstrap` to load and run them; `4lm stop` calls
`launchctl bootout` to stop and unload.

## Network exposure

The default bind is `127.0.0.1`. To expose to your LAN:

```sh
4lm expose lan --confirm
```

Without `--confirm` the command refuses and prints the risk summary. With
`--confirm` it writes `mode: lan` to `~/.4lm/config/network.yaml`, generates
a persistent `WEBUI_SECRET_KEY` (mode 0600), forces
`WEBUI_REGISTRATION_ENABLED=false` and `DEFAULT_USER_ROLE=pending`, then
restarts running services.

`4lm expose local --confirm` reverts.

For mobile or family access prefer Tailscale (or any VPN) over `lan`. Bind to
`127.0.0.1` and let the VPN handle authentication.

## File layout after install

```
~/.4lm/
├── bin/
│   ├── 4lm                    # control command
│   ├── 4lm-backend-start.sh   # called by launchd
│   └── 4lm-webui-start.sh     # called by launchd
├── launchd/
│   ├── com.4lm.backend.plist
│   └── com.4lm.webui.plist
├── config/
│   ├── mlx-active             # symlink → profiles/<active>.yaml
│   ├── mlx-previous           # plain text, for rollback
│   ├── network.yaml           # bind mode + ports
│   ├── webui_secret_key       # mode 0600, generated on first lan-mode start
│   └── profiles/
│       ├── default.yaml
│       ├── coding-only.yaml
│       └── knowledge-only.yaml
├── logs/                      # backend.log, webui.log (merged stdout+stderr)
└── openwebui-data/            # Open WebUI database, settings

~/.local/bin/4lm               # symlink to ~/.4lm/bin/4lm
/etc/newsyslog.d/4lm.conf      # log rotation
```

## Architecture

```
                       4lm  (single control command)
                              │ bootstrap / bootout / kickstart
                              ▼
        ┌──────────────────────────────────┐    ┌──────────────────────────────────┐
        │ com.4lm.backend    │    │ com.4lm.webui      │
        │   mlx-openai-server              │    │   open-webui serve               │
        │   :8000 (OpenAI API)             │←───│   :3000 (Web UI)                 │
        └──────────────────────────────────┘    └──────────────────────────────────┘
                  ▲                                ▲
                  │ HTTP                           │ HTTP (browser)
            ┌─────┴────┐                     ┌─────┴────┐
            │ OpenCode │                     │  Safari  │
            │   TUI    │                     │  Chrome  │
            └──────────┘                     └──────────┘
```

The backend is the source of truth. WebUI is a stateless frontend proxying to
the backend. OpenCode talks directly to `:8000/v1`.

See `specs/sdd/4lm-rework.md` for the design rationale (model selection, why
MLX over Ollama, why launchd over Docker, why bash over Python).

## Common operations

```sh
# Switch model profile (atomic, with rollback)
4lm profile list
4lm profile set coding-only

# Update software
pip install -r requirements.txt --upgrade
4lm restart

# After a crash
4lm logs backend
4lm restart backend

# Doctor (prereq + config check)
4lm doctor

# Total uninstall
4lm uninstall              # bootout agents + remove ~/.local/bin/4lm
rm -rf ~/.4lm              # configs, profiles, openwebui-data
sudo rm /etc/newsyslog.d/4lm.conf
```

## Documentation

- `docs/setup.md` — operator runbook (sudoers, troubleshooting, model pulls)
- `docs/profile-schema.md` — YAML key reference for `mlx-openai-server`
- `specs/sdd/` — design documents (rationale, decisions, requirements)
- `CLAUDE.md` — repo-orientation pointer for AI assistants

## Development

```sh
make lint         # shellcheck + shfmt -d
make fmt          # shfmt -w
make test         # bats tests/
make check        # everything (CI runs this on macos-latest)
```

CI on every PR: `shellcheck`, `shfmt -d`, `bash -n`, `plutil -lint`,
`xmllint --noout`, YAML schema validation, bats suite.
