# An unenforced pin is documentation, not a constraint

Date: 2026-08-17 · SDD: `specs/done/sdd/bump-omlx-2026-08-17.md`

`install.sh` pinned omlx to a git SHA and guarded the install with
`if pipx list --short | grep -q "^omlx "` — presence, not version. Any installed
omlx short-circuited the install, so the pin bound nothing. It went unnoticed
for three months: the pin read 2026-05-14 while the machine ran `0.3.9.dev1`,
and nothing in the repo could tell the two apart.

**What failed:** treating a version-comparison problem as a presence check, and
assuming that recording a pin makes it hold. The drift is invisible precisely
because the guard reports success.

**What worked:** compare an explicit expected version against what is installed,
and reinstall with `--force` on mismatch. Where the installer's own package
manager discards the identity you pinned on (pipx drops the git ref), pin a
second marker that survives — here the package version — and enforce against
that.

**Generalizes to:** any pinned dependency whose installer is idempotent on
presence rather than identity. The test is one question: after changing the pin
in the repo, does re-running the installer change anything on a machine that
already has the dependency? If not, the pin is a comment.
