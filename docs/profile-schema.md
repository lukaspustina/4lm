# Profile YAML Schema

Profiles describe the model set served by `mlx-openai-server`. The active
profile is selected via the `~/.4lm/config/mlx-active` symlink.

The schema below documents the keys consumed by `mlx-openai-server` v1.7.1.
Source of truth: [`app/config.py`](https://github.com/cubist38/mlx-openai-server/blob/main/app/config.py)
in the upstream repo.

## Top-level

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

`tool_call_parser` is a free-form string at the schema level. Valid parsers in
`app/parsers/` (v1.7.1):

- `functiongemma`
- `gemma4`
- `glm4_moe`
- `harmony`
- `hermes`
- `kimi_k2`
- `longcat_flash_lite`
- `minimax_m2`
- `qwen3`
- `qwen3_5`
- `qwen3_coder`
- `qwen3_moe`
- `solar_open`
- `step35`

The 4lm `validate_profile` enforces this enum.

`reasoning_parser` values are model-specific and not enumerated here. Use the
value documented for your model (e.g. `glm47_flash`, `qwen3`, `harmony`).

## Validation

`4lm profile set <name>` runs validation before swapping the active symlink.
The validator (`bin/4lm:validate_profile`) checks:

1. File is readable.
2. Top-level `models:` key is present.
3. At least one entry with `model_path:`.
4. Every entry has `served_model_name:`.
5. Every entry has `context_length:` as a positive integer.
6. Any `tool_call_parser` value is in the allowed enum above.

A validation failure aborts the switch with a non-zero exit and leaves the
active profile unchanged.
