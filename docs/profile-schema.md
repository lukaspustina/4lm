# Profile YAML Schema

Profiles describe the model set and backend for 4lm. The active profile is
selected via the `~/.4lm/config/active-profile` symlink.

## Top-level keys

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `backend` | `omlx` \| `mlx_lm` \| `ollama` | no, default `omlx` | Selects the inference daemon for this profile |
| `models` | list | yes | One or more model entries (see below) |

### `backend: omlx`

Uses `omlx serve` (vLLM-style MLX inference with block-based paged KV cache,
continuous batching, and multi-model EnginePool). Installed via pipx from git.

Host and port come exclusively from `~/.4lm/config/network.yaml`; there is no
fallback in the profile YAML.

**Optional `omlx:` block** (all fields optional; absent = omlx built-in defaults):

| Key | Type | Notes |
|---|---|---|
| `memory_guard_gb` | number > 0 | Passed as `--memory-guard-gb`: omlx's process memory ceiling in GB. Soft stop (admission pause, LRU eviction) at 85 %, in-flight abort at 95 %. Absent = omlx's dynamic `balanced` tier |
| `hot_cache_max_size` | string | Passed as `--hot-cache-max-size` |
| `paged_ssd_cache_dir` | string | Passed as `--paged-ssd-cache-dir`; tilde-expanded; validated |
| `paged_ssd_cache_max_size` | size \| `auto` | Passed as `--paged-ssd-cache-max-size` (e.g. `50GB`). omlx's default `auto` claims half the free disk; on a host that also swaps, cap it — free disk is macOS's only swap headroom |
| `max_concurrent_requests` | int | Passed as `--max-concurrent-requests` |

**Per-model fields** (in `models:` list):

| Key | Type | Required | Notes |
|---|---|---|---|
| `model_path` | string | yes | HuggingFace `org/repo` format; validated against `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` |
| `served_model_name` | string | yes | Alias exposed in `/v1/models` |
| `model_type` | `lm` \| `vlm` | no | Default: `lm`. Use `lm` for all non-visual models including embeddings and rerankers. |
| `pin` | bool | no | Keep model in memory (default: `false`) |
| `ttl` | int \| null | no | Unload after N seconds idle; `null` = never unload |
| `max_context_window` | int > 0 | no | Longest prompt omlx admits for this model, in tokens; longer requests are rejected up front. Measure it with omlx's context benchmark |
| `mtp` | bool | no | Speculative decoding with the checkpoint's own multi-token-prediction head (omlx `mtp_enabled`, adaptive depth). Needs an `-mtp` checkpoint. Gains are single-stream; a fixed draft depth (omlx `mtp_fixed_depth`) measured slower than adaptive and is not exposed |
| `reasoning_effort` | lowercase word | no | Default for the chat template's `reasoning_effort` (e.g. `low` / `medium` / `high` / `xhigh` — the values depend on the model's template), rendered as `chat_template_kwargs`. A request that sends its own value wins. Takes effect on omlx main after 0.7.0rc1; 0.6.0 ignored it. Measured on Qwen3.8-Flash-Next: `medium` cut a coding answer from ~78 s to ~21 s, and `low` made non-English prose slip into other scripts in most answers while `medium` did not |
| `top_k` | int > 0 | no | Per-model sampling default; omlx's global default is 0 (off). Use the value from the model card |

`~/.omlx/model_settings.json` is a **derived runtime artifact** rendered from
the active profile YAML by `render_omlx_settings()` on every `profile set`,
which overwrites it in full. A per-model value set in the omlx admin UI does
not survive; put it in the profile. Unknown `omlx:` keys fail validation.

Minimal omlx profile skeleton:

```yaml
backend: omlx

models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    pin: true
    ttl: null
```

See `config/profiles/lean.yaml` for a complete example.

### `backend: mlx_lm`

Uses `python3 -m mlx_lm server` (the direct MLX inference library). `python3`
is resolved from the omlx pipx venv — mlx_lm is co-installed there.

**Constraints**:
- Exactly one model entry (mlx_lm.server is single-model).
- `context_length` is not required (set by the model's native config).
- Clients must use `model_path` as the model id (not `served_model_name`).

Minimal mlx_lm profile skeleton:

```yaml
backend: mlx_lm

models:
  - model_path: mlx-community/Qwen3-Coder-30B-A3B-4bit   # HF repo (also the /v1/models id)
    served_model_name: qwen3-coder-30b                     # informational only for mlx_lm
```

No shipping profile currently uses `backend: mlx_lm` — it remains
supported for single-model upstream MLX use cases.

### `backend: ollama`

Uses `ollama serve` with `OLLAMA_HOST=<bind>:<port>`. Only `model_path:`
(Ollama pull tag, e.g. `gemma4:27b`) and `served_model_name:` are required
per model entry.

Minimal Ollama profile skeleton:

```yaml
backend: ollama

models:
  - model_path: gemma4:27b          # Ollama pull tag
    served_model_name: gemma4-27b   # OpenAI API model alias
```

## Validation

`4lm profile set <name>` runs validation before swapping the active symlink.
The validator (`bin/4lm:validate_profile`) checks:

1. File is readable.
2. Top-level `models:` key is present.
3. At least one entry with `model_path:`.
4. Every entry has `served_model_name:`.
5. `backend:` value is `omlx`, `mlx_lm`, or `ollama`.
   Unknown values are rejected.
6. **mlx_lm profiles only**: exactly one model entry.
7. **omlx profiles only**: every `model_path:` matches `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`.

A validation failure aborts the switch with a non-zero exit and leaves the
active profile unchanged.
