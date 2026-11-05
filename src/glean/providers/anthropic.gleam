//// Anthropic provider (Claude models), using the Messages API.
////
//// Thinking blocks (including redacted ones) are decoded with their
//// signatures and sent back unchanged on the next turn, which Claude
//// requires when thinking and tool use are combined.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string_tree.{type StringTree}
import glean/error.{type FinishReason, type GleanError}
import glean/json_value
import glean/message.{type Message}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type GeneratedContent,
  type Provider, GenerateResult, GeneratedRedactedReasoning, GeneratedReasoning,
  GeneratedText, GeneratedToolCall, Provider,
}
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils
import glean/providers/sse
import glean/schema
import glean/stream.{type StreamEvent, type Usage, Usage}
import httpp/sse as httpp_sse

const base_url = "https://api.anthropic.com/v1"

const anthropic_version = "2023-06-01"

/// Used when the caller doesn't set `max_output_tokens`
/// (the Messages API requires `max_tokens`).
const default_max_tokens = 8192

/// The default configuration for this provider. Change it with the
/// `glean/providers/config` setters, then pass it to `from_config`.
pub fn default_config(
  api_key api_key: String,
  model model: String,
) -> ProviderConfig {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
}

/// Create an Anthropic provider.
///
/// ## Example
///
/// ```gleam
/// let provider = anthropic.new(api_key: "sk-ant-...", model: "claude-sonnet-5-5")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  default_config(api_key: api_key, model: model)
  |> from_config
}

/// Create an Anthropic provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  Provider(
    name: "anthropic",
    model_id: cfg.model,
    generate: fn(request) { do_generate(cfg, request) },
    stream: fn(request, on_event) { do_stream(cfg, request, on_event) },
  )
}

// --- Non-streaming generation ---

fn do_generate(
  config: ProviderConfig,
  gen_request: GenerateRequest,
) -> Result(GenerateResult, GleanError) {
  use body <- result.try(encode_request(config.model, gen_request, False))
  use response_body <- result.try(http_utils.send_post(
    config,
    "anthropic",
    config.base_url <> "/messages",
    body,
    auth_headers(config),
  ))
  decode_response(config.model, response_body)
}

fn auth_headers(config: ProviderConfig) -> List(#(String, String)) {
  [
    #("x-api-key", config.api_key),
    #("anthropic-version", anthropic_version),
  ]
}

// --- Streaming generation ---

/// One content block being assembled from stream events.
type Block {
  TextBlock(text: StringTree)
  ThinkingBlock(text: StringTree, signature: StringTree)
  RedactedThinkingBlock(data: String)
  ToolUseBlock(id: String, name: String, args: StringTree)
  /// A block type glean doesn't use (e.g. server tool results).
  IgnoredBlock
}

