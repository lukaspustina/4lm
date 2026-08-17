# SDD Implementation Report: qwen38-profile.md

**Date**: 2026-08-17
**Phases run**: 1, 2
**Overall status**: all-shipped
**SDD amendments suggested**: 3 (A1/A2 repaired in flight, A3 fixed after review)

| Phase | Title | Status | Commit |
|-------|-------|--------|--------|
| 1 | Swap the chat slot | shipped | `d9edf43` |
| 2 | Documentation and changelog | shipped | `292be90` |

Follow-up from the reviewer's findings: `dc36ea3`.

**Test file naming**: the per-criterion convention was not used, for the same
reason as the preceding SDD — the runner is `bats tests/` with a `test_*.bats`
convention. Criteria were grouped by subject into
`tests/test_chat_slot_qwen38.bats` (profile/template contents) and
`tests/test_docs_chat_slot.bats` (user-facing documents), plus an edit to the
existing `tests/test_profile_state_machine.bats`.

## Phase 1: Swap the chat slot

**Status**: shipped
**Commit**: `d9edf43`
**Test Baseline**: `328c459` (6 of 8 red)

### Acceptance Criteria

| # | Criterion | Tests | Status |
|---|-----------|-------|--------|
| 1 | default serves Qwen3.8-27B as vlm, pin/ttl kept | test_chat_slot_qwen38.bats | passing |
| 2 | outgoing model gone from default | test_chat_slot_qwen38.bats | passing |
| 3 | mlx-knowledge swapped, pin/ttl kept | test_chat_slot_qwen38.bats | passing |
| 4 | lean deliberately unchanged | test_chat_slot_qwen38.bats | passing (green at baseline — guards against an unwanted change) |
| 5 | both profiles validate, review date stamped | test_chat_slot_qwen38.bats | passing |
| 6 | headers state 15.27 GB and the reasoning caveat | test_chat_slot_qwen38.bats | passing |
| 7 | opencode template carries both aliases | test_chat_slot_qwen38.bats | passing |
| 8 | state-machine test no longer hard-codes a model name | test_chat_slot_qwen38.bats | passing (green at baseline — the decoupling was part of the baseline commit) |

### Reviewer Findings

**Blockers**: none. All 11 requirements verified individually against the diff.

**SDD Amendments**:
- A1 · Requirement 5 · affected_phase 1 · repaired_in_phase yes — Requirement 5
  ordered a *rename* of the `qwen3.6-35b` key in the opencode template and
  justified it with "lean no longer shares this served name", which
  contradicts Requirement 3: lean keeps that name
  (`config/profiles/lean.yaml:90`). Renaming would have stripped lean's only
  chat model from the seeded template. The implementation added the new key
  and kept the old one; the SDD and its test scenario were corrected to match.
- A2 · Requirement 8 · affected_phase 2 · repaired_in_phase yes — the README
  sentence "Both 80B-class models are MoE" became false once the chat model
  went dense. Requirement 8 listed only the numeric edits; the sentence was
  rewritten anyway and the requirement extended to cover it.
- A3 · affected_phase 2 · repaired_in_phase no at review time, **fixed in
  `dc36ea3`** — the active SDD `specs/sdd/webui-tools-and-mcp.md` described
  the shipped stack with the old chat model at lines 11 and 20. Not a runtime
  consumer, but the next agent reading it would have got a wrong picture.

**Deferred**: D1 — the live `4lm profile set default` + `curl /v1/models` leg
of Phase 1's gate. See Manual Test Plan.

