# SDD: WebUI Tool Calling and MCP Integration

**Status**: Draft
**Created**: 2026-05-13
**Related PRD**: [specs/prd/4lm.md](../prd/4lm.md) (broad product PRD; no feature-scoped PRD exists)

---

## Overview

Wire end-to-end tool/function calling into the 4lm OpenWebUI stack so the locally-served Qwen3-Coder-Next and Qwen3.6-35B-A3B models can invoke OpenWebUI's built-in tools (web search, memory, notes, knowledge, code interpreter) instead of hallucinating. The first three phases close the tool-calling gap without touching MCP; phases 4–7 add MCP transports, default MCP servers, and Claude-Desktop-parity features (artifacts, filesystem) as later, independently-shippable increments.

Aim: a competitive Claude Desktop replacement on local hardware, with the same agentic surface, addressed phase by phase.

---

## Context & Constraints

- **Stack**: Bash 5.x control plane (`bin/4lm`), Python 3.12 helper (`bin/4lm_helpers.py`), launchd user agents in `~/.4lm/launchd/`, OpenAI-compatible seam at `127.0.0.1:8000/v1`. macOS Apple Silicon only.
- **Backends shipping today** (`config/profiles/default.yaml`): `omlx` serves the full Qwen3 stack — `Qwen3-Coder-Next-4bit` (coder), `Qwen3.6-35B-A3B-4bit` (chat), `Qwen3-Embedding-8B-4bit-DWQ` (embed), `Qwen3-Reranker-0.6B-4bit-DWQ` (rerank), `Qwen3-VL-8B-4bit-DWQ` (vision). `lean.yaml` and `max-100gb.yaml` are tier variants of the same stack; `mlx-coding.yaml` is Qwen3-Coder-only; `mlx-knowledge.yaml` is Qwen3.6-35B-A3B-only.
- **WebUI today** (`bin/4lm-webui-start.sh`): exports `OPENAI_API_BASE_URL`, memory, DuckDuckGo web search, Pyodide code interpreter, local-embedding RAG. No `ENABLE_FUNCTION_CALLING`, no `tool_call_parser`, no MCP env vars.
- **OpenWebUI version pinned**: `open-webui==0.9.2` (`requirements.txt`). MCP native HTTP/SSE support and per-model "Native Mode" function calling are both documented for current 0.9.x but the canonical REST surface is not formally versioned — pin and probe.
- **PRD anchor** (`specs/prd/4lm.md` AC15): WebUI ships with memory, web search, code interpreter, and RAG via `qwen3-embedding`. This SDD extends that surface with tool calling and MCP without breaking it.
- **Profile YAML conventions**: validated by `validate_profile()` in `bin/4lm`; the validator already accepts a `tool_call_parser` enum (`hermes | mistral | llama | qwen | qwen3_coder | glm4_moe | harmony`) from the original rework SDD, but no live profile uses it. `docs/profile-schema.md` does not yet document the key.
- **Hard constraints inherited from CLAUDE.md**: no env-var bind-mode overrides; profile switching is atomic with rollback; `4lm` is the only operator-facing entry point.

---

## Architecture

```
                    ┌────────────────────────────┐
                    │       OpenWebUI            │
                    │  (open-webui:3000)         │
                    │                            │
                    │   Native Mode FC ⬢         │
                    │   ↓                        │
                    │   Built-in Tools:          │
                    │     web_search             │
                    │     memory                 │
                    │     notes                  │
                    │     knowledge              │
                    │     code_interpreter       │
                    │                            │
                    │   External Tools:          │
                    │     OpenAPI servers ⟵──┐   │
                    │     HTTP MCP servers ⟵┐│   │
                    └────────────────────────┘│   │
                              │ /v1/*         │   │
                              ▼               │   │
                    ┌────────────────────────┐│   │
                    │ omlx backend           ││   │
                    │ (127.0.0.1:8000)       ││   │
                    │   tool_call_parser     ││   │
                    │   enable_auto_tool_    ││   │
                    │     choice             ││   │
                    └────────────────────────┘│   │
                                              │   │
   Future phases ──────────────────────────── ┘   │
                                                  │
            ┌─────────────────────────────────────┘
            ▼
   ┌────────────────────────┐    ┌────────────────────────┐
   │ mcpo bridge (Phase 4)  │    │ Remote MCP (Phase 5)   │
   │ stdio → OpenAPI        │    │ HTTP / SSE direct      │
   │   • Fetch (default)    │    │   • Notion, Linear     │
   │   • Filesystem (Ph 7)  │    │   • Personal vault     │
   │                        │    │     servers (Ph 6)     │
   └────────────────────────┘    └────────────────────────┘
```

