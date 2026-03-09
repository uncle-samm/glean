/// All error types for the glean SDK.
/// Every error is explicitly typed and must be handled — never silently swallowed.

import gleam/int
import gleam/string

pub type GleanError {
  /// Provider returned a non-200 status or network failure
  ProviderError(
    provider: String,
    model: String,
    status: Int,
    message: String,
  )
  /// Tool call referenced a tool name not in the toolset
  ToolNotFound(tool_name: String)
  /// Tool execution returned an error
  ToolExecutionError(
    tool_name: String,
    tool_call_id: String,
    reason: String,
  )
  /// Tool input failed schema validation
  ToolInputValidationError(
    tool_name: String,
    tool_call_id: String,
    errors: List(ValidationError),
  )
  /// Output validation failed
  OutputValidationError(errors: List(ValidationError))
  /// Max steps exceeded in the agent loop
  MaxStepsExceeded(max_steps: Int, steps_taken: Int)
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
    OutputValidationError(_) -> "OutputValidationError"
    MaxStepsExceeded(max, taken) ->
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

pub type FinishReason {
  Stop
  Length
  ContentFilter
  ToolCalls
  FinishError
  Other(String)
}
