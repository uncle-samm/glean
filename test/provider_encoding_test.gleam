//// Request and response shapes for the HTTP providers, checked without a
//// network: what glean sends for reasoning, structured output and tools,
//// and what it reads back.

import gleam/option.{None, Some}
import gleam/string
import glean/error
import glean/message
import glean/provider.{GenerateRequest}
import glean/providers/anthropic
import glean/providers/config
import glean/providers/openai_compatible
import glean/schema
import gleeunit/should

fn request(
  messages: List(message.Message),
  format: provider.ResponseFormat,
) -> provider.GenerateRequest {
  GenerateRequest(
    messages: messages,
    settings: provider.default_settings(),
    tools: [],
    tool_choice: provider.Auto,
    response_format: format,
  )
}

fn person() -> schema.Schema {
  schema.object(
    properties: [#("name", schema.string()), #("age", schema.int())],
    required: ["name", "age"],
  )
}

fn history() -> List(message.Message) {
  [
    message.user("hi"),
    message.AssistantMessage([
      message.AssistantReasoning("thinking hard", Some("sig-1")),
      message.AssistantReasoning("from another provider", None),
      message.AssistantRedactedReasoning("opaque"),
      message.AssistantText(""),
      message.AssistantToolCall("t1", "lookup", "{\"q\":\"x\"}"),
    ]),
    message.tool_results([message.ToolResultOk("t1", "lookup", "found")]),
  ]
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

// --- Anthropic ---

pub fn anthropic_replays_signed_thinking_only_test() {
  let assert Ok(body) =
    anthropic.encode_request("m", request(history(), provider.TextFormat), False)
  contains(
    body,
    "{\"type\":\"thinking\",\"thinking\":\"thinking hard\",\"signature\":\"sig-1\"}",
  )
  contains(body, "{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}")
  // Unsigned reasoning can't be replayed, and empty text is rejected by
  // the API, so neither is sent.
  lacks(body, "from another provider")
  lacks(body, "\"text\":\"\"")
  // Tool input goes as an object, not a string.
  contains(body, "\"input\":{\"q\":\"x\"}")
}

pub fn anthropic_structured_output_and_effort_test() {
  let req =
    GenerateRequest(
      ..request(
        [message.user("hi")],
        provider.JsonFormat(schema: Some(person()), name: None),
      ),
      settings: provider.ModelSettings(
        ..provider.default_settings(),
        reasoning_effort: Some(provider.LowEffort),
      ),
    )
  let assert Ok(body) = anthropic.encode_request("m", req, False)
  contains(body, "\"output_config\":{\"format\":{\"type\":\"json_schema\"")
  contains(body, "\"additionalProperties\":false")
  contains(body, "\"effort\":\"low\"")
}

pub fn anthropic_json_without_schema_is_a_config_error_test() {
  case
    anthropic.encode_request(
      "m",
      request([message.user("hi")], provider.JsonFormat(None, None)),
      False,
    )
  {
    Error(error.ConfigError(..)) -> Nil
    _ -> panic as "Expected ConfigError"
  }
}

pub fn anthropic_decodes_thinking_with_signature_test() {
  let body =
    "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\",\"signature\":\"s\"},"
    <> "{\"type\":\"redacted_thinking\",\"data\":\"d\"},"
    <> "{\"type\":\"text\",\"text\":\"done\"}],"
    <> "\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}"
  let assert Ok(result) = anthropic.decode_response("m", body)
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "hmm", signature: Some("s")),
    provider.GeneratedRedactedReasoning(data: "d"),
    provider.GeneratedText(text: "done"),
  ])
}

// --- OpenAI-compatible ---

pub fn openai_sends_reasoning_content_only_when_configured_test() {
  let req = request(history(), provider.TextFormat)
  let plain = config.new(api_key: "k", model: "m")
  openai_compatible.encode_request(plain, req, False)
  |> lacks("reasoning_content")

  let deepseek = config.send_reasoning_content(plain, True)
  let body = openai_compatible.encode_request(deepseek, req, False)
  // Only the text of all reasoning parts is sent, as one field.
  contains(body, "\"reasoning_content\":\"thinking hardfrom another provider\"")
}

pub fn openai_strict_only_for_strict_compatible_schemas_test() {
  let cfg = config.new(api_key: "k", model: "m")
  let body =
    openai_compatible.encode_request(
      cfg,
      request(
        [message.user("hi")],
        provider.JsonFormat(Some(person()), Some("person")),
      ),
      False,
    )
  contains(body, "\"name\":\"person\",\"schema\"")
  contains(body, "\"strict\":true")

  let optional_age =
    schema.object(
      properties: [#("name", schema.string()), #("age", schema.int())],
      required: ["name"],
    )
  let body =
    openai_compatible.encode_request(
      cfg,
      request([message.user("hi")], provider.JsonFormat(Some(optional_age), None)),
      False,
    )
  contains(body, "\"strict\":false")
  lacks(body, "additionalProperties")
}

pub fn openai_stream_usage_and_effort_test() {
  let cfg = config.new(api_key: "k", model: "m") |> config.stream_usage(True)
  let req =
    GenerateRequest(
      ..request([message.user("hi")], provider.TextFormat),
      settings: provider.ModelSettings(
        ..provider.default_settings(),
        reasoning_effort: Some(provider.HighEffort),
      ),
    )
  let body = openai_compatible.encode_request(cfg, req, True)
  contains(body, "\"stream_options\":{\"include_usage\":true}")
  contains(body, "\"reasoning_effort\":\"high\"")
}

pub fn openai_decodes_reasoning_content_test() {
  let body =
    "{\"choices\":[{\"message\":{\"content\":\"4\",\"reasoning_content\":\"2+2\"},"
    <> "\"finish_reason\":\"stop\"}]}"
  let assert Ok(result) = openai_compatible.decode_response("m", body)
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "2+2", signature: None),
    provider.GeneratedText(text: "4"),
  ])
}
