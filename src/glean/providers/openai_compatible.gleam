//// Shared implementation for all OpenAI-compatible Chat Completions APIs.
//// OpenAI, DeepSeek, Mistral, OpenRouter, Moonshot/Kimi, Qwen and MiniMax
//// all use this format, and so can any other compatible endpoint:
////
//// ```gleam
//// config.new(api_key: key, model: "my-model")
//// |> config.base_url("https://my-gateway.example.com/v1")
//// |> openai_compatible.create(name: "my-gateway", config: _)
//// ```
////
//// Reasoning returned as `reasoning_content` (DeepSeek, Qwen, Kimi,
//// MiniMax), `reasoning` (OpenRouter) or `thinking` content parts (Mistral's
//// Magistral) is surfaced as reasoning content and `ReasoningDelta` stream
//// events.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import glean/error.{type FinishReason, type GleanError}
import glean/message.{type Message}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type GeneratedContent,
  type Provider, GenerateResult, GeneratedReasoning, GeneratedText,
  GeneratedToolCall, Provider,
}
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils
import glean/providers/sse
import glean/schema
import glean/stream.{type StreamEvent}
import glean/usage.{type Usage, Usage}

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
  use body <- result.try(encode_request(config, gen_request, False))
  use response_body <- result.try(
    http_utils.send_post(
      config,
      provider_name,
      config.base_url <> "/chat/completions",
      body,
      [#("authorization", "Bearer " <> config.api_key)],
    ),
  )
  decode_response(config.model, response_body)
}

// --- Streaming generation ---

/// Accumulator for streaming state — threaded through a pure receive loop.
pub opaque type StreamAccumulator {
  StreamAccumulator(
    text: StringTree,
    reasoning: StringTree,
    /// Newest first; reversed once at the end.
    tool_calls: List(StreamingToolCall),
    finish_reason: FinishReason,
    usage: Usage,
    /// True once a chunk carrying a finish_reason has been seen.
    finished: Bool,
    /// The text or reasoning whose start event was sent and whose end
    /// event wasn't yet.
    open: OpenPart,
  )
}

type StreamingToolCall {
  StreamingToolCall(
    index: Int,
    id: String,
    name: StringTree,
    args: StringTree,
    /// The stream id its events carry.
    event_id: String,
    /// Whether its end event was sent.
    ended: Bool,
  )
}

/// Chat Completions streams have no start and end markers, so glean makes
/// them: a part starts with its first delta and ends when another kind of
/// content begins or the response finishes.
type OpenPart {
  NothingOpen
  TextOpen(id: String)
  ReasoningOpen(id: String)
}

