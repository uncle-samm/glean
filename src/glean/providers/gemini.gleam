//// Google Gemini provider, on the Gemini REST API.
////
//// What glean's settings become on the wire:
////
//// - `tool_choice` is sent as `toolConfig.functionCallingConfig`.
//// - `reasoning_effort` is sent as `thinkingConfig.thinkingLevel`, which
////   Gemini 3 and later models take. Gemini has no level above `high`, so
////   `XHighEffort` and `MaxEffort` send `high`. Gemini 2.5 models take a
////   token budget instead: leave `reasoning_effort` unset for them.
//// - `include_reasoning` asks for thought summaries
////   (`thinkingConfig.includeThoughts`); without it Gemini thinks but
////   returns no reasoning text.
//// - Files the model makes (images from the image models) come back as
////   `GeneratedFile` and are sent back on the next turn.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import glean/error.{type FinishReason, type GleanError}
import glean/json_value
import glean/message.{type Message}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type GeneratedContent,
  type Provider, GenerateResult, GeneratedFile, GeneratedReasoning,
  GeneratedRedactedReasoning, GeneratedText, GeneratedToolCall, Provider,
}
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils
import glean/providers/sse
import glean/schema
import glean/stream.{type StreamEvent}
import glean/usage.{type Usage, Usage}

const base_url = "https://generativelanguage.googleapis.com/v1beta"

/// The default configuration for this provider. Change it with the
/// `glean/providers/config` setters, then pass it to `from_config`.
pub fn default_config(
  api_key api_key: String,
  model model: String,
) -> ProviderConfig {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
}

/// Create a Gemini provider.
///
/// ## Example
///
/// ```gleam
/// let provider = gemini.new(api_key: "AIza...", model: "gemini-2.5-pro")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  default_config(api_key: api_key, model: model)
  |> from_config
}

/// Create a Gemini provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  Provider(
    name: "gemini",
    model_id: cfg.model,
    generate: fn(request) { do_generate(cfg, request) },
    stream: fn(request, on_event) { do_stream(cfg, request, on_event) },
  )
}

// --- Non-streaming ---

fn do_generate(
  config: ProviderConfig,
  gen_request: GenerateRequest,
) -> Result(GenerateResult, GleanError) {
  let body = encode_request(config, gen_request)
  let url = config.base_url <> "/models/" <> config.model <> ":generateContent"

  case make_http_request(config, url, body) {
    Error(err) -> Error(err)
    Ok(response_body) -> decode_response(config.model, response_body)
  }
}

// --- Streaming ---

type StreamState {
  StreamState(
    /// The parts that have ended, newest first.
    content: List(GeneratedContent),
    /// The text or reasoning part still receiving deltas.
    open: OpenPart,
    /// Numbers the parts, so every part's events carry their own id.
    next_part: Int,
    finish_reason: FinishReason,
    usage: Usage,
    /// True once a chunk carrying a finishReason has been seen.
    finished: Bool,
  )
}

type OpenPart {
  NothingOpen
  TextOpen(id: String, text: string_tree.StringTree)
  ReasoningOpen(id: String, text: string_tree.StringTree)
}

