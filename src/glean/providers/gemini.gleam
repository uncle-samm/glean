/// Google Gemini provider (gemini-2.5-pro, gemini-2.5-flash, etc.)
/// Uses the Gemini REST API format (different from OpenAI).
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import glean/error.{type FinishReason, type GleanError}
import glean/json_value
import glean/message.{type Message}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type GeneratedContent,
  type Provider, GenerateResult, GeneratedText, GeneratedToolCall, Provider,
}
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils
import glean/providers/sse
import glean/schema
import glean/stream.{type StreamEvent, type Usage, Usage}
import httpp/sse as httpp_sse

const base_url = "https://generativelanguage.googleapis.com/v1beta"

/// Create a Gemini provider.
///
/// ## Example
///
/// ```gleam
/// let provider = gemini.new(api_key: "AIza...", model: "gemini-2.5-pro")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
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
  let body = encode_request(gen_request)
  let url = config.base_url <> "/models/" <> config.model <> ":generateContent"

  case make_http_request(config, url, body) {
    Error(err) -> Error(err)
    Ok(response_body) -> decode_response(config.model, response_body)
  }
}

// --- Streaming ---

type GeminiStreamAccumulator {
  GeminiStreamAccumulator(
    text: string_tree.StringTree,
    tool_calls: List(GeminiStreamToolCall),
    finish_reason: FinishReason,
    usage: Usage,
    /// True once a chunk carrying a finishReason has been seen.
    finished: Bool,
  )
}

type GeminiStreamToolCall {
  GeminiStreamToolCall(id: String, name: String, args_json: String)
}

