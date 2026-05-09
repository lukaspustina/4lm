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
| `max_process_memory` | string | Passed as `--max-process-memory` (e.g. `"80%"`, `"100GB"`) |
| `max_model_memory` | string | Passed as `--max-model-memory` |
| `hot_cache_max_size` | string | Passed as `--hot-cache-max-size` |
| `paged_ssd_cache_dir` | string | Passed as `--paged-ssd-cache-dir`; tilde-expanded; validated |
| `max_concurrent_requests` | int | Passed as `--max-concurrent-requests` |

**Per-model fields** (in `models:` list):

| Key | Type | Required | Notes |
|---|---|---|---|
| `model_path` | string | yes | HuggingFace `org/repo` format; validated against `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` |
| `served_model_name` | string | yes | Alias exposed in `/v1/models` |
| `model_type` | `lm` \| `vlm` | no | Default: `lm`. Use `lm` for all non-visual models including embeddings and rerankers. |
| `pin` | bool | no | Keep model in memory (default: `false`) |
| `ttl` | int \| null | no | Unload after N seconds idle; `null` = never unload |
| `chat_template_kwargs` | dict | no | Passed to `~/.omlx/settings.json`; empty `{}` is omitted |
| `sampling` | dict | no | Per-model sampling defaults; empty `{}` is omitted |

`~/.omlx/settings.json` is a **derived runtime artifact** rendered from the
active profile YAML by `render_omlx_settings()`. Never edit it by hand.

Minimal omlx profile skeleton:

```yaml
backend: omlx

models:
  - model_path: mlx-community/Qwen3-Coder-Next-4bit
    served_model_name: qwen3-coder-next
    pin: true
    ttl: null
```

See `config/profiles/omlx-coding.yaml` for a complete example.

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
  - model_path: mlx-community/gemma-4-26b-a4b-it-4bit   # HF repo (also the /v1/models id)
    served_model_name: gemma4-26b                         # informational only for mlx_lm
```

See `config/profiles/exp-mlxlm-gemma4.yaml` for a complete example.

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
