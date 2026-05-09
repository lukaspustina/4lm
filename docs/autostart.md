# Autostart

By default, 4lm services do **not** start at login. Every `4lm start` is
explicit, and every reboot leaves the stack stopped. This is intentional:
the machine should not serve inference requests unless you deliberately
decide to run the stack.

Autostart is opt-in and reversible:

```
4lm autostart enable  [omlx|webui|all]   # enable login autostart
4lm autostart disable [omlx|webui|all]   # disable and stop the service
4lm autostart status                     # check current state (read-only)
```

## How it works

Plists live in `~/.4lm/launchd/` and are NOT visible to launchd at login.

`4lm autostart enable` symlinks the plist into `~/Library/LaunchAgents/`,
which launchd scans at login, then bootstraps the service for the current
session. The source plist in `~/.4lm/launchd/` is never modified.

`4lm autostart disable` removes the symlink from `~/Library/LaunchAgents/`
and boots out the running service. The source plist is left untouched.

`4lm start` and `4lm stop` continue to work regardless of autostart state —
they manage the current session only.

## KeepAlive and ThrottleInterval

When autostarted, the service runs with `KeepAlive: true`. launchd restarts
it automatically if it exits for any reason, with a 10-second throttle between
restarts. To stop permanently, use `4lm autostart disable` (which boots out
the service) rather than killing the process directly.

## Uninstall

`make uninstall` (or `./uninstall.sh`) removes any `~/Library/LaunchAgents/`
symlinks that 4lm installed before removing the source plists. Systems that
never enabled autostart are unaffected.
