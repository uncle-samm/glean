# Changelog

## 0.2.0 (unreleased)

This release has breaking changes. Most code needs new model constructor
names; the compiler points at each one.

### Fixed

- Streaming no longer turns API errors, timeouts or cut-off streams into
  empty successes. They return `ProviderError` or `Timeout`.
- `run.continue` now includes the model's last answer in the history.
- Tool schemas with no properties (`schema.object(properties: [], required: [])`)
  no longer crash.
- Schema properties keep the order you wrote them in.
- The Gemini API key is sent in the `x-goog-api-key` header instead of the URL.
- HTTP failures now say why they failed instead of "HTTP request failed".

### Added

- Tool arguments are validated against the tool's schema before the tool
  runs; invalid arguments go back to the model as an error result.
- Calls to unknown tools go back to the model with the list of available
  tools instead of ending the run.
- Tool calls in the same step run concurrently and keep the model's order.
  `agent.sequential_tool_calls` turns this off.
- Structured output: `agent.json_output(schema:, name:)`, validated with
  `schema.validate_json`, for OpenAI-compatible providers, Gemini and Claude.
- Reasoning: Claude thinking blocks (with signatures) and redacted thinking
  are kept and sent back; `reasoning_content` from DeepSeek, Kimi and Qwen is
  streamed and, where the API requires it, sent back.
- `reasoning_effort` on reasoning model builders (`reasoning_effort` for
  OpenAI-compatible APIs, `output_config.effort` for Claude).
- `custom(api_key:, model:)` and `configure(fn(ProviderConfig))` on every
  model builder, and `default_config` on every provider module.
  `glean/providers/*` are now public.
- `config.extra_body_field` for provider-specific request fields.
- Token usage in OpenAI-compatible streams (`stream_options.include_usage`).
- Retries with jitter, `Retry-After` support, and retries for failed
  connections, 408 and 409.
- Micro-benchmarks: `gleam run -m glean_bench` (also run in CI).
- CHANGELOG and LICENSE files.

### Changed

- Model catalogs refreshed against provider docs (November 2026). New:
  Claude Fable 5.1/5, Opus 5.5/5/4.8/4.7, Sonnet 5.5/5, Haiku 5.5; GPT-6.1
  Terra, GPT-5.5, GPT-5.4 mini/nano; Gemini 3.8/3.6 Flash, 3.5/3.1
  Flash-Lite; Mistral Large 4, Medium 3.5, Small 4; DeepSeek V4.1 Flash and
  V4 Pro; Qwen3.8 Max/Flash, Qwen3.7 Plus; Kimi K3, K2.7 Code, K2.6;
  MiniMax M3, M3.1 Flash.
- Parameters now match what each model accepts:
  - `glean/models/anthropic` (current Claude models) drops `temperature`,
    `top_p` and `top_k`, which those models reject. Older models that still
    take them moved to `glean/models/anthropic_sampling`.
  - GPT-5 and later moved to `glean/models/openai_reasoning` (no
    temperature or stop sequences). `glean/models/openai` now holds the
    GPT-4.1 and GPT-4o families.
  - MiniMax drops `temperature` and `top_p`, which MiniMax documents as
    having no effect.
  - DeepSeek's two modules now pick thinking off/on for the same models.
- Deprecated models keep the model ID you asked for (with a compiler
  warning) instead of silently switching to another model and printing to
  stdout. `model.deprecation_warning` is removed.
- Retired models are removed: DeepSeek `deepseek-chat`/`deepseek-reasoner`,
  Kimi K2/K2.5 and `moonshot-v1`, Claude 3.x, Opus 4/4.1, Sonnet 4,
  Gemini 2.0 and 3 Pro preview, MiniMax M1/M2.x Lightning, Mistral Nemo,
  OpenAI o1 and GPT-5 "pro" models (Responses API only).
- DeepSeek base URL is `https://api.deepseek.com`; MiniMax base URL is
  `https://api.minimax.io/v1`.
- `make release` runs the format check and tests first, and the publish
  script reads `HEXPM_API_KEY` from the environment instead of a file.

## 0.1.0

First release.
