import gleam/option.{None, Some}
import glean/providers/sse
import gleeunit/should

pub fn parses_complete_events_and_keeps_the_rest_test() {
  sse.parse_events("data: one\n\nevent: ping\ndata: two\n\ndata: thr")
  |> should.equal(
    #([sse.Event(None, "one"), sse.Event(Some("ping"), "two")], "data: thr"),
  )
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
