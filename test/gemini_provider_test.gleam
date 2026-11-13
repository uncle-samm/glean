//// The Gemini provider's request and response shapes and its stream
//// events, checked without a network.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/error
import glean/message
import glean/provider.{GenerateRequest}
import glean/providers/config
import glean/providers/gemini
import glean/providers/sse
import glean/schema
import glean/stream
import glean/usage.{Usage}
import gleeunit/should

fn cfg() -> config.ProviderConfig {
  gemini.default_config(api_key: "k", model: "gemini-test")
}

fn request(messages: List(message.Message)) -> provider.GenerateRequest {
  GenerateRequest(
    messages: messages,
    settings: provider.default_settings(),
    tools: [],
    tool_choice: provider.Auto,
    response_format: provider.TextFormat,
  )
}

fn lookup_tool() -> provider.ToolSpec {
  provider.ToolSpec(
    name: "lookup",
    description: "Look something up",
    input_schema: schema.object(
      properties: [#("q", schema.string())],
      required: ["q"],
    ),
  )
}

fn contains(haystack: String, needle: String) -> Nil {
  case string.contains(haystack, needle) {
    True -> Nil
    False -> panic as { "Expected " <> needle <> " in " <> haystack }
  }
}

fn lacks(haystack: String, needle: String) -> Nil {
  case string.contains(haystack, needle) {
    True -> panic as { "Did not expect " <> needle <> " in " <> haystack }
    False -> Nil
  }
}

// --- Requests ---

pub fn tool_choice_is_sent_test() {
  let body = fn(choice) {
    gemini.encode_request(
      cfg(),
      GenerateRequest(
        ..request([message.user("hi")]),
        tools: [lookup_tool()],
        tool_choice: choice,
      ),
    )
  }
  // Auto is Gemini's default.
  lacks(body(provider.Auto), "toolConfig")
  contains(
    body(provider.Required),
    "\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"ANY\"}}",
  )
  contains(
    body(provider.NoTools),
    "\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"NONE\"}}",
  )
  contains(
    body(provider.SpecificTool(name: "lookup")),
    "\"functionCallingConfig\":{\"mode\":\"ANY\",\"allowedFunctionNames\":[\"lookup\"]}",
  )
}

pub fn tool_choice_without_tools_sends_nothing_test() {
  let body =
    gemini.encode_request(
      cfg(),
      GenerateRequest(
        ..request([message.user("hi")]),
        tool_choice: provider.Required,
      ),
    )
  lacks(body, "toolConfig")
  lacks(body, "\"tools\"")
}

pub fn penalties_are_sent_test() {
  let body =
    gemini.encode_request(
      cfg(),
      GenerateRequest(
        ..request([message.user("hi")]),
        settings: provider.ModelSettings(
          ..provider.default_settings(),
          presence_penalty: Some(0.5),
          frequency_penalty: Some(-0.25),
          max_output_tokens: Some(64),
        ),
      ),
    )
  contains(body, "\"presencePenalty\":0.5")
  contains(body, "\"frequencyPenalty\":-0.25")
  contains(body, "\"maxOutputTokens\":64")
}

pub fn reasoning_settings_become_a_thinking_config_test() {
  let body = fn(effort, include) {
    gemini.encode_request(
      cfg(),
      GenerateRequest(
        ..request([message.user("hi")]),
        settings: provider.ModelSettings(
          ..provider.default_settings(),
          reasoning_effort: effort,
          include_reasoning: include,
        ),
      ),
    )
  }
  lacks(body(None, False), "thinkingConfig")
  lacks(body(None, False), "generationConfig")
  contains(
    body(Some(provider.LowEffort), False),
    "\"thinkingConfig\":{\"thinkingLevel\":\"low\"}",
  )
  contains(
    body(Some(provider.MediumEffort), True),
    "\"thinkingConfig\":{\"thinkingLevel\":\"medium\",\"includeThoughts\":true}",
  )
  // Gemini has nothing above high.
  contains(
    body(Some(provider.XHighEffort), False),
    "\"thinkingLevel\":\"high\"",
  )
  contains(body(Some(provider.MaxEffort), False), "\"thinkingLevel\":\"high\"")
  contains(body(None, True), "\"thinkingConfig\":{\"includeThoughts\":true}")
}

pub fn extra_body_fields_are_sent_test() {
  let with_extra =
    cfg()
    |> config.extra_body_field("cachedContent", json.string("cachedContents/1"))
    |> config.extra_body_field(
      "generationConfig",
      json.object([#("candidateCount", json.int(1))]),
    )
  let body =
    gemini.encode_request(
      with_extra,
      GenerateRequest(
        ..request([message.user("hi")]),
        settings: provider.ModelSettings(
          ..provider.default_settings(),
          max_output_tokens: Some(64),
        ),
      ),
    )
  contains(body, "\"cachedContent\":\"cachedContents/1\"")
  // An extra field replaces glean's field of the same name.
  contains(body, "\"generationConfig\":{\"candidateCount\":1}")
  lacks(body, "maxOutputTokens")
}

pub fn a_generated_file_is_sent_back_with_its_signature_test() {
  let body =
    gemini.encode_request(
      cfg(),
      request([
        message.user("draw a cat"),
        message.AssistantMessage([
          message.AssistantText("Here it is."),
          message.AssistantFile(
            media_type: "image/png",
            data: "aGVsbG8=",
            signature: Some("sig-9"),
          ),
          message.AssistantFile(
            media_type: "image/png",
            data: "d29ybGQ=",
            signature: None,
          ),
        ]),
        message.user("make it orange"),
      ]),
    )
  contains(
    body,
    "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"},\"thoughtSignature\":\"sig-9\"}",
  )
  contains(
    body,
    "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"d29ybGQ=\"}}",
  )
}

pub fn a_turn_gemini_cannot_read_is_left_out_test() {
  let body =
    gemini.encode_request(
      cfg(),
      request([
        message.user("hi"),
        message.AssistantMessage([message.AssistantRedactedReasoning("opaque")]),
        message.user("again"),
      ]),
    )
  lacks(body, "\"role\":\"model\"")
  lacks(body, "\"parts\":[]")
}

// --- Responses ---

pub fn usage_counts_thoughts_and_cached_tokens_test() {
  let body =
    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"4\"}]},\"finishReason\":\"STOP\"}],"
    <> "\"usageMetadata\":{\"promptTokenCount\":100,\"candidatesTokenCount\":20,"
    <> "\"thoughtsTokenCount\":30,\"cachedContentTokenCount\":60,\"totalTokenCount\":150}}"
  let assert Ok(result) = gemini.decode_response("m", body)
  result.usage
  |> should.equal(Usage(
    input_tokens: 100,
    // The answer and the thinking.
    output_tokens: 50,
    cache_read_tokens: 60,
    cache_write_tokens: 0,
    reasoning_tokens: 30,
  ))
}

pub fn a_generated_image_is_decoded_test() {
  let body =
    "{\"candidates\":[{\"content\":{\"parts\":["
    <> "{\"text\":\"thinking\",\"thought\":true},"
    <> "{\"text\":\"Here it is.\"},"
    <> "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"},\"thoughtSignature\":\"sig-9\"},"
    <> "{\"inlineData\":{\"mimeType\":\"image/jpeg\",\"data\":\"d29ybGQ=\"}},"
    <> "{\"executableCode\":{\"code\":\"print(1)\"}},"
    <> "{\"text\":\"\"}"
    <> "]},\"finishReason\":\"STOP\"}]}"
  let assert Ok(result) = gemini.decode_response("m", body)
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "thinking", signature: None),
    provider.GeneratedText(text: "Here it is."),
    provider.GeneratedFile(
      media_type: "image/png",
      data: "aGVsbG8=",
      signature: Some("sig-9"),
    ),
    provider.GeneratedFile(
      media_type: "image/jpeg",
      data: "d29ybGQ=",
      signature: None,
    ),
  ])
  result.usage |> should.equal(usage.zero())
}

