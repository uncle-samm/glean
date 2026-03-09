/// Anthropic provider (Claude models).
/// Uses the Anthropic Messages API format (different from OpenAI).

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string_tree
import glean/error.{type FinishReason, type GleanError}
import glean/json_value
import glean/message.{type Message}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type GeneratedContent, type Provider,
  GenerateResult, GeneratedText, GeneratedToolCall, Provider,
}
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils
import glean/providers/sse
import glean/schema
import glean/stream.{type StreamEvent, type Usage, Usage}
import httpp/sse as httpp_sse

const base_url = "https://api.anthropic.com/v1"

const anthropic_version = "2023-06-01"

/// Create an Anthropic provider.
///
/// ## Example
///
/// ```gleam
/// let provider = anthropic.new(api_key: "sk-ant-...", model: "claude-sonnet-4-20250514")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
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
  let body = encode_request(config.model, gen_request)
  let url = config.base_url <> "/messages"

  case make_http_request(config, url, body) {
    Error(err) -> Error(err)
    Ok(response_body) -> decode_response(config.model, response_body)
  }
}

/// Streaming accumulator — threaded through a pure receive loop.
type StreamAccumulator {
  StreamAccumulator(
    text: string_tree.StringTree,
    tool_calls: List(StreamingToolCall),
    finish_reason: FinishReason,
    usage: Usage,
    current_block_index: Int,
    current_block_type: String,
  )
}

type StreamingToolCall {
  StreamingToolCall(id: String, name: String, args: string_tree.StringTree)
}

fn do_stream(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  let body = encode_stream_request(config.model, gen_request)
  let url = config.base_url <> "/messages"

  let headers = [
    #("x-api-key", config.api_key),
    #("anthropic-version", anthropic_version),
    ..list.map(config.headers, fn(h) { #(h.0, h.1) })
  ]

  case sse.start_stream(url, headers, body, config.timeout_ms) {
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
          text: string_tree.new(),
          tool_calls: [],
          finish_reason: error.Stop,
          usage: stream.zero_usage(),
          current_block_index: 0,
          current_block_type: "",
        )

      let final_acc =
        anthropic_stream_loop(
          event_subject,
          manager_subject,
          acc,
          on_event,
          config.timeout_ms,
        )

      let text_content = case string_tree.to_string(final_acc.text) {
        "" -> []
        t -> [GeneratedText(text: t)]
      }

      let tool_content =
        list.map(final_acc.tool_calls, fn(tc) {
          GeneratedToolCall(
            tool_call_id: tc.id,
            tool_name: tc.name,
            arguments_json: string_tree.to_string(tc.args),
          )
        })

      Ok(GenerateResult(
        content: list.append(text_content, tool_content),
        finish_reason: final_acc.finish_reason,
        usage: final_acc.usage,
        model_id: config.model,
      ))
    }
  }
}

