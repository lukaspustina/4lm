# Measure the knob before building the schema for it

Date: 2026-08-17 · SDD: `specs/done/sdd/qwen38-profile-2026-08-17.md`

Qwen3.8-27B defaults its chat template to `reasoning_effort: xhigh`, which made
a single prompt run past 600 s. The obvious fix was to extend the profile
schema so a profile could set it — a plausible, well-scoped piece of work.

**What was done instead:** a throwaway second omlx instance on another port
with an isolated `HOME` and a one-model directory, run against the live system
without touching it. Three configurations, same prompt: unconfigured (>600 s),
the key in the request body (114 s and 128 s), the key in
`model_settings.json` (336 s). The server logged `Loaded settings for 1 models`,
so it read the file — and ignored that key.

**What that bought:** the schema extension would have shipped a field with no
effect. It was cancelled, the finding went into the profile headers and
`CLAUDE.md`, and the actual lever (client-side, per request) is now written
down where the next person will look.

**Two traps on the way**, both of which produced a *false negative* that looked
like a real answer:
- The first probe reused the live `HOME`, so a stale server on the port
  answered the requests. The log said `Address already in use`; the timing said
  "the setting does not work". Check what actually served the request.
- The second probe wrote a flat `{"model": {...}}` settings file. The real
  format is `{"version": 1, "models": {...}}`, and the giveaway was
  `Loaded settings for 0 models`. A config the tool silently ignores measures
  nothing.

**Generalizes to:** any "add a config field to control X" task where X is
enforced by a component you do not own. Cost here was ~40 minutes and one
15 GB download against a speculative field plus its tests, docs and schema
entry. The question to answer first is always the same: does the knob turn?
