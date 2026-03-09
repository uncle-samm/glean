/// SSE (Server-Sent Events) streaming client.
/// Wraps the httpp package for clean, native Gleam streaming.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/list
import httpp/sse as httpp_sse

/// Re-export SSE event type from httpp for use by providers.
pub type SseEvent =
  httpp_sse.SSEEvent

/// Re-export manager message type.
pub type SseManagerMessage =
  httpp_sse.SSEManagerMessage

/// Start an SSE stream for an HTTP POST request.
/// Returns a Subject that receives httpp SSEEvent messages, and a manager
/// Subject for sending Shutdown.
pub fn start_stream(
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> Result(
  #(process.Subject(SseEvent), process.Subject(SseManagerMessage)),
  String,
) {
  let req_result = request.to(url)
  case req_result {
    Error(_) -> Error("Invalid URL: " <> url)
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_header("content-type", "application/json")
        |> apply_headers(headers)
        |> request.map(fn(_) { bytes_tree.from_string(body) })

      let subject = process.new_subject()

      case httpp_sse.event_source(req, timeout_ms, subject) {
        Error(_) -> Error("Failed to start SSE stream")
        Ok(#(_client_ref, manager_subject)) ->
          Ok(#(subject, manager_subject))
      }
    }
  }
}

fn apply_headers(
  req: Request(String),
  headers: List(#(String, String)),
) -> Request(String) {
  list.fold(headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })
}
