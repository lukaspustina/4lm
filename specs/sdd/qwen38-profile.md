# SDD: Swap the chat slot to Qwen3.8-27B

Status: Ready for Implementation
Original: specs/sdd/qwen38-profile.md
Refined: 2026-08-17

## Overview

Qwen3.8-27B is a dense 27B vision-language model with a 262k context window,
released under Apache 2.0. It replaces `Qwen3.6-35B-A3B` in the chat/reasoning
slot of the `default` and `mlx-knowledge` profiles. `lean` keeps the MoE
deliberately — a dense 27B is the opposite of lean.

## Context & Constraints

- Stack: Bash + YAML profiles, bats test suite. `set -euo pipefail`,
  shellcheck-clean, shfmt-formatted.
- Requires omlx v0.6.0, shipped by `specs/done/sdd/bump-omlx-2026-08-17.md`.
  Earlier omlx builds cannot load this checkpoint.
- **Measured on this machine (2026-08-17), not estimated.** A throwaway omlx
  instance on port 8001 with an isolated `HOME` and a single-model dir was used
  for every number below; the repo and the running backend were untouched.
- omlx discovers the checkpoint as `type: vlm, engine: vlm` and reports
  `actual: 15.27GB`. The profile entry therefore needs `model_type: vlm` —
  the outgoing MoE is `lm`.
- The outgoing `Qwen3.6-35B-A3B-4bit` is documented as `~18 GB` in both
  profile headers. `README.md:157` states `~12 GB` for the same model; that
  line contradicts the headers and is corrected to match.
- **Speed is a real trade.** The outgoing model is an MoE with 3B active; the
  incoming one is dense with 27B active. Measured generation: ~27 tok/s
  (3452 tokens in 128 s).
- **The `xhigh` reasoning default is real and cannot be fixed here.** The
  model's own `chat_template.jinja` carries
  `reasoning_effort|default('xhigh')`. An unconfigured SVG-generation prompt
  ran past 600 s without finishing; the same prompt with
  `chat_template_kwargs: {reasoning_effort: "low"}` in the **request body**
  finished in 114 s and 128 s across two runs. The same key in
  `~/.omlx/model_settings.json` (correct `{"version": 1, "models": {…}}`
  format, confirmed by omlx logging `Loaded settings for 1 models`) did **not**
  take effect: 336 s and 12292 reasoning characters, against 128 s and 2275 on
  the identical server with a body override. Reasoning level is therefore a
  client-side concern, out of scope here.
- omlx logs `config declares mtp heads but checkpoint ships no mtp.* weights`
  for this checkpoint — no speculative-decoding gain is available without
  wiring the separate MTP drafter checkpoint (out of scope, see below).
- The `served_model_name` contract in `CLAUDE.md` covers embedders
  (`qwen3-embedding`), rerankers (`qwen3-reranker`) and vision
  (`qwen3-vl-8b`). The chat slot is **not** part of it, so no knowledge base
  needs reindexing.
- The chat slot's name is version-bearing (`qwen3.6-35b` → `qwen3.8-27b`), so
  every consumer that hard-codes it breaks. `config/opencode.example.jsonc` is
  only seeded into `~/.config/opencode/` at install time; an existing user
  config keeps the stale alias and must be edited by hand.
- `config/profiles/*.yaml` has no structural slot-role field — `model_path`,
  `served_model_name`, `model_type`, `pin`, `ttl` only (confirmed against
  `default.yaml` and `docs/profile-schema.md:35-40`). Slot identity today is
  positional: `models[0]` = coder, `models[1]` = chat, `models[2]` = embed,
  `models[3]` = rerank, `models[4]` = vision (see `default.yaml:83-112`).
  Extraction of "the chat entry" therefore has to use that position — see
  Requirement 6.
- `docs/setup.md:263` carries an example `model_path:
  mlx-community/Qwen3.6-35B-A3B-4bit-DWQ` with a `-DWQ` suffix that does not
  match the real profile's `Qwen3.6-35B-A3B-4bit` (no DWQ) — a pre-existing
  mismatch that predates this SDD. It stays as is; only the
  `served_model_name` on the following line is in scope (Requirement 9).

## Requirements

1. `config/profiles/default.yaml` shall serve
   `mlx-community/Qwen3.8-27B-4bit` as `qwen3.8-27b` with `model_type: vlm`
   in place of the `Qwen3.6-35B-A3B-4bit` / `qwen3.6-35b` entry at
   `models[1]` (lines 90-94), keeping the entry's `pin: false` and
   `ttl: 600` unchanged.
