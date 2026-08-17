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
- `install.sh:291` (§9a, the `requirements.txt` loop) already contains a
  one-line pin-comparison idiom:
  `if pipx list --short 2>/dev/null | grep -qE "^${pkg_listed} ${ver}( |$)"`.
  That idiom is not reused as-is for §9b — see Decision Log.
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
   package version alongside the pinned git ref. Phase 1 sets it to the
   interim value `0.3.9.dev1` (the version the currently pinned SHA
   resolves to); Phase 2 changes it to `0.6.0` per Requirement 7.
2. `install.sh` shall extract the installed omlx version with
   `pipx list --short 2>/dev/null | grep "^omlx " | awk '{print $2}'` —
   the existing extraction pair at `install.sh:304-305`, retained
   unchanged, with `2>/dev/null` added to suppress a failing `pipx list`
   (see Error Handling). Command substitution (`$(...)`) strips the
   trailing newline; `awk`'s field split leaves no other whitespace, so no
   further trimming step is needed. Empty output (no `omlx` line, or
   `pipx list` itself failing) is treated unambiguously as "not
   installed" — never as a parse error. If `pipx list --short` ever emits
   more than one `^omlx ` line (corrupted venv, manual edits), this is not
   a supported state; behaviour is undefined and no deduplication (e.g.
   `head -1`) is added, matching current code's lack of handling. The
   substitution shall end in `|| true`: under `set -euo pipefail` a
   non-matching `grep` exits 1 and, with `pipefail`, aborts the installer
   on the very case this branch exists to handle. This is the empty-default
   form of the repo's existing `|| echo <default>` idiom
   (`install.sh:203`, `install.sh:409`) and must not be removed.
3. `install.sh` shall compare the installed version against
   `OMLX_EXPECTED_VERSION` using exact string equality (`[[ "$installed"
   == "$OMLX_EXPECTED_VERSION" ]]`). No pre-release/dev suffix
   normalization is performed: `0.6.0rc1`, `0.6.0.dev1`, etc. always
   count as a mismatch against `0.6.0`.
4. When the installed version equals `OMLX_EXPECTED_VERSION`, `install.sh`
   shall not reinstall omlx and shall print an `ok` line reporting the
   installed version, extending the existing `ok "omlx already installed
   (...)"` pattern at `install.sh:305`.
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
10. The local `pipx` stub in `tests/test_install_idempotent.bats`'s
    `setup()` shall, for `list`, report omlx's version from
    `OMLX_INSTALLED_MARKER` when that env var is set and the file exists,
    and otherwise fall back to a hardcoded literal (`0.3.8` in Phase 1,
    updated to `0.6.0` in Phase 2 — see Decision Log). For `install`
    invocations whose arguments contain `omlx.git@`, the stub shall append
    the full invocation (`"$*"`) to `${OMLX_INSTALL_LOG:-/dev/null}`, and,
    when both `OMLX_INSTALLED_MARKER` and `OMLX_INSTALL_RESULT_VERSION`
    are set, shall overwrite the marker file with
    `${OMLX_INSTALL_RESULT_VERSION}` to simulate a successful install. The
    pre-existing `open-webui 0.6.43` line in the stub's `list` case is
    unchanged. A marker file that exists but is **empty** means omlx is not
    installed: the stub emits no `omlx` line at all. This is the only
    unambiguous encoding left, since the unset/missing-marker case is
    already claimed by the hardcoded fallback.
11. A new bats file `tests/test_helpers_pipx.bats` shall assert
    Requirement 8 directly against the unmodified shared
    `tests/helpers/pipx` stub (not the local override in
    `tests/test_install_idempotent.bats`).

## File & Module Structure

