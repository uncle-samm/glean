//// Providers end to end over HTTP, against a local test server: retries
//// of timed-out requests, the server's own retry delay, and a whole
//// streamed Claude response.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/error
import glean/message
import glean/provider.{GenerateRequest}
import glean/providers/anthropic
import glean/providers/config
import glean/providers/http_utils
import glean/providers/sse
import glean/stream
import glean/usage.{Usage}
import gleeunit/should

@external(erlang, "glean_test_http_server", "serve")
fn serve(responses: List(String)) -> Int

/// Each response is sent that many milliseconds after its request.
@external(erlang, "glean_test_http_server", "serve_slowly")
fn serve_slowly(responses: List(#(Int, String))) -> Int

@external(erlang, "glean_test_ffi", "monotonic_ms")
fn now_ms() -> Int

fn url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn response(status: String, headers: List(String), body: String) -> String {
  "HTTP/1.1 "
  <> status
  <> "\r\n"
  <> string.concat(list.map(headers, fn(header) { header <> "\r\n" }))
  <> "content-length: "
  <> int.to_string(string.byte_size(body))
  <> "\r\nconnection: close\r\n\r\n"
  <> body
}

fn event_stream(events: List(String)) -> String {
  let body = string.concat(events)
  "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
  <> "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
  <> int.to_base16(string.byte_size(body))
  <> "\r\n"
  <> body
  <> "\r\n0\r\n\r\n"
}

fn collect(events: sse.Stream, acc: List(sse.SseEvent)) -> List(sse.SseEvent) {
  case sse.next(events, 2000) {
    Error(Nil) -> list.reverse(acc)
    Ok(#(sse.Event(..) as event, events)) -> collect(events, [event, ..acc])
    Ok(#(last, _)) -> list.reverse([last, ..acc])
  }
}

// --- Timeouts ---

pub fn a_timed_out_request_is_tried_again_test() {
  // The first answer comes long after the timeout; the retry is answered
  // at once.
  let port =
    serve_slowly([
      #(3000, response("200 OK", [], "too late")),
      #(0, response("200 OK", [], "in time")),
    ])
  let cfg =
    config.new(api_key: "k", model: "m")
    |> config.timeout(300)
    |> config.initial_retry_delay(1)

  http_utils.send_post(cfg, "test", url(port), "{}", [])
  |> should.equal(Ok("in time"))
}

pub fn a_request_that_keeps_timing_out_is_a_timeout_error_test() {
  let port =
    serve_slowly([
      #(3000, response("200 OK", [], "too late")),
      #(3000, response("200 OK", [], "too late")),
    ])
  let cfg =
    config.new(api_key: "k", model: "m")
    |> config.timeout(100)
    |> config.initial_retry_delay(1)
    |> config.max_retries(1)

  http_utils.send_post(cfg, "test", url(port), "{}", [])
  |> should.equal(Error(error.Timeout(after_ms: 100)))
}

pub fn a_stream_that_does_not_start_in_time_is_tried_again_test() {
  let port =
    serve_slowly([
      #(3000, event_stream(["data: too late\n\n"])),
      #(0, event_stream(["data: in time\n\n"])),
    ])
  let cfg =
    config.new(api_key: "k", model: "m")
    |> config.timeout(300)
    |> config.initial_retry_delay(1)

  sse.start(cfg, url(port), [], "{}")
  |> collect([])
  |> should.equal([sse.Event(None, "in time"), sse.Closed])
}

pub fn a_stream_that_never_starts_is_a_timeout_test() {
  let port = serve_slowly([#(3000, event_stream(["data: too late\n\n"]))])
  let cfg =
    config.new(api_key: "k", model: "m")
    |> config.timeout(100)
    |> config.max_retries(0)

  sse.next(sse.start(cfg, url(port), [], "{}"), 100)
  |> should.equal(Error(Nil))
}

// --- The server's retry delay ---

/// The backoff alone would wait 30 seconds or more; the test passes only
/// if the server's much shorter delay is used instead.
fn patient() -> config.ProviderConfig {
  config.new(api_key: "k", model: "m")
  |> config.timeout(5000)
  |> config.initial_retry_delay(30_000)
}

pub fn retry_after_ms_is_used_for_requests_test() {
  let port =
    serve([
      response("429 Too Many Requests", ["retry-after-ms: 20"], "slow down"),
      response("200 OK", [], "done"),
    ])
  let started = now_ms()
  http_utils.send_post(patient(), "test", url(port), "{}", [])
  |> should.equal(Ok("done"))
  { now_ms() - started < 10_000 } |> should.be_true
}

pub fn fractional_retry_after_is_used_for_requests_test() {
  let port =
    serve([
      response("429 Too Many Requests", ["Retry-After: 0.05"], "busy"),
      response("200 OK", [], "done"),
    ])
  let started = now_ms()
  http_utils.send_post(patient(), "test", url(port), "{}", [])
  |> should.equal(Ok("done"))
  { now_ms() - started < 10_000 } |> should.be_true
}

pub fn retry_after_ms_is_used_for_streams_test() {
  let port =
    serve([
      response("429 Too Many Requests", ["retry-after-ms: 20"], "slow down"),
      event_stream(["data: ok\n\n"]),
    ])
  let started = now_ms()
  sse.start(patient(), url(port), [], "{}")
  |> collect([])
  |> should.equal([sse.Event(None, "ok"), sse.Closed])
  { now_ms() - started < 10_000 } |> should.be_true
}

pub fn retry_after_in_seconds_is_used_for_streams_test() {
  let port =
    serve([
      response("529 Overloaded", ["retry-after: 0"], "overloaded"),
      event_stream(["data: ok\n\n"]),
    ])
  let started = now_ms()
  sse.start(patient(), url(port), [], "{}")
  |> collect([])
  |> should.equal([sse.Event(None, "ok"), sse.Closed])
  { now_ms() - started < 10_000 } |> should.be_true
}

// --- Failures without a response ---

fn impatient() -> config.ProviderConfig {
  config.new(api_key: "k", model: "m")
  |> config.timeout(2000)
  |> config.initial_retry_delay(1)
}

pub fn a_dropped_connection_is_tried_again_test() {
  // The server reads the request and closes the connection without a
  // word. This used to raise an exception in the caller.
  let port = serve(["", response("200 OK", [], "done")])
  http_utils.send_post(impatient(), "test", url(port), "{}", [])
  |> should.equal(Ok("done"))
}

pub fn a_connection_that_keeps_dropping_is_an_error_test() {
  let port = serve(["", ""])
  let assert Error(error.ProviderError(
    provider: "test",
    model: "m",
    status: 0,
    message:,
  )) =
    http_utils.send_post(
      impatient() |> config.max_retries(1),
      "test",
      url(port),
      "{}",
      [],
    )
  string.starts_with(message, "HTTP request failed: ") |> should.be_true
}

pub fn a_response_httpc_cannot_read_is_tried_again_test() {
  // Some OTP versions fail the whole request on a 503 whose Retry-After
  // isn't a whole number. Either way glean retries and gets the answer.
  let port =
    serve([
      response("503 Service Unavailable", ["Retry-After: 0.05"], "busy"),
      response("200 OK", [], "done"),
    ])
  http_utils.send_post(impatient(), "test", url(port), "{}", [])
  |> should.equal(Ok("done"))
}

pub fn nothing_listening_is_an_error_test() {
  // The test server has served its (empty) list and closed its port.
  let port = serve([])
  let assert Error(error.ProviderError(status: 0, ..)) =
    http_utils.send_post(
      impatient() |> config.max_retries(0),
      "test",
      url(port),
      "{}",
      [],
    )
}

pub fn an_error_status_keeps_its_status_and_body_test() {
  let port =
    serve([response("401 Unauthorized", [], "{\"error\":\"bad key\"}")])
  http_utils.send_post(impatient(), "openai", url(port), "{}", [])
  |> should.equal(
    Error(error.ProviderError(
      provider: "openai",
      model: "m",
      status: 401,
      message: "{\"error\":\"bad key\"}",
    )),
  )
}

pub fn a_url_that_is_not_http_is_a_config_error_test() {
  let assert Error(error.ConfigError(..)) =
    http_utils.send_post(impatient(), "test", "not a url", "{}", [])
  let assert Error(error.ConfigError(..)) =
    http_utils.send_post(impatient(), "test", "ftp://example.com/x", "{}", [])
}

pub fn request_headers_test() {
  // A default user agent, and the last value of a repeated header.
  http_utils.request_headers([#("x-api-key", "a"), #("X-Api-Key", "b")])
  |> should.equal([#("user-agent", "glean"), #("x-api-key", "b")])
  http_utils.request_headers([#("User-Agent", "mine")])
  |> should.equal([#("user-agent", "mine")])
}

// --- A whole streamed Claude response ---

fn sse_event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

pub fn claude_stream_end_to_end_test() {
  let port =
    serve([
      event_stream([
        sse_event(
          "message_start",
          "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":5,"
            <> "\"cache_creation_input_tokens\":100,\"cache_read_input_tokens\":2000,\"output_tokens\":1}}}",
        ),
        sse_event(
          "content_block_start",
          "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
        ),
        sse_event(
          "content_block_delta",
          "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"2+2\"}}",
        ),
        sse_event(
          "content_block_delta",
          "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}",
        ),
        sse_event(
          "content_block_stop",
          "{\"type\":\"content_block_stop\",\"index\":0}",
        ),
        sse_event(
          "content_block_start",
          "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        ),
        sse_event(
          "content_block_delta",
          "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"4\"}}",
        ),
        sse_event(
          "content_block_stop",
          "{\"type\":\"content_block_stop\",\"index\":1}",
        ),
        sse_event(
          "message_delta",
          "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":12}}",
        ),
        sse_event("message_stop", "{\"type\":\"message_stop\"}"),
      ]),
    ])
  let claude =
    anthropic.default_config(api_key: "k", model: "claude-test")
    |> config.base_url(url(port))
    |> config.timeout(2000)
    |> anthropic.from_config
  let request =
    GenerateRequest(
      messages: [message.user("2+2?")],
      settings: provider.ModelSettings(
        ..provider.default_settings(),
        include_reasoning: True,
      ),
      tools: [],
      tool_choice: provider.Auto,
      response_format: provider.TextFormat,
    )
  let events = process.new_subject()

  let assert Ok(result) =
    claude.stream(request, fn(event) { process.send(events, event) })
  result.content
  |> should.equal([
    provider.GeneratedReasoning(text: "2+2", signature: Some("sig")),
    provider.GeneratedText(text: "4"),
  ])
  result.finish_reason |> should.equal(error.Stop)
  // Cached input is part of the input total; the last output count wins.
  result.usage
  |> should.equal(Usage(
    input_tokens: 2105,
    output_tokens: 12,
    cache_read_tokens: 2000,
    cache_write_tokens: 100,
    reasoning_tokens: 0,
  ))
  drain(events, [])
  |> should.equal([
    stream.ReasoningStart(id: "block_0"),
    stream.ReasoningDelta(id: "block_0", delta: "2+2"),
    stream.ReasoningEnd(id: "block_0"),
    stream.TextStart(id: "block_1"),
    stream.TextDelta(id: "block_1", delta: "4"),
    stream.TextEnd(id: "block_1"),
  ])
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
