# SDD: Enforce and bump the omlx pin to v0.6.0

Status: Ready for Implementation
Original: specs/sdd/bump-omlx.md
Refined: 2026-08-17

## Overview

`install.sh` pins omlx to a git SHA but never enforces it: the idempotency
check skips installation whenever *any* omlx version is present, so a pin
bump in the repo is a no-op on every machine that already runs 4lm. This SDD
makes the installer enforce the pin by comparing the installed package
version against an expected version, then bumps the pin from the
2026-05-14 SHA to **v0.6.0** — the first release with Qwen3.8 support, which
is the reason the bump is wanted.

## Context & Constraints

- Stack: Bash (`set -euo pipefail`, shellcheck-clean, shfmt-formatted), bats
  test suite with shared command stubs under `tests/helpers/` and
  file-local stub overrides (e.g. `tests/test_install_idempotent.bats`
  defines its own `pipx` stub in `STUB_BIN`, which the bats `PATH`
  (`${BATS_TEST_DIRNAME}/helpers:${PATH}` prepended, then `STUB_BIN`
  prepended again in that test's own `setup()`) puts ahead of
  `tests/helpers/pipx`).
- omlx is not on PyPI; it is installed via
  `pipx install --python "${PIPX_PYTHON}" "git+https://github.com/jundot/omlx.git@${OMLX_GIT_REF}"`
  in `install.sh` §9b (`install.sh:299-309`).
- pipx does **not** retain the git ref: after installation `package_or_url`
  is truncated to `git+https://github.com/jundot/omlx.git` (verified
  locally on 2026-08-17). The installed package *version*, reported by
  `pipx list --short`, is the only recoverable marker standing in for the
  SHA.
- `pipx list --short` output format (confirmed from the existing
  `install.sh:302` check `grep -q "^omlx "` and `install.sh:303`
  `awk '{print $2}'`, and from the local stub in
  `tests/test_install_idempotent.bats:27`, `echo "omlx 0.3.8"`): one line
  per package, `<name><space><version>`, no `==` separator (that syntax is
  `requirements.txt`'s, used only in §9a).
- Observed drift on the reference machine: the currently pinned SHA
  (`51907f08074742defec4375fb629e289801a8a9f`, 2026-05-14) resolves to an
  installed package reporting `0.3.9.dev1`. This is the expected-version
  value Phase 1 must use to represent "the currently pinned build."
- omlx v0.6.0 = tag SHA `b16a1d1b4647dfeb19facc95aa9bfd0d78168269`
  (2026-08-16), which adds blockwise FP8, embedded MTP and ModelOpt NVFP4
  loading for Qwen3.8; v0.6.0rc1 (2026-08-15) introduced Qwen3.8-27B
  support and official reasoning levels.
- The CI matrix runs both install shapes (`make ci-default`,
  `make ci-backend-only`); omlx is installed in both, so any change to
  §9b must hold on both legs.
- The `4lm upgrade python` channel bumps `requirements.txt` entries only
  (`bin/4lm:805-834`) and must not learn about omlx — the pin is
  deliberate friction.

## Requirements

1. `install.sh` shall declare `OMLX_EXPECTED_VERSION` as a `readonly` var
   immediately above `OMLX_GIT_REF` in §9b, recording the expected omlx
   package version alongside the pinned git ref.
2. `install.sh` shall extract the installed omlx version from
   `pipx list --short` with exact package-name matching (no substring or
   regex match against other package names), and shall treat empty/absent
   output unambiguously as "not installed" — not as a parse error.
3. `install.sh` shall compare the installed version against
   `OMLX_EXPECTED_VERSION` using exact string equality. No pre-release/dev
   suffix normalization is performed: `0.6.0rc1`, `0.6.0.dev1`, etc. always
   count as a mismatch against `0.6.0`.
4. When the installed version equals `OMLX_EXPECTED_VERSION`, `install.sh`
   shall not reinstall omlx and shall print an `ok` line reporting the
   installed version.
5. When omlx is installed at a version other than `OMLX_EXPECTED_VERSION`,
   `install.sh` shall reinstall it with `pipx install --python
   "${PIPX_PYTHON}" --force "git+https://github.com/jundot/omlx.git@${OMLX_GIT_REF}"`
   and shall print an `info` line naming both the installed and expected
   versions before doing so.
6. When omlx is not installed, `install.sh` shall install it with
   `pipx install --python "${PIPX_PYTHON}" "git+https://github.com/jundot/omlx.git@${OMLX_GIT_REF}"`
   (no `--force`), printing the existing `info` line first.
7. The pinned git ref shall be `b16a1d1b4647dfeb19facc95aa9bfd0d78168269`
   (omlx v0.6.0) and `OMLX_EXPECTED_VERSION` shall be `0.6.0`.
8. The shared `tests/helpers/pipx` stub shall respond to `list --short` by
   printing `${PIPX_LIST_SHORT}` verbatim (one line per package, `<name>
   <version>` format) when that env var is non-empty, and printing nothing
   when it is unset or empty. All other invocations keep the existing
   behaviour (log `"$*"` to `${PIPX_LOG}` and exit 0).
9. `docs/setup.md`'s "Changing pinned package versions" section
   (`docs/setup.md:407-412`) shall state that re-running the installer
   replaces a deviating omlx version with the pinned one.

## File & Module Structure

| Path | Change |
|---|---|
| `install.sh` | §9b (`install.sh:299-309`): add `readonly OMLX_EXPECTED_VERSION="0.6.0"` above `readonly OMLX_GIT_REF="b16a1d1b4647dfeb19facc95aa9bfd0d78168269"`; replace the presence check (`grep -q "^omlx "`) with a version-comparison branch (not-installed / match / mismatch) |
| `tests/helpers/pipx` | Add a `list --short)` case emitting `${PIPX_LIST_SHORT:-}` when non-empty; keep the existing `echo "$*" >> "${LOG}"; exit 0` behaviour for all other invocations |
| `tests/test_install_idempotent.bats` | Extend the local `pipx` stub (`STUB_BIN/pipx`, lines 23-32) to be stateful for omlx: read/write an installed-version marker file so a `pipx install --force ... @${OMLX_GIT_REF}` call updates what a subsequent `list` reports. Add the version-comparison bats cases (Phase 1) and the bumped-constant re-run (Phase 2) |
| `docs/setup.md` | One sentence appended to "Changing pinned package versions" (`docs/setup.md:407-412`) |

`CLAUDE.md` is deliberately untouched: it does not carry the pin, and the
omlx path-probe note stays valid.

## Configuration

| Name | Location | Value |
|---|---|---|
| `OMLX_GIT_REF` | `install.sh` §9b | `b16a1d1b4647dfeb19facc95aa9bfd0d78168269` (was `51907f08074742defec4375fb629e289801a8a9f`) |
| `OMLX_EXPECTED_VERSION` | `install.sh` §9b, new | `0.6.0` (Phase 1 interim value: `0.3.9.dev1`, matching the SHA the pin currently resolves to) |
| `PIPX_LIST_SHORT` | bats env, new | Test-only; contents the shared `tests/helpers/pipx` stub prints verbatim for `list --short` |
| `OMLX_INSTALLED_MARKER` | `tests/test_install_idempotent.bats`, new | Test-only; file path the local stateful `pipx` stub reads/writes to represent the "currently installed omlx version" across two `install.sh` runs in the same test |

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| `pipx list --short` yields no `omlx` line | omlx absent | Fresh install at the pinned ref, no `--force` | `info` line with the pipx command |
| Installed version ≠ `OMLX_EXPECTED_VERSION` | Drifted, older, or pre-release install | `pipx install --force` at the pinned ref | `info` line naming both the installed and expected versions |
| Installed version = `OMLX_EXPECTED_VERSION` | Already at pin | No reinstall | `ok` line reporting the version |
| `pipx install` exits non-zero | Network or build failure | Existing installer failure semantics (`set -euo pipefail`) unchanged | Installer aborts |

## Implementation Phases

## Phase 1 — Enforce the pin

Make the installer act on the pin without changing which ref is pinned. This
phase is a defect fix and is independently valuable: it is what makes both
the bump in Phase 2 and any future rollback executable at all.

Implements requirements 1-6 and 8. Introduces `OMLX_EXPECTED_VERSION` set to
`0.3.9.dev1` (the version the currently pinned SHA resolves to, per Context
& Constraints), extends the shared `pipx` stub, and makes the local stub in
`tests/test_install_idempotent.bats` stateful so a mismatch → force-install
→ no-op sequence can be asserted end-to-end.

Phase complete when: `make check` and `make test` pass, all new bats cases
pass, and `make ci` is green on both legs.

### Test Scenarios

- GIVEN `pipx list --short` reports no `omlx` line, WHEN `install.sh` runs,
  THEN it shall call `pipx install` exactly once with `OMLX_GIT_REF` in the
  argument and without `--force`.
- GIVEN `pipx list --short` reports `omlx 0.3.9.dev1` (the Phase 1
  `OMLX_EXPECTED_VERSION`), WHEN `install.sh` runs, THEN it shall not call
  `pipx install` for omlx and shall print an `ok` line reporting `0.3.9.dev1`.
- GIVEN `pipx list --short` reports `omlx 0.3.8` (mismatched), WHEN
  `install.sh` runs, THEN it shall call `pipx install --force` with
  `OMLX_GIT_REF` in the argument and print an `info` line naming both
  `0.3.8` and `0.3.9.dev1`.
- GIVEN `PIPX_LIST_SHORT` is set on the shared stub, WHEN `pipx` is invoked
  with `list --short`, THEN it shall emit that value verbatim on stdout;
  GIVEN `PIPX_LIST_SHORT` is unset, THEN it shall emit nothing.
- GIVEN the local stateful stub seeded at `omlx 0.3.8`, WHEN `install.sh`
  runs once, THEN it asserts a `--force` call happened and the stub's
  marker file now reads `0.3.9.dev1`; WHEN `install.sh` runs a second time
  against that same marker state, THEN it asserts zero `pipx install`
  calls for omlx — proving the mismatch → force-install → no-op loop
  closes, not just that each branch fires in isolation.

## Phase 2 — Bump to v0.6.0

Change `OMLX_GIT_REF` to the v0.6.0 tag SHA, `OMLX_EXPECTED_VERSION` to
`0.6.0`, and add the documentation sentence. Implements requirements 7 and
9.

Phase complete when: `make check`, `make test` and `make ci` pass with the
Phase 1 bats cases re-parameterized (not rewritten) against the bumped
constants.

### Test Scenarios

- GIVEN `OMLX_GIT_REF = b16a1d1b4647dfeb19facc95aa9bfd0d78168269` and
  `OMLX_EXPECTED_VERSION = 0.6.0`, WHEN the Phase 1 bats cases
  (mismatch/match/not-installed/double-run) run against these new
  constants, THEN they shall pass unmodified in structure — only the
  seeded and expected version literals change.
- GIVEN `docs/setup.md`, WHEN inspected, THEN the "Changing pinned package
  versions" section shall contain one sentence stating that re-running the
  installer replaces a deviating omlx version with the pinned one.

### Manual Verification (not run by `make ci`)

These require a real machine, network access, and real model weights —
outside what a bats fixture can provide. Run by hand after the automated
Phase 2 gate is green:

- GIVEN a reference machine with omlx `0.3.9.dev1` installed, WHEN
  `./install.sh` runs, THEN `pipx list --short | grep omlx` shall
  afterwards report `0.6.0`.
- GIVEN omlx `0.6.0` and the `default` profile active, WHEN the backend is
  started and `GET /v1/models` is queried, THEN the response shall list
  `qwen3-coder-next`, `qwen3.6-35b`, `qwen3-embedding`, `qwen3-reranker`
  and `qwen3-vl-8b`.
- GIVEN omlx `0.6.0` is running, WHEN `POST /v1/rerank` and `POST
  /v1/embeddings` are called against `127.0.0.1:8000`, THEN both shall
  answer successfully — this is the OpenWebUI RAG chain, whose breakage
  would otherwise surface only at the next knowledge-base query.
- GIVEN a regression in any of the above, WHEN `OMLX_GIT_REF` and
  `OMLX_EXPECTED_VERSION` are reverted to the Phase 1 pair
  (`51907f08074742defec4375fb629e289801a8a9f` / `0.3.9.dev1`) and
  `./install.sh` is re-run, THEN omlx shall be downgraded to
  `0.3.9.dev1` — the rollback path Phase 1's enforcement makes possible.

## Decision Log

- **Version comparison over a sentinel file.** Storing the installed SHA in
  `~/.4lm/state/` was considered and rejected: it introduces persistent
  state for a value the package version already approximates, and stale
  state would be a second failure mode. Rejected alternative to that:
  reading the SHA back from pipx metadata — verified impossible, pipx
  truncates the ref.
- **Exact string equality, no pre-release normalization.** Comparing
  `0.6.0rc1` or `0.6.0.dev1` against `0.6.0` as a match (e.g. via a
  semver-aware comparator) was considered and rejected: it would require a
  parsing dependency for a single comparison, and any non-exact version is
  drift that should be corrected, not tolerated.
- **Stateful local stub over a second shared stub variant.** Making the
  `tests/test_install_idempotent.bats` local `pipx` stub track installed
  state via a marker file was chosen over adding install-state tracking to
  the shared `tests/helpers/pipx` stub, because only this file's
  double-run test needs it and the shared stub is used unchanged by many
  other bats files.
- **Two commits, not one.** The enforcement fix and the pin bump are
  separate commits (`fix(install): …` then `chore(deps): …`) so the bump
  is revertible on its own and the fix stays testable without the version
  change.
- **`4lm upgrade` stays out of it.** Teaching the upgrade channel to bump
  omlx was rejected — the pin is intentional friction, and automating it
  removes the review step that this SDD exists to restore.
- **Qwen3.8 profile is not part of this.** The profile work depends on a
  verified v0.6.0 backend; bundling it would make the bump unrevertible
  without also reverting a profile.

## Open Decisions

None.

## Out of Scope

- A Qwen3.8 profile entry (slot placement, memory math, `served_model_name`).
- Profile-schema support for omlx's official reasoning levels — whether
  `xhigh`/`medium`/`low` are set via `chat_template_kwargs`
  (`docs/profile-schema.md:40`) or a new field is to be determined against
  a running v0.6.0, not guessed in advance.
- Any change to `4lm outdated` / `4lm upgrade` coverage of omlx.
- Migration of existing profiles to new v0.6.0 features (MTP, NVFP4).