| Path | Change |
|---|---|
| `install.sh` | §9b (`install.sh:299-309`): add `readonly OMLX_EXPECTED_VERSION="0.6.0"` above `readonly OMLX_GIT_REF="b16a1d1b4647dfeb19facc95aa9bfd0d78168269"`; replace the presence check (`grep -q "^omlx "`) with the version-comparison branch (not-installed / match / mismatch) per Requirements 2-6 |
| `tests/helpers/pipx` | Add a `list --short)` case emitting `${PIPX_LIST_SHORT:-}` when non-empty; keep the existing `echo "$*" >> "${LOG}"; exit 0` behaviour for all other invocations |
| `tests/test_helpers_pipx.bats` | New file. Loads `helpers/setup` only (no local stub override) and asserts Requirement 8/11: `PIPX_LIST_SHORT` set → shared stub's `list --short` stdout matches verbatim; `PIPX_LIST_SHORT` unset → stdout empty |
| `tests/test_install_idempotent.bats` | Extend the local `pipx` stub (`STUB_BIN/pipx`, lines 23-32) per Requirement 10: marker-file read for `list`, invocation logging + marker write for `install`. Add the Phase 1 version-comparison bats cases (mismatch/match/not-installed/double-run), the explicit "pre-existing double-run test still passes with no marker seeded" case, and the Phase 2 re-parameterization (bumped literals, including the stub's fallback default) |
| `docs/setup.md` | One sentence appended to "Changing pinned package versions" (`docs/setup.md:407-412`) |

`CLAUDE.md` is deliberately untouched: it does not carry the pin, and the
omlx path-probe note stays valid.

## Configuration

| Name | Location | Value |
|---|---|---|
| `OMLX_GIT_REF` | `install.sh` §9b | `b16a1d1b4647dfeb19facc95aa9bfd0d78168269` (was `51907f08074742defec4375fb629e289801a8a9f`) |
| `OMLX_EXPECTED_VERSION` | `install.sh` §9b, new | `0.6.0` (Phase 1 interim value: `0.3.9.dev1`, matching the SHA the pin currently resolves to) |
| `PIPX_LIST_SHORT` | bats env, new | Test-only; contents the shared `tests/helpers/pipx` stub prints verbatim for `list --short` (Requirement 8, tested by `tests/test_helpers_pipx.bats`) |
| `OMLX_INSTALLED_MARKER` | `tests/test_install_idempotent.bats`, new | Test-only; file path the local stub reads for the "currently installed omlx version" and writes back after a simulated install. Unset in the pre-existing "runs twice" test — falls back to the hardcoded default (Requirement 10) |
| `OMLX_INSTALL_LOG` | `tests/test_install_idempotent.bats`, new | Test-only; file path the local stub appends each omlx `install` invocation's full argv to, so `--force` presence and call count are assertable |
| `OMLX_INSTALL_RESULT_VERSION` | `tests/test_install_idempotent.bats`, new | Test-only; version string the local stub writes to `OMLX_INSTALLED_MARKER` after an omlx `install` call, simulating a successful install |

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| `pipx list --short` yields no `omlx` line | omlx absent | Fresh install at the pinned ref, no `--force` | `info` line with the pipx command |
| `pipx list --short` exits non-zero | pipx missing/broken | `2>/dev/null` suppresses the error; empty extraction is treated identically to "absent" | Same as the absent case: fresh install, no `--force` |
| `pipx list --short` emits more than one `^omlx ` line | Corrupted venv or manual edit | Undefined; not deduplicated, matching current code | Not specified — unsupported state |
| Installed version ≠ `OMLX_EXPECTED_VERSION` | Drifted, older, or pre-release install | `pipx install --force` at the pinned ref | `info` line naming both the installed and expected versions |
| Installed version = `OMLX_EXPECTED_VERSION` | Already at pin | No reinstall | `ok` line reporting the version |
| `pipx install` exits non-zero | Network or build failure | Existing installer failure semantics (`set -euo pipefail`) unchanged | Installer aborts |

## Implementation Phases

## Phase 1 — Enforce the pin

Make the installer act on the pin without changing which ref is pinned. This
phase is a defect fix and is independently valuable: it is what makes both
the bump in Phase 2 and any future rollback executable at all.

Implements requirements 1-6, 8, 10 and 11. Introduces `OMLX_EXPECTED_VERSION`
set to `0.3.9.dev1` (the version the currently pinned SHA resolves to, per
Context & Constraints), extends the shared `pipx` stub, adds
`tests/test_helpers_pipx.bats` to exercise it directly, and makes the local
stub in `tests/test_install_idempotent.bats` marker-aware (with a hardcoded
`0.3.8` fallback when no marker is seeded) so a mismatch → force-install →
no-op sequence can be asserted end-to-end without disturbing the pre-existing
"runs twice" test, whose `setup()` never seeds `OMLX_INSTALLED_MARKER`.

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
  with `list --short` (via `tests/test_helpers_pipx.bats`), THEN it shall
  emit that value verbatim on stdout; GIVEN `PIPX_LIST_SHORT` is unset,
  THEN it shall emit nothing.
- GIVEN the local stub's `OMLX_INSTALLED_MARKER` seeded with `0.3.8` and
  `OMLX_INSTALL_RESULT_VERSION="0.3.9.dev1"`, WHEN `install.sh` runs once,
  THEN `OMLX_INSTALL_LOG` shall show exactly one omlx `install --force`
  call and the marker file shall now read `0.3.9.dev1`; WHEN `install.sh`
  runs a second time against that same marker state, THEN `OMLX_INSTALL_LOG`
  shall show zero further omlx `install` calls — proving the mismatch →
  force-install → no-op loop closes, not just that each branch fires in
  isolation.
- GIVEN the pre-existing "runs twice and produces identical state" test's
  `setup()`, which does not seed `OMLX_INSTALLED_MARKER`, WHEN `install.sh`
  runs twice, THEN both runs shall exit 0, the `~/.4lm` snapshot and
  `~/.local/bin/4lm` symlink target shall be identical across runs, and the
  stub shall not error on the unset-marker path (it falls back to the
  hardcoded `0.3.8` literal each time, per Requirement 10).

## Phase 2 — Bump to v0.6.0

Change `OMLX_GIT_REF` to the v0.6.0 tag SHA, `OMLX_EXPECTED_VERSION` to
`0.6.0`, add the documentation sentence, and re-parameterize the Phase 1 bats
literals — including the local stub's hardcoded fallback (`0.3.8` →
`0.6.0`) used by the pre-existing "runs twice" test, not only the new
Phase 1 cases. Implements requirements 7 and 9.

