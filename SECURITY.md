# Security Policy

## Threat model

4lm is a **single-user, local-host tool**. The OpenAI-compatible
backend on `:8000` requires an **API key in every mode**: `install.sh`
generates `~/.4lm/config/api-key` (0600) and the backend wrapper refuses
to start without it. Local clients (Open WebUI, opencode, `4lm` itself)
read the same file.

`4lm expose lan --confirm` switches the bind to `0.0.0.0`. The key is
then the only gate on `/v1/*` — there is no TLS, so it travels in clear
text on the LAN. Only the omlx backend enforces a key; ollama and
`mlx_lm` profiles refuse a LAN bind. Give each remote client its own
omlx sub key so it can be revoked alone, and keep the main key (which
also opens omlx's admin UI) on the host.

omlx stores the key in plain text in `~/.omlx/settings.json`; 4lm keeps
that file at 0600 and `4lm doctor` checks it.

The WebUI hardening defaults shipped by 4lm — `DEFAULT_USER_ROLE=pending`,
`ENABLE_SIGNUP=False`, persistent `WEBUI_SECRET_KEY` — mitigate WebUI
account-takeover scenarios.

## Reporting a vulnerability

If you find a vulnerability, please **do not** open a public GitHub
issue. Instead, open a private security advisory on the repo's
GitHub Security tab (Security → Advisories → "Report a vulnerability").

Please include reproduction steps and any impact assessment you've done.
A reasonable acknowledgement timeline is **7 days**; fix timelines depend
on severity.

## Out of scope

- Issues that require an attacker who already has shell access to the
  Mac running 4lm.
- Issues in upstream projects (omlx, ollama, OpenWebUI, opencode) — please
  report those directly to the respective project.
- Key interception on an untrusted network after `4lm expose lan` — the
  backend speaks plain HTTP; the docs warn about this and the `--confirm`
  gate makes it a deliberate choice.