**Nits**: 5, of which two were fixed (see below) and three left standing:
N4 (the `-DWQ` example path in `docs/setup.md` was corrected although the SDD
scoped it out — a beneficial over-delivery), N5 (a pre-existing README/profile
mismatch on the reranker's quant suffix, unrelated to this change), and the
observation that `mlx-knowledge`'s pin/ttl assertions are exact only by
accident.

### Test defect found and fixed after the baseline

The reviewer's N2 was a real defect in a test I wrote: the `model_type: vlm`
assertion scanned **forward** from the chat entry's `model_path`, and
`default.yaml`'s vision slot also declares `vlm` — so a regression of the chat
entry to `model_type: lm` would have passed. Fixed in `dc36ea3` by anchoring
on the chat entry and reading the four lines that follow it, and extended to
guard `pin: false` / `ttl: 600` (the reviewer's N3).

Verified by mutation rather than by inspection: with `model_type: vlm` changed
to `lm` in a copy of `default.yaml`, the new extraction returns
`model_type: lm`, failing the assertion. The old form would have returned the
vision slot's `vlm` and stayed green.

This is a post-baseline test edit. It strengthens the assertion; it does not
weaken it.

### Behavioral Verification

The runtime leg could not be completed without reinstalling over the operator's
running system (`~/.4lm/config/profiles/` holds copies, not symlinks, so a
repo edit does not reach the active profile without `./install.sh`). What was
verified instead, without touching the running backend:

- `render_omlx_settings config/profiles/default.yaml` → the rendered
  `models` keys are `qwen3-coder-next`, `qwen3.8-27b`, `qwen3-embedding`,
  `qwen3-reranker`, `qwen3-vl-8b`.
- `profile_model_entries config/profiles/default.yaml` → position 2 is
  `qwen3.8-27b|mlx-community/Qwen3.8-27B-4bit|permanent`, which is exactly
  what the decoupled state-machine test reads.

The `/v1/models` assertion itself remains open — see Manual Test Plan step 2.

## Phase 2: Documentation and changelog

**Status**: shipped
**Commit**: `292be90`
**Test Baseline**: `bea9a8c` (6 of 6 red)

### Acceptance Criteria

| # | Criterion | Tests | Status |
|---|-----------|-------|--------|
| 1 | README and index name the same chat model | test_docs_chat_slot.bats | passing |
| 2 | README and index agree on steady-state figures | test_docs_chat_slot.bats | passing |
| 3 | CLAUDE.md lineup matches | test_docs_chat_slot.bats | passing |
| 4 | README memory math states the measured size | test_docs_chat_slot.bats | passing |
| 5 | docs/setup.md names the current slot | test_docs_chat_slot.bats | passing |
| 6 | CHANGELOG records the swap as breaking | test_docs_chat_slot.bats | passing |

### Reviewer Findings

Covered in the Phase 1 section — the review ran over the whole
`328c459..HEAD` range rather than per phase.

## Gates

`make check` exit 0 and `make ci` exit 0 on both legs, before each production
commit and again after the review follow-up. `adlc auto verify-gate` exit 0
before the Phase 1 commit (its first run returned 1 because the attestation
had been written against a dirty tree — committed first, then re-attested,
which is what the gate's own message prescribes).

## Manual Test Plan

The runtime leg needs the operator's machine and a reinstall:

1. `./install.sh` — copies the changed profiles into `~/.4lm/config/profiles/`.
   Expected: no omlx reinstall (already at the pinned `0.6.0`).
2. `4lm profile set default`, then
   `curl -s localhost:8000/v1/models | jq -r '.data[].id'` — expected:
   `qwen3.8-27b` present, `qwen3.6-35b` absent. Note omlx 0.6.0 additionally
   lists HF-cache entries under their raw repo ids; that is cache discovery,
   not a profile leak.
3. Ask the chat model something substantial and watch the latency. With no
   `chat_template_kwargs` the `xhigh` default applies — measured here at over
   600 s for an SVG-generation prompt. If that is painful in daily use, the
   fix is client-side: send
   `"chat_template_kwargs": {"reasoning_effort": "low"}` per request
   (measured 114 s / 128 s for the same prompt).
4. `4lm profile set mlx-knowledge` and repeat step 2 for that profile.
5. Rollback if needed: `git revert d9edf43` and re-run `./install.sh`.