fn do_stream(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  let body = encode_request(config, gen_request)
  let url =
    config.base_url
    <> "/models/"
    <> config.model
    <> ":streamGenerateContent?alt=sse"

  // The API key goes in a header, never the URL, so it can't leak into
  // logs, proxies, or error messages.
  let headers = [#("x-goog-api-key", config.api_key), ..config.headers]

  sse.start(config, url, headers, body)
  |> stream_events(on_event, config.model, config.timeout_ms)
}

/// Read a Gemini stream to its end: emit its events and build the result.
///
/// Every text and reasoning part gets a start event, its deltas and an end
/// event, all with the part's own id. Reasoning is part of the result's
/// content, as it is without streaming.
@internal
pub fn stream_events(
  events: sse.Stream,
  on_event: fn(StreamEvent) -> Nil,
  model: String,
  timeout_ms: Int,
) -> Result(GenerateResult, GleanError) {
  let state =
    StreamState(
      content: [],
      open: NothingOpen,
      next_part: 0,
      finish_reason: error.Stop,
      usage: usage.zero(),
      finished: False,
    )
  use state <- result.map(gemini_stream_loop(
    events,
    state,
    on_event,
    model,
    timeout_ms,
  ))
  // A chunk with a finishReason closes the open part, so nothing is open.
  let assert NothingOpen = state.open
  GenerateResult(
    content: list.reverse(state.content),
    finish_reason: state.finish_reason,
    usage: state.usage,
    model_id: model,
  )
}

/// Receive SSE events until the stream closes.
///
/// Gemini ends a stream by closing the connection, so `Closed` is only a
/// success after a chunk carrying a finishReason. Timeouts, non-2xx
/// responses, early closes and in-stream error payloads are returned as
/// errors.
fn gemini_stream_loop(
  events: sse.Stream,
  state: StreamState,
  on_event: fn(StreamEvent) -> Nil,
  model: String,
  timeout_ms: Int,
) -> Result(StreamState, GleanError) {
  let fail = fn(status, message) {
    Error(error.ProviderError(
      provider: "gemini",
      model: model,
      status: status,
      message: message,
    ))
  }
  case sse.next(events, timeout_ms) {
    Error(Nil) -> Error(error.Timeout(after_ms: timeout_ms))
    Ok(#(sse.Closed, _)) ->
      case state.finished {
        True -> Ok(state)
        False -> fail(0, "Stream closed before the response finished")
      }
    Ok(#(sse.HttpStatus(status, body), _)) -> fail(status, body)
    Ok(#(sse.Failed(reason), _)) -> fail(0, "Streaming failed: " <> reason)
    Ok(#(sse.Event(_, data), events)) ->
      case json.parse(data, stream_error_decoder()) {
        Ok(message) -> {
          sse.stop(events)
          fail(0, message)
        }
        Error(_) ->
          gemini_stream_loop(
            events,
            process_gemini_chunk(state, data, on_event),
            on_event,
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

fn process_gemini_chunk(
  state: StreamState,
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamState {
  case json.parse(data, response_decoder()) {
    // A chunk that isn't a response (a keep-alive, say) carries nothing.
    Error(_) -> state
    Ok(chunk) -> {
      let state =
        list.fold(chunk.content, state, fn(state, part) {
          stream_part(state, part, on_event)
        })

      let state = case chunk.finish_reason {
        None -> state
        Some(reason) ->
          StreamState(
            ..close_open_part(state, on_event),
            finish_reason: reason,
            finished: True,
          )
      }

      // Each chunk's usage is the running total, so the last one wins.
      case chunk.usage == usage.zero() {
        True -> state
        False -> StreamState(..state, usage: chunk.usage)
      }
    }
  }
}

/// Add one part of a chunk to the stream: a delta for the open part when
/// it is more of the same kind, otherwise the end of that part and the
/// start of a new one.
fn stream_part(
  state: StreamState,
  part: GeneratedContent,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamState {
  case part, state.open {
    GeneratedText(text: ""), _ | GeneratedReasoning(text: "", ..), _ -> state
    GeneratedText(text:), TextOpen(id:, text: so_far) -> {
      on_event(stream.TextDelta(id: id, delta: text))
      StreamState(
        ..state,
        open: TextOpen(id: id, text: string_tree.append(so_far, text)),
      )
    }
    GeneratedReasoning(text:, ..), ReasoningOpen(id:, text: so_far) -> {
      on_event(stream.ReasoningDelta(id: id, delta: text))
      StreamState(
        ..state,
        open: ReasoningOpen(id: id, text: string_tree.append(so_far, text)),
      )
    }
    GeneratedText(text:), _ -> {
      let #(state, id) = next_part_id(close_open_part(state, on_event))
      on_event(stream.TextStart(id: id))
      on_event(stream.TextDelta(id: id, delta: text))
      StreamState(
        ..state,
        open: TextOpen(id: id, text: string_tree.from_string(text)),
      )
    }
    GeneratedReasoning(text:, ..), _ -> {
      let #(state, id) = next_part_id(close_open_part(state, on_event))
      on_event(stream.ReasoningStart(id: id))
      on_event(stream.ReasoningDelta(id: id, delta: text))
      StreamState(
        ..state,
        open: ReasoningOpen(id: id, text: string_tree.from_string(text)),
      )
    }
    GeneratedToolCall(tool_call_id:, tool_name:, arguments_json:), _ -> {
      // Gemini sends a function call whole, never in pieces.
      let #(state, id) = next_part_id(close_open_part(state, on_event))
      on_event(stream.ToolCallStart(
        id: id,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
      ))
      on_event(stream.ToolCallDelta(
        id: id,
        tool_call_id: tool_call_id,
        delta: arguments_json,
      ))
      on_event(stream.ToolCallEnd(id: id, tool_call_id: tool_call_id))
      StreamState(..state, content: [part, ..state.content])
    }
    GeneratedFile(..), _ | GeneratedRedactedReasoning(..), _ -> {
      // No stream event carries a file; it is in the result's content.
      let state = close_open_part(state, on_event)
      StreamState(..state, content: [part, ..state.content])
    }
  }
}

fn next_part_id(state: StreamState) -> #(StreamState, String) {
  #(
    StreamState(..state, next_part: state.next_part + 1),
    "gemini-" <> int.to_string(state.next_part),
  )
}

/// End the open text or reasoning part and move it into the content.
fn close_open_part(
  state: StreamState,
  on_event: fn(StreamEvent) -> Nil,
) -> StreamState {
  case state.open {
    NothingOpen -> state
    TextOpen(id:, text:) -> {
      on_event(stream.TextEnd(id: id))
      StreamState(..state, open: NothingOpen, content: [
        GeneratedText(text: string_tree.to_string(text)),
        ..state.content
      ])
    }
    ReasoningOpen(id:, text:) -> {
      on_event(stream.ReasoningEnd(id: id))
      StreamState(..state, open: NothingOpen, content: [
        GeneratedReasoning(text: string_tree.to_string(text), signature: None),
        ..state.content
      ])
    }
  }
}

// --- HTTP ---

fn make_http_request(
  config: ProviderConfig,
  url: String,
  body: String,
) -> Result(String, GleanError) {
  http_utils.send_post(config, "gemini", url, body, [
    #("x-goog-api-key", config.api_key),
  ])
}

// --- Request encoding (Gemini format) ---

/// The JSON body of a `generateContent` or `streamGenerateContent` call.
@internal
pub fn encode_request(
  config: ProviderConfig,
  gen_request: GenerateRequest,
) -> String {
  let #(system_parts, conversation) = split_system(gen_request.messages)
  let contents = encode_contents(conversation)

  let fields = [#("contents", json.preprocessed_array(contents))]

  // System instruction
  let fields = case system_parts {
    [] -> fields
    parts -> {
      let text = string.join(parts, "\n")
      list.append(fields, [
        #(
          "systemInstruction",
          json.object([
            #(
              "parts",
              json.preprocessed_array([
                json.object([#("text", json.string(text))]),
              ]),
            ),
          ]),
        ),
      ])
    }
  }

  // Tools, and how the model may choose among them
  let fields = case gen_request.tools {
    [] -> fields
    tools -> {
      let declarations =
        json.object([
          #(
            "functionDeclarations",
            json.preprocessed_array(encode_tools(tools)),
          ),
        ])
      let fields =
        list.append(fields, [
          #("tools", json.preprocessed_array([declarations])),
        ])
      case encode_function_calling_config(gen_request.tool_choice) {
        None -> fields
        Some(calling) ->
          list.append(fields, [
            #("toolConfig", json.object([#("functionCallingConfig", calling)])),
          ])
      }
    }
  }

  let settings = gen_request.settings
  let format_fields = case gen_request.response_format {
    provider.TextFormat -> []
    provider.JsonFormat(schema: None, ..) -> [
      #("responseMimeType", json.string("application/json")),
    ]
    provider.JsonFormat(schema: Some(output_schema), ..) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseJsonSchema", schema.to_json(output_schema)),
    ]
  }
  let gen_config_fields =
    list.flatten([
      optional("maxOutputTokens", settings.max_output_tokens, json.int),
      optional("temperature", settings.temperature, json.float),
      optional("topP", settings.top_p, json.float),
      optional("topK", settings.top_k, json.int),
      optional("stopSequences", settings.stop_sequences, json.array(
        _,
        json.string,
      )),
      optional("seed", settings.seed, json.int),
      optional("presencePenalty", settings.presence_penalty, json.float),
      optional("frequencyPenalty", settings.frequency_penalty, json.float),
      optional("thinkingConfig", encode_thinking_config(settings), fn(c) { c }),
      format_fields,
    ])

  let fields = case gen_config_fields {
    [] -> fields
    _ ->
      list.append(fields, [
        #("generationConfig", json.object(gen_config_fields)),
      ])
  }

  config.with_extra_body(fields, config)
  |> json.object
  |> json.to_string
}

/// A field that is only sent when it has a value.
fn optional(
  name: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    None -> []
    Some(value) -> [#(name, encode(value))]
  }
}

/// `Auto` is Gemini's default, so nothing is sent for it.
fn encode_function_calling_config(
  choice: provider.ToolChoice,
) -> Option(json.Json) {
  case choice {
    provider.Auto -> None
    provider.Required -> Some(json.object([#("mode", json.string("ANY"))]))
    provider.NoTools -> Some(json.object([#("mode", json.string("NONE"))]))
    provider.SpecificTool(name:) ->
      Some(
        json.object([
          #("mode", json.string("ANY")),
          #("allowedFunctionNames", json.array([name], json.string)),
        ]),
      )
  }
}

fn encode_thinking_config(
  settings: provider.ModelSettings,
) -> Option(json.Json) {
  let level = case settings.reasoning_effort {
    None -> []
    Some(effort) -> {
      let level = case effort {
        provider.LowEffort -> "low"
        provider.MediumEffort -> "medium"
        provider.HighEffort | provider.XHighEffort | provider.MaxEffort ->
          "high"
      }
      [#("thinkingLevel", json.string(level))]
    }
  }
  let thoughts = case settings.include_reasoning {
    False -> []
    True -> [#("includeThoughts", json.bool(True))]
  }
  case list.append(level, thoughts) {
    [] -> None
    fields -> Some(json.object(fields))
  }
}

fn split_system(messages: List(Message)) -> #(List(String), List(Message)) {
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

fn encode_contents(messages: List(Message)) -> List(json.Json) {
  list.flat_map(messages, encode_content)
}

fn encode_content(msg: Message) -> List(json.Json) {
  case msg {
    message.SystemMessage(_) -> []
    message.UserMessage(content) -> [
      json.object([
        #("role", json.string("user")),
        #("parts", json.preprocessed_array(list.map(content, encode_user_part))),
      ]),
    ]
    message.AssistantMessage(content) ->
      // A turn with nothing Gemini can read (only another provider's
      // encrypted reasoning, say) is left out: Gemini rejects empty parts.
      case list.filter_map(content, encode_model_part) {
        [] -> []
        parts -> [
          json.object([
            #("role", json.string("model")),
            #("parts", json.preprocessed_array(parts)),
          ]),
        ]
      }
    message.ToolResultMessage(results) -> [
      json.object([
        #("role", json.string("user")),
        #(
          "parts",
          json.preprocessed_array(list.map(results, encode_function_response)),
        ),
      ]),
    ]
  }
}

fn encode_user_part(content: message.UserContent) -> json.Json {
  case content {
    message.UserText(text) -> json.object([#("text", json.string(text))])
    message.UserFile(data, media_type) ->
      case data {
        message.Base64Data(b64) ->
          json.object([
            #(
              "inlineData",
              json.object([
                #("mimeType", json.string(media_type)),
                #("data", json.string(b64)),
              ]),
            ),
          ])
        message.UrlData(url) ->
          json.object([
            #(
              "fileData",
              json.object([
                #("mimeType", json.string(media_type)),
                #("fileUri", json.string(url)),
              ]),
            ),
          ])
      }
  }
}

/// Reasoning goes back marked as a thought so it isn't mistaken for the
/// answer. Encrypted reasoning from other providers has no Gemini form and
/// is left out. A file the model made goes back as it came, with its
/// thought signature.
fn encode_model_part(
  content: message.AssistantContent,
) -> Result(json.Json, Nil) {
  case content {
    message.AssistantText(text) ->
      Ok(json.object([#("text", json.string(text))]))
    message.AssistantReasoning(text, _) ->
      Ok(
        json.object([
          #("text", json.string(text)),
          #("thought", json.bool(True)),
        ]),
      )
    message.AssistantRedactedReasoning(_) -> Error(Nil)
    message.AssistantFile(media_type:, data:, signature:) -> {
      let inline_data =
        json.object([
          #("mimeType", json.string(media_type)),
          #("data", json.string(data)),
        ])
      Ok(
        json.object(case signature {
          None -> [#("inlineData", inline_data)]
          Some(signature) -> [
            #("inlineData", inline_data),
            #("thoughtSignature", json.string(signature)),
          ]
        }),
      )
    }
    message.AssistantToolCall(id, name, args_json) -> {
      let args = json_value.arguments_to_object(args_json)
      let fc =
        json.object([
          #("name", json.string(name)),
          #("args", args),
        ])
      // thoughtSignature is at the part level, sibling to functionCall
      let part_fields = [#("functionCall", fc)]
      let part_fields = case string.starts_with(id, "gemini_sig:") {
        True -> {
          let sig = string.drop_start(id, string.length("gemini_sig:"))
          list.append(part_fields, [
            #("thoughtSignature", json.string(sig)),
          ])
        }
        False -> part_fields
      }
      Ok(json.object(part_fields))
    }
  }
}

fn encode_function_response(result: message.ToolResult) -> json.Json {
  case result {
    message.ToolResultOk(_, tool_name, output) ->
      json.object([
        #(
          "functionResponse",
          json.object([
            #("name", json.string(tool_name)),
            #("response", json.object([#("result", json.string(output))])),
          ]),
        ),
      ])
    message.ToolResultError(_, tool_name, error_message) ->
      json.object([
        #(
          "functionResponse",
          json.object([
            #("name", json.string(tool_name)),
            #("response", json.object([#("error", json.string(error_message))])),
          ]),
        ),
      ])
  }
}

fn encode_tools(tools: List(provider.ToolSpec)) -> List(json.Json) {
  list.map(tools, fn(t) {
    json.object([
      #("name", json.string(t.name)),
      #("description", json.string(t.description)),
      #("parameters", schema.to_json(t.input_schema)),
    ])
  })
}

// --- Response decoding (Gemini format) ---

/// Decode the body of a `generateContent` response.
@internal
pub fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  case json.parse(body, response_decoder()) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode Gemini response",
      ))
    Ok(parsed) ->
      Ok(GenerateResult(
        content: list.filter(parsed.content, fn(part) {
          part != GeneratedText(text: "")
        }),
        finish_reason: case parsed.finish_reason, parsed.blocked {
          Some(reason), _ -> reason
          // A prompt blocked by safety filters comes back with no
          // candidates.
          None, True -> error.ContentFilter
          None, False -> error.Stop
        },
        usage: parsed.usage,
        model_id: model_id,
      ))
  }
}

/// A whole response, or one chunk of a streamed one.
type ParsedResponse {
  ParsedResponse(
    content: List(GeneratedContent),
    /// None in the stream chunks before the last.
    finish_reason: Option(FinishReason),
    /// True when the response has no candidate at all.
    blocked: Bool,
    usage: Usage,
  )
}

fn response_decoder() -> decode.Decoder(ParsedResponse) {
  let candidate_decoder = {
    use content <- decode.optional_field("content", [], {
      use parts <- decode.optional_field(
        "parts",
        [],
        decode.list(part_decoder()),
      )
      decode.success(option.values(parts))
    })
    use finish_reason <- decode.optional_field(
      "finishReason",
      None,
      decode.map(decode.string, Some),
    )
    decode.success(#(content, finish_reason))
  }

  use candidates <- decode.optional_field(
    "candidates",
    [],
    decode.list(candidate_decoder),
  )
  use usage <- decode.optional_field(
    "usageMetadata",
    usage.zero(),
    usage_decoder(),
  )

  decode.success(case candidates {
    [#(parts, reason), ..] ->
      ParsedResponse(
        content: parts,
        finish_reason: option.map(reason, parse_gemini_finish_reason),
        blocked: False,
        usage: usage,
      )
    [] ->
      ParsedResponse(
        content: [],
        finish_reason: None,
        blocked: True,
        usage: usage,
      )
  })
}

/// Gemini counts thinking apart from the answer and counts cached input
/// inside the prompt; glean's totals include both.
fn usage_decoder() -> decode.Decoder(Usage) {
  use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
  use candidates <- decode.optional_field("candidatesTokenCount", 0, decode.int)
  use thoughts <- decode.optional_field("thoughtsTokenCount", 0, decode.int)
  use cached <- decode.optional_field("cachedContentTokenCount", 0, decode.int)
  decode.success(Usage(
    input_tokens: prompt,
    output_tokens: candidates + thoughts,
    cache_read_tokens: cached,
    cache_write_tokens: 0,
    reasoning_tokens: thoughts,
  ))
}

/// Decodes one response part. Thought parts become reasoning and inline
/// data becomes a file; part types glean doesn't use (code execution)
/// decode to None instead of failing the whole response.
fn part_decoder() -> decode.Decoder(Option(GeneratedContent)) {
  let present = fn(name, next) {
    decode.optional_field(name, False, decode.success(True), next)
  }
  use is_function_call <- present("functionCall")
  use is_inline_data <- present("inlineData")
  case is_function_call, is_inline_data {
    True, _ -> decode.map(function_call_part_decoder(), Some)
    False, True -> decode.map(inline_data_part_decoder(), Some)
    False, False -> {
      use text <- decode.optional_field(
        "text",
        None,
        decode.map(decode.string, Some),
      )
      use thought <- decode.optional_field("thought", False, decode.bool)
      case text, thought {
        Some(t), True ->
          decode.success(Some(GeneratedReasoning(text: t, signature: None)))
        Some(t), False -> decode.success(Some(GeneratedText(text: t)))
        None, _ -> decode.success(None)
      }
    }
  }
}

fn inline_data_part_decoder() -> decode.Decoder(GeneratedContent) {
  use #(media_type, data) <- decode.field("inlineData", {
    use media_type <- decode.field("mimeType", decode.string)
    use data <- decode.field("data", decode.string)
    decode.success(#(media_type, data))
  })
  use signature <- decode.optional_field(
    "thoughtSignature",
    None,
    decode.map(decode.string, Some),
  )
  decode.success(GeneratedFile(
    media_type: media_type,
    data: data,
    signature: signature,
  ))
}

fn function_call_part_decoder() -> decode.Decoder(GeneratedContent) {
  use fc <- decode.field("functionCall", {
    use name <- decode.field("name", decode.string)
    use args <- decode.optional_field(
      "args",
      json_value.JsonObject([]),
      json_value.decoder(),
    )
    decode.success(#(name, json_value.to_string(args)))
  })
  // thoughtSignature is at the part level, sibling to functionCall
  use thought_sig <- decode.optional_field(
    "thoughtSignature",
    "",
    decode.string,
  )
  // Encode thoughtSignature in tool_call_id for round-tripping.
  // Use random suffix to avoid duplicate IDs when same tool is called twice.
  let tool_call_id = case thought_sig {
    "" -> "gemini_tc_" <> fc.0 <> "_" <> int.to_string(int.random(999_999_999))
    sig -> "gemini_sig:" <> sig
  }
  decode.success(GeneratedToolCall(
    tool_call_id: tool_call_id,
    tool_name: fc.0,
    arguments_json: fc.1,
  ))
}

fn parse_gemini_finish_reason(reason: String) -> FinishReason {
  case reason {
    "STOP" -> error.Stop
    "MAX_TOKENS" -> error.Length
    "SAFETY"
    | "RECITATION"
    | "BLOCKLIST"
    | "PROHIBITED_CONTENT"
    | "SPII"
    | "IMAGE_SAFETY"
    | "IMAGE_PROHIBITED_CONTENT" -> error.ContentFilter
    // The model wrote a function call Gemini could not read or run.
    "MALFORMED_FUNCTION_CALL" | "UNEXPECTED_TOOL_CALL" -> error.FinishError
    other -> error.Other(other)
  }
}