pub fn finish_reasons_test() {
  let reason = fn(name) {
    let assert Ok(result) =
      gemini.decode_response(
        "m",
        "{\"candidates\":[{\"finishReason\":\"" <> name <> "\"}]}",
      )
    result.finish_reason
  }
  reason("STOP") |> should.equal(error.Stop)
  reason("MAX_TOKENS") |> should.equal(error.Length)
  reason("SAFETY") |> should.equal(error.ContentFilter)
  reason("RECITATION") |> should.equal(error.ContentFilter)
  reason("BLOCKLIST") |> should.equal(error.ContentFilter)
  reason("PROHIBITED_CONTENT") |> should.equal(error.ContentFilter)
  reason("SPII") |> should.equal(error.ContentFilter)
  reason("IMAGE_SAFETY") |> should.equal(error.ContentFilter)
  reason("MALFORMED_FUNCTION_CALL") |> should.equal(error.FinishError)
  reason("UNEXPECTED_TOOL_CALL") |> should.equal(error.FinishError)
  reason("LANGUAGE") |> should.equal(error.Other("LANGUAGE"))
}

pub fn a_blocked_prompt_is_a_content_filter_finish_test() {
  let assert Ok(result) =
    gemini.decode_response(
      "m",
      "{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}",
    )
  result.finish_reason |> should.equal(error.ContentFilter)
  result.content |> should.equal([])
}