The SHA needs no test edit: the Phase 1 tests read it out of `install.sh`
(`grep -E '^readonly OMLX_GIT_REF=' | cut -d'"' -f2`). The version literals
do, and they occur in five roles — marker seeds,
`OMLX_INSTALL_RESULT_VERSION`, output assertions, and the stub's fallback
in `tests/test_install_idempotent.bats`, plus the seeded
`omlx 0.6.0` sample in `tests/test_helpers_pipx.bats:11` (which after the
bump coincidentally equals the pinned version; it is a stub-output fixture
and carries no assertion about the pin).

Phase complete when: `make check`, `make test` and `make ci` pass with the
Phase 1 bats cases re-parameterized (not rewritten) against the bumped
constants.

### Test Scenarios

- GIVEN `OMLX_GIT_REF = b16a1d1b4647dfeb19facc95aa9bfd0d78168269` and
  `OMLX_EXPECTED_VERSION = 0.6.0`, WHEN the Phase 1 bats cases
  (mismatch/match/not-installed/double-run) run against these new
  constants, THEN they shall pass unmodified in structure — only the
  seeded and expected version literals change.
- GIVEN the local stub's hardcoded fallback literal updated from `0.3.8` to
  `0.6.0`, WHEN the pre-existing "runs twice" test runs (still without
  seeding `OMLX_INSTALLED_MARKER`), THEN both runs shall take the
  already-installed (`ok`, no reinstall) branch and shall still produce an
  identical `~/.4lm` snapshot and symlink target.
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
- **§9a's `grep -qE "^${pkg} ${ver}( |$)"` idiom is not reused for §9b.**
  It collapses "absent" and "wrong version" into a single boolean, always
  taking the same branch — but Requirements 5 and 6 need those two cases
  distinguished (`--force` vs. no `--force`), so §9b needs its own
  extract-then-compare shape instead of a single grep boolean.
- **Marker file with a hardcoded fallback, not an always-stateful stub.**
  The local `tests/test_install_idempotent.bats` stub falls back to a
  hardcoded literal (`0.3.8` in Phase 1, `0.6.0` in Phase 2) when
  `OMLX_INSTALLED_MARKER` is unset, rather than always requiring a marker
  file. This keeps the pre-existing "runs twice" test's `setup()`
  unmodified while giving the new Phase 1 cases an explicit, logged,
  stateful path via the marker + `OMLX_INSTALL_LOG` +
  `OMLX_INSTALL_RESULT_VERSION` env vars. Chosen over adding install-state
  tracking to the shared `tests/helpers/pipx` stub, because only this
  file's tests need it and the shared stub is used unchanged by many other
  bats files.
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
