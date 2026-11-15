/// Scripted test provider for deterministic testing.
/// Returns predetermined responses in sequence — no real API calls.
import gleam/list
import glean/error.{type GleanError}
import glean/message
import glean/provider.{
  type GenerateRequest, type GenerateResult, type Provider, GenerateResult,
  GeneratedText, GeneratedToolCall, Provider,
}
import glean/stream.{type StreamEvent}
import glean/usage

/// A scripted response the test provider should return.
pub type ScriptedResponse {
  /// Return a successful text response
  TextResponse(text: String)
  /// Return a response containing tool calls
  ToolCallResponse(calls: List(ScriptedToolCall))
  /// Return a provider error
  ErrorResponse(error: GleanError)
}

/// A tool call to include in a scripted response.
pub type ScriptedToolCall {
  ScriptedToolCall(id: String, name: String, arguments: String)
}

/// Create a test provider that returns scripted responses in order.
///
/// Each call to `generate` consumes the next response from the list.
/// Uses a closure over a mutable index — the one controlled escape hatch
/// for stateful test providers, hidden behind the Provider interface.
///
/// ## Example
///
/// ```gleam
/// let provider = test_provider([
///   ToolCallResponse([ScriptedToolCall("c1", "calc", "{\"a\":1}")]),
///   TextResponse("The answer is 1"),
/// ])
/// ```
pub fn test_provider(responses: List(ScriptedResponse)) -> Provider {
  // Convert to a list of GenerateResults or errors up front
  let indexed_responses =
    responses
    |> list.index_map(fn(r, i) { #(i, r) })

  // We use a simple approach: the provider is stateless but responses
  // are selected based on the number of assistant messages in the
  // conversation (which acts as a step counter).
  let generate_fn = fn(request: GenerateRequest) -> Result(
    GenerateResult,
    GleanError,
  ) {
    let step = count_assistant_messages(request.messages)
    let response = find_response(indexed_responses, step)
    scripted_to_result(response)
  }

  let stream_fn = fn(
    request: GenerateRequest,
    _on_event: fn(StreamEvent) -> Nil,
  ) -> Result(GenerateResult, GleanError) {
    // For test provider, streaming behaves the same as non-streaming
    let step = count_assistant_messages(request.messages)
    let response = find_response(indexed_responses, step)
    scripted_to_result(response)
  }

  Provider(
    name: "test",
    model_id: "test-model",
    generate: generate_fn,
    stream: stream_fn,
  )
}

/// Create a simple text response GenerateResult (for building custom test flows).
pub fn text_result(text: String) -> GenerateResult {
  GenerateResult(
    content: [GeneratedText(text: text)],
    finish_reason: error.Stop,
    usage: usage.new(input_tokens: 10, output_tokens: 5),
    model_id: "test-model",
  )
}

/// Create a tool call response GenerateResult.
pub fn tool_call_result(
  calls: List(#(String, String, String)),
) -> GenerateResult {
  let content =
    list.map(calls, fn(c) {
      GeneratedToolCall(tool_call_id: c.0, tool_name: c.1, arguments_json: c.2)
    })
  GenerateResult(
    content: content,
    finish_reason: error.ToolCalls,
    usage: usage.new(input_tokens: 10, output_tokens: 5),
    model_id: "test-model",
  )
}

// --- Internal helpers ---

fn count_assistant_messages(messages: List(message.Message)) -> Int {
  list.fold(messages, 0, fn(count, msg) {
    case msg {
      message.AssistantMessage(_) -> count + 1
      _ -> count
    }
  })
}

fn find_response(
  responses: List(#(Int, ScriptedResponse)),
  step: Int,
) -> ScriptedResponse {
  case list.find(responses, fn(entry) { entry.0 == step }) {
    Ok(#(_, response)) -> response
    Error(Nil) -> {
      // If step exceeds scripted responses, use the last one
      let assert Ok(#(_, last)) = list.last(responses)
      last
    }
  }
}

fn scripted_to_result(
  response: ScriptedResponse,
) -> Result(GenerateResult, GleanError) {
  case response {
    TextResponse(text) -> Ok(text_result(text))
    ToolCallResponse(calls) -> {
      let content =
        list.map(calls, fn(c) {
          GeneratedToolCall(
            tool_call_id: c.id,
            tool_name: c.name,
            arguments_json: c.arguments,
          )
        })
      Ok(GenerateResult(
        content: content,
        finish_reason: error.ToolCalls,
        usage: usage.new(input_tokens: 10, output_tokens: 5),
        model_id: "test-model",
      ))
    }
    ErrorResponse(err) -> Error(err)
  }
}