fn encode_stream_request(
  model: String,
  gen_request: GenerateRequest,
) -> String {
  let #(system_parts, conversation_messages) =
    split_system_messages(gen_request.messages)
  let anthropic_messages = encode_messages(conversation_messages)

  let fields = [
    #("model", json.string(model)),
    #("messages", json.preprocessed_array(anthropic_messages)),
    #("stream", json.bool(True)),
  ]

  let fields = case system_parts {
    [] -> fields
    _ ->
      list.append(fields, [
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
      ])
  }

  let max_tokens = case gen_request.settings.max_output_tokens {
    Some(max) -> max
    None -> 4096
  }
  let fields =
    list.append(fields, [#("max_tokens", json.int(max_tokens))])

  let fields = case gen_request.tool_choice {
    provider.NoTools -> fields
    choice ->
      case gen_request.tools {
        [] -> fields
        tools ->
          list.append(fields, [
            #("tools", json.preprocessed_array(encode_tools(tools))),
            #("tool_choice", encode_tool_choice(choice)),
          ])
      }
  }

  let fields = case gen_request.settings.temperature {
    None -> fields
    Some(temp) -> list.append(fields, [#("temperature", json.float(temp))])
  }

  let fields = case gen_request.settings.top_p {
    None -> fields
    Some(p) -> list.append(fields, [#("top_p", json.float(p))])
  }

  let fields = case gen_request.settings.top_k {
    None -> fields
    Some(k) -> list.append(fields, [#("top_k", json.int(k))])
  }

  let fields = case gen_request.settings.stop_sequences {
    None -> fields
    Some(stops) ->
      list.append(fields, [#("stop_sequences", json.array(stops, json.string))])
  }

  json.object(fields)
  |> json.to_string
}

fn anthropic_stream_loop(
  subject: process.Subject(httpp_sse.SSEEvent),
  manager: process.Subject(httpp_sse.SSEManagerMessage),
  acc: StreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
  timeout_ms: Int,
) -> StreamAccumulator {
  case process.receive(subject, timeout_ms) {
    Error(_) -> {
      process.send(manager, httpp_sse.Shutdown)
      acc
    }
    Ok(httpp_sse.Closed) -> acc
    Ok(httpp_sse.Event(event_type, _event_id, data)) -> {
      let new_acc =
        process_anthropic_event(acc, event_type, data, on_event)
      case event_type {
        Some("message_stop") -> {
          process.send(manager, httpp_sse.Shutdown)
          new_acc
        }
        _ ->
          anthropic_stream_loop(
            subject,
            manager,
            new_acc,
            on_event,
            timeout_ms,
          )
      }
    }
  }
}

fn process_anthropic_event(
  acc: StreamAccumulator,
  event_type: option.Option(String),
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  case event_type {
    Some("message_start") -> {
      let usage_decoder = {
        use msg <- decode.field("message", {
          use usage <- decode.field("usage", {
            use input <- decode.field("input_tokens", decode.int)
            use output <- decode.optional_field(
              "output_tokens",
              0,
              decode.int,
            )
            decode.success(Usage(input_tokens: input, output_tokens: output))
          })
          decode.success(usage)
        })
        decode.success(msg)
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
          decode.success(#(block_type, id, name))
        })
        decode.success(#(index, block))
      }
      case json.parse(data, block_decoder) {
        Ok(#(index, #(block_type, id, name))) -> {
          case block_type {
            "text" -> {
              on_event(stream.TextStart(
                id: "block_" <> int.to_string(index),
              ))
              StreamAccumulator(
                ..acc,
                current_block_index: index,
                current_block_type: "text",
              )
            }
            "tool_use" -> {
              on_event(stream.ToolCallStart(
                id: "block_" <> int.to_string(index),
                tool_call_id: id,
                tool_name: name,
              ))
              let new_tc =
                StreamingToolCall(
                  id: id,
                  name: name,
                  args: string_tree.new(),
                )
              StreamAccumulator(
                ..acc,
                current_block_index: index,
                current_block_type: "tool_use",
                tool_calls: list.append(acc.tool_calls, [new_tc]),
              )
            }
            _ -> acc
          }
        }
        Error(_) -> acc
      }
    }

    Some("content_block_delta") -> {
      let delta_decoder = {
        use index <- decode.field("index", decode.int)
        use delta <- decode.field("delta", {
          use delta_type <- decode.field("type", decode.string)
          use text <- decode.optional_field("text", "", decode.string)
          use partial_json <- decode.optional_field(
            "partial_json",
            "",
            decode.string,
          )
          decode.success(#(delta_type, text, partial_json))
        })
        decode.success(#(index, delta))
      }
      case json.parse(data, delta_decoder) {
        Ok(#(index, #(delta_type, text, partial_json))) -> {
          case delta_type {
            "text_delta" -> {
              on_event(stream.TextDelta(
                id: "block_" <> int.to_string(index),
                delta: text,
              ))
              StreamAccumulator(
                ..acc,
                text: string_tree.append(acc.text, text),
              )
            }
            "input_json_delta" -> {
              let tc_id = case list.last(acc.tool_calls) {
                Ok(tc) -> tc.id
                Error(_) -> ""
              }
              on_event(stream.ToolCallDelta(
                id: "block_" <> int.to_string(index),
                tool_call_id: tc_id,
                delta: partial_json,
              ))
              StreamAccumulator(
                ..acc,
                tool_calls: update_last_tool_call(
                  acc.tool_calls,
                  partial_json,
                ),
              )
            }
            _ -> acc
          }
        }
        Error(_) -> acc
      }
    }

    Some("content_block_stop") -> {
      let block_id =
        "block_" <> int.to_string(acc.current_block_index)
      case acc.current_block_type {
        "text" -> on_event(stream.TextEnd(id: block_id))
        "tool_use" -> {
          let tc_id = case list.last(acc.tool_calls) {
            Ok(tc) -> tc.id
            Error(_) -> ""
          }
          on_event(stream.ToolCallEnd(id: block_id, tool_call_id: tc_id))
        }
        _ -> Nil
      }
      acc
    }

    Some("message_delta") -> {
      let msg_delta_decoder = {
        use stop_reason <- decode.optional_field("delta", "", {
          use sr <- decode.optional_field("stop_reason", "", decode.string)
          decode.success(sr)
        })
        use usage <- decode.optional_field("usage", Usage(0, 0), {
          use output <- decode.field("output_tokens", decode.int)
          decode.success(Usage(
            input_tokens: acc.usage.input_tokens,
            output_tokens: output,
          ))
        })
        decode.success(#(stop_reason, usage))
      }
      case json.parse(data, msg_delta_decoder) {
        Ok(#(stop_reason, usage)) -> {
          let finish = case stop_reason {
            "" -> acc.finish_reason
            sr -> parse_stop_reason(sr)
          }
          let final_usage = case usage {
            Usage(0, 0) -> acc.usage
            u -> u
          }
          StreamAccumulator(
            ..acc,
            finish_reason: finish,
            usage: final_usage,
          )
        }
        Error(_) -> acc
      }
    }

    // message_stop, ping, error, etc
    _ -> acc
  }
}

fn update_last_tool_call(
  tool_calls: List(StreamingToolCall),
  args_delta: String,
) -> List(StreamingToolCall) {
  case list.reverse(tool_calls) {
    [] -> []
    [last, ..rest] -> {
      let updated =
        StreamingToolCall(
          ..last,
          args: string_tree.append(last.args, args_delta),
        )
      list.reverse([updated, ..rest])
    }
  }
}

// --- HTTP ---

fn make_http_request(
  config: ProviderConfig,
  url: String,
  body: String,
) -> Result(String, GleanError) {
  http_utils.send_post(
    config,
    "anthropic",
    url,
    body,
    [
      #("x-api-key", config.api_key),
      #("anthropic-version", anthropic_version),
    ],
  )
}

// --- Request encoding (Anthropic format) ---

fn encode_request(model: String, gen_request: GenerateRequest) -> String {
  let #(system_parts, conversation_messages) =
    split_system_messages(gen_request.messages)

  let anthropic_messages = encode_messages(conversation_messages)

  let fields = [
    #("model", json.string(model)),
    #("messages", json.preprocessed_array(anthropic_messages)),
  ]

  // System prompt
  let fields = case system_parts {
    [] -> fields
    _ ->
      list.append(fields, [
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
      ])
  }

  // Max tokens (required by Anthropic)
  let max_tokens = case gen_request.settings.max_output_tokens {
    Some(max) -> max
    None -> 4096
  }
  let fields =
    list.append(fields, [#("max_tokens", json.int(max_tokens))])

  // Tools — when NoTools, don't include tools in the request at all
  let fields = case gen_request.tool_choice {
    provider.NoTools -> fields
    choice ->
      case gen_request.tools {
        [] -> fields
        tools ->
          list.append(fields, [
            #("tools", json.preprocessed_array(encode_tools(tools))),
            #("tool_choice", encode_tool_choice(choice)),
          ])
      }
  }

  // Optional settings
  let fields = case gen_request.settings.temperature {
    None -> fields
    Some(temp) -> list.append(fields, [#("temperature", json.float(temp))])
  }

  let fields = case gen_request.settings.top_p {
    None -> fields
    Some(p) -> list.append(fields, [#("top_p", json.float(p))])
  }

  let fields = case gen_request.settings.top_k {
    None -> fields
    Some(k) -> list.append(fields, [#("top_k", json.int(k))])
  }

  let fields = case gen_request.settings.stop_sequences {
    None -> fields
    Some(stops) ->
      list.append(fields, [#("stop_sequences", json.array(stops, json.string))])
  }

  json.object(fields)
  |> json.to_string
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

fn encode_messages(messages: List(Message)) -> List(json.Json) {
  list.flat_map(messages, encode_message)
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
          json.preprocessed_array(
            list.map(content, encode_assistant_content),
          ),
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
    message.UserFile(data, media_type) ->
      case data {
        message.Base64Data(b64) ->
          json.object([
            #("type", json.string("image")),
            #(
              "source",
              json.object([
                #("type", json.string("base64")),
                #("media_type", json.string(media_type)),
                #("data", json.string(b64)),
              ]),
            ),
          ])
        message.UrlData(url) ->
          json.object([
            #("type", json.string("image")),
            #(
              "source",
              json.object([
                #("type", json.string("url")),
                #("url", json.string(url)),
              ]),
            ),
          ])
      }
  }
}

fn encode_assistant_content(content: message.AssistantContent) -> json.Json {
  case content {
    message.AssistantText(text) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    message.AssistantReasoning(text) ->
      json.object([
        #("type", json.string("thinking")),
        #("thinking", json.string(text)),
      ])
    message.AssistantToolCall(id, name, args_json) -> {
      // Anthropic expects input as an object, not a string
      // Parse the JSON string back to a JSON value for embedding
      let input_json = json_value.parse_to_json(args_json)
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("input", input_json),
      ])
    }
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
        #("content", json.string("Error: " <> error_message)),
        #("is_error", json.bool(True)),
      ])
  }
}

fn encode_tools(tools: List(provider.ToolSpec)) -> List(json.Json) {
  list.map(tools, fn(t) {
    json.object([
      #("name", json.string(t.name)),
      #("description", json.string(t.description)),
      #("input_schema", schema.to_json(t.input_schema)),
    ])
  })
}

fn encode_tool_choice(choice: provider.ToolChoice) -> json.Json {
  case choice {
    provider.Auto | provider.NoTools ->
      json.object([#("type", json.string("auto"))])
    provider.Required -> json.object([#("type", json.string("any"))])
    provider.SpecificTool(name) ->
      json.object([
        #("type", json.string("tool")),
        #("name", json.string(name)),
      ])
  }
}

// --- Response decoding (Anthropic format) ---

fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  let decoder = anthropic_response_decoder()
  case json.parse(body, decoder) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode Anthropic response",
      ))
    Ok(parsed) ->
      Ok(GenerateResult(
        content: parsed.content,
        finish_reason: parsed.finish_reason,
        usage: parsed.usage,
        model_id: model_id,
      ))
  }
}

type ParsedResponse {
  ParsedResponse(
    content: List(GeneratedContent),
    finish_reason: FinishReason,
    usage: Usage,
  )
}

fn anthropic_response_decoder() -> decode.Decoder(ParsedResponse) {
  let usage_decoder = {
    use input_tokens <- decode.field("input_tokens", decode.int)
    use output_tokens <- decode.field("output_tokens", decode.int)
    decode.success(Usage(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
    ))
  }

  // Anthropic content blocks can be "text" or "tool_use"
  let content_block_decoder =
    decode.one_of(text_block_decoder(), [tool_use_block_decoder()])

  use content <- decode.field("content", decode.list(content_block_decoder))
  use stop_reason <- decode.field("stop_reason", decode.string)
  use usage <- decode.field("usage", usage_decoder)

  decode.success(ParsedResponse(
    content: content,
    finish_reason: parse_stop_reason(stop_reason),
    usage: usage,
  ))
}

fn text_block_decoder() -> decode.Decoder(GeneratedContent) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(GeneratedText(text: text))
    }
    _ -> decode.failure(GeneratedText(text: ""), "text block")
  }
}

fn tool_use_block_decoder() -> decode.Decoder(GeneratedContent) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "tool_use" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      // input is a JSON object — we encode it back to a string
      use input <- decode.field("input", decode.dynamic)
      let args_json = json_value.dynamic_to_string(input)
      decode.success(GeneratedToolCall(
        tool_call_id: id,
        tool_name: name,
        arguments_json: args_json,
      ))
    }
    _ -> decode.failure(GeneratedToolCall("", "", ""), "tool_use block")
  }
}

fn parse_stop_reason(reason: String) -> FinishReason {
  case reason {
    "end_turn" -> error.Stop
    "tool_use" -> error.ToolCalls
    "max_tokens" -> error.Length
    "stop_sequence" -> error.Stop
    other -> error.Other(other)
  }
}

