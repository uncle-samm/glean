//// Streaming must never turn a failed or cut-off stream into a success.
//// These tests drive the OpenAI-compatible SSE loop with hand-made events.

import gleam/option.{None}
import glean/error
import glean/providers/openai_compatible
import glean/providers/sse
import gleeunit/should

fn run_events(
  events: List(sse.SseEvent),
) -> Result(openai_compatible.StreamAccumulator, error.GleanError) {
  openai_compatible.stream_loop(
    sse.from_events(events),
    openai_compatible.new_stream_accumulator(),
    fn(_event) { Nil },
    "openai",
    "test-model",
    50,
  )
}

fn data(json: String) -> sse.SseEvent {
  sse.Event(event_type: None, data: json)
}

const text_chunk =
  "{\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"

const finish_chunk =
  "{\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"

pub fn done_marker_completes_stream_test() {
  let assert Ok(acc) = run_events([data(text_chunk), data("[DONE]")])
  openai_compatible.accumulated_text(acc) |> should.equal("Hi")
}

pub fn close_after_finish_reason_completes_stream_test() {
  let assert Ok(acc) =
    run_events([data(text_chunk), data(finish_chunk), sse.Closed])
  openai_compatible.accumulated_text(acc) |> should.equal("Hi")
}

pub fn http_status_is_reported_test() {
  case run_events([sse.HttpStatus(401, "{\"error\":\"bad key\"}")]) {
    Error(error.ProviderError(status: 401, message: "{\"error\":\"bad key\"}", ..)) ->
      Nil
    other -> panic as { "Expected a 401 ProviderError, got " <> string_of(other) }
  }
}

pub fn connection_failure_is_an_error_test() {
  case run_events([sse.Failed("econnrefused")]) {
    Error(error.ProviderError(status: 0, ..)) -> Nil
    other -> panic as { "Expected ProviderError, got " <> string_of(other) }
  }
}

pub fn close_before_finish_is_an_error_test() {
  case run_events([data(text_chunk), sse.Closed]) {
    Error(error.ProviderError(provider: "openai", ..)) -> Nil
    other -> panic as { "Expected ProviderError, got " <> string_of(other) }
  }
}

pub fn empty_stream_is_an_error_test() {
  case run_events([sse.Closed]) {
    Error(error.ProviderError(..)) -> Nil
    other -> panic as { "Expected ProviderError, got " <> string_of(other) }
  }
}

pub fn in_stream_error_payload_is_an_error_test() {
  case
    run_events([
      data(text_chunk),
      data("{\"error\":{\"message\":\"Rate limit reached\"}}"),
    ])
  {
    Error(error.ProviderError(message: "Rate limit reached", ..)) -> Nil
    other -> panic as { "Expected ProviderError, got " <> string_of(other) }
  }
}

pub fn timeout_is_an_error_test() {
  run_events([data(text_chunk)])
  |> should.equal(Error(error.Timeout(after_ms: 50)))
}

fn string_of(
  result: Result(openai_compatible.StreamAccumulator, error.GleanError),
) -> String {
  case result {
    Ok(acc) -> "Ok(" <> openai_compatible.accumulated_text(acc) <> ")"
    Error(err) -> "Error(" <> error.to_string(err) <> ")"
  }
}