pub fn a_candidate_without_a_finish_reason_stopped_test() {
  let assert Ok(result) =
    gemini.decode_response(
      "m",
      "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}",
    )
  result.finish_reason |> should.equal(error.Stop)
}

pub fn a_body_that_is_not_json_is_an_error_test() {
  let assert Error(error.JsonParseError(input: "<html>", ..)) =
    gemini.decode_response("m", "<html>")
}

// --- Streams ---

fn chunk(parts: String, rest: String) -> sse.SseEvent {
  sse.Event(
    event_type: None,
    data: "{\"candidates\":[{\"content\":{\"parts\":["
      <> parts
      <> "]}"
      <> rest
      <> "}]}",
  )
}

fn run_stream(
  events: List(sse.SseEvent),
) -> #(
  Result(provider.GenerateResult, error.GleanError),
  List(stream.StreamEvent),
) {
  let seen = process.new_subject()
  let result =
    gemini.stream_events(
      sse.from_events(events),
      fn(event) { process.send(seen, event) },
      "gemini-test",
      50,
    )
  #(result, drain(seen, []))
}

fn drain(
  events: process.Subject(stream.StreamEvent),
  acc: List(stream.StreamEvent),
) -> List(stream.StreamEvent) {
  case process.receive(events, 0) {
    Ok(event) -> drain(events, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn every_part_has_start_and_end_events_with_its_own_id_test() {
  let #(result, events) =
    run_stream([
      chunk("{\"text\":\"Let me \",\"thought\":true}", ""),
      chunk("{\"text\":\"think.\",\"thought\":true}", ""),
      chunk("{\"text\":\"The answer \"}", ""),
      chunk(
        "{\"text\":\"is 4.\"},{\"functionCall\":{\"name\":\"lookup\",\"args\":{\"q\":\"x\"}},\"thoughtSignature\":\"s1\"}",
        "",
      ),
      chunk("{\"text\":\"Done.\"}", ",\"finishReason\":\"STOP\""),
      sse.Closed,
    ])

  events
  |> should.equal([
    stream.ReasoningStart(id: "gemini-0"),
    stream.ReasoningDelta(id: "gemini-0", delta: "Let me "),
    stream.ReasoningDelta(id: "gemini-0", delta: "think."),
    stream.ReasoningEnd(id: "gemini-0"),
    stream.TextStart(id: "gemini-1"),
    stream.TextDelta(id: "gemini-1", delta: "The answer "),
    stream.TextDelta(id: "gemini-1", delta: "is 4."),
    stream.TextEnd(id: "gemini-1"),
    stream.ToolCallStart(
      id: "gemini-2",
      tool_call_id: "gemini_sig:s1",
      tool_name: "lookup",
    ),
    stream.ToolCallDelta(
      id: "gemini-2",
      tool_call_id: "gemini_sig:s1",
      delta: "{\"q\":\"x\"}",
    ),
    stream.ToolCallEnd(id: "gemini-2", tool_call_id: "gemini_sig:s1"),
    stream.TextStart(id: "gemini-3"),
    stream.TextDelta(id: "gemini-3", delta: "Done."),
    stream.TextEnd(id: "gemini-3"),
  ])

  // The result holds the same parts, reasoning included, in order.
  let assert Ok(result) = result
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "Let me think.", signature: None),
    provider.GeneratedText(text: "The answer is 4."),
    provider.GeneratedToolCall(
      tool_call_id: "gemini_sig:s1",
      tool_name: "lookup",
      arguments_json: "{\"q\":\"x\"}",
    ),
    provider.GeneratedText(text: "Done."),
  ])
  result.finish_reason |> should.equal(error.Stop)
  result.model_id |> should.equal("gemini-test")
}