Phases 1–3 light up the path WebUI → omlx → tool_calls and let the built-in tools fire. Phase 4 adds the first external MCP via `mcpo`. Phases 5–7 broaden the MCP surface and add Claude-Desktop-parity features.

---

## Requirements

### Tool calling (Phases 0–3)

1. The omlx backend installed by `install.sh` shall be probed during Phase 0 to confirm it parses `tool_call_parser` and `enable_auto_tool_choice` per-model keys and emits `tool_calls` in `/v1/chat/completions` responses when `tools` is supplied.
2. `config/profiles/default.yaml` shall declare `enable_auto_tool_choice: true` and `tool_call_parser: qwen3_coder` on the Qwen3-Coder-Next model entry.
3. `config/profiles/default.yaml` shall declare `enable_auto_tool_choice: true` and a parser confirmed by Phase 0 on the Gemma4-31B model entry. If no Gemma-specific parser exists in the installed omlx, the entry shall use the closest enum value validated by Phase 0; if no parser produces correct output, the Gemma entry shall be deferred to a follow-up SDD and the Qwen-only path shall ship.
4. `config/profiles/omlx-coding.yaml` shall mirror Requirement 2 on its Qwen3-Coder-Next entry.
5. `bin/4lm` `validate_profile` shall reject a profile whose `tool_call_parser` is outside the enum without changing the enum surface.
6. `docs/profile-schema.md` shall document `enable_auto_tool_choice` (bool, optional, default false) and `tool_call_parser` (enum, optional) with the full enum list and a one-line note that tool-calling-capable models require both.
7. A new `4lm webui setup-tools` subcommand shall PATCH each model's per-model parameters in OpenWebUI to `function_calling = "native"` via the OpenWebUI REST API, idempotently (no-op if already native), reading an admin token from `~/.4lm/config/webui-admin-token` (mode 0600, gitignored, generated by the operator from the admin UI).
8. `4lm webui setup-tools` shall exit 1 with a remediation message if the admin token file is absent or unreadable.
9. `4lm webui setup-tools` shall print per-model status: `<model-id>: already native` or `<model-id>: enabled`.
10. `docs/setup.md` shall include a walkthrough for the manual admin-UI path (Settings → Models → Function Calling → Native) as the documented fallback.
11. `bin/4lm-webui-start.sh` shall not flip `ENABLE_PERSISTENT_CONFIG=False` — the per-model function-calling toggle is the only setting being seeded, and disabling persistent config would erase admin-UI persistence for everything else.

### MCP and parity (Phases 4–7) — outline only

