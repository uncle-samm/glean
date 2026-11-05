//// Server-Sent Events over a streaming HTTP POST.
////
//// The HTTP part is a small Erlang FFI over OTP's `httpc`
//// (`src/glean_http_stream_ffi.erl`); SSE parsing is pure Gleam. Unlike the
//// previous SSE client, a non-2xx response is reported with its status and
//// body, and failed connections and retryable statuses are retried before
//// any event is delivered.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glean/providers/config.{type ProviderConfig}
import glean/providers/http_utils

/// What a stream delivers.
pub type SseEvent {
  /// One SSE event. `event_type` is the `event:` field, if any.
  Event(event_type: Option(String), data: String)
  /// The server finished the response.
  Closed
  /// The server answered with a non-2xx status.
  HttpStatus(status: Int, body: String)
  /// The connection failed or the response couldn't be read.
  Failed(reason: String)
}

/// A running (or scripted) stream.
pub opaque type Stream {
  Stream(
    request: Option(RequestId),
    buffer: BitArray,
    pending: List(SseEvent),
    done: Bool,
  )
}

type RequestId

/// What the FFI reports for one message from httpc.
type Message {
  Started
  Chunk(BitArray)
  Finished
  Status(Int, Option(String), BitArray)
  Failed(String)
  TimedOut
}

@external(erlang, "glean_http_stream_ffi", "start")
fn ffi_start(
  url: String,
  headers: List(#(String, String)),
  body: String,
  connect_timeout_ms: Int,
) -> Result(RequestId, String)

@external(erlang, "glean_http_stream_ffi", "next")
fn ffi_next(request: RequestId, timeout_ms: Int) -> Message

@external(erlang, "glean_http_stream_ffi", "cancel")
fn ffi_cancel(request: RequestId) -> Nil

/// Start a streaming POST. Retries failed connections and retryable
/// statuses (429, 5xx, ...) the way non-streaming requests do, but only
/// before the first byte of the response body; a stream is never restarted
/// once events have been delivered.
///
/// Must be called from the process that will read the stream.
pub fn start(
  config: ProviderConfig,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Stream {
  start_attempt(config, url, headers, body, 0, config.initial_retry_delay_ms)
}

fn start_attempt(
  config: ProviderConfig,
  url: String,
  headers: List(#(String, String)),
  body: String,
  attempt: Int,
  delay_ms: Int,
) -> Stream {
  let can_retry = attempt < config.max_retries
  let retry = fn(retry_after: Option(String)) {
    process.sleep(http_utils.retry_delay(
      delay_ms,
      retry_after,
      int.random(delay_ms / 2 + 1),
    ))
    start_attempt(config, url, headers, body, attempt + 1, delay_ms * 2)
  }
  case ffi_start(url, headers, body, config.timeout_ms) {
    Error(reason) -> from_events([Failed(reason)])
    Ok(request) ->
      case ffi_next(request, config.timeout_ms) {
        Started -> Stream(Some(request), <<>>, [], False)
        Chunk(bits) -> feed(Stream(Some(request), <<>>, [], False), bits)
        Finished -> from_events([Closed])
        Status(status, retry_after, response_body) ->
          case can_retry && http_utils.is_retryable(status) {
            True -> retry(retry_after)
            False -> from_events([HttpStatus(status, to_text(response_body))])
          }
        Failed(reason) ->
          case can_retry {
            True -> retry(None)
            False -> from_events([Failed(reason)])
          }
        TimedOut -> {
          ffi_cancel(request)
          Stream(None, <<>>, [], False)
        }
      }
  }
}

/// A stream that delivers the given events, then times out. For tests.
pub fn from_events(events: List(SseEvent)) -> Stream {
  Stream(request: None, buffer: <<>>, pending: events, done: True)
}

/// Wait up to `timeout_ms` for the next event. `Error(Nil)` means nothing
/// arrived in time; the request is cancelled.
pub fn next(stream: Stream, timeout_ms: Int) -> Result(#(SseEvent, Stream), Nil) {
  case stream.pending, stream.request {
    [event, ..rest], _ -> Ok(#(event, Stream(..stream, pending: rest)))
    [], None -> Error(Nil)
    [], Some(_) if stream.done -> Error(Nil)
    [], Some(request) ->
      case ffi_next(request, timeout_ms) {
        Started -> next(stream, timeout_ms)
        Chunk(bits) -> next(feed(stream, bits), timeout_ms)
        Finished -> {
          let rest = case stream.buffer {
            <<>> -> [Closed]
            _ ->
              case bit_array.to_string(stream.buffer) {
                // A final event without a trailing blank line still counts.
                Ok(text) -> list.append(parse_events(text <> "\n\n").0, [Closed])
                Error(_) -> [Failed("Response is not valid UTF-8")]
              }
          }
          next(Stream(..stream, buffer: <<>>, pending: rest, done: True), timeout_ms)
        }
        Status(status, _, body) ->
          Ok(#(HttpStatus(status, to_text(body)), Stream(..stream, done: True)))
        Failed(reason) -> Ok(#(Failed(reason), Stream(..stream, done: True)))
        TimedOut -> {
          ffi_cancel(request)
          Error(Nil)
        }
      }
  }
}

/// Stop reading a stream early.
pub fn stop(stream: Stream) -> Nil {
  case stream.request, stream.done {
    Some(request), False -> ffi_cancel(request)
    _, _ -> Nil
  }
}

/// Add a body chunk and queue every complete event in the buffer.
fn feed(stream: Stream, bits: BitArray) -> Stream {
  let buffer = bit_array.append(stream.buffer, bits)
  case bit_array.to_string(buffer) {
    // A multi-byte character split across chunks: wait for the rest.
    Error(_) -> Stream(..stream, buffer: buffer)
    Ok(text) -> {
      let #(events, rest) = parse_events(text)
      Stream(
        ..stream,
        buffer: bit_array.from_string(rest),
        pending: list.append(stream.pending, events),
      )
    }
  }
}

/// Split text into complete SSE events and the unfinished remainder.
/// Public for tests.
pub fn parse_events(text: String) -> #(List(SseEvent), String) {
  let normalised = string.replace(text, "\r\n", "\n")
  let blocks = string.split(normalised, "\n\n")
  let #(complete, rest) = case list.reverse(blocks) {
    [last, ..others] -> #(list.reverse(others), last)
    [] -> #([], "")
  }
  #(list.filter_map(complete, parse_block), rest)
}

/// One event block. Comment lines (`:`) and unknown fields are ignored;
/// a block without `data:` lines is not an event.
fn parse_block(block: String) -> Result(SseEvent, Nil) {
  let #(event_type, data_lines) =
    block
    |> string.split("\n")
    |> list.fold(#(None, []), fn(acc, line) {
      let #(event_type, data) = acc
      case field(line) {
        Ok(#("event", value)) -> #(Some(value), data)
        Ok(#("data", value)) -> #(event_type, [value, ..data])
        _ -> acc
      }
    })
  case data_lines {
    [] -> Error(Nil)
    _ -> Ok(Event(event_type, string.join(list.reverse(data_lines), "\n")))
  }
}

fn field(line: String) -> Result(#(String, String), Nil) {
  case string.split_once(line, ":") {
    Ok(#("", _)) -> Error(Nil)
    Ok(#(name, value)) ->
      case value {
        " " <> rest -> Ok(#(name, rest))
        _ -> Ok(#(name, value))
      }
    Error(Nil) ->
      case line {
        "" -> Error(Nil)
        _ -> Ok(#(line, ""))
      }
  }
}

fn to_text(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(text) -> text
    Error(_) -> "<non-UTF-8 response body>"
  }
}