pub fn the_last_usage_of_a_stream_wins_test() {
  let usage_chunk = fn(prompt, candidates, rest) {
    sse.Event(
      event_type: None,
      data: "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"a\"}]}"
        <> rest
        <> "}],\"usageMetadata\":{\"promptTokenCount\":"
        <> prompt
        <> ",\"candidatesTokenCount\":"
        <> candidates
        <> ",\"thoughtsTokenCount\":2}}",
    )
  }
  let #(result, _events) =
    run_stream([
      usage_chunk("9", "1", ""),
      usage_chunk("9", "5", ",\"finishReason\":\"MAX_TOKENS\""),
      sse.Closed,
    ])
  let assert Ok(result) = result
  result.usage
  |> should.equal(Usage(
    input_tokens: 9,
    output_tokens: 7,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    reasoning_tokens: 2,
  ))
  result.finish_reason |> should.equal(error.Length)
}

pub fn a_streamed_file_is_in_the_result_test() {
  let #(result, events) =
    run_stream([
      chunk("{\"text\":\"Here.\"}", ""),
      chunk(
        "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"}}",
        ",\"finishReason\":\"STOP\"",
      ),
      sse.Closed,
    ])
  let assert Ok(result) = result
  result.content
  |> should.equal([
    provider.GeneratedText(text: "Here."),
    provider.GeneratedFile(
      media_type: "image/png",
      data: "aGVsbG8=",
      signature: None,
    ),
  ])
  // The text part ended before the file.
  events
  |> should.equal([
    stream.TextStart(id: "gemini-0"),
    stream.TextDelta(id: "gemini-0", delta: "Here."),
    stream.TextEnd(id: "gemini-0"),
  ])
}

pub fn empty_text_parts_open_nothing_test() {
  let #(result, events) =
    run_stream([
      chunk("{\"text\":\"\"}", ",\"finishReason\":\"STOP\""),
      sse.Closed,
    ])
  let assert Ok(result) = result
  result.content |> should.equal([])
  events |> should.equal([])
}

pub fn a_stream_cut_short_is_an_error_test() {
  let #(result, events) =
    run_stream([chunk("{\"text\":\"The ans\"}", ""), sse.Closed])
  let assert Error(error.ProviderError(provider: "gemini", status: 0, ..)) =
    result
  // What arrived was still passed on.
  events
  |> should.equal([
    stream.TextStart(id: "gemini-0"),
    stream.TextDelta(id: "gemini-0", delta: "The ans"),
  ])
}

pub fn stream_failures_are_errors_test() {
  let #(result, _) = run_stream([sse.HttpStatus(429, "slow down")])
  let assert Error(error.ProviderError(status: 429, message: "slow down", ..)) =
    result

  let #(result, _) =
    run_stream([
      sse.Event(None, "{\"error\":{\"message\":\"quota exceeded\"}}"),
    ])
  let assert Error(error.ProviderError(message: "quota exceeded", ..)) = result

  let #(result, _) = run_stream([chunk("{\"text\":\"a\"}", "")])
  result |> should.equal(Error(error.Timeout(after_ms: 50)))
}
