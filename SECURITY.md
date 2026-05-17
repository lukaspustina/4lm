# Security Policy

## Threat model

4lm is a **single-user, local-host tool**. The OpenAI-compatible
backend on `:8000` ships with **no authentication**. When 4lm binds
to `127.0.0.1` (the default), the threat surface is limited to other
processes on the same Mac.

`4lm expose lan --confirm` switches the bind to `0.0.0.0` so other
machines on the LAN can reach the backend. **At that point, anyone
on the same network can call `/v1/*` without credentials.** Use this
mode only on a network you trust, or put the host behind Tailscale
or another VPN that provides authentication.

The WebUI hardening defaults shipped by 4lm — `DEFAULT_USER_ROLE=pending`,
`WEBUI_REGISTRATION_ENABLED=false`, persistent `WEBUI_SECRET_KEY` —
mitigate WebUI account-takeover scenarios but **do not** add auth to
the raw backend API.

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
- Misuse of `4lm expose lan` on an untrusted network — the docs warn
  about this and the `--confirm` gate makes it a deliberate choice.
