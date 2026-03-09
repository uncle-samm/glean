/// Shared implementation for all OpenAI-compatible providers.
/// OpenAI, DeepSeek, Mistral, OpenRouter, Moonshot/Kimi, Qwen, MiniMax all use this format.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/string_tree
import glean/error.{type FinishReason, type GleanError}
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

/// Create a Provider from an OpenAI-compatible config.
pub fn create(
  name provider_name: String,
  config config: ProviderConfig,
) -> Provider {
  Provider(
    name: provider_name,
    model_id: config.model,
    generate: fn(request) { do_generate(config, provider_name, request) },
    stream: fn(request, on_event) {
      do_stream(config, provider_name, request, on_event)
    },
  )
}

// --- Non-streaming generation ---

fn do_generate(
  config: ProviderConfig,
  provider_name: String,
  gen_request: GenerateRequest,
) -> Result(GenerateResult, GleanError) {
  let body = encode_request(config, gen_request, False)
  let url = config.base_url <> "/chat/completions"

  case make_http_request(config, provider_name, url, body) {
    Error(err) -> Error(err)
    Ok(response_body) -> decode_response(config.model, response_body)
  }
}

// --- Streaming generation ---

/// Accumulator for streaming state — threaded through a pure receive loop.
type StreamAccumulator {
  StreamAccumulator(
    text: string_tree.StringTree,
    tool_calls: List(StreamingToolCall),
    finish_reason: FinishReason,
    usage: Usage,
  )
}

type StreamingToolCall {
  StreamingToolCall(
    index: Int,
    id: String,
    name: string_tree.StringTree,
    args: string_tree.StringTree,
    started: Bool,
  )
}

