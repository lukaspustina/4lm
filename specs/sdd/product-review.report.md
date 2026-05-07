# SDD Implementation Report: product-review.md

**Date**: 2026-05-07
**Phases run**: 1, 2, 3, 4, 5, 6
**Overall status**: all-shipped

| Phase | Title | Status | Commit |
|-------|-------|--------|--------|
| 1 | Correctness & Safety | shipped | c69c539 |
| 2 | Onboarding & Post-Start UX | shipped | faa4b37 |
| 3 | Error Message Consistency | shipped | 047b3d3 |
| 4 | 4lm diag Implementation Gap | shipped | eb068e6 |
| 5 | Help Surface & Destructive-Operation Guards | shipped | ccd7832 |
| 6 | WebUI Start Script Test Coverage | shipped | a92fc48 |

## Manual Test Plan

1. `4lm profile set default` — expected: switches profile (or "already active" message if already set), no error
2. `4lm expose lan` — expected: exit 1, stderr contains `error: pass --confirm to expose on LAN`
3. `4lm expose lan --confirm` — expected: exit 0, `~/.4lm/config/network.yaml` contains `mode: lan`
4. `4lm expose local` — expected: exit 0, network.yaml contains `mode: local`
5. `4lm expose lan bogus --confirm` — expected: exit 1, stderr contains `error: unknown argument: bogus`
6. `4lm models rm org/repo` — expected: exit 0, stdout contains `--confirm` and `org/repo`, cache unchanged
7. `4lm uninstall` — expected: exit 0, prints `Would remove:` list including `~/.4lm`, nothing removed
8. `4lm start` — expected: exit 0, stdout contains `http://127.0.0.1:NNNN` and `4lm open`
9. `4lm health` — expected: exit 0 if GPU wired limit adequate, output contains `GB` and `OK`; exit 1 with `error:` if below threshold
10. `4lm diag` — expected: stdout contains `Backend clients` and `WebUI clients` sections
11. `4lm profile list` (no yaml files) — expected: stdout contains `No profiles found` and `make install`
12. `4lm help` — expected: output contains `models cleanup` line
13. `4lm models clean` — expected: `hf cache prune --yes` invoked (no interactive prompt)
14. Start WebUI start script — expected: `WEBUI_REGISTRATION_ENABLED=false` and `DEFAULT_USER_ROLE=pending` in environment; secret key file created at `~/.4lm/config/webui_secret_key` with 600 permissions

## Notes

- `test_http_probe_ok` in `tests/python/test_diag.py` fails in sandbox mode (socket binding blocked). Pre-existing issue unrelated to this SDD.
- Phase 6 `stat -f %Lp` returns `600` (not `0600`) on this macOS — the SDD had incorrect documentation; test uses `600`.
