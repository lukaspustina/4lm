# Profile YAML Schema

Profiles describe the model set and backend for 4lm. The active profile is
selected via the `~/.4lm/config/active-profile` symlink.

## Top-level keys

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `backend` | `mlx` \| `mlx_lm` \| `ollama` | no, default `mlx` | Selects the inference daemon for this profile |
| `models` | list | yes | One or more model entries (see below) |

### `backend: mlx` (default)

Uses `mlx-openai-server`. All model entry fields apply. The `server.host` and
`server.port` from the YAML are ignored — they are set by `4lm-backend-start.sh`
from `~/.4lm/config/network.yaml`.

### `backend: mlx_lm`

Uses `python3 -m mlx_lm server` (the direct MLX inference library). `python3`
is resolved from the mlx-openai-server pipx venv — mlx_lm is co-installed there.

**Constraints**:
- Exactly one model entry (mlx_lm.server is single-model).
- `context_length` is not required (set by the model's native config).
- `tool_call_parser` is not supported (auto-detected from tokenizer).
- Clients must use `model_path` as the model id (not `served_model_name`).
- No server-level `repetition_penalty`; set `frequency_penalty` per-request if needed.

Minimal mlx_lm profile skeleton:

```yaml
backend: mlx_lm

models:
  - model_path: mlx-community/gemma-4-26b-a4b-it-4bit   # HF repo (also the /v1/models id)
    served_model_name: gemma4-26b                         # informational only for mlx_lm
```

See `config/profiles/mlx-lm-gemma4.yaml` for a complete example.

### `backend: ollama`

Uses `ollama serve` with `OLLAMA_HOST=<bind>:<port>`. mlx-specific fields
(`model_type`, `tool_call_parser`, `reasoning_parser`, `context_length`,
`on_demand`) are not required and are ignored by the validator. Only
`model_path:` (Ollama pull tag, e.g. `gemma4:27b`) and `served_model_name:`
are required per model entry.

Minimal Ollama profile skeleton:

```yaml
backend: ollama

models:
  - model_path: gemma4:27b          # Ollama pull tag
    served_model_name: gemma4-27b   # OpenAI API model alias
```

See `config/profiles/ollama-gemma4.yaml` for a complete example.

### mlx profile structure

```yaml
server:
  host: "<set by wrapper, ignored from YAML>"
  port: <integer 1-65535>

models:
  - <model entry>
  - <model entry>
```

`server.host` in the YAML is overridden by the start wrapper based on
`~/.4lm/config/network.yaml` mode. Set it to `127.0.0.1` for documentation;
the runtime value is `127.0.0.1` (mode=local) or `0.0.0.0` (mode=lan).

`server.port` is also taken from `network.yaml` at runtime; the YAML value is
ignored.

## Model entry

| Key | Type | Required | Notes |
|---|---|---|---|
| `model_path` | string | yes | Hugging Face repo or local path |
| `served_model_name` | string | yes | The model id exposed in `/v1/models` |
| `model_type` | enum | no, default `lm` | One of `lm`, `multimodal`, `image-generation`, `image-edit`, `embeddings`, `whisper` |
| `enable_auto_tool_choice` | bool | no, default `false` | Enable native tool-call parsing |
| `tool_call_parser` | string | no | See parser values below |
| `reasoning_parser` | string | no | Model-specific reasoning parser |
| `context_length` | int | yes (4lm convention) | Max context tokens. Required by 4lm validator. |
| `on_demand` | bool | no, default `false` | Load lazily; release after idle timeout |
| `on_demand_idle_timeout` | int | no, default `60` | Seconds of inactivity before unload (only when `on_demand: true`) |
| `queue_timeout` | int | no, default `300` | Seconds before a queued request is dropped |
| `queue_size` | int | no, default `100` | Max queued requests |
| `disable_auto_resize` | bool | no, default `false` | Disable image auto-resize (multimodal only) |
| `batch_completion_size` | int | no, default `32` | Token-generation batch size |
| `batch_prefill_size` | int | no, default `8` | Prefill batch size |
| `batch_prefill_step_size` | int | no, default `2048` | Prefill chunk size |
| `message_converter` | string | no | Model-specific request transformer |

### Phase 1 verification (2026-04-26)

`on_demand` is supported. The correct idle key is `on_demand_idle_timeout`,
**not** `idle_timeout`. The pre-rework profiles used the wrong key —
mlx-openai-server silently ignored it, leaving `on_demand_idle_timeout` at its
60 s default. Profiles in this repo use the correct key.

The pre-rework profiles also used `context_window` (not in the schema) and
`max_concurrency` (not in the schema). Both were silently ignored. The current
profiles use `context_length`.

### KV-cache size

Per-model KV-cache memory is roughly `n_layers × n_kv_heads × head_dim ×
bytes_per_element × context_length × 2` (×2 for K and V). MLX quants don't
expose `n_kv_heads`/`head_dim` uniformly, and quantisation may compact the
cache, so a static estimate is unreliable across the model set in
`default.yaml`. Measure at runtime once models are loaded — `4lm status` shows
backend RSS, and Activity Monitor / `vm_stat` reflect the unified-memory
working set.

## Parser values

`tool_call_parser` is a free-form string at the schema level. Source of truth
is `mlx-openai-server launch --help` (`--tool-call-parser` choices); the 4lm
validator enforces it. Current set:

- `functiongemma`
- `gemma4`
- `glm4_moe`
- `harmony`
- `hermes`
- `iquest_coder_v1`
- `kimi_k2`
- `longcat_flash_lite`
- `minimax_m2`
- `nemotron3_nano`
- `qwen3`
- `qwen3_coder`
- `qwen3_moe`
- `qwen3_vl`
- `solar_open`
- `step_35`

`reasoning_parser` is also enum-restricted by the binary
(`--reasoning-parser` choices) but 4lm does not validate it — use a value
listed by `mlx-openai-server launch --help`. Examples used in this repo:
`glm47_flash`, `qwen3`, `harmony`.

## Validation

`4lm profile set <name>` runs validation before swapping the active symlink.
The validator (`bin/4lm:validate_profile`) checks:

1. File is readable.
2. Top-level `models:` key is present.
3. At least one entry with `model_path:`.
4. Every entry has `served_model_name:`.
5. `backend:` value is `mlx`, `mlx_lm`, `ollama`, or absent (defaults to `mlx`).
   Unknown values are rejected.
6. **mlx_lm profiles only**: exactly one model entry.
7. **mlx profiles only**: every entry has `context_length:` as a positive
   integer; any `tool_call_parser` value must be in the allowed enum above.

A validation failure aborts the switch with a non-zero exit and leaves the
active profile unchanged.
