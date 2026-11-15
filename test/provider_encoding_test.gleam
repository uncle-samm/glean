//// Request and response shapes for the HTTP providers, checked without a
//// network: what glean sends for reasoning, structured output and tools,
//// and what it reads back.

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/error
import glean/message
import glean/provider.{GenerateRequest}
import glean/providers/anthropic
import glean/providers/config
import glean/providers/openai_compatible
import glean/schema
import glean/usage.{Usage}
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

fn claude() -> config.ProviderConfig {
  config.new(api_key: "k", model: "m")
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
    anthropic.encode_request(
      claude(),
      request(history(), provider.TextFormat),
      False,
    )
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
  let assert Ok(body) = anthropic.encode_request(claude(), req, False)
  contains(body, "\"output_config\":{\"format\":{\"type\":\"json_schema\"")
  contains(body, "\"additionalProperties\":false")
  contains(body, "\"effort\":\"low\"")
}

pub fn anthropic_json_without_schema_is_a_config_error_test() {
  case
    anthropic.encode_request(
      claude(),
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
  let assert Ok(body) = openai_compatible.encode_request(plain, req, False)
  lacks(body, "reasoning_content")

  let deepseek = config.send_reasoning_content(plain, True)
  let assert Ok(body) = openai_compatible.encode_request(deepseek, req, False)
  // Only the text of all reasoning parts is sent, as one field.
  contains(body, "\"reasoning_content\":\"thinking hardfrom another provider\"")
}

pub fn openai_strict_only_for_strict_compatible_schemas_test() {
  let cfg = config.new(api_key: "k", model: "m")
  let assert Ok(body) =
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
  let assert Ok(body) =
    openai_compatible.encode_request(
      cfg,
      request(
        [message.user("hi")],
        provider.JsonFormat(Some(optional_age), None),
      ),
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
  let assert Ok(body) = openai_compatible.encode_request(cfg, req, True)
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

// --- Claude: reasoning, caching, schema limits, files, usage ---

fn with_settings(
  req: provider.GenerateRequest,
  effort: option.Option(provider.ReasoningEffort),
  include_reasoning: Bool,
) -> provider.GenerateRequest {
  GenerateRequest(
    ..req,
    settings: provider.ModelSettings(
      ..provider.default_settings(),
      reasoning_effort: effort,
      include_reasoning: include_reasoning,
    ),
  )
}

pub fn anthropic_thinking_is_asked_for_test() {
  let body = fn(effort, include) {
    let assert Ok(body) =
      anthropic.encode_request(
        claude(),
        with_settings(
          request([message.user("hi")], provider.TextFormat),
          effort,
          include,
        ),
        False,
      )
    body
  }
  // Nothing asked: the model's own default.
  lacks(body(None, False), "\"thinking\"")
  // An effort turns thinking on for the models that don't think unasked.
  contains(
    body(Some(provider.HighEffort), False),
    "\"thinking\":{\"type\":\"adaptive\"}",
  )
  // Asking for the reasoning text asks for its summary.
  contains(
    body(None, True),
    "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}",
  )
  contains(body(Some(provider.MaxEffort), True), "\"display\":\"summarized\"")
  contains(body(Some(provider.MaxEffort), True), "\"effort\":\"max\"")
  contains(body(Some(provider.XHighEffort), False), "\"effort\":\"xhigh\"")
}

pub fn anthropic_prompt_caching_is_a_top_level_field_test() {
  let req = request([message.user("hi")], provider.TextFormat)
  let assert Ok(off) = anthropic.encode_request(claude(), req, False)
  lacks(off, "cache_control")

  let assert Ok(on) =
    anthropic.encode_request(
      claude() |> config.prompt_caching(True),
      req,
      False,
    )
  contains(on, "\"cache_control\":{\"type\":\"ephemeral\"}")
}

pub fn anthropic_sends_extra_body_fields_test() {
  let cfg =
    claude()
    |> config.extra_body_field("service_tier", json.string("auto"))
    |> config.extra_body_field("max_tokens", json.int(123))
  let assert Ok(body) =
    anthropic.encode_request(
      cfg,
      request([message.user("hi")], provider.TextFormat),
      False,
    )
  contains(body, "\"service_tier\":\"auto\"")
  // An extra field replaces glean's own field of the same name.
  contains(body, "\"max_tokens\":123")
  string.split(body, "\"max_tokens\"") |> list.length |> should.equal(2)
}

pub fn anthropic_structured_output_moves_limits_into_descriptions_test() {
  let limited =
    schema.object(
      properties: [
        #("age", schema.int_range(minimum: 0, maximum: 150)),
        #(
          "name",
          schema.string_with_length(min_length: Some(1), max_length: Some(40))
            |> schema.describe(description: "Full name."),
        ),
        #(
          "tags",
          schema.array(of: schema.string_with_length(
            min_length: None,
            max_length: Some(8),
          )),
        ),
      ],
      required: ["age", "name", "tags"],
    )
  let assert Ok(body) =
    anthropic.encode_request(
      claude(),
      request(
        [message.user("hi")],
        provider.JsonFormat(schema: Some(limited), name: None),
      ),
      False,
    )
  // Claude's structured outputs reject these keywords.
  lacks(body, "\"minimum\"")
  lacks(body, "\"maximum\"")
  lacks(body, "\"minLength\"")
  lacks(body, "\"maxLength\"")
  // The model is still told about them.
  contains(body, "\"description\":\"Between 0 and 150.\"")
  contains(body, "\"description\":\"Full name. Between 1 and 40 characters.\"")
  contains(body, "\"description\":\"At most 8 characters.\"")

  // And glean still checks them in the answer.
  let assert Error([error.ValidationError(path: ["age"], ..)]) =
    schema.validate_json(limited, "{\"age\":200,\"name\":\"Sam\",\"tags\":[]}")
}

pub fn anthropic_tool_schemas_keep_their_limits_test() {
  // Only structured outputs reject limits; tool input schemas take them.
  let req =
    GenerateRequest(
      ..request([message.user("hi")], provider.TextFormat),
      tools: [
        provider.ToolSpec(
          name: "set_age",
          description: "Set the age",
          input_schema: schema.object(
            properties: [#("age", schema.int_range(minimum: 0, maximum: 150))],
            required: ["age"],
          ),
        ),
      ],
    )
  let assert Ok(body) = anthropic.encode_request(claude(), req, False)
  contains(body, "\"minimum\":0")
  contains(body, "\"maximum\":150")
}

fn user_file(data: message.FileData, media_type: String) -> message.Message {
  message.user_parts([
    message.UserText("What is this?"),
    message.UserFile(data: data, media_type: media_type),
  ])
}

pub fn anthropic_files_test() {
  let body = fn(data, media_type) {
    anthropic.encode_request(
      claude(),
      request([user_file(data, media_type)], provider.TextFormat),
      False,
    )
  }
  let assert Ok(image) = body(message.Base64Data("aGVsbG8="), "image/png")
  contains(
    image,
    "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}}",
  )
  let assert Ok(image_url) =
    body(message.UrlData("https://example.com/cat.webp"), "image/webp")
  contains(
    image_url,
    "{\"type\":\"image\",\"source\":{\"type\":\"url\",\"url\":\"https://example.com/cat.webp\"}}",
  )
  let assert Ok(pdf) = body(message.Base64Data("JVBERg=="), "application/pdf")
  contains(
    pdf,
    "{\"type\":\"document\",\"source\":{\"type\":\"base64\",\"media_type\":\"application/pdf\",\"data\":\"JVBERg==\"}}",
  )
  // Plain text is sent as the text itself: "hello" is aGVsbG8= in base64.
  let assert Ok(text) = body(message.Base64Data("aGVsbG8="), "text/plain")
  contains(
    text,
    "{\"type\":\"document\",\"source\":{\"type\":\"text\",\"media_type\":\"text/plain\",\"data\":\"hello\"}}",
  )
}

pub fn anthropic_files_it_cannot_take_are_config_errors_test() {
  let rejected = fn(data, media_type) {
    case
      anthropic.encode_request(
        claude(),
        request([user_file(data, media_type)], provider.TextFormat),
        False,
      )
    {
      Error(error.ConfigError(message:)) -> message
      Ok(_) -> panic as { "Expected a ConfigError for " <> media_type }
      Error(other) -> panic as error.to_string(other)
    }
  }
  // Before this, a WAV file was sent as an image block.
  contains(rejected(message.Base64Data("UklGRg=="), "audio/wav"), "audio/wav")
  contains(rejected(message.Base64Data("AAAA"), "image/tiff"), "image/tiff")
  contains(
    rejected(message.UrlData("https://example.com/a.txt"), "text/plain"),
    "Base64Data",
  )
  // Not base64, and base64 of bytes that aren't UTF-8.
  contains(rejected(message.Base64Data("***"), "text/plain"), "UTF-8")
  contains(rejected(message.Base64Data("//79"), "text/plain"), "UTF-8")
}

pub fn anthropic_leaves_out_files_other_models_made_test() {
  let assert Ok(body) =
    anthropic.encode_request(
      claude(),
      request(
        [
          message.user("draw"),
          message.AssistantMessage([
            message.AssistantText("Here."),
            message.AssistantFile(
              media_type: "image/png",
              data: "aGVsbG8=",
              signature: Some("sig"),
            ),
          ]),
          message.user("thanks"),
        ],
        provider.TextFormat,
      ),
      False,
    )
  contains(body, "Here.")
  lacks(body, "aGVsbG8=")
}

pub fn anthropic_usage_counts_cached_tokens_test() {
  let body =
    "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\","
    <> "\"usage\":{\"input_tokens\":5,\"cache_creation_input_tokens\":100,"
    <> "\"cache_read_input_tokens\":2000,\"output_tokens\":7}}"
  let assert Ok(result) = anthropic.decode_response("m", body)
  result.usage
  |> should.equal(Usage(
    // Claude reports the three kinds of input apart; the total is all three.
    input_tokens: 2105,
    output_tokens: 7,
    cache_read_tokens: 2000,
    cache_write_tokens: 100,
    reasoning_tokens: 0,
  ))

  // Without caching the numbers are as before, also when the API sends
  // null for the cache fields.
  let plain =
    "{\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,"
    <> "\"output_tokens\":4,\"cache_creation_input_tokens\":null}}"
  let assert Ok(result) = anthropic.decode_response("m", plain)
  result.usage |> should.equal(usage.new(input_tokens: 3, output_tokens: 4))
}

// --- OpenAI-compatible: content parts, usage details, files ---

pub fn openai_decodes_content_given_as_parts_test() {
  // Mistral's reasoning models answer with a list of parts.
  let body =
    "{\"choices\":[{\"message\":{\"content\":["
    <> "{\"type\":\"thinking\",\"thinking\":[{\"type\":\"text\",\"text\":\"2+2 \"},{\"type\":\"text\",\"text\":\"is 4\"}]},"
    <> "{\"type\":\"text\",\"text\":\"The answer \"},"
    <> "{\"type\":\"reference\",\"reference_ids\":[1]},"
    <> "{\"type\":\"text\",\"text\":\"is 4.\"}"
    <> "]},\"finish_reason\":\"stop\"}]}"
  let assert Ok(result) = openai_compatible.decode_response("m", body)
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "2+2 is 4", signature: None),
    provider.GeneratedText(text: "The answer is 4."),
  ])
}