fn do_stream(
  config: ProviderConfig,
  gen_request: GenerateRequest,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(GenerateResult, GleanError) {
  let body = encode_request(gen_request)
  let url =
    config.base_url
    <> "/models/"
    <> config.model
    <> ":streamGenerateContent?alt=sse"

  // The API key goes in a header, never the URL, so it can't leak into
  // logs, proxies, or error messages.
  let headers = [
    #("x-goog-api-key", config.api_key),
    ..list.map(config.headers, fn(h) { #(h.0, h.1) })
  ]

  case sse.start_stream(url, headers, body, config.timeout_ms) {
    Error(msg) ->
      Error(error.ProviderError(
        provider: "gemini",
        model: config.model,
        status: 0,
        message: "Streaming failed: " <> msg,
      ))
    Ok(#(event_subject, manager_subject)) -> {
      let acc =
        GeminiStreamAccumulator(
          text: string_tree.new(),
          tool_calls: [],
          finish_reason: error.Stop,
          usage: stream.zero_usage(),
          finished: False,
        )

      use final_acc <- result.try(gemini_stream_loop(
        event_subject,
        manager_subject,
        acc,
        on_event,
        config.model,
        config.timeout_ms,
      ))

      let text_content = case string_tree.to_string(final_acc.text) {
        "" -> []
        t -> [GeneratedText(text: t)]
      }

      let tool_content =
        list.map(final_acc.tool_calls, fn(tc) {
          GeneratedToolCall(
            tool_call_id: tc.id,
            tool_name: tc.name,
            arguments_json: tc.args_json,
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

/// Receive SSE events until the stream closes.
///
/// Gemini ends a stream by closing the connection, so `Closed` is only a
/// success after a chunk carrying a finishReason. Timeouts, early closes
/// (including non-2xx responses, whose status the SSE client hides) and
/// in-stream error payloads are returned as errors.
fn gemini_stream_loop(
  subject: process.Subject(httpp_sse.SSEEvent),
  manager: process.Subject(httpp_sse.SSEManagerMessage),
  acc: GeminiStreamAccumulator,
  on_event: fn(StreamEvent) -> Nil,
  model: String,
  timeout_ms: Int,
) -> Result(GeminiStreamAccumulator, GleanError) {
  case process.receive(subject, timeout_ms) {
    Error(_) -> {
      process.send(manager, httpp_sse.Shutdown)
      Error(error.Timeout(after_ms: timeout_ms))
    }
    Ok(httpp_sse.Closed) ->
      case acc.finished {
        True -> Ok(acc)
        False ->
          Error(error.ProviderError(
            provider: "gemini",
            model: model,
            status: 0,
            message: "Stream closed before the response finished",
          ))
      }
    Ok(httpp_sse.Event(_event_type, _event_id, data)) ->
      case json.parse(data, stream_error_decoder()) {
        Ok(message) -> {
          process.send(manager, httpp_sse.Shutdown)
          Error(error.ProviderError(
            provider: "gemini",
            model: model,
            status: 0,
            message: message,
          ))
        }
        Error(_) ->
          gemini_stream_loop(
            subject,
            manager,
            process_gemini_chunk(acc, data, on_event),
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
  acc: GeminiStreamAccumulator,
  data: String,
  on_event: fn(StreamEvent) -> Nil,
) -> GeminiStreamAccumulator {
  let decoder = gemini_chunk_decoder()
  case json.parse(data, decoder) {
    Error(_) -> acc
    Ok(chunk) -> {
      // Process each content piece from this chunk
      let acc =
        list.fold(chunk.content, acc, fn(a, content) {
          case content {
            GeneratedText(text: text) -> {
              on_event(stream.TextDelta(id: "gemini", delta: text))
              GeminiStreamAccumulator(
                ..a,
                text: string_tree.append(a.text, text),
              )
            }
            provider.GeneratedReasoning(text: text) -> {
              on_event(stream.ReasoningDelta(id: "gemini", delta: text))
              a
            }
            GeneratedToolCall(
              tool_call_id: id,
              tool_name: name,
              arguments_json: args,
            ) -> {
              on_event(stream.ToolCallStart(
                id: "gemini",
                tool_call_id: id,
                tool_name: name,
              ))
              on_event(stream.ToolCallDelta(
                id: "gemini",
                tool_call_id: id,
                delta: args,
              ))
              on_event(stream.ToolCallEnd(id: "gemini", tool_call_id: id))
              GeminiStreamAccumulator(
                ..a,
                tool_calls: list.append(a.tool_calls, [
                  GeminiStreamToolCall(id: id, name: name, args_json: args),
                ]),
              )
            }
          }
        })

      // Update finish reason if present in this chunk
      let acc = case chunk.finish_reason {
        "" -> acc
        fr ->
          GeminiStreamAccumulator(
            ..acc,
            finish_reason: parse_gemini_finish_reason(fr),
            finished: True,
          )
      }

      // Update usage if present in this chunk
      case chunk.usage {
        Usage(input_tokens: 0, output_tokens: 0) -> acc
        u -> GeminiStreamAccumulator(..acc, usage: u)
      }
    }
  }
}

type GeminiChunk {
  GeminiChunk(
    content: List(GeneratedContent),
    finish_reason: String,
    usage: Usage,
  )
}

fn gemini_chunk_decoder() -> decode.Decoder(GeminiChunk) {
  let part_decoder =
    decode.one_of(text_part_decoder(), [function_call_part_decoder()])

  let candidate_decoder = {
    use content <- decode.optional_field("content", [], {
      use parts <- decode.optional_field("parts", [], decode.list(part_decoder))
      decode.success(parts)
    })
    use finish_reason <- decode.optional_field(
      "finishReason",
      "",
      decode.string,
    )
    decode.success(#(content, finish_reason))
  }

  let usage_decoder = {
    use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
    use candidates <- decode.optional_field(
      "candidatesTokenCount",
      0,
      decode.int,
    )
    decode.success(Usage(input_tokens: prompt, output_tokens: candidates))
  }

  use candidates <- decode.optional_field(
    "candidates",
    [],
    decode.list(candidate_decoder),
  )
  use usage <- decode.optional_field(
    "usageMetadata",
    Usage(input_tokens: 0, output_tokens: 0),
    usage_decoder,
  )

  let #(content, finish_reason) = case candidates {
    [#(parts, fr), ..] -> #(parts, fr)
    [] -> #([], "")
  }

  decode.success(GeminiChunk(
    content: content,
    finish_reason: finish_reason,
    usage: usage,
  ))
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

fn encode_request(gen_request: GenerateRequest) -> String {
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

  // Tools
  let fields = case gen_request.tools {
    [] -> fields
    tools ->
      list.append(fields, [
        #(
          "tools",
          json.preprocessed_array([
            json.object([
              #(
                "functionDeclarations",
                json.preprocessed_array(encode_tools(tools)),
              ),
            ]),
          ]),
        ),
      ])
  }

  // Generation config
  let gen_config_fields = []

  let gen_config_fields = case gen_request.settings.max_output_tokens {
    None -> gen_config_fields
    Some(max) ->
      list.append(gen_config_fields, [#("maxOutputTokens", json.int(max))])
  }

  let gen_config_fields = case gen_request.settings.temperature {
    None -> gen_config_fields
    Some(temp) ->
      list.append(gen_config_fields, [#("temperature", json.float(temp))])
  }

  let gen_config_fields = case gen_request.settings.top_p {
    None -> gen_config_fields
    Some(p) -> list.append(gen_config_fields, [#("topP", json.float(p))])
  }

  let gen_config_fields = case gen_request.settings.top_k {
    None -> gen_config_fields
    Some(k) -> list.append(gen_config_fields, [#("topK", json.int(k))])
  }

  let gen_config_fields = case gen_request.settings.stop_sequences {
    None -> gen_config_fields
    Some(stops) ->
      list.append(gen_config_fields, [
        #("stopSequences", json.array(stops, json.string)),
      ])
  }

  let fields = case gen_config_fields {
    [] -> fields
    _ ->
      list.append(fields, [
        #("generationConfig", json.object(gen_config_fields)),
      ])
  }

  json.object(fields)
  |> json.to_string
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
    message.AssistantMessage(content) -> [
      json.object([
        #("role", json.string("model")),
        #(
          "parts",
          json.preprocessed_array(list.map(content, encode_model_part)),
        ),
      ]),
    ]
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

fn encode_model_part(content: message.AssistantContent) -> json.Json {
  case content {
    message.AssistantText(text) -> json.object([#("text", json.string(text))])
    message.AssistantReasoning(text) ->
      json.object([#("text", json.string(text))])
    message.AssistantToolCall(id, name, args_json) -> {
      let args = json_value.parse_to_json(args_json)
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
      json.object(part_fields)
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

fn decode_response(
  model_id: String,
  body: String,
) -> Result(GenerateResult, GleanError) {
  let decoder = gemini_response_decoder()
  case json.parse(body, decoder) {
    Error(_) ->
      Error(error.JsonParseError(
        input: body,
        message: "Failed to decode Gemini response",
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

fn gemini_response_decoder() -> decode.Decoder(ParsedResponse) {
  let usage_decoder = {
    use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
    use candidates <- decode.optional_field(
      "candidatesTokenCount",
      0,
      decode.int,
    )
    decode.success(Usage(input_tokens: prompt, output_tokens: candidates))
  }

  // Parts can be text or functionCall
  let part_decoder =
    decode.one_of(text_part_decoder(), [function_call_part_decoder()])

  let candidate_decoder = {
    use content <- decode.field("content", {
      use parts <- decode.field("parts", decode.list(part_decoder))
      decode.success(parts)
    })
    use finish_reason <- decode.optional_field(
      "finishReason",
      "STOP",
      decode.string,
    )
    decode.success(#(content, finish_reason))
  }

  use candidates <- decode.field("candidates", decode.list(candidate_decoder))
  use usage <- decode.optional_field(
    "usageMetadata",
    Usage(input_tokens: 0, output_tokens: 0),
    usage_decoder,
  )

  let #(content, finish_reason) = case candidates {
    [#(parts, fr), ..] -> #(parts, parse_gemini_finish_reason(fr))
    [] -> #([], error.Stop)
  }

  decode.success(ParsedResponse(
    content: content,
    finish_reason: finish_reason,
    usage: usage,
  ))
}

fn text_part_decoder() -> decode.Decoder(GeneratedContent) {
  use text <- decode.field("text", decode.string)
  decode.success(GeneratedText(text: text))
}

fn function_call_part_decoder() -> decode.Decoder(GeneratedContent) {
  use fc <- decode.field("functionCall", {
    use name <- decode.field("name", decode.string)
    use args <- decode.field("args", decode.dynamic)
    let args_json = json_value.dynamic_to_string(args)
    decode.success(#(name, args_json))
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
    "SAFETY" -> error.ContentFilter
    "RECITATION" -> error.ContentFilter
    other -> error.Other(other)
  }
}
