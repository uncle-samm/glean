# glean

A Gleam framework for building AI agents. Think [Vercel AI SDK](https://github.com/vercel/ai) or [pydantic-ai](https://github.com/pydantic/pydantic-ai) — but for Gleam, running on the BEAM.

[![Package Version](https://img.shields.io/hexpm/v/glean)](https://hex.pm/packages/glean)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glean/)

## Features

- **Type-safe model builders** — each model only exposes its supported parameters. The compiler catches unsupported settings.
- **10 providers, 78+ models** — OpenAI, Anthropic, Google Gemini, Mistral, DeepSeek, Qwen, Moonshot, MiniMax, OpenRouter, plus any OpenAI-compatible endpoint
- **Tool calling** — typed tools with dependency injection, JSON schema validation, retry logic, and error recovery
- **Real streaming** — SSE-based streaming with start/delta/end events for text, reasoning, and tool calls across all providers
- **Multi-turn conversations** — continue previous conversations with full message history
- **Middleware** — composable request/result transformers
- **Structured output** — JSON schema response format
- **Simulation testing** — deterministic multi-step agent testing without API calls
- **Pure Gleam** — no FFI, no macros, no magic. BEAM-only target.

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
    anthropic.haiku_4_5(api_key: "sk-ant-...")
    |> anthropic.temperature(0.7)
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
import glean/models/openai
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
        Error(_) -> Error("Could not parse city")
      }
    },
  )

  let my_agent =
    openai.gpt5(api_key: "sk-...")
    |> openai.temperature(0.3)
    |> openai.build
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
    anthropic.sonnet_4_6(api_key: "sk-ant-...")
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
let my_agent = agent.from(anthropic.haiku_4_5(api_key: key) |> anthropic.build)

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

### Structured output

Request JSON responses conforming to a schema:

```gleam
import glean/provider
import glean/schema

let response_schema = schema.object(
  properties: [
    #("name", schema.string()),
    #("age", schema.int()),
    #("hobbies", schema.array(of: schema.string())),
  ],
  required: ["name", "age", "hobbies"],
)

let my_agent =
  agent.from(model)
  |> agent.settings(provider.ModelSettings(
    ..provider.default_settings(),
    response_format: Some(provider.JsonFormat),
  ))
```

## Type-Safe Model Builders

Each provider has its own opaque type that only exposes the parameters that model supports. The compiler prevents unsupported settings.

```gleam
import glean/models/openai
import glean/models/openai_reasoning
import glean/models/anthropic
import glean/models/gemini

// GPT-5 supports temperature, top_p, seed, penalties, stops
let gpt = openai.gpt5(api_key: key)
  |> openai.temperature(0.7)
  |> openai.seed(42)
  |> openai.frequency_penalty(0.5)
  |> openai.build

// o3 is a reasoning model — only max_output_tokens and stop_sequences
let o3 = openai_reasoning.o3(api_key: key)
  |> openai_reasoning.max_output_tokens(4096)
  |> openai_reasoning.build
// openai_reasoning.temperature(o3, 0.5)  // COMPILE ERROR

// Claude supports temperature, top_p, top_k, stops
let claude = anthropic.opus_4_6(api_key: key)
  |> anthropic.temperature(0.5)
  |> anthropic.top_k(40)
  |> anthropic.build

// Gemini supports temperature, top_p, top_k, seed, stops
let gem = gemini.flash_2_5(api_key: key)
  |> gemini.temperature(0.8)
  |> gemini.seed(123)
  |> gemini.build
```

### Deprecated model handling

Deprecated models emit a compiler warning and automatically swap to their replacement at runtime:

```gleam
// Compiler warning: "gpt-4o is deprecated (shutdown: Feb 16, 2026). Use gpt5() instead."
let model = openai.gpt4o(api_key: key) |> openai.build
// At runtime: prints warning, uses "gpt-5" model ID
```

### Available Models

| Provider | Module | Current Models |
|---|---|---|
| OpenAI | `glean/models/openai` | GPT-5.4, GPT-5.4 Pro, GPT-5.3, GPT-5.2, GPT-5.2 Pro, GPT-5.1, GPT-5, GPT-5 Pro, GPT-OSS 120B/20B |
| OpenAI Reasoning | `glean/models/openai_reasoning` | o3, o3-mini, o3-pro, GPT-5 Mini, GPT-5 Nano |
| Anthropic | `glean/models/anthropic` | Claude Opus 4.6, Sonnet 4.6, Haiku 4.5 |
| Google Gemini | `glean/models/gemini` | Gemini 3.1 Pro, 3 Flash, 3.1 Flash Lite, 2.5 Pro/Flash/Flash Lite, image models |
| Mistral | `glean/models/mistral` | Large 3, Medium 3.1, Small 3.2, Magistral, Codestral, Devstral, Ministral 3B/8B/14B |
| DeepSeek | `glean/models/deepseek` | DeepSeek Chat, V3.1 |
| DeepSeek Reasoning | `glean/models/deepseek_reasoning` | Reasoner, R1 |
| Qwen | `glean/models/qwen` | Qwen 3.5 Plus/Flash, Qwen 3 Max/Plus, QwQ Plus, Qwen 3 Coder |
| Moonshot | `glean/models/moonshot` | Kimi K2.5, K2, K2 Thinking |
| MiniMax | `glean/models/minimax` | MiniMax M2.5, M2.1, M2.1 Lightning, M2, M1 |
| OpenRouter | `glean/providers/openrouter` | Any model via `"provider/model"` format |

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

Retries apply to `ToolExecutionError` and `ToolInputValidationError`. `ToolNotFound` is immediately fatal.

## Provider Configuration

For advanced use cases, configure providers directly with `ProviderConfig`:

```gleam
import glean/providers/config

let cfg = config.new(api_key: "sk-...", model: "gpt-5")
  |> config.base_url("https://my-proxy.example.com/v1")
  |> config.timeout(120_000)        // 2 minute timeout
  |> config.max_retries(5)          // retry 429/5xx up to 5 times
  |> config.initial_retry_delay(500) // start backoff at 500ms
  |> config.headers([#("X-Custom", "value")])
```

All providers include:
- **HTTP timeout** — configurable per-provider (default 60s)
- **Automatic retry** — exponential backoff on 429 (rate limit) and 5xx (server errors)
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
    anthropic.gleam       Claude models
    gemini.gleam          Gemini models
    deepseek.gleam        DeepSeek chat models
    deepseek_reasoning.gleam  DeepSeek reasoning models
    mistral.gleam         Mistral models
    moonshot.gleam        Moonshot/Kimi models
    qwen.gleam            Qwen models
    minimax.gleam         MiniMax models

  providers/            Provider implementations (internal)
  testing/              Test infrastructure
    provider.gleam        Scripted test provider
    function_provider.gleam  Function-backed test provider
    simulation.gleam      Deterministic simulation engine
```

## Target

Glean runs on the **BEAM** (Erlang VM) only. JavaScript is not supported — the framework depends on `gleam_httpc`, `gleam_erlang`, and `gleam_otp` for HTTP, process management, and SSE streaming.

## Development

```sh
gleam build    # Compile
gleam test     # Run 123 unit tests (no API keys needed)

# Integration tests (set API keys)
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
export GEMINI_API_KEY=AIza...
gleam test     # Runs all tests including integration
```

## Publishing

```sh
# Store your Hex API key
echo "your-hex-api-key" > .hex_api_key

# Full release: push, tag, publish to Hex
make release

# Or individual steps
make push      # Push main to origin
make tag       # Create and push version tag
make publish   # Publish to Hex
```

## License

MIT
