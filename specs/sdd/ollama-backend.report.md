# SDD Implementation Report: ollama-backend.md

**Date**: 2026-05-04
**Phases run**: 1, 2, 3, 4, 5
**Overall status**: all-shipped

| Phase | Title | Status | Commit |
|-------|-------|--------|--------|
| 1 | Rename mlx-active → active-profile | shipped | 0123273 |
| 2 | Profile schema + validate_profile backend awareness | shipped | afd6ba2 |
| 3 | 4lm-backend-start.sh Ollama launch branch | shipped | ee38bf4 |
| 4 | Backend-aware model download, list, outdated, doctor | shipped | 6be2130 |
| 5 | install.sh Ollama detection + docs | shipped | bb5c694 |

## Reviewer Verdict: PASS

0 blockers, 8 nits. All 16 SDD requirements satisfied.

### Requirements Coverage

| R# | Requirement | Status |
|----|-------------|--------|
| R1 | `backend: mlx | ollama` key, default `mlx` | satisfied |
| R2 | ollama profiles accept `model_path` + `served_model_name` only | satisfied |
| R3 | Unknown backend rejected with stderr message | satisfied |
| R4 | mlx profiles still require `context_length` and valid `tool_call_parser` | satisfied |
| R5 | `4lm-backend-start.sh` dispatches mlx vs `ollama serve` with `OLLAMA_HOST` | satisfied |
| R6 | Wired-memory sysctl gated to mlx only | satisfied |
| R7 | `4lm model download` (no-arg) dispatches per backend with dedup | satisfied |
| R8 | Explicit-arg form HF-only; `:` arg exits 1 with error | satisfied |
| R9 | `make models` backend-aware dispatch | satisfied |
| R10 | `4lm model list` annotates backend; `~` for ollama | satisfied |
| R11 | `4lm doctor` warns on missing ollama, exit 0, no fail | satisfied |
| R12 | `install.sh` migrates mlx-active → active-profile | satisfied |
| R13 | `install.sh` warns (non-fatal) on missing ollama | satisfied |
| R14 | `config/profiles/ollama-gemma4.yaml` reference profile present | satisfied |
| R15 | Cross-backend switching uses existing kickstart/rollback | satisfied |
| R16 | `run_outdated_check()` skips ollama profiles via per-profile loop | satisfied |

### Notable Nits (non-blocking)
- `command -v hf` check moved inside the per-model loop in `cmd_models_download()` — minor redundancy on the success path
- `run_outdated_check()` uses `profile_model_entries()` instead of the SDD's inline awk — cleaner reuse
- CLAUDE.md not updated to mention `backend:` key (docs/profile-schema.md covers it)

## Manual Test Plan

1. `4lm profile set default` — expected: output "Switched to default"; `readlink ~/.4lm/config/active-profile` ends in `default.yaml`
2. `4lm profile set ollama-gemma4` — expected: "Switched to ollama-gemma4"; symlink points to `ollama-gemma4.yaml`
3. `4lm start` with ollama profile active — expected: `ollama serve` launched on port 8000; `OLLAMA_HOST=127.0.0.1:8000`
4. `4lm start` with mlx profile active — expected: `mlx-openai-server launch` called; wired-memory sysctl applied
5. `4lm model list` — expected: mlx profiles show `(mlx)`, ollama profiles show `(ollama)`; ollama models show `~` in cache column
6. `4lm model download` — expected: logs `hf download` for mlx models, `ollama pull` for ollama models
7. `4lm model download gemma4:27b` — expected: exit 1 with "explicit download is HF-only"
8. `4lm doctor` without ollama installed — expected: warns about ollama, exit 0
9. `./install.sh` on system with `mlx-active` symlink — expected: migrated to `active-profile`, old name removed
10. `4lm profile set bad-backend` (profile with `backend: llamacpp`) — expected: exit 1, "unknown backend"

## Stuck Tests

None.