fn do_stream(
  config: ProviderConfig,
  provider_name: String,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  use body <- result.try(encode_request(config, gen_request, True))
  let headers = [
    #("authorization", "Bearer " <> config.api_key),
    ..list.map(config.headers, fn(h) { #(h.0, h.1) })
  ]

  let events =
    sse.start(config, config.base_url <> "/chat/completions", headers, body)
  use final_acc <- result.try(stream_loop(
    events,
    new_stream_accumulator(),
    on_event,
    provider_name,
    config.model,
    config.timeout_ms,
  ))
  Ok(GenerateResult(
    content: accumulated_content(final_acc),
    finish_reason: final_acc.finish_reason,
    usage: final_acc.usage,
    model_id: config.model,
  ))
}

/// Receive SSE events until the stream completes.
///
/// Returns an error — never a partial success — when the stream times out,
/// gets a non-2xx response, closes before the provider signalled
/// completion, or carries an error payload.
///
/// Public so tests can drive it with `sse.from_events`.
pub fn stream_loop(
  events: sse.Stream,
  acc: StreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
  provider_name: String,
  model: String,
  timeout_ms: Int,
) -> Result(StreamAccumulator, GleanError) {
  let fail = fn(status, message) {
    Error(error.ProviderError(
      provider: provider_name,
      model: model,
      status: status,
      message: message,
    ))
  }
  case sse.next(events, timeout_ms) {
    Error(Nil) -> Error(error.Timeout(after_ms: timeout_ms))
    Ok(#(sse.Closed, _)) ->
      case acc.finished {
        True -> Ok(acc)
        False -> fail(0, "Stream closed before the response finished")
      }
    Ok(#(sse.HttpStatus(status, body), _)) -> fail(status, body)
    Ok(#(sse.Failed(reason), _)) -> fail(0, "Streaming failed: " <> reason)
    Ok(#(sse.Event(_, "[DONE]"), events)) -> {
      sse.stop(events)
      // Some servers end with [DONE] alone, without a finish_reason chunk.
      Ok(end_parts(acc, on_event))
    }
    Ok(#(sse.Event(_, data), events)) ->
      case json.parse(data, stream_error_decoder()) {
        Ok(message) -> {
          sse.stop(events)
          fail(0, message)
        }
        Error(_) ->
          stream_loop(
            events,
            process_chunk(acc, data, on_event),
            on_event,
            provider_name,
            model,
            timeout_ms,
          )
      }
  }
}

/// Decodes an in-stream error payload: `{"error": {"message": "..."}}`.
fn stream_error_decoder() -> decode.Decoder(String) {
  use message <- decode.field("error", {
    use message <- decode.optional_field(
      "message",
      "Unknown streaming error",
      decode.string,
    )
    decode.success(message)
  })
  decode.success(message)
}

/// A fresh accumulator. Public for tests.
pub fn new_stream_accumulator() -> StreamAccumulator {
  StreamAccumulator(
    text: string_tree.new(),
    reasoning: string_tree.new(),
    tool_calls: [],
    finish_reason: error.Stop,
    usage: stream.zero_usage(),
    finished: False,
    open: NothingOpen,
  )
}

/// The text accumulated so far. Public for tests.
pub fn accumulated_text(acc: StreamAccumulator) -> String {
  string_tree.to_string(acc.text)
}

/// The usage a stream reported, or zero when it reported none. Public
/// for tests.
pub fn accumulated_usage(acc: StreamAccumulator) -> Usage {
  acc.usage
}

/// Everything accumulated, in the order a non-streaming response has it:
/// reasoning, text, then tool calls. Public for tests.
pub fn accumulated_content(acc: StreamAccumulator) -> List(GeneratedContent) {
  let reasoning = case string_tree.to_string(acc.reasoning) {
    "" -> []
    r -> [GeneratedReasoning(text: r, signature: None)]
  }
  let text = case string_tree.to_string(acc.text) {
    "" -> []
    t -> [GeneratedText(text: t)]
  }
  let tool_calls =
    acc.tool_calls
    |> list.reverse
    |> list.map(fn(tc) {
      GeneratedToolCall(
        tool_call_id: tc.id,
        tool_name: string_tree.to_string(tc.name),
        arguments_json: case string_tree.to_string(tc.args) {
          "" -> "{}"
          args -> args
        },
      )
    })
  list.flatten([reasoning, text, tool_calls])
}

type ChunkData {
  ChunkData(
    id: String,
    text_delta: String,
    reasoning_delta: String,
    tool_call_deltas: List(ToolCallDelta),
    finish_reason: String,
    usage: Option(Usage),
  )
}

type ToolCallDelta {
  ToolCallDelta(index: Int, id: String, name: String, args: String)
}

fn process_chunk(
  acc: StreamAccumulator,
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  case json.parse(data, chunk_decoder()) {
    // Keep-alives and payloads glean doesn't use.
    Error(_) -> acc
    Ok(chunk) -> {
      let acc = case chunk.reasoning_delta {
        "" -> acc
        delta -> {
          let acc = open_part(acc, ReasoningOpen(id: chunk.id), on_event)
          on_event(stream.ReasoningDelta(id: chunk.id, delta: delta))
          StreamAccumulator(
            ..acc,
            reasoning: string_tree.append(acc.reasoning, delta),
          )
        }
      }

      let acc = case chunk.text_delta {
        "" -> acc
        delta -> {
          let acc = open_part(acc, TextOpen(id: chunk.id), on_event)
          on_event(stream.TextDelta(id: chunk.id, delta: delta))
          StreamAccumulator(..acc, text: string_tree.append(acc.text, delta))
        }
      }

      let acc = case chunk.tool_call_deltas {
        [] -> acc
        deltas ->
          list.fold(deltas, close_open_part(acc, on_event), fn(a, tcd) {
            process_tool_call_delta(a, tcd, chunk.id, on_event)
          })
      }

      let acc = case chunk.finish_reason {
        "" -> acc
        fr ->
          StreamAccumulator(
            ..end_parts(acc, on_event),
            finish_reason: parse_finish_reason(fr),
            finished: True,
          )
      }

      case chunk.usage {
        None -> acc
        Some(u) -> StreamAccumulator(..acc, usage: u)
      }
    }
  }
}

/// Make `part` the open part: end the one that was open, if it is another
/// kind, and send the new one's start event.
fn open_part(
  acc: StreamAccumulator,
  part: OpenPart,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  case acc.open, part {
    TextOpen(_), TextOpen(_) | ReasoningOpen(_), ReasoningOpen(_) -> acc
    _, _ -> {
      let acc = close_open_part(acc, on_event)
      case part {
        TextOpen(id) -> on_event(stream.TextStart(id: id))
        ReasoningOpen(id) -> on_event(stream.ReasoningStart(id: id))
        NothingOpen -> Nil
      }
      StreamAccumulator(..acc, open: part)
    }
  }
}

/// Send the end event of the open text or reasoning, if there is one.
fn close_open_part(
  acc: StreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  case acc.open {
    NothingOpen -> Nil
    TextOpen(id) -> on_event(stream.TextEnd(id: id))
    ReasoningOpen(id) -> on_event(stream.ReasoningEnd(id: id))
  }
  StreamAccumulator(..acc, open: NothingOpen)
}

/// The response is complete: end the open text or reasoning, and every
/// tool call, in the order the model started them. Does nothing the second
/// time.
fn end_parts(
  acc: StreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  let acc = close_open_part(acc, on_event)
  // `tool_calls` is newest first.
  let tool_calls =
    acc.tool_calls
    |> list.reverse
    |> list.map(fn(tc) {
      case tc.ended {
        True -> tc
        False -> {
          on_event(stream.ToolCallEnd(id: tc.event_id, tool_call_id: tc.id))
          StreamingToolCall(..tc, ended: True)
        }
      }
    })
    |> list.reverse
  StreamAccumulator(..acc, tool_calls: tool_calls)
}

fn process_tool_call_delta(
  acc: StreamAccumulator,
  delta: ToolCallDelta,
  chunk_id: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamAccumulator {
  let existing = list.find(acc.tool_calls, fn(tc) { tc.index == delta.index })
  let tc = case existing {
    Ok(tc) -> tc
    Error(Nil) ->
      StreamingToolCall(
        index: delta.index,
        id: delta.id,
        name: string_tree.new(),
        args: string_tree.new(),
        event_id: chunk_id,
        ended: False,
      )
  }
  let tc = case delta.id, tc.id {
    "", _ -> tc
    id, "" -> StreamingToolCall(..tc, id: id)
    _, _ -> tc
  }
  let tc =
    StreamingToolCall(..tc, name: string_tree.append(tc.name, delta.name))

  case existing {
    Error(Nil) ->
      on_event(stream.ToolCallStart(
        id: tc.event_id,
        tool_call_id: tc.id,
        tool_name: string_tree.to_string(tc.name),
      ))
    Ok(_) -> Nil
  }

  let tc = case delta.args {
    "" -> tc
    args -> {
      on_event(stream.ToolCallDelta(
        id: tc.event_id,
        tool_call_id: tc.id,
        delta: args,
      ))
      StreamingToolCall(..tc, args: string_tree.append(tc.args, args))
    }
  }

  let tool_calls = case existing {
    Error(Nil) -> [tc, ..acc.tool_calls]
    Ok(_) ->
      list.map(acc.tool_calls, fn(c) {
        case c.index == tc.index {
          True -> tc
          False -> c
        }
      })
  }
  StreamAccumulator(..acc, tool_calls: tool_calls)
}

fn chunk_decoder() -> decode.Decoder(ChunkData) {
  use id <- decode.optional_field("id", "", nullable_string())

  let tool_call_delta_decoder = {
    use index <- decode.optional_field("index", 0, decode.int)
    use id <- decode.optional_field("id", "", nullable_string())
    use function <- decode.optional_field("function", #("", ""), {
      use name <- decode.optional_field("name", "", nullable_string())
      use args <- decode.optional_field("arguments", "", nullable_string())
      decode.success(#(name, args))
    })
    decode.success(ToolCallDelta(
      index: index,
      id: id,
      name: function.0,
      args: function.1,
    ))
  }

  let choice_decoder = {
    use delta <- decode.optional_field("delta", #("", "", []), {
      use content <- decode.optional_field(
        "content",
        Content(text: "", thinking: ""),
        content_decoder(),
      )
      use reasoning <- decode.then(reasoning_decoder(content.thinking))
      use tool_calls <- decode.optional_field(
        "tool_calls",
        [],
        nullable_list(tool_call_delta_decoder),
      )
      decode.success(#(content.text, reasoning, tool_calls))
    })
    use finish_reason <- decode.optional_field(
      "finish_reason",
      "",
      nullable_string(),
    )
    decode.success(#(delta, finish_reason))
  }

  use choices <- decode.optional_field(
    "choices",
    [],
    nullable_list(choice_decoder),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )

  let #(text_delta, reasoning_delta, tool_call_deltas, finish_reason) = case
    choices
  {
    [#(#(text, reasoning, tcs), fr), ..] -> #(text, reasoning, tcs, fr)
    [] -> #("", "", [], "")
  }

  decode.success(ChunkData(
    id: id,
    text_delta: text_delta,
    reasoning_delta: reasoning_delta,
    tool_call_deltas: tool_call_deltas,
    finish_reason: finish_reason,
    usage: usage,
  ))
}

/// A string field that may be `null`; null decodes to "".
fn nullable_string() -> decode.Decoder(String) {
  decode.optional(decode.string)
  |> decode.map(option.unwrap(_, ""))
}

/// A list field that may be `null`; null decodes to [].
fn nullable_list(of inner: decode.Decoder(a)) -> decode.Decoder(List(a)) {
  decode.optional(decode.list(inner))
  |> decode.map(option.unwrap(_, []))
}

/// A message's `content`: its text, and the reasoning it carried as
/// `thinking` parts.
type Content {
  Content(text: String, thinking: String)
}

/// `content` is a string, `null`, or, from Mistral, a list of parts:
/// `{"type": "text", "text": ...}` and, from its reasoning models,
/// `{"type": "thinking", "thinking": [parts]}`. Other part types are left
/// out.
fn content_decoder() -> decode.Decoder(Content) {
  let text_part = {
    use part_type <- decode.optional_field("type", "", decode.string)
    use text <- decode.optional_field("text", "", nullable_string())
    decode.success(case part_type {
      "text" -> text
      _ -> ""
    })
  }
  let part = {
    use part_type <- decode.optional_field("type", "", decode.string)
    case part_type {
      "text" -> {
        use text <- decode.optional_field("text", "", nullable_string())
        decode.success(Content(text: text, thinking: ""))
      }
      "thinking" -> {
        use thinking <- decode.optional_field(
          "thinking",
          "",
          decode.one_of(decode.string, or: [
            decode.list(text_part) |> decode.map(string.concat),
          ]),
        )
        decode.success(Content(text: "", thinking: thinking))
      }
      _ -> decode.success(Content(text: "", thinking: ""))
    }
  }
  decode.one_of(
    decode.string |> decode.map(fn(text) { Content(text: text, thinking: "") }),
    or: [
      decode.list(part)
        |> decode.map(fn(parts) {
          Content(
            text: string.concat(list.map(parts, fn(p) { p.text })),
            thinking: string.concat(list.map(parts, fn(p) { p.thinking })),
          )
        }),
      decode.optional(decode.string)
        |> decode.map(fn(text) {
          Content(text: option.unwrap(text, ""), thinking: "")
        }),
    ],
  )
}

/// Reasoning text from `reasoning_content` (DeepSeek, Qwen, Kimi, MiniMax)
/// or `reasoning` (OpenRouter), on the same object as `content`, or else
/// the `thinking` parts found in `content` itself (Mistral).
fn reasoning_decoder(content_thinking: String) -> decode.Decoder(String) {
  use reasoning_content <- decode.optional_field(
    "reasoning_content",
    "",
    nullable_string(),
  )
  use reasoning <- decode.optional_field("reasoning", "", nullable_string())
  decode.success(case reasoning_content, reasoning {
    "", "" -> content_thinking
    "", r -> r
    rc, _ -> rc
  })
}

/// `prompt_tokens` and `completion_tokens` are totals: cached input and
/// reasoning output are parts of them, reported in the `*_details` objects
/// (or, by DeepSeek, as `prompt_cache_hit_tokens`).
fn usage_decoder() -> decode.Decoder(Usage) {
  let detail = fn(name: String) {
    decode.optional(decode.optionally_at([name], 0, nullable_int()))
    |> decode.map(option.unwrap(_, 0))
  }
  use input <- decode.optional_field("prompt_tokens", 0, nullable_int())
  use output <- decode.optional_field("completion_tokens", 0, nullable_int())
  use cached <- decode.optional_field(
    "prompt_tokens_details",
    0,
    detail("cached_tokens"),
  )
  use cache_hit <- decode.optional_field(
    "prompt_cache_hit_tokens",
    0,
    nullable_int(),
  )
  use reasoning <- decode.optional_field(
    "completion_tokens_details",
    0,
    detail("reasoning_tokens"),
  )
  decode.success(Usage(
    input_tokens: input,
    output_tokens: output,
    cache_read_tokens: int.max(cached, cache_hit),
    cache_write_tokens: 0,
    reasoning_tokens: reasoning,
  ))
}

/// A number field that may be `null`; null decodes to 0.
fn nullable_int() -> decode.Decoder(Int) {
  decode.optional(decode.int)
  |> decode.map(option.unwrap(_, 0))
}

// --- Request encoding ---

/// Encode a Chat Completions request body. Fails with `ConfigError` for a
/// file these APIs have no way to take. Public for tests.
pub fn encode_request(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  stream: Bool,
) -> Result(String, GleanError) {
  let settings = gen_request.settings
  use messages <- result.try(
    list.try_map(gen_request.messages, fn(msg) {
      encode_message(msg, config.send_reasoning_content)
    }),
  )
  // Fields are collected newest first and reversed once at the end.
  let fields = [
    #("messages", json.preprocessed_array(list.flatten(messages))),
    #("model", json.string(config.model)),
  ]

  let fields = case gen_request.tools {
    [] -> fields
    tools -> [
      #("tool_choice", encode_tool_choice(gen_request.tool_choice)),
      #("tools", json.preprocessed_array(list.map(tools, encode_tool))),
      ..fields
    ]
  }

  let fields =
    fields
    |> add_optional(
      config.max_tokens_field,
      settings.max_output_tokens,
      json.int,
    )
    |> add_optional("temperature", settings.temperature, json.float)
    |> add_optional("top_p", settings.top_p, json.float)
    |> add_optional("seed", settings.seed, json.int)
    |> add_optional("presence_penalty", settings.presence_penalty, json.float)
    |> add_optional("frequency_penalty", settings.frequency_penalty, json.float)
    |> add_optional("stop", settings.stop_sequences, fn(stops) {
      json.array(stops, json.string)
    })
    |> add_optional("reasoning_effort", settings.reasoning_effort, fn(effort) {
      json.string(provider.reasoning_effort_to_string(effort))
    })

  let fields = case stream, config.stream_usage {
    False, _ -> fields
    True, False -> [#("stream", json.bool(True)), ..fields]
    True, True -> [
      #("stream_options", json.object([#("include_usage", json.bool(True))])),
      #("stream", json.bool(True)),
      ..fields
    ]
  }

  let fields = case gen_request.response_format {
    provider.TextFormat -> fields
    provider.JsonFormat(schema_opt, name_opt) -> [
      #("response_format", encode_response_format(schema_opt, name_opt)),
      ..fields
    ]
  }

  // Provider-specific extras replace glean's field of the same name.
  json.object(config.with_extra_body(list.reverse(fields), config))
  |> json.to_string
  |> Ok
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

fn encode_message(
  msg: Message,
  send_reasoning: Bool,
) -> Result(List(json.Json), GleanError) {
  case msg {
    message.SystemMessage(content) ->
      Ok([
        json.object([
          #("role", json.string("system")),
          #("content", json.string(content)),
        ]),
      ])
    message.UserMessage([message.UserText(text)]) ->
      Ok([
        json.object([
          #("role", json.string("user")),
          #("content", json.string(text)),
        ]),
      ])
    message.UserMessage(content) -> {
      use parts <- result.map(list.try_map(content, encode_user_content))
      [
        json.object([
          #("role", json.string("user")),
          #("content", json.preprocessed_array(parts)),
        ]),
      ]
    }
    message.AssistantMessage(content) ->
      Ok([encode_assistant_message(content, send_reasoning)])
    // Each tool result must be a separate message in OpenAI format
    message.ToolResultMessage(results) ->
      Ok(list.map(results, encode_tool_result))
  }
}

/// Images go as `image_url` parts (a URL, or the data inline), PDFs as
/// `file` parts and WAV or MP3 audio as `input_audio` parts, both inline
/// only. Chat Completions has no part for anything else.
fn encode_user_content(
  content: message.UserContent,
) -> Result(json.Json, GleanError) {
  case content {
    message.UserText(text) ->
      Ok(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(text)),
        ]),
      )
    message.UserFile(data, media_type) ->
      case data, audio_format(media_type) {
        _, _ if media_type == "application/pdf" ->
          case data {
            message.Base64Data(b64) ->
              Ok(
                json.object([
                  #("type", json.string("file")),
                  #(
                    "file",
                    json.object([
                      #("filename", json.string("file.pdf")),
                      #(
                        "file_data",
                        json.string("data:application/pdf;base64," <> b64),
                      ),
                    ]),
                  ),
                ]),
              )
            message.UrlData(_) ->
              Error(unsupported_file(
                "a PDF by URL; send its contents with Base64Data",
              ))
          }
        message.Base64Data(b64), Ok(format) ->
          Ok(
            json.object([
              #("type", json.string("input_audio")),
              #(
                "input_audio",
                json.object([
                  #("data", json.string(b64)),
                  #("format", json.string(format)),
                ]),
              ),
            ]),
          )
        message.UrlData(_), Ok(_) ->
          Error(unsupported_file(
            "audio by URL; send its contents with Base64Data",
          ))
        _, Error(Nil) ->
          case string.starts_with(media_type, "image/"), data {
            True, message.Base64Data(b64) ->
              Ok(image_url_part("data:" <> media_type <> ";base64," <> b64))
            True, message.UrlData(url) -> Ok(image_url_part(url))
            False, _ ->
              Error(unsupported_file(
                "a file of type "
                <> media_type
                <> "; if it is text, put the text in the message",
              ))
          }
      }
  }
}

fn image_url_part(url: String) -> json.Json {
  json.object([
    #("type", json.string("image_url")),
    #("image_url", json.object([#("url", json.string(url))])),
  ])
}

/// The `input_audio.format` for a media type, for the two formats the API
/// takes.
fn audio_format(media_type: String) -> Result(String, Nil) {
  case media_type {
    "audio/wav" | "audio/x-wav" | "audio/wave" -> Ok("wav")
    "audio/mpeg" | "audio/mp3" -> Ok("mp3")
    _ -> Error(Nil)
  }
}

fn unsupported_file(what: String) -> GleanError {
  error.ConfigError(
    message: "OpenAI-compatible APIs take images, PDF files and WAV or MP3 audio. They can't take "
    <> what
    <> ".",
  )
}

fn encode_assistant_message(
  content: List(message.AssistantContent),
  send_reasoning: Bool,
) -> json.Json {
  let text =
    content
    |> list.filter_map(fn(c) {
      case c {
        message.AssistantText(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat

  let reasoning =
    content
    |> list.filter_map(fn(c) {
      case c {
        message.AssistantReasoning(text, _) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat

  let tool_calls =
    list.filter_map(content, fn(c) {
      case c {
        message.AssistantToolCall(id, name, args) ->
          Ok(
            json.object([
              #("id", json.string(id)),
              #("type", json.string("function")),
              #(
                "function",
                json.object([
                  #("name", json.string(name)),
                  #("arguments", json.string(args)),
                ]),
              ),
            ]),
          )
        _ -> Error(Nil)
      }
    })

  let fields = [
    #("role", json.string("assistant")),
    #("content", case text {
      "" -> json.null()
      t -> json.string(t)
    }),
  ]

  let fields = case send_reasoning, reasoning {
    True, r if r != "" ->
      list.append(fields, [#("reasoning_content", json.string(r))])
    _, _ -> fields
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
  let #(tool_call_id, content) = case result {
    message.ToolResultOk(tool_call_id, _, output) -> #(tool_call_id, output)
    message.ToolResultError(tool_call_id, _, error_message) -> #(
      tool_call_id,
      "Error: " <> error_message,
    )
  }
  json.object([
    #("role", json.string("tool")),
    #("tool_call_id", json.string(tool_call_id)),
    #("content", json.string(content)),
  ])
}

fn encode_tool(t: provider.ToolSpec) -> json.Json {
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

/// Strict mode is only requested when the schema meets OpenAI's strict-mode
/// rules (every object property required); otherwise the schema is sent as
/// guidance and glean's own validation of the answer does the enforcing.
fn encode_response_format(
  schema_opt: Option(schema.Schema),
  name_opt: Option(String),
) -> json.Json {
  case schema_opt {
    None -> json.object([#("type", json.string("json_object"))])
    Some(s) -> {
      let strict = schema.is_strict_compatible(s)
      let schema_json = case strict {
        True -> schema.to_json_strict(s)
        False -> schema.to_json(s)
      }
      json.object([
        #("type", json.string("json_schema")),
        #(
          "json_schema",
          json.object([
            #("name", json.string(option.unwrap(name_opt, "response"))),
            #("schema", schema_json),
            #("strict", json.bool(strict)),
          ]),
        ),
      ])
    }
  }
}

// --- Response decoding ---

/// Decode a non-streaming Chat Completions response body. Public for tests.
pub fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  case json.parse(body, response_decoder()) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode Chat Completions response",
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

fn response_decoder() -> decode.Decoder(
  #(List(GeneratedContent), FinishReason, Usage),
) {
  let tool_call_decoder = {
    use id <- decode.field("id", decode.string)
    use function <- decode.field("function", {
      use name <- decode.field("name", decode.string)
      use arguments <- decode.optional_field("arguments", "{}", decode.string)
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
        Content(text: "", thinking: ""),
        content_decoder(),
      )
      use reasoning <- decode.then(reasoning_decoder(content.thinking))
      use tool_calls <- decode.optional_field(
        "tool_calls",
        [],
        nullable_list(tool_call_decoder),
      )
      decode.success(#(content.text, reasoning, tool_calls))
    })
    use finish_reason <- decode.optional_field(
      "finish_reason",
      "stop",
      nullable_string(),
    )
    decode.success(#(message, finish_reason))
  }

  use choices <- decode.field("choices", decode.list(choice_decoder))
  use usage <- decode.optional_field(
    "usage",
    usage.zero(),
    decode.optional(usage_decoder())
      |> decode.map(option.unwrap(_, usage.zero())),
  )

  let #(content, finish_reason) = case choices {
    [#(#(text, reasoning, tool_calls), fr), ..] -> {
      let reasoning_content = case reasoning {
        "" -> []
        r -> [GeneratedReasoning(text: r, signature: None)]
      }
      let text_content = case text {
        "" -> []
        t -> [GeneratedText(text: t)]
      }
      #(
        list.flatten([reasoning_content, text_content, tool_calls]),
        parse_finish_reason(fr),
      )
    }
    [] -> #([], error.Stop)
  }

  decode.success(#(content, finish_reason, usage))
}

fn parse_finish_reason(reason: String) -> FinishReason {
  case reason {
    "stop" -> error.Stop
    "length" -> error.Length
    "tool_calls" | "function_call" -> error.ToolCalls
    "content_filter" -> error.ContentFilter
    // OpenRouter, when the model behind it failed part way.
    "error" -> error.FinishError
    other -> error.Other(other)
  }
}