/// Streaming accumulator — threaded through a pure receive loop.
/// Blocks are kept newest first (keyed by block index) and reversed once at
/// the end, so the result keeps the order Claude produced them in.
type StreamAccumulator {
  StreamAccumulator(
    blocks: List(#(Int, Block)),
    finish_reason: FinishReason,
    usage: Usage,
  )
}

fn do_stream(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  use body <- result.try(encode_request(config.model, gen_request, True))
  let headers =
    list.append(
      auth_headers(config),
      list.map(config.headers, fn(h) { #(h.0, h.1) }),
    )

  case
    sse.start_stream(
      config.base_url <> "/messages",
      headers,
      body,
      config.timeout_ms,
    )
  {
    Error(msg) ->
      Error(error.ProviderError(
        provider: "anthropic",
        model: config.model,
        status: 0,
        message: "Streaming failed: " <> msg,
      ))
    Ok(#(event_subject, manager_subject)) -> {
      let acc =
        StreamAccumulator(
          blocks: [],
          finish_reason: error.Stop,
          usage: stream.zero_usage(),
        )
      use final_acc <- result.try(anthropic_stream_loop(
        event_subject,
        manager_subject,
        acc,
        on_event,
        config.model,
        config.timeout_ms,
      ))
      Ok(GenerateResult(
        content: blocks_to_content(list.reverse(final_acc.blocks)),
        finish_reason: final_acc.finish_reason,
        usage: final_acc.usage,
        model_id: config.model,
      ))
    }
  }
}

fn blocks_to_content(blocks: List(#(Int, Block))) -> List(GeneratedContent) {
  list.filter_map(blocks, fn(entry) {
    case entry.1 {
      TextBlock(text) -> Ok(GeneratedText(text: string_tree.to_string(text)))
      ThinkingBlock(text, signature) ->
        Ok(GeneratedReasoning(
          text: string_tree.to_string(text),
          signature: case string_tree.to_string(signature) {
            "" -> None
            sig -> Some(sig)
          },
        ))
      RedactedThinkingBlock(data) -> Ok(GeneratedRedactedReasoning(data: data))
      ToolUseBlock(id, name, args) ->
        Ok(GeneratedToolCall(
          tool_call_id: id,
          tool_name: name,
          arguments_json: case string_tree.to_string(args) {
            // A tool with no arguments streams no input at all.
            "" -> "{}"
            json -> json
          },
        ))
      IgnoredBlock -> Error(Nil)
    }
  })
}

/// Receive SSE events until `message_stop`.
///
/// Timeouts, `error` events (e.g. `overloaded_error`) and streams that
/// close before `message_stop` are returned as errors, never as a partial
/// success. A non-2xx response (401, 429, ...) has no SSE events, and the
/// SSE client hides its status, so it shows up as an early close.
fn anthropic_stream_loop(
  subject: process.Subject(httpp_sse.SSEEvent),
  manager: process.Subject(httpp_sse.SSEManagerMessage),
  acc: StreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
  model: String,
  timeout_ms: Int,
) -> Result(StreamAccumulator, GleanError) {
  case process.receive(subject, timeout_ms) {
    Error(_) -> {
      process.send(manager, httpp_sse.Shutdown)
      Error(error.Timeout(after_ms: timeout_ms))
    }
    Ok(httpp_sse.Closed) ->
      Error(error.ProviderError(
        provider: "anthropic",
        model: model,
        status: 0,
        message: "Stream closed before message_stop",
      ))
    Ok(httpp_sse.Event(Some("error"), _event_id, data)) -> {
      process.send(manager, httpp_sse.Shutdown)
      Error(error.ProviderError(
        provider: "anthropic",
        model: model,
        status: 0,
        message: data,
      ))
    }
    Ok(httpp_sse.Event(Some("message_stop"), _event_id, _data)) -> {
      process.send(manager, httpp_sse.Shutdown)
      Ok(acc)
    }
    Ok(httpp_sse.Event(event_type, _event_id, data)) ->
      anthropic_stream_loop(
        subject,
        manager,
        process_anthropic_event(acc, event_type, data, on_event),
        on_event,
        model,
        timeout_ms,
      )
  }
}

fn block_id(index: Int) -> String {
  "block_" <> int.to_string(index)
}

type Delta {
  Delta(
    delta_type: String,
    text: String,
    thinking: String,
    signature: String,
    partial_json: String,
  )
}

fn process_anthropic_event(
  acc: StreamAccumulator,
  event_type: Option(String),
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  case event_type {
    Some("message_start") -> {
      let usage_decoder = {
        use usage <- decode.subfield(["message", "usage"], {
          use input <- decode.field("input_tokens", decode.int)
          use output <- decode.optional_field("output_tokens", 0, decode.int)
          decode.success(Usage(input_tokens: input, output_tokens: output))
        })
        decode.success(usage)
      }
      case json.parse(data, usage_decoder) {
        Ok(usage) -> StreamAccumulator(..acc, usage: usage)
        Error(_) -> acc
      }
    }

    Some("content_block_start") -> {
      let block_decoder = {
        use index <- decode.field("index", decode.int)
        use block <- decode.field("content_block", {
          use block_type <- decode.field("type", decode.string)
          use id <- decode.optional_field("id", "", decode.string)
          use name <- decode.optional_field("name", "", decode.string)
          use data <- decode.optional_field("data", "", decode.string)
          decode.success(#(block_type, id, name, data))
        })
        decode.success(#(index, block))
      }
      case json.parse(data, block_decoder) {
        Error(_) -> acc
        Ok(#(index, #(block_type, id, name, data))) -> {
          let block = case block_type {
            "text" -> {
              on_event(stream.TextStart(id: block_id(index)))
              TextBlock(string_tree.new())
            }
            "thinking" -> {
              on_event(stream.ReasoningStart(id: block_id(index)))
              ThinkingBlock(string_tree.new(), string_tree.new())
            }
            "redacted_thinking" -> RedactedThinkingBlock(data)
            "tool_use" -> {
              on_event(stream.ToolCallStart(
                id: block_id(index),
                tool_call_id: id,
                tool_name: name,
              ))
              ToolUseBlock(id, name, string_tree.new())
            }
            _ -> IgnoredBlock
          }
          StreamAccumulator(..acc, blocks: [#(index, block), ..acc.blocks])
        }
      }
    }

    Some("content_block_delta") -> {
      let delta_decoder = {
        use index <- decode.field("index", decode.int)
        use delta <- decode.field("delta", {
          use delta_type <- decode.field("type", decode.string)
          use text <- decode.optional_field("text", "", decode.string)
          use thinking <- decode.optional_field("thinking", "", decode.string)
          use signature <- decode.optional_field(
            "signature",
            "",
            decode.string,
          )
          use partial_json <- decode.optional_field(
            "partial_json",
            "",
            decode.string,
          )
          decode.success(Delta(
            delta_type:,
            text:,
            thinking:,
            signature:,
            partial_json:,
          ))
        })
        decode.success(#(index, delta))
      }
      case json.parse(data, delta_decoder) {
        Error(_) -> acc
        Ok(#(index, delta)) ->
          StreamAccumulator(
            ..acc,
            blocks: update_block(acc.blocks, index, fn(block) {
              apply_delta(block, index, delta, on_event)
            }),
          )
      }
    }

    Some("content_block_stop") -> {
      case json.parse(data, decode.field("index", decode.int, decode.success)) {
        Error(_) -> Nil
        Ok(index) ->
          case list.key_find(acc.blocks, index) {
            Ok(TextBlock(_)) -> on_event(stream.TextEnd(id: block_id(index)))
            Ok(ThinkingBlock(..)) ->
              on_event(stream.ReasoningEnd(id: block_id(index)))
            Ok(ToolUseBlock(id: id, ..)) ->
              on_event(stream.ToolCallEnd(id: block_id(index), tool_call_id: id))
            _ -> Nil
          }
      }
      acc
    }

    Some("message_delta") -> {
      let msg_delta_decoder = {
        use stop_reason <- decode.optional_field("delta", None, {
          use sr <- decode.optional_field(
            "stop_reason",
            None,
            decode.optional(decode.string),
          )
          decode.success(sr)
        })
        use output <- decode.optional_field("usage", None, {
          use output <- decode.field("output_tokens", decode.int)
          decode.success(Some(output))
        })
        decode.success(#(stop_reason, output))
      }
      case json.parse(data, msg_delta_decoder) {
        Error(_) -> acc
        Ok(#(stop_reason, output)) ->
          StreamAccumulator(
            ..acc,
            finish_reason: case stop_reason {
              Some(sr) -> parse_stop_reason(sr)
              None -> acc.finish_reason
            },
            usage: case output {
              Some(n) -> Usage(..acc.usage, output_tokens: n)
              None -> acc.usage
            },
          )
      }
    }

    // ping and unknown events
    _ -> acc
  }
}

fn apply_delta(
  block: Block,
  index: Int,
  delta: Delta,
  on_event: fn(StreamEvent) -> Nil,
) -> Block {
  case delta.delta_type, block {
    "text_delta", TextBlock(tree) -> {
      on_event(stream.TextDelta(id: block_id(index), delta: delta.text))
      TextBlock(string_tree.append(tree, delta.text))
    }
    "thinking_delta", ThinkingBlock(tree, sig) -> {
      on_event(stream.ReasoningDelta(id: block_id(index), delta: delta.thinking))
      ThinkingBlock(string_tree.append(tree, delta.thinking), sig)
    }
    "signature_delta", ThinkingBlock(tree, sig) ->
      ThinkingBlock(tree, string_tree.append(sig, delta.signature))
    "input_json_delta", ToolUseBlock(id, name, args) -> {
      on_event(stream.ToolCallDelta(
        id: block_id(index),
        tool_call_id: id,
        delta: delta.partial_json,
      ))
      ToolUseBlock(id, name, string_tree.append(args, delta.partial_json))
    }
    _, other -> other
  }
}

fn update_block(
  blocks: List(#(Int, Block)),
  index: Int,
  f: fn(Block) -> Block,
) -> List(#(Int, Block)) {
  list.map(blocks, fn(entry) {
    case entry.0 == index {
      True -> #(index, f(entry.1))
      False -> entry
    }
  })
}

// --- Request encoding (Anthropic format) ---

/// Encode a Messages API request body. Public for tests.
pub fn encode_request(
  model: String,
  gen_request: GenerateRequest,
  stream: Bool,
) -> Result(String, GleanError) {
  use output_config <- result.try(encode_output_config(
    gen_request.response_format,
    gen_request.settings.reasoning_effort,
  ))
  let #(system_parts, conversation_messages) =
    split_system_messages(gen_request.messages)

  // Fields are collected newest first and reversed once at the end.
  let fields = [
    #(
      "max_tokens",
      json.int(option.unwrap(
        gen_request.settings.max_output_tokens,
        default_max_tokens,
      )),
    ),
    #(
      "messages",
      json.preprocessed_array(list.flat_map(
        conversation_messages,
        encode_message,
      )),
    ),
    #("model", json.string(model)),
  ]

  let fields = case system_parts {
    [] -> fields
    _ -> [
      #(
        "system",
        json.preprocessed_array(
          list.map(system_parts, fn(s) {
            json.object([
              #("type", json.string("text")),
              #("text", json.string(s)),
            ])
          }),
        ),
      ),
      ..fields
    ]
  }

  let fields = case gen_request.tools {
    [] -> fields
    tools -> [
      #("tool_choice", encode_tool_choice(gen_request.tool_choice)),
      #("tools", json.preprocessed_array(list.map(tools, encode_tool))),
      ..fields
    ]
  }

  let settings = gen_request.settings
  let fields =
    fields
    |> add_optional("temperature", settings.temperature, json.float)
    |> add_optional("top_p", settings.top_p, json.float)
    |> add_optional("top_k", settings.top_k, json.int)
    |> add_optional("stop_sequences", settings.stop_sequences, fn(stops) {
      json.array(stops, json.string)
    })
    |> add_optional("output_config", output_config, fn(c) { c })

  let fields = case stream {
    True -> [#("stream", json.bool(True)), ..fields]
    False -> fields
  }

  Ok(json.to_string(json.object(list.reverse(fields))))
}

/// Build `output_config`: structured output (`format`) and `effort`.
///
/// Claude's structured outputs need a schema, so `JsonFormat(schema: None)`
/// is a configuration error rather than a request that would quietly return
/// free text.
fn encode_output_config(
  format: provider.ResponseFormat,
  effort: Option(provider.ReasoningEffort),
) -> Result(Option(json.Json), GleanError) {
  use format_field <- result.try(case format {
    provider.TextFormat -> Ok([])
    provider.JsonFormat(schema: Some(s), ..) ->
      Ok([
        #(
          "format",
          json.object([
            #("type", json.string("json_schema")),
            #("schema", schema.to_json_strict(s)),
          ]),
        ),
      ])
    provider.JsonFormat(schema: None, ..) ->
      Error(error.ConfigError(
        message: "Claude's JSON output needs a schema. "
        <> "Pass one with agent.json_output(schema: Some(...)).",
      ))
  })
  let effort_field = case effort {
    None -> []
    Some(e) -> [#("effort", json.string(provider.reasoning_effort_to_string(e)))]
  }
  case list.append(format_field, effort_field) {
    [] -> Ok(None)
    fields -> Ok(Some(json.object(fields)))
  }
}

fn add_optional(
  fields: List(#(String, json.Json)),
  name: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    None -> fields
    Some(v) -> [#(name, encode(v)), ..fields]
  }
}

fn split_system_messages(
  messages: List(Message),
) -> #(List(String), List(Message)) {
  let system =
    list.filter_map(messages, fn(m) {
      case m {
        message.SystemMessage(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
  let non_system =
    list.filter(messages, fn(m) {
      case m {
        message.SystemMessage(_) -> False
        _ -> True
      }
    })
  #(system, non_system)
}

fn encode_message(msg: Message) -> List(json.Json) {
  case msg {
    message.SystemMessage(_) -> []
    message.UserMessage(content) -> [
      json.object([
        #("role", json.string("user")),
        #(
          "content",
          json.preprocessed_array(list.map(content, encode_user_content)),
        ),
      ]),
    ]
    message.AssistantMessage(content) -> [
      json.object([
        #("role", json.string("assistant")),
        #(
          "content",
          json.preprocessed_array(list.filter_map(
            content,
            encode_assistant_content,
          )),
        ),
      ]),
    ]
    message.ToolResultMessage(results) -> [
      json.object([
        #("role", json.string("user")),
        #(
          "content",
          json.preprocessed_array(list.map(results, encode_tool_result)),
        ),
      ]),
    ]
  }
}

fn encode_user_content(content: message.UserContent) -> json.Json {
  case content {
    message.UserText(text) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    message.UserFile(data, media_type) -> {
      let block_type = case media_type {
        "application/pdf" -> "document"
        _ -> "image"
      }
      let source = case data {
        message.Base64Data(b64) ->
          json.object([
            #("type", json.string("base64")),
            #("media_type", json.string(media_type)),
            #("data", json.string(b64)),
          ])
        message.UrlData(url) ->
          json.object([
            #("type", json.string("url")),
            #("url", json.string(url)),
          ])
      }
      json.object([
        #("type", json.string(block_type)),
        #("source", source),
      ])
    }
  }
}

/// Thinking without a signature (e.g. reasoning that came from another
/// provider) can't be replayed to Claude, so it is left out.
fn encode_assistant_content(
  content: message.AssistantContent,
) -> Result(json.Json, Nil) {
  case content {
    message.AssistantText(text) ->
      Ok(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(text)),
        ]),
      )
    message.AssistantReasoning(text, Some(signature)) ->
      Ok(
        json.object([
          #("type", json.string("thinking")),
          #("thinking", json.string(text)),
          #("signature", json.string(signature)),
        ]),
      )
    message.AssistantReasoning(_, None) -> Error(Nil)
    message.AssistantRedactedReasoning(data) ->
      Ok(
        json.object([
          #("type", json.string("redacted_thinking")),
          #("data", json.string(data)),
        ]),
      )
    message.AssistantToolCall(id, name, args_json) ->
      // Anthropic expects input as an object, not a string
      Ok(
        json.object([
          #("type", json.string("tool_use")),
          #("id", json.string(id)),
          #("name", json.string(name)),
          #("input", json_value.arguments_to_object(args_json)),
        ]),
      )
  }
}

fn encode_tool_result(result: message.ToolResult) -> json.Json {
  case result {
    message.ToolResultOk(tool_call_id, _, output) ->
      json.object([
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(tool_call_id)),
        #("content", json.string(output)),
      ])
    message.ToolResultError(tool_call_id, _, error_message) ->
      json.object([
        #("type", json.string("tool_result")),
        #("tool_use_id", json.string(tool_call_id)),
        #("content", json.string(error_message)),
        #("is_error", json.bool(True)),
      ])
  }
}

fn encode_tool(t: provider.ToolSpec) -> json.Json {
  json.object([
    #("name", json.string(t.name)),
    #("description", json.string(t.description)),
    #("input_schema", schema.to_json(t.input_schema)),
  ])
}

fn encode_tool_choice(choice: provider.ToolChoice) -> json.Json {
  case choice {
    provider.Auto -> json.object([#("type", json.string("auto"))])
    provider.NoTools -> json.object([#("type", json.string("none"))])
    provider.Required -> json.object([#("type", json.string("any"))])
    provider.SpecificTool(name) ->
      json.object([
        #("type", json.string("tool")),
        #("name", json.string(name)),
      ])
  }
}

// --- Response decoding (Anthropic format) ---

/// Decode a non-streaming Messages API response body. Public for tests.
pub fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  case json.parse(body, anthropic_response_decoder()) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode Anthropic response",
      ))
    Ok(#(content, finish_reason, usage)) ->
      Ok(GenerateResult(
        content: content,
        finish_reason: finish_reason,
        usage: usage,
        model_id: model_id,
      ))
  }
}

fn anthropic_response_decoder() -> decode.Decoder(
  #(List(GeneratedContent), FinishReason, Usage),
) {
  let usage_decoder = {
    use input_tokens <- decode.field("input_tokens", decode.int)
    use output_tokens <- decode.field("output_tokens", decode.int)
    decode.success(Usage(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
    ))
  }

  use blocks <- decode.field("content", decode.list(content_block_decoder()))
  use stop_reason <- decode.optional_field(
    "stop_reason",
    None,
    decode.optional(decode.string),
  )
  use usage <- decode.field("usage", usage_decoder)

  decode.success(#(
    option.values(blocks),
    case stop_reason {
      Some(reason) -> parse_stop_reason(reason)
      None -> error.Stop
    },
    usage,
  ))
}

/// Decodes one content block. Block types glean doesn't use decode to None
/// instead of failing the whole response.
fn content_block_decoder() -> decode.Decoder(Option(GeneratedContent)) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Some(GeneratedText(text: text)))
    }
    "thinking" -> {
      use text <- decode.field("thinking", decode.string)
      use signature <- decode.optional_field(
        "signature",
        None,
        decode.optional(decode.string),
      )
      decode.success(Some(GeneratedReasoning(text: text, signature: signature)))
    }
    "redacted_thinking" -> {
      use data <- decode.field("data", decode.string)
      decode.success(Some(GeneratedRedactedReasoning(data: data)))
    }
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use input <- decode.field("input", json_value.decoder())
      decode.success(
        Some(GeneratedToolCall(
          tool_call_id: id,
          tool_name: name,
          arguments_json: json_value.to_string(input),
        )),
      )
    }
    _ -> decode.success(None)
  }
}

fn parse_stop_reason(reason: String) -> FinishReason {
  case reason {
    "end_turn" -> error.Stop
    "tool_use" -> error.ToolCalls
    "max_tokens" -> error.Length
    "stop_sequence" -> error.Stop
    "refusal" -> error.ContentFilter
    other -> error.Other(other)
  }
}