12. `bin/4lm` shall manage a third launchd service `com.4lm.mcpo` that runs the `mcpo` proxy on a local port, bridging stdio MCP servers into OpenAPI tools consumable by OpenWebUI.
13. The Anthropic Fetch MCP server shall be the only stdio server shipped by default; additional stdio servers shall be opt-in via a YAML config file (path TBD in Phase 4 detail).
14. `4lm` shall expose a subcommand surface for adding remote (HTTP / SSE) MCP servers to OpenWebUI — either by orchestrating the existing admin-UI flow or by direct REST API integration (transport choice deferred to Phase 5 detail).
15. Custom stdio MCP servers (e.g. an Obsidian-vault server keyed on the operator's local notes path) shall be addable via the same surface as Requirement 14 with a documented example in `docs/setup.md`. The operator's specific server names are out of scope for this SDD.
16. Claude-Desktop-parity for artifacts (interactive previews, side-by-side editing) and a scoped filesystem MCP server shall ship as later phases; their requirements remain undefined here.

---

## File & Module Structure

### New files

| Path | Purpose |
|---|---|
| `tests/test_profile_tool_call.bats` | Validator accepts/rejects `tool_call_parser` enum; YAML loads with new keys. |
| `tests/test_webui_setup_tools.bats` | `cmd_webui_setup_tools` happy path + missing-token path (curl stubbed). |
| `tests/helpers/curl-webui` | Curl stub that records WebUI REST calls and returns canned JSON for `GET /api/v1/models` and `PATCH /api/v1/models/<id>/update`. |
| `~/.4lm/config/webui-admin-token` | Operator-generated, mode 0600, gitignored. Not in repo; documented in `docs/setup.md`. |

### Modified files

| Path | Change |
|---|---|
| `config/profiles/default.yaml` | Add `enable_auto_tool_choice` + `tool_call_parser` to two model entries. |
| `config/profiles/omlx-coding.yaml` | Same on Qwen3-Coder-Next entry. |
| `bin/4lm` | Add `cmd_webui_setup_tools()` and route it via `webui setup-tools`. |
| `docs/profile-schema.md` | Document the two new keys + enum. |
| `docs/setup.md` | Admin-token generation + Native Mode walkthrough + `4lm webui setup-tools` usage. |
| `.gitignore` | Add `~/.4lm/config/webui-admin-token` pattern (path under `~/.4lm/` already ignored — verify and document). |

---

## Data Models

### Profile YAML — new per-model keys

```yaml
models:
  - model_path: "<HF repo or local>"
    served_model_name: qwen3-coder-next
    enable_auto_tool_choice: true        # NEW — required for tool calling
    tool_call_parser: qwen3_coder        # NEW — enum: hermes | mistral | llama | qwen | qwen3_coder | glm4_moe | harmony
    # ... existing keys (model_type, pin, ttl, chat_template_kwargs, sampling, ...) unchanged
```

### `~/.4lm/config/webui-admin-token`

Plain text, single line: the JWT bearer token copied from the OWUI admin UI (Settings → Account → API Keys). Mode 0600. Never logged. Never re-issued by 4lm.

---

## API Contracts

### Backend → WebUI: tool-calling probe (Phase 0)

```
POST http://127.0.0.1:8000/v1/chat/completions
Content-Type: application/json

{
  "model": "qwen3-coder-next",
  "messages": [{"role":"user","content":"List the files in /tmp"}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "list_files",
      "description": "List files in a directory",
      "parameters": {"type":"object","properties":{"path":{"type":"string"}}}
    }
  }],
  "tool_choice": "auto"
}
```

Expected response shape:
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "tool_calls": [{
        "id": "<id>",
        "type": "function",
        "function": {"name":"list_files","arguments":"{\"path\":\"/tmp\"}"}
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

Probe passes if `tool_calls` is present and `finish_reason == "tool_calls"`.

### 4lm → WebUI: per-model function-calling toggle (Phase 2)

```
GET  http://127.0.0.1:3000/api/v1/models
     Authorization: Bearer <admin-token>
     → JSON array; pick entries by `id` matching the two configured `served_model_name`s.

PATCH http://127.0.0.1:3000/api/v1/models/<id>/update
     Authorization: Bearer <admin-token>
     Content-Type: application/json
     Body: { "params": { "function_calling": "native" } }
     → 200 on success; 404 if model not yet known to WebUI (handle as soft-fail with retry hint).
```

If the OWUI 0.9.2 surface differs (endpoint name, payload shape), the implementation shall match the actually-shipping API discovered in Phase 0 and the spec amended.

---

## Configuration

No new env vars in Phases 0–3. Phase 4 will introduce `MCPO_PORT` and `MCPO_CONFIG_PATH` once detailed.

---

## Error Handling

| Failure | Trigger | Behaviour | User-visible |
|---|---|---|---|
| omlx ignores `tool_call_parser` | Phase 0 probe | Stop work; do not edit profiles | `Phase 0 failed: omlx <version> does not parse tool_call_parser. See docs/setup.md §Tool calling` |
| `webui-admin-token` missing | `4lm webui setup-tools` | Exit 1, do not call WebUI | `Admin token missing at ~/.4lm/config/webui-admin-token. Generate one in OWUI Settings → Account → API Keys.` |
| WebUI returns 404 for model PATCH | Model not yet registered in WebUI | Print warning, continue with remaining models, exit 1 at end | `qwen3-coder-next: not yet known to WebUI. Open the model picker once, then re-run setup-tools.` |
| WebUI returns 401 | Token expired or wrong | Exit 1 immediately | `Admin token rejected. Regenerate in OWUI Settings → Account.` |
| Profile validator rejects new key | `tool_call_parser` value typo | Profile-set state-machine rolls back (existing behaviour) | `Profile validation failed: tool_call_parser '<bad>' not in allowed enum` |

---

## Implementation Phases

## Phase 0 — Probe omlx tool-call support

Single-PR investigation. No production changes. The output is either a "go" with confirmed parser names, or a "stop" with a fall-back plan.

Steps:
1. `pip show omlx | grep Location` → grep the installed package source for `tool_call_parser`, `enable_auto_tool_choice`, and the parser registry.
2. With one profile temporarily edited (in a worktree), curl the backend with a tools-bearing request and verify `tool_calls` in the response.
3. Determine the correct parser name for Gemma 4 (candidates: a Gemma-specific parser, `harmony`, or none).
4. Document findings in this SDD (amend Requirement 3 once known) and in `docs/profile-schema.md`.

**Phase complete when**: a single curl test against the live backend returns a populated `tool_calls` array, AND the parser names for both Qwen3-Coder and Gemma 4 are confirmed (or Gemma is formally deferred).

### Test Scenarios

```
GIVEN omlx installed by install.sh with default.yaml active
WHEN curl POSTs /v1/chat/completions with a `tools` array (qwen3-coder-next model)
THEN the response includes choices[0].message.tool_calls
AND  choices[0].finish_reason == "tool_calls"
```

```
GIVEN the omlx package source is grepped
WHEN searching for "tool_call_parser" and "enable_auto_tool_choice"
THEN both keys are referenced in the YAML loader and passed to the generator
AND  the parser registry enumerates known parser names
```

---

## Phase 1 — Backend profile wiring

Edit profile YAMLs and docs. No code change in `bin/4lm` (validator already enforces the enum).

Steps:
1. Add `enable_auto_tool_choice: true` and `tool_call_parser: qwen3_coder` to the `Qwen3-Coder-Next` entry in `default.yaml` and `omlx-coding.yaml`.
2. Add `enable_auto_tool_choice: true` and the Phase-0-confirmed parser to the `Gemma4-31B-it-4bit` entry in `default.yaml` (skip if Phase 0 deferred Gemma).
3. Update `docs/profile-schema.md` to document the two new keys + the full enum + the "required for tool-calling models" note.
4. Add `tests/test_profile_tool_call.bats` covering: valid profile loads; profile with `tool_call_parser: bogus` fails validation; profile without `tool_call_parser` but with `enable_auto_tool_choice` produces a clear validator warning (or passes — TBD by validator behaviour audit).
5. `4lm profile set default` succeeds end-to-end with the new keys; `4lm status` clean.

**Phase complete when**: `make check` green, both models accept `tools` in the API, profile-switch state machine still rolls back on a malformed value.

### Test Scenarios

```
GIVEN config/profiles/default.yaml contains tool_call_parser: qwen3_coder
WHEN `4lm profile set default` is invoked
THEN validate_profile exits 0
AND  the active-profile symlink swaps
AND  /v1/models lists both qwen3-coder-next and gemma4-31b
```

```
GIVEN config/profiles/default.yaml contains tool_call_parser: bogus_parser
WHEN `4lm profile set default` is invoked
THEN validate_profile exits 1 before any symlink swap
AND  stderr contains "tool_call_parser 'bogus_parser' not in allowed enum"
```

---

## Phase 2 — WebUI Native Mode helper

Single-purpose subcommand and operator docs.

Steps:
1. Implement `cmd_webui_setup_tools` in `bin/4lm` (~40 LOC). Reuses existing colour helpers; uses `curl` directly against `:3000/api/v1/models{,/<id>/update}`. Reads token from `~/.4lm/config/webui-admin-token` (mode 0600).
2. Idempotent — GET model first, compare `params.function_calling`, PATCH only if not `native`.
3. Soft-fail per model: 404 (model not registered yet) prints hint and continues; 401 (bad token) exits 1 immediately.
4. Add `webui` subcommand dispatch in `bin/4lm` with `setup-tools` as the first verb (future: more `webui` verbs may land).
5. Document admin-token generation + the new subcommand + the manual UI fallback in `docs/setup.md`.
6. Add `tests/test_webui_setup_tools.bats` using a `tests/helpers/curl-webui` stub that records calls and returns canned JSON.

**Phase complete when**: `4lm webui setup-tools` toggles function calling for both models on a fresh OWUI install in a single invocation; rerunning prints `already native`; `make check` green.

### Test Scenarios

```
GIVEN ~/.4lm/config/webui-admin-token is missing
WHEN `4lm webui setup-tools` is invoked
THEN it exits 1
AND  stderr contains "Admin token missing"
AND  no HTTP call to :3000 is made
```

```
GIVEN ~/.4lm/config/webui-admin-token is mode 0600 and valid
AND   WebUI knows qwen3-coder-next with params.function_calling == "default"
WHEN  `4lm webui setup-tools` is invoked
THEN  curl records PATCH /api/v1/models/qwen3-coder-next/update with body {"params":{"function_calling":"native"}}
AND   stdout prints "qwen3-coder-next: enabled"
AND   exit code is 0
```

```
GIVEN WebUI returns 404 for qwen3-coder-next (not yet registered)
WHEN  `4lm webui setup-tools` is invoked
THEN  stdout prints "qwen3-coder-next: not yet known to WebUI"
AND   the command continues to the next model
AND   exit code is 1 (some models unhandled)
```

---

## Phase 3 — End-to-end verification

No code; verification harness only.

Steps:
1. Add a `4lm doctor` check (or extend the existing one) that POSTs a tools-bearing request to `/v1/chat/completions` and confirms `tool_calls` in the response. Exit 0 / 1 with a remediation message.
2. Document the three-step manual smoke (`4lm restart && 4lm webui setup-tools && ask "what's the weather in Berlin" in WebUI → see web_search invoked`) in `docs/setup.md`.
3. Optionally: add a bats end-to-end test gated by an `E2E=1` env var that boots a real (or container) OWUI and runs the smoke. Default-off in CI to keep `make check` deterministic.

**Phase complete when**: `4lm doctor` flags backend without `tools` support; in WebUI, asking for the weather invokes `web_search`; asking to remember a fact invokes `memory`.

### Test Scenarios

```
GIVEN backend is running with default.yaml active and tool_call_parser configured
WHEN  4lm doctor is run
THEN  the new tool-calling check passes
AND   stdout includes "tool calling: ok (qwen3-coder-next, gemma4-31b)"
```

```
GIVEN WebUI is configured with Native Mode for both models
WHEN  the operator asks "what's the weather in Berlin" via the WebUI
THEN  the chat UI shows a tool-call card for web_search
AND   the assistant's final reply cites at least one URL
AND   the chat history shows the tool's return value
```

---

## Phase 4 — MCP stdio bridge (mcpo) — outline

Bring up `mcpo` as a third launchd service so stdio MCP servers (starting with Anthropic Fetch) are exposed to OpenWebUI as OpenAPI tools.

Sketch:
- New launchd plist `~/.4lm/launchd/com.4lm.mcpo.plist`; wrapper script `bin/4lm-mcpo-start.sh` reads a config of stdio servers to bridge.
- New YAML at `~/.4lm/config/mcpo.yaml` listing stdio MCP servers; default ships Fetch only.
- `4lm` gains `mcp {start|stop|status|list|add|remove}` subcommands.
- `install.sh` adds `mcpo` to `requirements.txt` via `pipx`.
- WebUI: `4lm webui setup-mcp` PATCHes the OpenAPI server URL into OWUI's external-tools config.

**Phase complete when**: a fresh `4lm start` boots a third service on a local port; the Fetch tool appears in WebUI's tool drawer; asking "fetch https://example.com/" invokes Fetch and returns the body.

### Test Scenarios

To be detailed during phase planning. Minimum coverage:
- `4lm mcp status` reports the third service running.
- Fetch returns a 200 against `https://example.com/`.
- Adding a non-existent stdio command via `4lm mcp add` exits 1 with a clear error.

---

## Phase 5 — Native HTTP / SSE MCP — outline

Add remote MCP server registration to OpenWebUI via a 4lm subcommand. No new launchd service — OWUI is the MCP client; 4lm just orchestrates registration.

Sketch:
- `4lm mcp add-http <url> [--auth bearer:<token>|oauth]` → PATCHes the OWUI external-tools config.
- `4lm mcp list` shows both stdio (Phase 4) and HTTP servers uniformly.
- `docs/setup.md` documents a known-good example (Notion or similar).
- Token handling: store in `~/.4lm/config/mcp-tokens.d/<name>.token` mode 0600.

**Phase complete when**: registering Notion's hosted MCP via `4lm mcp add-http https://mcp.notion.com/mcp --auth oauth` lights up Notion tools in WebUI; subsequent restarts preserve the registration.

### Test Scenarios

To be detailed during phase planning. Minimum coverage:
- Bad URL → exit 1.
- Successful registration → tool visible in OWUI tool drawer (manual confirmation step).
- Token-file permissions enforced at 0600.

---

## Phase 6 — Custom stdio MCP server examples — outline

Ship `mcpo.yaml.example` entries that demonstrate how an operator can
wire their own stdio MCP servers (commonly: an Obsidian vault server
keyed on the operator's notes path). The operator's specific server
names are out of scope; this phase ships the template, not the data.

Sketch:
- Add a commented-out vault example to `mcpo.yaml.example` so the
  operator can copy + adapt — default disabled so installing 4lm does
  not silently expose private notes via MCP.
- Document the vault-path resolution + permissions in `docs/setup.md`,
  with a worked example.
- No new code beyond config + docs.

**Phase complete when**: an operator enabling a custom stdio entry and
running `4lm mcp restart` makes that server's tools available in WebUI;
the assistant can invoke the operator's custom tool.

### Test Scenarios

To be detailed during phase planning.

---

## Phase 7 — Artifacts and filesystem MCP — outline

The two largest Claude-Desktop-parity gaps. Each warrants its own SDD when reached.

- **Artifacts**: OpenWebUI's artifact surface is more primitive than Claude Desktop's. Investigate canvas-style preview support; possibly contribute upstream rather than fork.
- **Filesystem MCP**: Anthropic's filesystem MCP server is powerful and security-sensitive. Need a scoped root, write/read partitioning, and an audit log before defaulting it on.

**Phase complete when**: each is split out into its own SDD with full requirements; no inline detail here.

### Test Scenarios

Deferred to per-phase SDDs.

---

## Decision Log

| Considered | Decision | Reason |
|---|---|---|
| Flip `ENABLE_PERSISTENT_CONFIG=False` to make env vars authoritative every start | Rejected — keep persistent config on | Per-model function-calling is a DB row, not an env var. Disabling persistent config would erase admin-UI persistence for memory, RAG, defaults, etc. — too much collateral. |
| Skip MCP entirely from this SDD (per user pre-vote) | Pulled MCP back in as later phases | User asked to fold the out-of-scope items in as phases yet to detail. Tool calling first, MCP after, in shippable increments. |
| Use only Qwen3-Coder as the tool-calling model | Both models per-purpose | User-confirmed: Gemma 4 31B for general agentic, Qwen3-Coder for code-heavy. Per-purpose routing in the WebUI model dropdown. |
| Patch omlx if `tool_call_parser` isn't honoured | Fall back to Ollama profile instead | Forking the inference backend is out of scope; Ollama supports OpenAI-compat tools natively. |
| Run all WebUI setup as a one-shot at install time | Helper subcommand `4lm webui setup-tools` invoked by the operator post-admin-promotion | Admin token doesn't exist at install time; first-user promotion is operator-driven; idempotent subcommand is cleaner than a brittle install hook. |
| Native HTTP MCP only — skip mcpo | Phased: HTTP first impulse, then mcpo for Fetch | Native HTTP covers remote managed MCP. The Anthropic-stock toolset (filesystem/fetch/git) is stdio-only and needs mcpo. The user picked Fetch as the one default MCP server, which forces mcpo. |
| Filesystem MCP as Phase 4 default | Deferred to Phase 7 | Security-sensitive; needs scoped root + write/read partitioning. Premature. |
| Document setup-tools as a manual UI step instead of a subcommand | Ship the subcommand AND document the UI fallback | The subcommand is idempotent and bats-testable; the manual path is the safety net when the OWUI REST surface drifts. |

---

## Open Decisions

1. **Gemma 4 parser name** — which omlx enum value emits valid tool calls from Gemma 4 31B? Options: a dedicated `gemma` parser (if the omlx fork added one), `harmony`, fall back to template-driven. Impact: determines whether Gemma 4 is included in Phase 1 or deferred. Resolved by Phase 0.
2. **OWUI per-model PATCH endpoint shape** — is the canonical 0.9.2 endpoint `/api/v1/models/<id>/update`, `/api/v1/models/<id>`, or something else? Options: as written, alternative path, or "no REST surface — admin UI only". Impact: determines whether `cmd_webui_setup_tools` can ship or whether docs-only is the only path. Resolved by Phase 0 / early Phase 2 probe against the live WebUI.
3. **mlx-coding.yaml inclusion** — should the Qwen3-Coder-only `mlx-coding.yaml` profile also get the tool-call keys, given it uses the `mlx_lm` backend (single-model upstream)? `mlx_lm` may not parse the keys. Options: include and let validation flag it, exclude pending an `mlx_lm` probe, or drop the profile from scope. Impact: minor — only affects operators who explicitly switch to the upstream backend. Resolved by Phase 1 or deferred to a `mlx_lm` SDD.

---

## Out of Scope

- Patching the omlx backend itself.
- Cloud fallback providers (Z.ai, Kimi, Claude, Gemini) — see `specs/prd/4lm.md` Non-Goals.
- Multi-user OWUI configuration — single-user stack assumption preserved.
- Backups of `~/.4lm/openwebui-data/` (covered by operator's existing backup stack).
- Auto-promotion of the first OWUI user — `DEFAULT_USER_ROLE=pending` is preserved per AC15.
- Replacing OpenWebUI with a different frontend.
- Voice / speech-to-text — outside the agentic-tools scope.
