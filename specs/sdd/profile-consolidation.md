# SDD: Consolidate the profiles to one per machine class

Status: Active
Created: 2026-09-29

## Overview

Eight profiles have grown out of past experiments; most predate the stability standard (memory
guard, context cap, pinned models without TTL churn) and the current model generation. Replace
them with one profile per memory class plus the ollama smoke profile.

## Requirements

1. The repo ships exactly `default` (256 GB), `mid` (128 GB), `lean` (64 GB) and `ollama`.
   `max-100gb`, `max-170gb`, `mlx-coding`, `mlx-knowledge` and `ornith-vs-qwen` are removed.
2. `default` is the former `max-170gb` unchanged in substance: Qwen3.8-Flash-Next (VLM) with
   MTP, embedder, 4B reranker, memory guard 170 GiB, `max_context_window` 262144, plus
   `reasoning_effort: medium` and `top_k: 20` from the 2026-09-29 measurements.
3. `mid` is the former `default` modernised: Qwen3-Coder-Next + Qwen3.8-27B (VLM, takes vision) +
   embedder + 0.6B reranker; no `qwen3-vl-8b`; all pinned, no TTL; memory guard and
   `max_context_window` set and marked as derived, not measured.
4. `lean` is the former `lean` modernised the same way (Qwen3-Coder-30B + Qwen3.6-35B + embedder +
   0.6B reranker), guard and context cap marked as derived.
5. Every omlx profile in the repo carries `memory_guard_gb`, a `max_context_window` on every
   generative model, and `pin: true` / `ttl: null` on every model. A test enforces it.
6. On a fresh install, `install.sh` activates the profile matching the machine's RAM:
   ≥ 250 GB `default`, ≥ 120 GB `mid`, otherwise `lean`. An existing active profile is kept.
7. `4lm doctor`'s RAM check knows `default` 256, `mid` 128, `lean` 64, `ollama` 36.
8. README, index, `docs/setup.md`, CLAUDE.md, the opencode template and the CHANGELOG
   (BREAKING) follow; the served-name contract drops `qwen3-vl-8b`.

## Out of scope

- Measuring `mid` and `lean` on 64/128 GB hardware (no such machine at hand) — the headers say
  how to verify with `4lm bench --context`.
- Removing the ollama or mlx_lm backend.