pub fn openai_decodes_null_content_test() {
  let body =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"t1\","
    <> "\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},"
    <> "\"finish_reason\":\"tool_calls\"}]}"
  let assert Ok(result) = openai_compatible.decode_response("m", body)
  result.content
  |> should.equal([
    provider.GeneratedToolCall(
      tool_call_id: "t1",
      tool_name: "lookup",
      arguments_json: "{}",
    ),
  ])
}

pub fn openai_usage_details_test() {
  let usage_of = fn(usage_json) {
    let assert Ok(result) =
      openai_compatible.decode_response(
        "m",
        "{\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":"
          <> usage_json
          <> "}",
      )
    result.usage
  }
  // OpenAI's shape.
  usage_of(
    "{\"prompt_tokens\":100,\"completion_tokens\":50,"
    <> "\"prompt_tokens_details\":{\"cached_tokens\":80},"
    <> "\"completion_tokens_details\":{\"reasoning_tokens\":30}}",
  )
  |> should.equal(Usage(
    input_tokens: 100,
    output_tokens: 50,
    cache_read_tokens: 80,
    cache_write_tokens: 0,
    reasoning_tokens: 30,
  ))
  // DeepSeek's shape.
  usage_of(
    "{\"prompt_tokens\":100,\"completion_tokens\":50,"
    <> "\"prompt_cache_hit_tokens\":64,\"prompt_cache_miss_tokens\":36}",
  )
  |> should.equal(Usage(
    input_tokens: 100,
    output_tokens: 50,
    cache_read_tokens: 64,
    cache_write_tokens: 0,
    reasoning_tokens: 0,
  ))
  // No details, and details sent as null.
  usage_of("{\"prompt_tokens\":3,\"completion_tokens\":4}")
  |> should.equal(usage.new(input_tokens: 3, output_tokens: 4))
  usage_of(
    "{\"prompt_tokens\":3,\"completion_tokens\":4,"
    <> "\"prompt_tokens_details\":null,\"completion_tokens_details\":{\"reasoning_tokens\":null}}",
  )
  |> should.equal(usage.new(input_tokens: 3, output_tokens: 4))
}

