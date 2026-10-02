# SDD — System daemon mode

Status: done · 2026-10-02

## Context

4lm runs its backend as a LaunchAgent in the installing user's GUI domain. A
headless inference host wants the backend as a system-domain LaunchDaemon under
a dedicated service account instead: it starts at boot once the disk is
unlocked, needs no GUI login, and keeps the LAN-facing process out of the
account that holds the operator's personal data.

Verified before this design (macOS 27, Apple Silicon, one user logged in): a
LaunchDaemon running as root and one running as a hidden service account both
get the Metal GPU device, the same recommended working set as a GUI session, and
the same matmul throughput via MLX.

Everything under 4lm resolves from `$HOME` (`~/.4lm`, `~/.omlx`, the HF cache,
pipx venvs). The service account's home is therefore the whole install: daemon
mode is a normal backend-only install owned by that account, plus a system
plist and a root-owned CLI entry point.

## Requirements

1. `sudo <checkout>/bin/4lm install --daemon <user>` installs daemon mode for an **existing**
   account. It fails fast when not root, when the account does not exist, when
   its home is missing or not owned by it, or when the account cannot read the
   source checkout. 4lm never creates or deletes accounts.
2. The account's install is the regular backend-only install, run as that
   account (`sudo -u <user> -H`). Steps that need root or a GUI user are skipped
   there: the `~/.local/bin` link, newsyslog, legacy sudoers removal, the ollama
   Homebrew install.
3. Root writes `/Library/LaunchDaemons/com.4lm.backend.plist` from the same
   template with the account's home and `UserName <user>`, owned `root:wheel`,
   mode 644. The installer does not bootstrap it; launchd loads it at boot.
4. Root installs a root-owned copy of the CLI at `/usr/local/bin/4lm` (mode
   755). Root never executes a file the service account can write.
5. Root adds a newsyslog entry for the account's `backend.log`, owned by the
   account.
6. The CLI detects daemon mode by the system plist and reads the account from
   its `UserName`.
   - As root: `start` bootstraps (or kickstarts) `system/com.4lm.backend`,
     `stop` boots it out, `restart` kickstarts it. Root reads nothing from the
     account's home. Every other command re-executes itself as the account.
   - As the account: launchd queries use `system/<label>`; a restart signals
     the backend process and waits for it to exit, and `KeepAlive` respawns it.
     `start`, `stop` and `autostart` refuse with a pointer to `sudo 4lm`.
   - As anyone else: refuse with a pointer to `sudo 4lm <cmd>`.
7. `profile set`, `expose`, `status`, `doctor`, `model …`, `bench`, `logs` and
   `diag` work in daemon mode through that re-execution, including the
   profile-switch rollback.
8. `sudo 4lm uninstall --daemon --confirm` removes only the system pieces (boots out the
   daemon, removes the system plist, the CLI copy and the newsyslog entry). The
   account and its home, including downloaded models, stay.
9. The GUI-domain install is unchanged when no system plist exists.

## Design

- **Privilege split by re-execution.** `sudo 4lm <cmd>` is the single entry
  point. Root handles only the three launchd lifecycle verbs, which touch
  nothing but the root-owned plist. Everything that reads or writes 4lm state
  runs as the account, so a compromised backend cannot plant a symlink that a
  root process follows.
- **Restart without root.** The account cannot kickstart a system-domain job,
  but it owns the backend process. Sending it `SIGTERM` and waiting for the pid
  to vanish has the effect of `kickstart -k` under `KeepAlive`. No sudoers rule.
- **`LAUNCHD_DOMAIN`.** One variable replaces the hardcoded `gui/<uid>`, and one
  function (`service_kick`) replaces the scattered `launchctl kickstart -k`
  calls, so the daemon branch lives in two places.
- **Operator-side prerequisites stay outside 4lm:** creating the account,
  putting a checkout where it can read it, moving existing model caches into
  its home, power settings, monitoring.

## Phases

| Phase | Change | Verification |
|---|---|---|
| 1 | Refactor: `LAUNCHD_DOMAIN` and `service_kick` in `bin/4lm` | full bats suite green before and after |
| 2 | CLI daemon detection, root dispatch, account-side restart | new bats: root / account / other-user paths with stubbed `id`, `sudo`, `plutil`, `launchctl` |
| 3 | `4lm install --daemon <user>` (`daemon_install`) and the account-side `--service` skip set | new bats: fail-fast checks, plist content, CLI copy, newsyslog line, account install invoked |
| 4 | `4lm uninstall --daemon` (`daemon_uninstall`) | new bats: system pieces removed, home untouched |
| 5 | Docs: setup runbook section, README, CLAUDE.md, CHANGELOG | review |

On-host acceptance after phase 5: install over a disposable account, `sudo 4lm
start`, `sudo 4lm status`, `sudo 4lm profile set <name>` restarts and serves,
`sudo 4lm stop`, uninstall leaves the home intact.

## Acceptance result

Run on an Apple Silicon host with a hidden service account, twice.

- 2026-09-30: install, start, `expose lan`, key enforcement (401 without a key on
  loopback and LAN) passed. Five findings, all fixed with tests: install ran
  from the caller's unreadable cwd; the migration doc moved only `models--*`
  (dead blob links); `logs` waited silently on a root-owned log; `status`
  reported LaunchAgent autostart; `start` right after install crash-looped
  with EX_CONFIG instead of staging the runtime.
- 2026-10-02: `uninstall --daemon --confirm` removed the system pieces and kept
  the account's home; re-install with the fixes and omlx v0.7.0, `start`,
  `status`, `logs` passed; the daemon came up on the first run (no respawns),
  401 without a key on loopback and LAN.
- Not exercised on the host: `sudo 4lm profile set` restarting the daemon by
  signal (covered by bats with a stubbed launchd).
