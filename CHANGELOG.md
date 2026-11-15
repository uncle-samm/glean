# Changelog

## Unreleased

This release has breaking changes, listed under Changed. The next version
is 0.3.0.

### Fixed

- A tool that panics, or whose process dies, no longer takes the whole run
  (and the calling process) down. Every tool call runs in its own process;
  a crash is sent back to the model as an error result and the other calls
  carry on.
- A dropped connection, a reset or a response `httpc` can't parse no longer
  raises an exception in the process running the agent. Requests that
  aren't streamed now go through glean's own `httpc` layer, which returns
  every failure as an error and retries it like a failed connection.
- Streams from OpenAI-compatible providers and Gemini now send the start
  and end events (`TextStart`/`TextEnd`, `ReasoningStart`/`ReasoningEnd`)
  the README promised, and `ToolCallEnd` for every tool call. Gemini's
  parts each have their own id instead of all sharing `"gemini"`.
- Gemini: reasoning is kept in a streamed result's content, as it is
  without streaming.
- Gemini: `tool_choice` is sent (`toolConfig`), as are `presence_penalty`,
  `frequency_penalty`, `reasoning_effort` (`thinkingLevel`) and
  `config.extra_body_field` fields, all of which were dropped before.
- Claude: `config.extra_body_field` fields are sent; they were dropped.
- Claude: structured output with `schema.int_range` or
  `schema.string_with_length` no longer fails with a 400. Claude's
  structured outputs reject those keywords, so the limits are written into
  the field descriptions instead, and glean still checks them in the
  answer.
- Claude Opus 4.7 and 4.8 now think when `reasoning_effort` is set; before,
  the effort was sent but thinking stayed off.
- Files: a file a provider can't take is a `ConfigError` instead of being
  sent as an image. Claude now takes PDFs and plain text as documents;
  OpenAI-compatible providers take PDFs and WAV/MP3 audio.
- Mistral: answers that arrive as a list of content parts (its reasoning
  models) are read instead of failing to decode.
- `stream.collect_tool_calls` matches deltas to their call by id, so tool
  calls that stream at the same time no longer mix their arguments.
- A structured answer that was cut off at the output token limit says so,
  instead of "Invalid JSON".
- `schema.nullable` and `schema.one_of` are written as `anyOf`. `oneOf`
  rejected values that match two variants (3 is an integer and a number),
  which `validate` accepts, and OpenAI's strict mode doesn't take `oneOf`.
- Finish reasons: `function_call` is `ToolCalls`; OpenRouter's `error` and
  Gemini's `MALFORMED_FUNCTION_CALL` are the new `FinishError`; Gemini's
  other safety reasons are `ContentFilter`.
- `retry-after-ms` and fractional `Retry-After` values are honoured.
- The Gleam version requirement is `>= 1.14.0`, which is what the current
  `gleam_stdlib` needs; it said 1.11.

### Added

- `agent.tool_timeout(ms)`: a tool call that takes longer is stopped and
  reported to the model as an error result.
- `agent.output_retries(n)`: when the final answer doesn't match the JSON
  schema, the model is told what is wrong and asked again (once by
  default).
- `simulation.run_agent(simulation, agent, deps)`: run a script against a
  real agent. The agent loop and the agent's own tools run, and the
  simulation fails when a tool returns something other than its scripted
  result. `simulation.run` still walks the script alone.
- `glean/usage`: `Usage` gains `cache_read_tokens`, `cache_write_tokens`
  and `reasoning_tokens`, read from every provider that reports them.
- Claude prompt caching: `anthropic.prompt_caching` on the model builders
  (or `config.prompt_caching`).
- `show_reasoning` on the Claude and Gemini builders
  (`ModelSettings.include_reasoning`): Claude and Gemini only return the
  text of their reasoning when asked. `reasoning_effort` on the Gemini
  builder. Two more effort levels, `XHighEffort` and `MaxEffort`.
- `stream.StreamError`: sent to the stream callback when a streamed run
  fails, just before `run.stream` returns the error.
- Images from Gemini's image models: `GeneratedFile` content, kept in the
  conversation as `AssistantFile` and sent back to Gemini on the next turn.
- Claude Fable 5.2 (`anthropic.fable_5_2`).
- Requests that time out are retried like failed connections, for streams
  too (before the first event).
- CI runs the tests on OTP 27 and 29.

### Changed

- **Breaking:** `Usage` has three new fields and lives in `glean/usage`.
  Code that builds a `Usage` should call `usage.new(input_tokens:,
  output_tokens:)`; `stream.Usage` is still there as a type alias.
  `input_tokens` and `output_tokens` are now totals on every provider:
  Claude's input includes cached tokens, and Gemini's output includes
  thinking tokens.
- **Breaking:** `OutputValidationError` carries `text`, `finish_reason`,
  `messages` and `usage` next to `errors`, and `MaxStepsExceeded` carries
  `usage`. Patterns on them need `..`.
- **Breaking:** new variants: `FinishError` (`FinishReason`),
  `StreamError` (`StreamEvent`), `GeneratedFile` (`GeneratedContent`),
  `AssistantFile` (`AssistantContent`), `XHighEffort` and `MaxEffort`
  (`ReasoningEffort`). Exhaustive `case` expressions on these types need a
  branch for them. `ModelSettings` has a new field, `include_reasoning`,
  and `Agent` has `tool_timeout_ms` and `output_retries`.
- **Breaking:** `openai_compatible.encode_request` returns a `Result`, and
  `anthropic.encode_request` takes the provider config instead of the
  model name.
- Tools run in their own process, so a tool can't read the calling
  process's dictionary or mailbox. Pass what it needs through `deps`.
- The default request timeout is 10 minutes instead of 60 seconds. A long
  answer from a reasoning model takes minutes, and a timeout threw the
  whole answer away.
- `gleam_httpc` and `gleam_http` are no longer dependencies. The FFI
  module is now `src/glean_http_ffi.erl` and does both kinds of request.
- Dependencies updated: `gleam_stdlib` 1.0.5, `gleeunit` 1.11.0.

## 0.2.0 - 2026-11-06

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
- `MaxStepsExceeded` carries the conversation so far (`messages`), so the
  work done before the limit isn't lost.
- Tool arguments that aren't a JSON object are sent back to Anthropic and
  Gemini wrapped as `{"invalid_arguments": "..."}` instead of being replaced
  by `{}`; Gemini tool arguments are decoded without going through
  `Dynamic`.

### Added

- `run.stream_messages` and `run.continue_stream`: streaming versions of
  `run.generate_messages` and `run.continue`, for multi-turn streaming.
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
- Streaming errors keep the HTTP status and body (a bad key is a 401,
  not "stream closed early"), and streaming requests are retried like
  normal ones before the first event arrives.
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
- Streaming no longer uses `httpp`. A small Erlang FFI over OTP `httpc`
  (`src/glean_http_stream_ffi.erl`) plus a Gleam SSE parser replace it,
  which drops httpp, hackney and seven rebar3 packages from the dependency
  tree. The unused `gleam_otp` dependency is removed too.
- `make release` runs the format check and tests first. The publish script
  takes `HEXPM_API_KEY` from the environment and falls back to
  `.hex_api_key`.

## 0.1.0

First release.
