//// Streaming must never turn a failed or cut-off stream into a success.
//// These tests drive the OpenAI-compatible SSE loop with hand-made events.

import gleam/erlang/process
import gleam/option.{None}
import glean/error
import glean/providers/openai_compatible
import gleeunit/should
import httpp/sse as httpp_sse

fn run_events(
  events: List(httpp_sse.SSEEvent),
) -> Result(openai_compatible.StreamAccumulator, error.GleanError) {
  let subject = process.new_subject()
  let manager = process.new_subject()
  send_all(subject, events)
  openai_compatible.stream_loop(
    subject,
    manager,
    openai_compatible.new_stream_accumulator(),
    fn(_event) { Nil },
    "openai",
    "test-model",
    50,
  )
}

fn send_all(
  subject: process.Subject(httpp_sse.SSEEvent),
  events: List(httpp_sse.SSEEvent),
) -> Nil {
  case events {
    [] -> Nil
    [event, ..rest] -> {
      process.send(subject, event)
      send_all(subject, rest)
    }
  }
}

fn data(json: String) -> httpp_sse.SSEEvent {
  httpp_sse.Event(event_type: None, event_id: None, data: json)
}

const text_chunk = "{\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"

const finish_chunk = "{\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"

pub fn done_marker_completes_stream_test() {
  let assert Ok(acc) = run_events([data(text_chunk), data("[DONE]")])
  openai_compatible.accumulated_text(acc) |> should.equal("Hi")
}

pub fn close_after_finish_reason_completes_stream_test() {
  let assert Ok(acc) =
    run_events([data(text_chunk), data(finish_chunk), httpp_sse.Closed])
  openai_compatible.accumulated_text(acc) |> should.equal("Hi")
}

pub fn close_before_finish_is_an_error_test() {
  // This is also what a 401 or 429 looks like: no events, then a close.
  case run_events([data(text_chunk), httpp_sse.Closed]) {
    Error(error.ProviderError(provider: "openai", ..)) -> Nil
    other -> panic as { "Expected ProviderError, got " <> string_of(other) }
  }
}

pub fn empty_stream_is_an_error_test() {
  case run_events([httpp_sse.Closed]) {
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
