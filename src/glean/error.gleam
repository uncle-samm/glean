/// All error types for the glean SDK.
/// Every error is explicitly typed and must be handled — never silently swallowed.
import gleam/int
import gleam/list
import gleam/string
import glean/message.{type Message}
import glean/usage.{type Usage}

pub type GleanError {
  /// Provider returned a non-200 status or network failure
  ProviderError(provider: String, model: String, status: Int, message: String)
  /// Tool call referenced a tool name not in the toolset
  ToolNotFound(tool_name: String)
  /// Tool execution returned an error
  ToolExecutionError(tool_name: String, tool_call_id: String, reason: String)
  /// Tool input failed schema validation
  ToolInputValidationError(
    tool_name: String,
    tool_call_id: String,
    errors: List(ValidationError),
  )
  /// The final answer is not the JSON the agent's schema asks for, and the
  /// retries allowed by `agent.output_retries` are used up.
  ///
  /// `text` is the answer that failed, `messages` the conversation up to
  /// and including it, and `usage` what the run cost. When `finish_reason`
  /// is `Length` the answer was cut off at the output token limit, so it
  /// is not retried: raise `max_output_tokens` instead.
  OutputValidationError(
    errors: List(ValidationError),
    text: String,
    finish_reason: FinishReason,
    messages: List(Message),
    usage: Usage,
  )
  /// Max steps exceeded in the agent loop
  /// The conversation so far, including every tool call and result, so it
  /// can be inspected or resumed with `run.generate_messages`, and the
  /// tokens the steps used.
  MaxStepsExceeded(
    max_steps: Int,
    steps_taken: Int,
    messages: List(Message),
    usage: Usage,
  )
  /// JSON parsing failed
  JsonParseError(input: String, message: String)
  /// Request timed out
  Timeout(after_ms: Int)
  /// Configuration error at agent build time
  ConfigError(message: String)
}

pub type ValidationError {
  ValidationError(path: List(String), message: String)
}

/// Convert a GleanError to a human-readable string.
pub fn to_string(error: GleanError) -> String {
  case error {
    ProviderError(provider, model, status, message) ->
      "ProviderError("
      <> provider
      <> ", "
      <> model
      <> ", status="
      <> int.to_string(status)
      <> "): "
      <> string.slice(message, 0, 200)
    ToolNotFound(name) -> "ToolNotFound: " <> name
    ToolExecutionError(name, _, reason) ->
      "ToolExecutionError(" <> name <> "): " <> reason
    ToolInputValidationError(name, _, _) ->
      "ToolInputValidationError(" <> name <> ")"
    OutputValidationError(errors:, finish_reason: Length, ..) ->
      "OutputValidationError: the answer was cut off at the output token limit: "
      <> validation_errors_to_string(errors)
    OutputValidationError(errors:, ..) ->
      "OutputValidationError: " <> validation_errors_to_string(errors)
    MaxStepsExceeded(max, taken, _, _) ->
      "MaxStepsExceeded(max="
      <> int.to_string(max)
      <> ", taken="
      <> int.to_string(taken)
      <> ")"
    JsonParseError(_, message) -> "JsonParseError: " <> message
    Timeout(ms) -> "Timeout(after=" <> int.to_string(ms) <> "ms)"
    ConfigError(message) -> "ConfigError: " <> message
  }
}

/// Every violation, as its path and what is wrong there, joined with `; `.
pub fn validation_errors_to_string(errors: List(ValidationError)) -> String {
  errors
  |> list.map(fn(e) {
    case e.path {
      [] -> e.message
      path -> string.join(path, ".") <> ": " <> e.message
    }
  })
  |> string.join("; ")
}

pub type FinishReason {
  /// The model finished its answer.
  Stop
  /// The answer was cut off at the output token limit.
  Length
  /// A safety filter stopped the answer, or the model refused.
  ContentFilter
  /// The model asked for tools.
  ToolCalls
  /// The provider said the generation failed part way: OpenRouter's
  /// `error` finish reason, Gemini's `MALFORMED_FUNCTION_CALL`.
  FinishError
  Other(String)
}
