import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/providers/config
import glean/providers/sse
import gleeunit/should

pub fn parses_complete_events_and_keeps_the_rest_test() {
  sse.parse_events("data: one\n\nevent: ping\ndata: two\n\ndata: thr")
  |> should.equal(#(
    [sse.Event(None, "one"), sse.Event(Some("ping"), "two")],
    "data: thr",
  ))
}

pub fn multi_line_data_and_crlf_test() {
  sse.parse_events("data: a\r\ndata: b\r\n\r\n")
  |> should.equal(#([sse.Event(None, "a\nb")], ""))
}

pub fn comments_and_empty_blocks_are_skipped_test() {
  sse.parse_events(": keep-alive\n\nevent: ping\n\ndata:x\n\n")
  |> should.equal(#([sse.Event(None, "x")], ""))
}

pub fn scripted_stream_delivers_then_times_out_test() {
  let stream = sse.from_events([sse.Event(None, "a"), sse.Closed])
  let assert Ok(#(sse.Event(None, "a"), stream)) = sse.next(stream, 10)
  let assert Ok(#(sse.Closed, stream)) = sse.next(stream, 10)
  sse.next(stream, 10) |> should.equal(Error(Nil))
}

// --- End to end through the FFI, against a local test server ---

@external(erlang, "glean_test_http_server", "serve")
fn serve(responses: List(String)) -> Int

fn url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/stream"
}

fn test_config() -> config.ProviderConfig {
  config.new(api_key: "k", model: "m")
  |> config.timeout(2000)
  |> config.initial_retry_delay(1)
}

fn chunked(chunks: List(String)) -> String {
  "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
  <> "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
  <> {
    chunks
    |> list.map(fn(c) {
      int.to_base16(string.byte_size(c)) <> "\r\n" <> c <> "\r\n"
    })
    |> string.concat
  }
  <> "0\r\n\r\n"
}

fn collect(stream: sse.Stream, acc: List(sse.SseEvent)) -> List(sse.SseEvent) {
  case sse.next(stream, 2000) {
    Error(Nil) -> list.reverse(acc)
    Ok(#(sse.Closed, _)) -> list.reverse([sse.Closed, ..acc])
    Ok(#(sse.HttpStatus(..) as e, _)) -> list.reverse([e, ..acc])
    Ok(#(sse.Failed(..) as e, _)) -> list.reverse([e, ..acc])
    Ok(#(event, stream)) -> collect(stream, [event, ..acc])
  }
}

pub fn streams_events_split_across_chunks_test() {
  // The second event and a multi-byte character are split across chunks.
  let port =
    serve([
      chunked(["data: one\n\nda", "ta: h\u{e9}", "llo\n\n", "data: [DONE]\n\n"]),
    ])
  sse.start(test_config(), url(port), [], "{}")
  |> collect([])
  |> should.equal([
    sse.Event(None, "one"),
    sse.Event(None, "h\u{e9}llo"),
    sse.Event(None, "[DONE]"),
    sse.Closed,
  ])
}

pub fn error_status_keeps_status_and_body_test() {
  let body = "{\"error\":\"bad key\"}"
  let port =
    serve([
      "HTTP/1.1 401 Unauthorized\r\ncontent-type: application/json\r\n"
      <> "content-length: "
      <> int.to_string(string.byte_size(body))
      <> "\r\nconnection: close\r\n\r\n"
      <> body,
    ])
  sse.start(test_config(), url(port), [], "{}")
  |> collect([])
  |> should.equal([sse.HttpStatus(401, body)])
}

pub fn retryable_status_is_retried_before_streaming_test() {
  let port =
    serve([
      "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\n"
        <> "connection: close\r\n\r\n",
      chunked(["data: ok\n\n"]),
    ])
  sse.start(test_config(), url(port), [], "{}")
  |> collect([])
  |> should.equal([sse.Event(None, "ok"), sse.Closed])
}

pub fn connection_refused_is_a_failure_test() {
  // Nothing listens on a port the test server has already closed.
  let port = serve([])
  let cfg = test_config() |> config.max_retries(0)
  case collect(sse.start(cfg, url(port), [], "{}"), []) {
    [sse.Failed(_)] -> Nil
    other -> panic as { "Expected Failed, got " <> string.inspect(other) }
  }
}
