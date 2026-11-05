/// Function-backed test provider.
/// Delegates to a user-supplied function for full control over responses.
import glean/error.{type GleanError}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type Provider, Provider,
}
import glean/stream.{type StreamEvent}

/// Create a provider backed by a user-supplied function.
/// The function receives each request and returns a result or error.
///
/// ## Example
///
/// ```gleam
/// let provider = function_provider("test", fn(request) {
///   case list.length(request.messages) {
///     1 -> Ok(test_provider.text_result("Hello!"))
///     _ -> Ok(test_provider.text_result("Goodbye!"))
///   }
/// })
/// ```
pub fn function_provider(
  name: String,
  handler: fn(GenerateRequest) -> Result(GenerateResult, GleanError),
) -> Provider {
  let stream_fn = fn(
    request: GenerateRequest,
    _on_event: fn(StreamEvent) -> Nil,
  ) -> Result(GenerateResult, GleanError) {
    handler(request)
  }

  Provider(
    name: name,
    model_id: name <> "-model",
    generate: handler,
    stream: stream_fn,
  )
}