pub fn openai_finish_reasons_test() {
  let reason = fn(name) {
    let assert Ok(result) =
      openai_compatible.decode_response(
        "m",
        "{\"choices\":[{\"message\":{\"content\":\"x\"},\"finish_reason\":\""
          <> name
          <> "\"}]}",
      )
    result.finish_reason
  }
  reason("stop") |> should.equal(error.Stop)
  reason("length") |> should.equal(error.Length)
  reason("tool_calls") |> should.equal(error.ToolCalls)
  // The older name for the same thing.
  reason("function_call") |> should.equal(error.ToolCalls)
  reason("content_filter") |> should.equal(error.ContentFilter)
  // OpenRouter: the upstream provider failed part way.
  reason("error") |> should.equal(error.FinishError)
}

pub fn openai_files_test() {
  let cfg = config.new(api_key: "k", model: "m")
  let body = fn(data, media_type) {
    openai_compatible.encode_request(
      cfg,
      request([user_file(data, media_type)], provider.TextFormat),
      False,
    )
  }
  let assert Ok(image) = body(message.Base64Data("aGVsbG8="), "image/png")
  contains(
    image,
    "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}}",
  )
  let assert Ok(image_url) =
    body(message.UrlData("https://example.com/cat.png"), "image/png")
  contains(image_url, "\"image_url\":{\"url\":\"https://example.com/cat.png\"}")
  let assert Ok(pdf) = body(message.Base64Data("JVBERg=="), "application/pdf")
  contains(
    pdf,
    "{\"type\":\"file\",\"file\":{\"filename\":\"file.pdf\",\"file_data\":\"data:application/pdf;base64,JVBERg==\"}}",
  )
  let assert Ok(wav) = body(message.Base64Data("UklGRg=="), "audio/wav")
  contains(
    wav,
    "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"}}",
  )
  let assert Ok(mp3) = body(message.Base64Data("SUQz"), "audio/mpeg")
  contains(mp3, "\"format\":\"mp3\"")
}