2. `config/profiles/mlx-knowledge.yaml` shall carry the same replacement at
   `models[0]` (lines 66-70), keeping its own `pin: true` and `ttl: null`
   unchanged.
3. `config/profiles/lean.yaml` shall keep `Qwen3.6-35B-A3B-4bit` unchanged.
4. Both changed profile headers (`default.yaml:1-79`,
   `mlx-knowledge.yaml:1-61`) shall be updated as follows:
   - **Memory budget block.** `default.yaml:11-13`: `Resident if all loaded`
     ~75 GB → ~72 GB, `Steady state` ~65 GB → ~62 GB, `KV-cache headroom`
     ~35 GB → ~38 GB (all three shift by the same -2.73/+2.73 GB delta as
     the Memory Math table below). `mlx-knowledge.yaml:12-14`: `Resident if
     all loaded` ~24 GB → ~21 GB, `Steady state` ~23 GB → ~20 GB,
     `KV-cache headroom` ~85 GB → ~88 GB.
   - **"Why: chat" bullet**, rewritten in place (`default.yaml:27-32`,
     `mlx-knowledge.yaml:19-23`) to state: the model, `15.27 GB` resident,
     dense 27B (not MoE), the measured ~27 tok/s (3452 tokens in 128 s) as
     the throughput trade against the outgoing MoE, the shared Qwen3 family
     with the coder (coherent tool-call syntax), the 262K native context,
     and the `xhigh` reasoning-effort default with the request-body
     `chat_template_kwargs: {reasoning_effort: "low"}` workaround (per
     Context & Constraints) since `model_settings.json` does not apply it.
     For `mlx-knowledge.yaml` specifically, lead with the 262K-context
     rationale — it is this profile's reason to exist.
   - **"Assumptions to validate" bullet naming the outgoing model** is
     updated to name the incoming model, preserving the rest of its wording:
     `default.yaml:72-74` ("Qwen3.6-35B-A3B German fluency…") becomes
     "Qwen3.8-27B German fluency is acceptable. If German polish becomes a
     daily pain point, consider a Gemma 3 27B hot-swap profile (NOT a
     regression to Gemma 4 — that's the bug we fixed)."; `mlx-knowledge.yaml:
     52-53` ("Qwen3.6-35B-A3B remains the right pick — re-evaluate if a
     stronger Qwen3.7 / Qwen4 MoE chat model lands with comparable
     footprint.") becomes "Qwen3.8-27B remains the right pick — re-evaluate
     if a stronger dense reasoning/chat model lands with comparable
     footprint." (drop "MoE": the incoming model is dense).
   - `Last reviewed:` line (`default.yaml:79`, `mlx-knowledge.yaml:61`)
     shall read `2026-08-17`.
   - The historical `Changed 2026-05-15:` note in `mlx-knowledge.yaml:56-59`
     is untouched — it documents a past change, not the current state.
5. `config/opencode.example.jsonc` shall rename the `qwen3.6-35b` entry
   (line 27) to `qwen3.8-27b` with display name `"Qwen3.8-27B (plan/chat)"`,
   and update its preceding comment (line 26, `// default / lean /
   mlx-knowledge profiles`) to `// default / mlx-knowledge profiles` — `lean`
   no longer shares this served name after Requirement 3.
6. `tests/test_profile_state_machine.bats`'s `"make models: dispatches hf
   download for all omlx profiles"` test (lines 566-575) shall extract the
   chat entry's `model_path` from `config/profiles/default.yaml` at run time
   by sourcing `bin/4lm` and calling `profile_model_entries()` (position 1 =
   chat, per Context & Constraints), e.g.:
   ```bash
   source "${REPO_ROOT}/bin/4lm"
   expected_path="$(profile_model_entries "${REPO_ROOT}/config/profiles/default.yaml" \
     | sed -n '2p' | cut -d'|' -f2)"
   ```
   and assert `HF_LOG` contains that extracted value, instead of the literal
   string `mlx-community/Qwen3.6-35B-A3B-4bit`. The stale comment referencing
   the outgoing model by name is removed. The plain-awk equivalent (`awk
   '/^[[:space:]]*-[[:space:]]*model_path:/{print $NF}'
   "${REPO_ROOT}/config/profiles/default.yaml" | sed -n '2p'`) is an
   acceptable alternative.
7. The profile tables in `README.md:149-155` and `index.md:70-76` shall show
   `Qwen3.8-27B` in the `default` and `mlx-knowledge` rows' Chat column, with
   Steady `~62 GB` (`default`) and `~20 GB` (`mlx-knowledge`), leaving `lean`
   and `max-100gb` rows unchanged.
8. `README.md:156-161`'s "Memory math for `default`" paragraph shall be
   recomputed for the swap: the chat term changes from `Qwen3.6-35B-A3B
   (~12 GB)` to `Qwen3.8-27B (~15.27 GB)`, the componentwise total from
   `65 GB` to `68 GB` (42 + 15.27 + 5 + 0.4 + 5 ≈ 67.67, rounded to 68), and
   the trailing "~33 GB of the wired-memory budget" sentence on line 161 to
   "~28 GB" (96 GB wired budget − 68 GB ≈ 28 GB). This resolves the
   pre-existing `~12`-vs-`~18` GB contradiction between this paragraph and the
   profile headers (Context & Constraints) as part of the same edit.
9. `docs/setup.md:141` shall name `qwen3.8-27b` instead of `qwen3.6-35b`.
   `docs/setup.md:264`'s `served_model_name: qwen3.6-35b` line shall become
   `served_model_name: qwen3.8-27b`; the `model_path:` line above it
   (line 263, pre-existing `-DWQ` mismatch) is unchanged — out of scope per
   Context & Constraints.
10. `CLAUDE.md`'s profile lineup table (`CLAUDE.md:122-127`) shall read
    `~62 GB` for `default` and `~20 GB` for `mlx-knowledge`.
11. `CHANGELOG.md`'s `[Unreleased]` section (`CHANGELOG.md:8-17`) shall gain
    a `### Changed` line recording that the `default` and `mlx-knowledge`
    chat slot moves from `qwen3.6-35b` to `qwen3.8-27b`, flagged as breaking
    for any consumer (e.g. an already-seeded `~/.config/opencode/
    opencode.jsonc`) hard-coding the old served name.

## File & Module Structure

| Path | Change |
|---|---|
| `config/profiles/default.yaml` | chat-slot entry (lines 90-94) + header (memory budget, "Why: chat" bullet, assumptions bullet, `Last reviewed:`) |
| `config/profiles/mlx-knowledge.yaml` | chat-slot entry (lines 66-70) + header (same set) |
| `config/opencode.example.jsonc` | line 26-27: comment + model alias `qwen3.6-35b` → `qwen3.8-27b` |
| `tests/test_profile_state_machine.bats` | lines 566-575: `profile_model_entries()`-based extraction instead of the literal model string |
| `README.md` | table rows (149-155) + memory-math paragraph (156-161) |
| `index.md` | table rows (70-76), same table, GitHub Pages copy |
| `docs/setup.md` | line 141 + line 264 served-model-name references |
| `CLAUDE.md` | profile lineup steady-state figures (122-127) |
| `CHANGELOG.md` | `[Unreleased]` entry |

`config/profiles/max-100gb.yaml` carries only a comment mentioning
Qwen3.6-35B as a comparison point; it stays as is.

## Memory Math

| Profile | Steady before | Chat slot | Steady after |
|---|---|---|---|
| `default` | ~65 GB | ~18 GB → 15.27 GB | ~62 GB |
| `mlx-knowledge` | ~23 GB | ~18 GB → 15.27 GB | ~20 GB |

Both shrink. Neither approaches the 110 GB usable budget. This table is the
source of truth for the "Steady state" and Memory Math figures used in
Requirements 4, 7, and 10 (`README.md`'s own componentwise paragraph in
Requirement 8 uses a different, pre-existing accounting method — summing
individual model sizes rather than taking the profile header's stated
steady-state figure — and does not reconcile to this table's ~62 GB; see
Decision Log).

## Phase 1 — Swap the chat slot

Replace the model in both profiles, update the headers, fix the opencode
alias, and make the state-machine test derive its expectation instead of
hard-coding a model name. Implements requirements 1-6.

Phase complete when: `make check` and `make test` pass, `make ci` is green on
both legs, and `4lm profile set default` followed by `curl /v1/models` lists
`qwen3.8-27b` and no longer lists `qwen3.6-35b`.

### Test Scenarios

- GIVEN `config/profiles/default.yaml` WHEN read THEN it does not contain
  the string `Qwen3.6-35B-A3B-4bit` and contains a `models[]` entry with
  `model_path: mlx-community/Qwen3.8-27B-4bit`, `served_model_name:
  qwen3.8-27b`, `model_type: vlm`.
- GIVEN `config/profiles/default.yaml` WHEN run through `validate_profile`
  (in `bin/4lm`) THEN exit status is 0.
- GIVEN `config/profiles/mlx-knowledge.yaml` WHEN read THEN it contains the
  same `Qwen3.8-27B-4bit` / `qwen3.8-27b` / `model_type: vlm` entry, with its
  pre-existing `pin: true` / `ttl: null` unchanged (diff limited to model
  fields).
- GIVEN `config/profiles/lean.yaml` WHEN read THEN it still contains
  `mlx-community/Qwen3.6-35B-A3B-4bit` verbatim (no diff on this profile).
- GIVEN `config/opencode.example.jsonc` WHEN parsed as JSONC THEN it defines
  a model key `qwen3.8-27b` and no key `qwen3.6-35b`.
- GIVEN `tests/test_profile_state_machine.bats` WHEN grepped for the literal
  strings `Qwen3.6-35B-A3B-4bit` and `Qwen3.8-27B-4bit` THEN neither appears
  in the test file itself (only in fixture-independent extraction code).
- GIVEN `make -C <repo> models` run against the real `default.yaml` WHEN
  `HF_LOG` is inspected THEN it contains the exact `model_path` string
  extracted via `profile_model_entries()` for `models[1]` of
  `config/profiles/default.yaml` (currently `mlx-community/Qwen3.8-27B-4bit`).
- GIVEN the full suite WHEN `make check && make test` run THEN both exit 0,
  and `make ci` is green on `ci-default` and `ci-backend-only`.
- GIVEN a running backend WHEN `4lm profile set default` then `curl
  /v1/models` THEN the response lists `qwen3.8-27b` and does not list
  `qwen3.6-35b`.

## Phase 2 — Documentation and changelog

Bring the user-facing documents in line and record the breaking change.
Implements requirements 7-11.

Phase complete when: `make check` passes, and the profile tables in
`README.md` and `index.md` agree with `CLAUDE.md` and with the profile
headers on every figure they share (the `default` steady-state figure is
~62 GB in the table, per Requirement 7/10 and the Memory Math table; the
componentwise memory-math paragraph in `README.md` is exempted per
Requirement 8's note and Decision Log — it uses a different, pre-existing
accounting method).

### Test Scenarios

- GIVEN `README.md` and `index.md` profile tables WHEN their `default` and
  `mlx-knowledge` rows are compared THEN both name the same chat model
  string (`Qwen3.8-27B`) and the same steady-state GB figure as each other
  (`~62 GB` / `~20 GB`), and both match `CLAUDE.md`'s profile lineup table
  for those two rows.
- GIVEN `README.md` WHEN grepped for the outgoing model's size prose THEN it
  reads `Qwen3.8-27B (~15.27 GB)` and no longer contains `Qwen3.6-35B-A3B
  (~12 GB)`.
- GIVEN `docs/setup.md` WHEN grepped for `qwen3.6-35b` THEN zero matches;
  grepped for `qwen3.8-27b` THEN at least one match.
- GIVEN `CHANGELOG.md`'s `[Unreleased]` section WHEN read THEN it contains a
  line stating `qwen3.6-35b` is replaced by `qwen3.8-27b` and flags it as
  breaking for hard-coded consumers.
- GIVEN the repo WHEN `make check` runs THEN it exits 0 (no test re-run
  required — Phase 2 has no bats scenarios of its own).

## Decision Log

- **Chat slot, not vision, not an added slot.** Qwen3.8-27B is a VLM and
  overlaps both the chat slot and `qwen3-vl-8b`. Replacing both was rejected:
  the 8B vision model exists for fast image work, and routing every image
  through a dense 27B would make it slow. Adding it as a third slot was
  rejected as well — it costs memory and clutters the OpenWebUI model list
  for a comparison a profile switch already provides.
- **`default` and `mlx-knowledge`, not `lean`.** `lean` exists to be small
  and quick, and its chat slot is its only general model; a dense 27B removes
  the property the profile is named for. `mlx-knowledge` is included because
  the 262k context window is worth most where long documents are.
- **4bit, not 8bit or mxfp4.** Dense models are memory-bandwidth-bound, so
  8bit (~29 GB) would roughly halve throughput on a model that is already the
  slow option. mxfp4 was rejected for lack of comparison data on this
  checkpoint. 4bit is also the variant with published third-party numbers.
- **No reasoning-level configuration.** The measurement above shows
  `chat_template_kwargs` in `model_settings.json` does not reach the chat
  template, so a profile field for it would have no effect. Extending
  `render_omlx_settings` to pass a key that provably does nothing was
  rejected — it would be a speculative field with no working caller.
- **No MTP / speculative decoding.** omlx logs
  `config declares mtp heads but checkpoint ships no mtp.* weights` for this
  checkpoint, so the throughput gain reported for Qwen3.8 elsewhere would
  need the separate `Qwen3.8-27B-MTP-4bit` drafter wired through
  `dflash_draft_model` — a distinct piece of work with its own memory cost.
- **Test derives the model name instead of hard-coding it.**
  `tests/test_profile_state_machine.bats:573` asserts a literal model path, so
  it fails on every future chat-slot change for a reason unrelated to what it
  tests (that `make models` dispatches downloads at all). Extraction is
  positional (`models[1]` = chat via `profile_model_entries()`) rather than
  name-anchored, because
  anchoring on `served_model_name: qwen3.8-27b` would reintroduce the same
  hard-coding one rename later. Position is not perfectly stable either
  (breaks on slot reorder) but that is a far rarer event than a chat-model
  rename, and reorder failures are loud (`validate_profile` / staging errors)
  rather than silent.
- **`profile_model_entries()`, not `yq`, for the test extraction.** The repo
  parses profile YAML with `awk` everywhere and has no YAML tooling by
  choice; adding `yq` as a dependency for one bats assertion was rejected.
  `bin/4lm:230-243` already provides `profile_model_entries()`, emitting
  `name|path|od` for every entry in declaration order — the existing utility
  the original search for the literal string `yq` failed to surface.
  `tests/lint-profiles.sh:10` already sources `bin/4lm` to reach such
  functions, so the bats test does the same.
- **README's componentwise memory-math paragraph is corrected on its own
  terms, not forced to match the Memory Math table.** `README.md:156-161`
  derives its total by summing individual model sizes (a method that, even
  before this swap, summed to `64.4 GB` while being presented as `65 GB` —
  a pre-existing ~0.6 GB rounding gap). The Memory Math table above instead
  takes the profile header's stated "Steady state" baseline and applies the
  chat-slot delta (`65 - 18 + 15.27 ≈ 62`). These are two different
  pre-existing accounting methods for the same profile that already didn't
  agree exactly; reconciling them fully is a pre-existing documentation
  defect unrelated to this swap (consistent with this SDD's practice of
  flagging, not fixing, pre-existing issues like `docs/profile-schema.md:40`
  and the `docs/setup.md` `-DWQ` mismatch). Requirement 8 recomputes the
  paragraph honestly from its own components (42 + 15.27 + 5 + 0.4 + 5 ≈
  67.67 → 68 GB) rather than overriding it to match the table's ~62 GB,
  which would make the componentwise arithmetic wrong by a larger margin
  than today's ~0.6 GB gap.

## Open Decisions

None.

## Out of Scope

- Reasoning-level control in the profile schema — proven ineffective via
  `model_settings.json`; belongs at the client.
- Wiring `Qwen3.8-27B-MTP-4bit` as a DFlash drafter.
- The unimplemented `chat_template_kwargs` row in `docs/profile-schema.md:40`,
  which documents a field `bin/4lm` never writes. A real defect, unrelated to
  this swap.
- omlx 0.6.0 listing HF-cache models in `/v1/models` beyond the active
  profile's slots (confirmed to be cache discovery, not a profile leak).
- Any change to `lean` or `max-100gb`.
- The `-DWQ` suffix mismatch in `docs/setup.md:263`'s example `model_path` —
  pre-existing, predates this SDD.
- Reconciling README's componentwise memory-math method with the profile
  header's "Steady state" figure into a single accounting method — pre-
  existing ~0.6 GB gap, unrelated to this swap (see Decision Log).
- `README.md:317` mentions `Qwen3.6-35B-A3B` in release-history prose about
  v0.3 and stays unchanged, consistent with leaving historical notes alone.
