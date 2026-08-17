# SDD Implementation Report: bump-omlx.md

**Date**: 2026-08-17
**Phases run**: 1, 2
**Overall status**: all-shipped
**SDD amendments suggested**: 3 (all applied to the SDD before Phase 2 ran)

| Phase | Title | Status | Commit |
|-------|-------|--------|--------|
| 1 | Enforce the pin | shipped | `87376f8` |
| 2 | Bump to v0.6.0 | shipped | `1103017` |

**Test file naming**: the prescribed per-criterion convention
(`sdd_<stem>_p<N>_c<i>_*`) was not used. The runner is `bats tests/`, whose
suite convention is `test_*.bats`, and the SDD names its target files
explicitly — five of six Phase 1 criteria need the same file-local `pipx`
stub, so they cannot live in separate files. Criteria were gathered into
`tests/test_install_idempotent.bats` (stub-dependent cases),
`tests/test_helpers_pipx.bats` (shared-stub case, new file) and
`tests/test_phase4_ci_docs.bats` (the static docs check, matching that file's
existing purpose).

## Phase 1: Enforce the pin

**Status**: shipped
**Commit**: `87376f8`
**Test Baseline**: `b6a83c0`

### Acceptance Criteria

| # | Criterion | Tests | Status |
|---|-----------|-------|--------|
| 1 | omlx absent → install, no `--force` | test_install_idempotent.bats | passing (already green at baseline — branch unchanged by this SDD) |
| 2 | version matches → no reinstall, `ok` line | test_install_idempotent.bats | passing (already green at baseline) |
| 3 | version mismatches → `--force` + `info` naming both | test_install_idempotent.bats | passing (red at baseline) |
| 4 | shared stub honours `PIPX_LIST_SHORT` | test_helpers_pipx.bats | passing (red at baseline) |
| 5 | mismatch → force-install → no-op loop closes | test_install_idempotent.bats | passing (red at baseline) |
| 6 | pre-existing "runs twice" test unaffected | test_install_idempotent.bats | passing |

### Reviewer Findings

**Blockers**: none
**SDD Amendments Needed** (advisory, all applied to the SDD before Phase 2):
- A1 · requirement 2 · affected_phase 1 — the quoted extraction command is
  unimplementable as written: under `set -euo pipefail` a non-matching `grep`
  exits 1 and aborts the installer on exactly the "absent" case the branch
  exists for. Implementation appends `|| true`, the empty-default form of the
  repo's existing `|| echo <default>` idiom (`install.sh:203`, `:409`). SDD
  amended to require it.
- A2 · requirement 10 · affected_phase 1 — no encoding was specified for
  "omlx absent" in the local stub. An existing-but-empty marker file was
  chosen (the unset/missing case is already taken by the fallback literal).
  SDD amended.
- A3 · affected_phase 2 — Phase 2's re-parameterization list was incomplete.
  Amended before Phase 2 ran, so the phase was not built from a wrong spec.

**Deferred**: none
**Nits**: 4, all accepted as-is (one weak-but-paired negative assertion, the
uncommitted-SDD observation resolved by this phase's commit, `.adlc/` left
untracked deliberately, a grown comment block in §9b).

### Behavioral Verification

All three branches executed against a real `install.sh` run with a stubbed
`pipx` and an isolated `$HOME`:

- mismatch → `→ omlx 0.3.8 != pinned 0.3.9.dev1 — reinstalling at 51907f08…`
  followed by `install --python python3.12 --force git+…@51907f08…`
- match → `✓ omlx already installed (0.3.9.dev1)`, no install call
- absent → `install --python python3.12 git+…@51907f08…`, no `--force`

### Notes

The Phase 1 test-baseline commit `b6a83c0` also carried
`specs/sdd/bump-omlx.md`, which was still staged from the refine step. The
file belongs in the repo; only its arrival one commit early was unintended.

## Phase 2: Bump to v0.6.0

**Status**: shipped
**Commit**: `1103017`
**Test Baseline**: `9222df8` (4 tests red)

### Acceptance Criteria

| # | Criterion | Tests | Status |
|---|-----------|-------|--------|
| 1 | Phase 1 cases pass against the bumped constants | test_install_idempotent.bats | passing |
| 2 | "runs twice" takes the already-installed branch on the new fallback | test_install_idempotent.bats | passing |
| 3 | docs/setup.md carries the pin-enforcement sentence | test_phase4_ci_docs.bats | passing |

### Reviewer Findings

**Blockers**: none
**SDD Amendments Needed**: none. The Manual Verification rollback path was
checked specifically and still holds — the mismatch branch is
direction-agnostic, so reverting the two constants downgrades just as it
upgrades.
**Deferred**: none
**Nits**: 3. Nits 1 and 2 (the docs assertion only checked for the substring
`omlx`, inside a fragile `-A8` window) were **fixed after the review**: the
test now extracts the section heading-to-heading with `awk` and asserts the
requirement's actual sentence. This is a post-baseline test edit, recorded
here as required — it strengthens the assertion, it does not weaken it. Nit 3
(two substring assertions satisfiable independently) left as-is; the adjacent
install-count assertion carries the real weight.

### Behavioral Verification

`install.sh` run with `pipx` reporting `omlx 0.3.9.dev1` — the version
actually installed on this machine:

```
→ omlx 0.3.9.dev1 != pinned 0.6.0 — reinstalling at b16a1d1b…
PIPX-INSTALL: install --python python3.12 --force git+…omlx.git@b16a1d1b…
```

That is the defect this SDD exists to fix: before Phase 1, this machine's
installer would have skipped omlx entirely.

## Gates

`make check` exit 0 (206 bats + 45 pytest), `make ci` exit 0 on both legs
(`ci-default`, `ci-backend-only`), `adlc auto verify-gate` exit 0 before each
production commit.

## Manual Test Plan

Not run here — these need real network access and real model weights. Run on
the reference machine after pulling:

1. `./install.sh` — expected: a `--force` reinstall of omlx from `0.3.9.dev1`
   to `0.6.0`; confirm with `pipx list --short | grep omlx`.
2. `4lm start && 4lm doctor` — expected: prereqs and smoke test pass.
3. `4lm profile set default`, then `curl -s localhost:8000/v1/models | jq -r
   '.data[].id'` — expected: `qwen3-coder-next`, `qwen3.6-35b`,
   `qwen3-embedding`, `qwen3-reranker`, `qwen3-vl-8b`.
4. `POST /v1/rerank` and `POST /v1/embeddings` against `127.0.0.1:8000` —
   expected: both answer successfully. This is the OpenWebUI RAG chain; a
   break here would otherwise surface only at the next knowledge-base query.
5. On any regression: revert `OMLX_GIT_REF` / `OMLX_EXPECTED_VERSION` to
   `51907f08074742defec4375fb629e289801a8a9f` / `0.3.9.dev1` and re-run
   `./install.sh` — expected: omlx downgraded. Phase 1 is what makes this
   rollback execute at all.