pub fn openai_files_it_cannot_take_are_config_errors_test() {
  let cfg = config.new(api_key: "k", model: "m")
  let rejected = fn(data, media_type) {
    case
      openai_compatible.encode_request(
        cfg,
        request([user_file(data, media_type)], provider.TextFormat),
        False,
      )
    {
      Error(error.ConfigError(message:)) -> message
      Ok(_) -> panic as { "Expected a ConfigError for " <> media_type }
      Error(other) -> panic as error.to_string(other)
    }
  }
  // Before this, every file was sent as an image.
  contains(rejected(message.Base64Data("aGVsbG8="), "text/plain"), "text/plain")
  contains(rejected(message.Base64Data("AAAA"), "video/mp4"), "video/mp4")
  contains(
    rejected(message.UrlData("https://example.com/a.pdf"), "application/pdf"),
    "Base64Data",
  )
  contains(
    rejected(message.UrlData("https://example.com/a.wav"), "audio/wav"),
    "Base64Data",
  )
}

// --- Schemas ---

pub fn nullable_and_one_of_are_any_of_test() {
  // 3 is an integer and a number: `oneOf` would reject it, `validate`
  // accepts it, and OpenAI's strict mode only knows `anyOf`.
  let number = schema.one_of(variants: [schema.int(), schema.float()])
  let text = schema.to_json_string(number)
  contains(text, "\"anyOf\"")
  lacks(text, "\"oneOf\"")
  let assert Ok(_) = schema.validate_json(number, "3")

  let maybe = schema.to_json_string(schema.nullable(schema.string()))
  contains(maybe, "\"anyOf\"")
  lacks(maybe, "\"oneOf\"")
}