fn do_stream(
  config: ProviderConfig,
  provider_name: String,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  let body = encode_request(config, gen_request, True)
  let url = config.base_url <> "/chat/completions"

  let headers = [
    #("authorization", "Bearer " <> config.api_key),
    ..list.map(config.headers, fn(h) { #(h.0, h.1) })
  ]

  case sse.start_stream(url, headers, body, config.timeout_ms) {
    Error(msg) ->
      Error(error.ProviderError(
        provider: provider_name,
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
        )

      // Pure receive loop — state threaded through recursion
      let final_acc =
        openai_stream_loop(
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
            tool_name: string_tree.to_string(tc.name),
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

fn openai_stream_loop(
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
    Ok(httpp_sse.Event(_event_type, _event_id, data)) -> {
      case data {
        "[DONE]" -> {
          process.send(manager, httpp_sse.Shutdown)
          acc
        }
        _ -> {
          let new_acc = process_openai_chunk(acc, data, on_event)
          openai_stream_loop(
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
}

fn process_openai_chunk(
  acc: StreamAccumulator,
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  let chunk_decoder = openai_chunk_decoder()
  case json.parse(data, chunk_decoder) {
    Error(_) -> acc
    Ok(chunk) -> {
      // Process text delta
      let acc = case chunk.text_delta {
        "" -> acc
        delta -> {
          on_event(stream.TextDelta(id: chunk.id, delta: delta))
          StreamAccumulator(
            ..acc,
            text: string_tree.append(acc.text, delta),
          )
        }
      }

      // Process tool call deltas
      let acc =
        list.fold(chunk.tool_call_deltas, acc, fn(a, tcd) {
          process_tool_call_delta(a, tcd, chunk.id, on_event)
        })

      // Process finish reason
      let acc = case chunk.finish_reason {
        "" -> acc
        fr ->
          StreamAccumulator(..acc, finish_reason: parse_finish_reason(fr))
      }

      // Process usage (some providers send it in the last chunk)
      case chunk.usage {
        Usage(0, 0) -> acc
        u -> StreamAccumulator(..acc, usage: u)
      }
    }
  }
}

type ChunkData {
  ChunkData(
    id: String,
    text_delta: String,
    tool_call_deltas: List(ToolCallDelta),
    finish_reason: String,
    usage: Usage,
  )
}

type ToolCallDelta {
  ToolCallDelta(index: Int, id: String, name: String, args: String)
}

fn openai_chunk_decoder() -> decode.Decoder(ChunkData) {
  use id <- decode.optional_field("id", "", decode.string)

  let tool_call_delta_decoder = {
    use index <- decode.field("index", decode.int)
    use id <- decode.optional_field("id", "", decode.string)
    use name <- decode.optional_field("function", "", {
      use n <- decode.optional_field("name", "", decode.string)
      decode.success(n)
    })
    use args <- decode.optional_field("function", "", {
      use a <- decode.optional_field("arguments", "", decode.string)
      decode.success(a)
    })
    decode.success(ToolCallDelta(index: index, id: id, name: name, args: args))
  }

  let choice_decoder = {
    use delta <- decode.optional_field("delta", #("", []), {
      use content <- decode.optional_field(
        "content",
        None,
        decode.optional(decode.string),
      )
      use tool_calls <- decode.optional_field(
        "tool_calls",
        [],
        decode.list(tool_call_delta_decoder),
      )
      decode.success(#(option.unwrap(content, ""), tool_calls))
    })
    use finish_reason <- decode.optional_field(
      "finish_reason",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(delta, option.unwrap(finish_reason, "")))
  }

  use choices <- decode.optional_field(
    "choices",
    [],
    decode.list(choice_decoder),
  )
  use usage <- decode.optional_field("usage", Usage(0, 0), {
    use input <- decode.optional_field("prompt_tokens", 0, decode.int)
    use output <- decode.optional_field("completion_tokens", 0, decode.int)
    decode.success(Usage(input_tokens: input, output_tokens: output))
  })

  let #(text_delta, tool_call_deltas, finish_reason) = case choices {
    [#(#(text, tcs), fr), ..] -> #(text, tcs, fr)
    [] -> #("", [], "")
  }

  decode.success(ChunkData(
    id: id,
    text_delta: text_delta,
    tool_call_deltas: tool_call_deltas,
    finish_reason: finish_reason,
    usage: usage,
  ))
}

fn process_tool_call_delta(
  acc: StreamAccumulator,
  delta: ToolCallDelta,
  chunk_id: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  let #(tc, is_new) = case find_tool_call(acc.tool_calls, delta.index) {
    Ok(existing) -> #(existing, False)
    Error(_) -> #(
      StreamingToolCall(
        index: delta.index,
        id: "",
        name: string_tree.new(),
        args: string_tree.new(),
        started: False,
      ),
      True,
    )
  }

  let tc = case delta.id {
    "" -> tc
    id -> StreamingToolCall(..tc, id: id)
  }

  let tc = case delta.name {
    "" -> tc
    name -> StreamingToolCall(..tc, name: string_tree.append(tc.name, name))
  }

  let tc = case is_new && tc.id != "" {
    True -> {
      on_event(stream.ToolCallStart(
        id: chunk_id,
        tool_call_id: tc.id,
        tool_name: string_tree.to_string(tc.name),
      ))
      StreamingToolCall(..tc, started: True)
    }
    False -> tc
  }

  let tc = case delta.args {
    "" -> tc
    args -> {
      on_event(stream.ToolCallDelta(
        id: chunk_id,
        tool_call_id: tc.id,
        delta: args,
      ))
      StreamingToolCall(..tc, args: string_tree.append(tc.args, args))
    }
  }

  let tool_calls = upsert_tool_call(acc.tool_calls, tc)
  StreamAccumulator(..acc, tool_calls: tool_calls)
}

fn find_tool_call(
  calls: List(StreamingToolCall),
  index: Int,
) -> Result(StreamingToolCall, Nil) {
  list.find(calls, fn(tc) { tc.index == index })
}

fn upsert_tool_call(
  calls: List(StreamingToolCall),
  tc: StreamingToolCall,
) -> List(StreamingToolCall) {
  case list.any(calls, fn(c) { c.index == tc.index }) {
    True ->
      list.map(calls, fn(c) {
        case c.index == tc.index {
          True -> tc
          False -> c
        }
      })
    False -> list.append(calls, [tc])
  }
}

// --- HTTP request ---

fn make_http_request(
  config: ProviderConfig,
  provider_name: String,
  url: String,
  body: String,
) -> Result(String, GleanError) {
  http_utils.send_post(
    config,
    provider_name,
    url,
    body,
    [#("authorization", "Bearer " <> config.api_key)],
  )
}

// --- Request encoding ---

fn encode_request(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  stream: Bool,
) -> String {
  let messages_json = encode_messages(gen_request.messages)
  let tools_json = encode_tools(gen_request.tools)

  let fields = [
    #("model", json.string(config.model)),
    #("messages", json.preprocessed_array(messages_json)),
  ]

  let fields = case tools_json {
    [] -> fields
    _ ->
      list.append(fields, [
        #("tools", json.preprocessed_array(tools_json)),
        #("tool_choice", encode_tool_choice(gen_request.tool_choice)),
      ])
  }

  let fields = case gen_request.settings.max_output_tokens {
    None -> fields
    Some(max) ->
      list.append(fields, [#(config.max_tokens_field, json.int(max))])
  }

  let fields = case gen_request.settings.temperature {
    None -> fields
    Some(temp) -> list.append(fields, [#("temperature", json.float(temp))])
  }

  let fields = case gen_request.settings.top_p {
    None -> fields
    Some(p) -> list.append(fields, [#("top_p", json.float(p))])
  }

  let fields = case gen_request.settings.seed {
    None -> fields
    Some(s) -> list.append(fields, [#("seed", json.int(s))])
  }

  let fields = case gen_request.settings.presence_penalty {
    None -> fields
    Some(pp) ->
      list.append(fields, [#("presence_penalty", json.float(pp))])
  }

  let fields = case gen_request.settings.frequency_penalty {
    None -> fields
    Some(fp) ->
      list.append(fields, [#("frequency_penalty", json.float(fp))])
  }

  let fields = case gen_request.settings.stop_sequences {
    None -> fields
    Some(stops) ->
      list.append(fields, [#("stop", json.array(stops, json.string))])
  }

  let fields = case stream {
    False -> fields
    True -> list.append(fields, [#("stream", json.bool(True))])
  }

  let fields = case gen_request.response_format {
    provider.TextFormat -> fields
    provider.JsonFormat(schema_opt, name_opt) ->
      list.append(fields, [
        #("response_format", encode_response_format(schema_opt, name_opt)),
      ])
  }

  json.object(fields)
  |> json.to_string
}

fn encode_messages(messages: List(Message)) -> List(json.Json) {
  list.flat_map(messages, encode_message)
}

fn encode_message(msg: Message) -> List(json.Json) {
  case msg {
    message.SystemMessage(content) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ]),
    ]
    message.UserMessage(content) ->
      case content {
        [message.UserText(text)] -> [
          json.object([
            #("role", json.string("user")),
            #("content", json.string(text)),
          ]),
        ]
        _ -> [
          json.object([
            #("role", json.string("user")),
            #("content", json.preprocessed_array(
              list.map(content, encode_user_content),
            )),
          ]),
        ]
      }
    message.AssistantMessage(content) -> [encode_assistant_message(content)]
    // Each tool result must be a separate message in OpenAI format
    message.ToolResultMessage(results) ->
      list.map(results, encode_tool_result)
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
            #("type", json.string("image_url")),
            #(
              "image_url",
              json.object([
                #(
                  "url",
                  json.string(
                    "data:" <> media_type <> ";base64," <> b64,
                  ),
                ),
              ]),
            ),
          ])
        message.UrlData(url) ->
          json.object([
            #("type", json.string("image_url")),
            #(
              "image_url",
              json.object([#("url", json.string(url))]),
            ),
          ])
      }
  }
}

fn encode_assistant_message(
  content: List(message.AssistantContent),
) -> json.Json {
  let text_parts =
    list.filter_map(content, fn(c) {
      case c {
        message.AssistantText(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })

  let tool_calls =
    list.filter_map(content, fn(c) {
      case c {
        message.AssistantToolCall(id, name, args) ->
          Ok(json.object([
            #("id", json.string(id)),
            #("type", json.string("function")),
            #(
              "function",
              json.object([
                #("name", json.string(name)),
                #("arguments", json.string(args)),
              ]),
            ),
          ]))
        _ -> Error(Nil)
      }
    })

  let text = string.join(text_parts, "")

  let fields = [
    #("role", json.string("assistant")),
  ]

  let fields = case text {
    "" ->
      case tool_calls {
        [] -> list.append(fields, [#("content", json.null())])
        _ -> list.append(fields, [#("content", json.null())])
      }
    t -> list.append(fields, [#("content", json.string(t))])
  }

  let fields = case tool_calls {
    [] -> fields
    _ ->
      list.append(fields, [
        #("tool_calls", json.preprocessed_array(tool_calls)),
      ])
  }

  json.object(fields)
}

fn encode_tool_result(result: message.ToolResult) -> json.Json {
  case result {
    message.ToolResultOk(tool_call_id, _, output) ->
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string(output)),
      ])
    message.ToolResultError(tool_call_id, _, error_message) ->
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string("Error: " <> error_message)),
      ])
  }
}

fn encode_tools(tools: List(provider.ToolSpec)) -> List(json.Json) {
  list.map(tools, fn(t) {
    json.object([
      #("type", json.string("function")),
      #(
        "function",
        json.object([
          #("name", json.string(t.name)),
          #("description", json.string(t.description)),
          #("parameters", schema.to_json(t.input_schema)),
        ]),
      ),
    ])
  })
}

fn encode_tool_choice(choice: provider.ToolChoice) -> json.Json {
  case choice {
    provider.Auto -> json.string("auto")
    provider.Required -> json.string("required")
    provider.NoTools -> json.string("none")
    provider.SpecificTool(name) ->
      json.object([
        #("type", json.string("function")),
        #("function", json.object([#("name", json.string(name))])),
      ])
  }
}

fn encode_response_format(
  schema_opt: Option(schema.Schema),
  name_opt: Option(String),
) -> json.Json {
  case schema_opt {
    None -> json.object([#("type", json.string("json_object"))])
    Some(s) -> {
      let name = case name_opt {
        None -> "response"
        Some(n) -> n
      }
      json.object([
        #("type", json.string("json_schema")),
        #(
          "json_schema",
          json.object([
            #("name", json.string(name)),
            #("schema", schema.to_json_strict(s)),
            #("strict", json.bool(True)),
          ]),
        ),
      ])
    }
  }
}

// --- Response decoding ---

fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  let decoder = openai_response_decoder()
  case json.parse(body, decoder) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode OpenAI response",
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

// Internal parsed response structure
type ParsedResponse {
  ParsedResponse(
    content: List(GeneratedContent),
    finish_reason: FinishReason,
    usage: Usage,
  )
}

fn openai_response_decoder() -> decode.Decoder(ParsedResponse) {
  let usage_decoder = {
    use input_tokens <- decode.field("prompt_tokens", decode.int)
    use output_tokens <- decode.field("completion_tokens", decode.int)
    decode.success(Usage(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
    ))
  }

  let tool_call_decoder = {
    use id <- decode.field("id", decode.string)
    use function <- decode.field("function", {
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", decode.string)
      decode.success(#(name, arguments))
    })
    decode.success(GeneratedToolCall(
      tool_call_id: id,
      tool_name: function.0,
      arguments_json: function.1,
    ))
  }

  let choice_decoder = {
    use message <- decode.field("message", {
      use content <- decode.optional_field(
        "content",
        None,
        decode.optional(decode.string),
      )
      use tool_calls <- decode.optional_field(
        "tool_calls",
        None,
        decode.optional(decode.list(tool_call_decoder)),
      )
      decode.success(#(content, tool_calls))
    })
    use finish_reason <- decode.field("finish_reason", decode.string)
    decode.success(#(message, finish_reason))
  }

  use choices <- decode.field("choices", decode.list(choice_decoder))
  use usage <- decode.field("usage", usage_decoder)

  let #(content, finish_reason) = case choices {
    [#(message, fr), ..] -> {
      let #(text_opt, tool_calls_opt) = message
      let text_content = case text_opt {
        Some(text) if text != "" -> [GeneratedText(text: text)]
        _ -> []
      }
      let tool_content = case tool_calls_opt {
        Some(calls) -> calls
        None -> []
      }
      #(list.append(text_content, tool_content), parse_finish_reason(fr))
    }
    [] -> #([], error.Stop)
  }

  decode.success(ParsedResponse(
    content: content,
    finish_reason: finish_reason,
    usage: usage,
  ))
}

fn parse_finish_reason(reason: String) -> FinishReason {
  case reason {
    "stop" -> error.Stop
    "length" -> error.Length
    "tool_calls" -> error.ToolCalls
    "content_filter" -> error.ContentFilter
    other -> error.Other(other)
  }
}
