# glean

A Gleam framework for building AI agents. Think [Vercel AI SDK](https://github.com/vercel/ai) or [pydantic-ai](https://github.com/pydantic/pydantic-ai) — but for Gleam, running on the BEAM.

[![Package Version](https://img.shields.io/hexpm/v/glean)](https://hex.pm/packages/glean)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glean/)

## Features

- **Type-safe model builders** — each model only exposes its supported parameters. The compiler catches unsupported settings.
- **10 providers** — OpenAI, Anthropic, Google Gemini, Mistral, DeepSeek, Qwen, Moonshot, MiniMax, OpenRouter, plus any OpenAI-compatible endpoint. Every builder has `custom(model:)` for model IDs released after this version.
- **Tool calling** — typed tools with dependency injection, JSON Schema definitions, arguments validated before your tool runs, parallel execution, retries, and error recovery
- **Structured output** — ask for JSON matching a schema; glean validates the answer
- **Reasoning** — thinking/reasoning content from Claude, Gemini, DeepSeek, Kimi and Qwen is streamed and sent back on later turns as each API requires
- **Real streaming** — SSE-based streaming with start/delta/end events for text, reasoning, and tool calls across all providers
- **Multi-turn conversations** — continue previous conversations with full message history
- **Middleware** — composable request/result transformers
- **Simulation testing** — deterministic multi-step agent testing without API calls
- **Pure Gleam** — no FFI, no macros, no magic. BEAM-only target.

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## Installation

```sh
gleam add glean
```

## Quick Start

### Simple text generation

```gleam
import gleam/io
import glean/agent
import glean/error
import glean/models/anthropic
import glean/run

pub fn main() {
  let my_agent =
    anthropic.sonnet_5_5(api_key: "sk-ant-...")
    |> anthropic.max_output_tokens(1024)
    |> anthropic.build
    |> agent.from
    |> agent.system("You are a helpful assistant.")

  case run.generate(my_agent, Nil, "What is the capital of France?") {
    Ok(result) -> io.println(result.text)
    Error(err) -> io.println("Error: " <> error.to_string(err))
  }
}
```

### With tools

```gleam
import gleam/dynamic/decode
import gleam/io
import gleam/json
import glean/agent
import glean/error
import glean/models/openai_reasoning
import glean/run
import glean/schema
import glean/tool

pub fn main() {
  let weather_tool = tool.new(
    name: "get_weather",
    description: "Get the current weather for a city",
    input_schema: schema.object(
      properties: [
        #("city", schema.string() |> schema.describe("City name")),
      ],
      required: ["city"],
    ),
    execute: fn(_ctx, args_json) {
      let decoder = {
        use city <- decode.field("city", decode.string)
        decode.success(city)
      }
      case json.parse(args_json, decoder) {
        Ok(city) -> Ok("Weather in " <> city <> ": 22C, sunny")
        Error(_) ->
          Error(error.ToolExecutionError(
            tool_name: "get_weather",
            tool_call_id: "",
            reason: "Could not parse city",
          ))
      }
    },
  )

  let my_agent =
    openai_reasoning.gpt5_5(api_key: "sk-...")
    |> openai_reasoning.build
    |> agent.from
    |> agent.system("You are a weather assistant. Use the get_weather tool.")
    |> agent.tools(tool.toolset([weather_tool]))

  case run.generate(my_agent, Nil, "What's the weather in Tokyo?") {
    Ok(result) -> io.println(result.text)
    Error(err) -> io.println("Error: " <> error.to_string(err))
  }
}
```

The agent loop automatically handles the tool call cycle: generate -> tool call -> tool result -> generate again until the model responds with text.

Before a tool runs, its arguments are checked against `input_schema`. Invalid arguments, unknown tool names and tool errors are all sent back to the model as error results so it can correct itself; they don't end the run. When the model asks for several tools at once they run concurrently, and results are returned in the order the model asked for them (use `agent.sequential_tool_calls` to turn this off).

### Structured output

```gleam
import gleam/option.{Some}

let person =
  schema.object(
    properties: [#("name", schema.string()), #("age", schema.int())],
    required: ["name", "age"],
  )

let my_agent =
  model
  |> agent.from
  |> agent.json_output(schema: Some(person), name: Some("person"))

// result.text is JSON that matches `person`; anything else fails the run
// with OutputValidationError.
let assert Ok(result) = run.generate(my_agent, Nil, "Invent a person")
```

OpenAI-compatible providers use `response_format` (with `strict: true` when the schema allows it), Gemini uses `responseJsonSchema`, and Claude uses `output_config.format`.

### Streaming

```gleam
import gleam/int
import gleam/io
import glean/agent
import glean/models/anthropic
import glean/run
import glean/stream

pub fn main() {
  let my_agent =
    anthropic.sonnet_5_5(api_key: "sk-ant-...")
    |> anthropic.build
    |> agent.from

  let _result = run.stream(my_agent, Nil, "Tell me a story", fn(event) {
    case event {
      stream.TextDelta(_, delta) -> io.print(delta)
      stream.ToolCallStart(_, _, tool_name) ->
        io.println("[Calling " <> tool_name <> "...]")
      stream.Finish(_, usage) ->
        io.println("\nTokens: " <> int.to_string(usage.input_tokens + usage.output_tokens))
      _ -> Nil
    }
  })
}
```

All providers support real SSE streaming — text arrives token-by-token. Events follow the start/delta/end pattern:

| Event | Description |
|---|---|
| `TextStart` / `TextDelta` / `TextEnd` | Text content tokens |
| `ReasoningStart` / `ReasoningDelta` / `ReasoningEnd` | Chain-of-thought reasoning |
| `ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` | Tool call streaming |
| `ToolResultEvent` / `ToolErrorEvent` | Tool execution results (emitted by agent loop) |
| `StepStart` / `StepEnd` | Agent loop step boundaries |
| `Finish` | Generation complete with usage stats |

### Multi-turn conversation

```gleam
let my_agent = agent.from(anthropic.haiku_5_5(api_key: key) |> anthropic.build)

// First turn
let assert Ok(result1) = run.generate(my_agent, Nil, "My name is Sam.")

// Continue — previous messages are preserved
let assert Ok(result2) = run.continue(my_agent, Nil, result1, "What's my name?")
// result2.text contains "Sam"
```

### Dependency injection

Tools receive a typed `deps` value — inject database connections, HTTP clients, config, or any state your tools need:

```gleam
import glean/tool.{type ToolContext}

type Deps {
  Deps(db: Database, api_base_url: String)
}

let lookup_tool = tool.new(
  name: "lookup_user",
  description: "Look up a user by ID",
  input_schema: schema.object(
    properties: [#("user_id", schema.string())],
    required: ["user_id"],
  ),
  execute: fn(ctx: ToolContext(Deps), args_json) {
    let db = ctx.deps.db
    // ... use db to look up user
    Ok("User found: Sam")
  },
)

let my_agent = agent.from(model) |> agent.tools(tool.toolset([lookup_tool]))
let deps = Deps(db: my_db, api_base_url: "https://api.example.com")

// deps flows through to every tool execution
run.generate(my_agent, deps, "Look up user 123")
```

## Type-Safe Model Builders

Each provider has its own opaque type that only exposes the parameters that model supports. The compiler prevents unsupported settings.

```gleam
import glean/models/anthropic
import glean/models/gemini
import glean/models/openai_reasoning
import glean/provider
import glean/providers/config

// GPT-5 and later are reasoning models: no temperature, but reasoning effort
let gpt = openai_reasoning.gpt5_5(api_key: key)
  |> openai_reasoning.reasoning_effort(provider.HighEffort)
  |> openai_reasoning.build
// openai_reasoning.temperature(gpt, 0.5)  // COMPILE ERROR

// Current Claude models reject sampling parameters, so they aren't offered
let claude = anthropic.opus_5_5(api_key: key)
  |> anthropic.reasoning_effort(provider.MediumEffort)
  |> anthropic.build

// Gemini supports temperature, top_p, top_k, seed, stops
let gem = gemini.flash_3_8(api_key: key)
  |> gemini.temperature(0.8)
  |> gemini.seed(123)
  |> gemini.build
```

### New models, proxies and timeouts

Every model module has `custom` for model IDs that glean doesn't list yet, and `configure` to change the provider configuration:

```gleam
let model =
  anthropic.custom(api_key: key, model: "claude-next")
  |> anthropic.configure(fn(cfg) {
    cfg
    |> config.base_url("https://my-proxy.example.com/v1")
    |> config.timeout(120_000)
  })
  |> anthropic.build
```

### Deprecated and retired models

Models with an announced retirement date are marked `@deprecated`, so the compiler warns you; glean still calls the model you asked for. Retired models are removed, so code that uses them stops compiling instead of failing at runtime.

### Available Models

| Provider | Module | Models |
|---|---|---|
| OpenAI (reasoning) | `glean/models/openai_reasoning` | GPT-6.1 Terra, GPT-5.5, GPT-5.4 (+ mini, nano), GPT-5.2, GPT-5.1, GPT-5 (+ mini, nano), o3, o3-mini, o4-mini |
| OpenAI (sampling) | `glean/models/openai` | GPT-4.1 (+ mini, nano), GPT-4o (+ mini) |
| Anthropic | `glean/models/anthropic` | Claude Fable 5.1, Fable 5, Opus 5.5, Opus 5, Opus 4.8, Opus 4.7, Sonnet 5.5, Sonnet 5, Haiku 5.5 |
| Anthropic (sampling) | `glean/models/anthropic_sampling` | Claude Opus 4.6, Sonnet 4.6, Haiku 4.5, Opus 4.5, Sonnet 4.5 (retiring) |
| Google Gemini | `glean/models/gemini` | Gemini 3.1 Pro, 3.8 Flash, 3.6 Flash, 3.5 Flash-Lite, 3.1 Flash-Lite, 3 Flash, 2.5 Pro/Flash/Flash-Lite, image models |
| Mistral | `glean/models/mistral` | Large 4, Medium 3.5, Small 4, Large 3, Magistral, Codestral, Devstral, Ministral 3B/8B/14B |
| DeepSeek | `glean/models/deepseek`, `glean/models/deepseek_reasoning` | V4.1 Flash, V4 Pro (thinking off / on) |
| Qwen | `glean/models/qwen` | Qwen3.8 Max, Qwen3.7 Plus, Qwen3.8 Flash, Qwen3.5 Plus/Flash, Qwen3 Max, Qwen3 Coder Plus, QwQ Plus |
| Moonshot | `glean/models/moonshot` | Kimi K3, K2.7 Code (+ high-speed), K2.6 |
| MiniMax | `glean/models/minimax` | MiniMax M3, M3.1 Flash, M2.7 and M2.5 (retiring Nov 18, 2026) |
| OpenRouter | `glean/providers/openrouter` | Any model via `"provider/model"` format |

The catalog was checked against provider docs in November 2026. Model lists change quickly; use `custom` when a model you need is missing.

## Middleware

Transform requests before they reach the provider or results after they come back:

```gleam
import gleam/int
import gleam/io
import gleam/list
import glean/middleware

// Log every request
let logging = middleware.request_middleware(fn(req) {
  io.println("Sending " <> int.to_string(list.length(req.messages)) <> " messages")
  req
})

// Transform results
let postprocess = middleware.result_middleware(fn(result) {
  result
})

// Chain middlewares (left-to-right) and apply to a provider
let enhanced = middleware.apply(my_provider, middleware.chain([logging, postprocess]))
```

## Simulation Testing

Test multi-step agent workflows deterministically, without API calls:

```gleam
import glean/testing/provider.{ScriptedToolCall}
import glean/testing/simulation.{ScriptedToolExecution, ToolSuccess}

let state =
  simulation.new("weather lookup", "What's the weather?")
  |> simulation.with_system_prompt("You are a weather bot.")
  |> simulation.then_call_tools([
    ScriptedToolExecution(
      call: ScriptedToolCall(
        id: "call_1",
        name: "get_weather",
        arguments: "{\"city\":\"Tokyo\"}",
      ),
      result: ToolSuccess("22C, sunny"),
    ),
  ])
  |> simulation.then_respond_text("The weather in Tokyo is 22C and sunny!")
  |> simulation.run
  |> simulation.assert_passed

// state.step_count == 2
```

You can also use `testing/provider.test_provider` for scripted responses, or `testing/function_provider.function_provider` for full control:

```gleam
import glean/testing/provider

// Returns responses in sequence
let fake = provider.test_provider([
  provider.TextResponse("Hello!"),
  provider.ToolCallResponse([
    provider.ScriptedToolCall(id: "1", name: "search", arguments: "{}"),
  ]),
  provider.TextResponse("Here are the results."),
])
```

## Tool Retry

Tools can be configured with automatic retry on execution errors:

```gleam
let flaky_tool = tool.new(
  name: "external_api",
  description: "Call an external API that may fail",
  input_schema: schema.object(properties: [], required: []),
  execute: fn(ctx, _args) {
    // ctx.retry tells you which attempt this is (0, 1, 2...)
    // ctx.max_retries tells you the limit
    call_external_api()
  },
)
|> tool.with_max_retries(3)
```

Retries apply to any error returned by the tool's `execute` function. Once retries run out, the error is sent back to the model so it can recover.

## Provider Configuration

Model builders take a configuration change through `configure` (see above). You can also build a provider directly from a `ProviderConfig`:

```gleam
import glean/providers/config

import glean/providers/openai

let provider = openai.default_config(api_key: "sk-...", model: "gpt-5.5")
  |> config.base_url("https://my-proxy.example.com/v1")
  |> config.timeout(120_000)        // 2 minute timeout
  |> config.max_retries(5)          // retry 429/5xx up to 5 times
  |> config.initial_retry_delay(500) // start backoff at 500ms
  |> config.headers([#("X-Custom", "value")])
  |> openai.from_config
```

All providers include:
- **HTTP timeout** — configurable per-provider (default 60s)
- **Automatic retry** — exponential backoff with jitter on 408, 409, 429, 5xx and failed connections, honouring `Retry-After`
- **Custom headers** — add any headers to requests

## Architecture

```
glean/
  agent.gleam           Agent builder (immutable config, reusable)
  run.gleam             Pure recursive execution loop
  tool.gleam            Tool definition with dependency injection
  provider.gleam        Provider interface (function records)
  model.gleam           Type-safe Model bridge
  message.gleam         Conversation message types
  schema.gleam          JSON Schema builder (opaque type)
  stream.gleam          Streaming event types
  middleware.gleam      Request/result transformers
  error.gleam           Explicit error types

  models/               Per-provider type-safe model builders
    openai.gleam          GPT chat models
    openai_reasoning.gleam  o-series and reasoning models
    anthropic.gleam       Current Claude models
    anthropic_sampling.gleam  Older Claude models with sampling parameters
    gemini.gleam          Gemini models
    deepseek.gleam        DeepSeek, thinking off
    deepseek_reasoning.gleam  DeepSeek, thinking on
    mistral.gleam         Mistral models
    moonshot.gleam        Moonshot/Kimi models
    qwen.gleam            Qwen models
    minimax.gleam         MiniMax models

  providers/            Provider implementations and ProviderConfig
  testing/              Test infrastructure
    provider.gleam        Scripted test provider
    function_provider.gleam  Function-backed test provider
    simulation.gleam      Deterministic simulation engine
```

## Performance

Network time dominates real agent runs; glean's own work is small. Numbers from `gleam run -m glean_bench` on a GitHub Actions runner (OTP 29):

| Benchmark | Mean |
|---|---|
| Encode a 100-message request (OpenAI / Anthropic) | 38 µs / 84 µs |
| Encode a 1000-message request (OpenAI / Anthropic) | 0.5 ms / 1.1 ms |
| Decode a 10 KB OpenAI response | 30 µs |
| Validate a 500-item array against a schema | 1.2 ms |
| Process 1000 streamed SSE chunks | 5.6 ms |
| 10-step tool loop with the test provider | 35 µs |

The benchmarks run in CI on every push.

## Target

Glean runs on the **BEAM** (Erlang VM) only. JavaScript is not supported — the framework depends on `gleam_httpc`, `gleam_erlang`, and `gleam_otp` for HTTP, process management, and SSE streaming.

## Development

```sh
gleam build    # Compile
gleam test     # Run the unit tests (no API keys needed; integration tests are no-ops without keys)

# Integration tests (set API keys)
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export GEMINI_API_KEY=AIza...
gleam test     # Runs all tests including integration

gleam run -m glean_bench   # Micro-benchmarks (encoding, decoding, validation, run loop)
```

## Publishing

```sh
# Full release: runs the tests, pushes, tags, and publishes to Hex
make release
```

The publish step reads `HEXPM_API_KEY` from the environment, or the git-ignored `.hex_api_key` file.

## License

MIT
