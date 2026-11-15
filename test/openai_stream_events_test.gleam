//// The events an OpenAI-compatible stream emits: every text and reasoning
//// part and every tool call has a start, its deltas and an end.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import glean/provider
import glean/providers/openai_compatible
import glean/providers/sse
import glean/stream
import glean/usage.{Usage}
import gleeunit/should

fn data(json: String) -> sse.SseEvent {
  sse.Event(event_type: None, data: json)
}

fn delta(fields: String) -> sse.SseEvent {
  data("{\"id\":\"c1\",\"choices\":[{\"delta\":{" <> fields <> "}}]}")
}

fn finish(reason: String) -> sse.SseEvent {
  data(
    "{\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\""
    <> reason
    <> "\"}]}",
  )
}

fn run_events(
  events: List(sse.SseEvent),
) -> #(openai_compatible.StreamAccumulator, List(stream.StreamEvent)) {
  let seen = process.new_subject()
  let assert Ok(acc) =
    openai_compatible.stream_loop(
      sse.from_events(events),
      openai_compatible.new_stream_accumulator(),
      fn(event) { process.send(seen, event) },
      "openai",
      "test-model",
      50,
    )
  #(acc, drain(seen, []))
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

pub fn text_has_a_start_and_an_end_test() {
  let #(acc, events) =
    run_events([
      delta("\"content\":\"Hel\""),
      delta("\"content\":\"lo\""),
      finish("stop"),
      data("[DONE]"),
    ])
  events
  |> should.equal([
    stream.TextStart(id: "c1"),
    stream.TextDelta(id: "c1", delta: "Hel"),
    stream.TextDelta(id: "c1", delta: "lo"),
    stream.TextEnd(id: "c1"),
  ])
  openai_compatible.accumulated_text(acc) |> should.equal("Hello")
}

pub fn reasoning_ends_when_the_answer_starts_test() {
  let #(acc, events) =
    run_events([
      delta("\"reasoning_content\":\"2+2 \""),
      delta("\"reasoning_content\":\"is 4\""),
      delta("\"content\":\"4\""),
      finish("stop"),
      data("[DONE]"),
    ])
  events
  |> should.equal([
    stream.ReasoningStart(id: "c1"),
    stream.ReasoningDelta(id: "c1", delta: "2+2 "),
    stream.ReasoningDelta(id: "c1", delta: "is 4"),
    stream.ReasoningEnd(id: "c1"),
    stream.TextStart(id: "c1"),
    stream.TextDelta(id: "c1", delta: "4"),
    stream.TextEnd(id: "c1"),
  ])
  openai_compatible.accumulated_content(acc)
  |> should.equal([
    provider.GeneratedReasoning(text: "2+2 is 4", signature: None),
    provider.GeneratedText(text: "4"),
  ])
}

pub fn every_tool_call_ends_test() {
  let call = fn(index, id, name, arguments) {
    delta(
      "\"tool_calls\":[{\"index\":"
      <> index
      <> id
      <> ",\"function\":{"
      <> name
      <> "\"arguments\":\""
      <> arguments
      <> "\"}}]",
    )
  }
  let #(acc, events) =
    run_events([
      delta("\"content\":\"Let me look.\""),
      call("0", ",\"id\":\"t1\"", "\"name\":\"search\",", ""),
      call("0", "", "", "{\\\"q\\\":"),
      call("1", ",\"id\":\"t2\"", "\"name\":\"calc\",", "{}"),
      call("0", "", "", "\\\"x\\\"}"),
      finish("tool_calls"),
      data("[DONE]"),
    ])
  events
  |> should.equal([
    stream.TextStart(id: "c1"),
    stream.TextDelta(id: "c1", delta: "Let me look."),
    // The text ends when the first tool call starts.
    stream.TextEnd(id: "c1"),
    stream.ToolCallStart(id: "c1", tool_call_id: "t1", tool_name: "search"),
    stream.ToolCallDelta(id: "c1", tool_call_id: "t1", delta: "{\"q\":"),
    stream.ToolCallStart(id: "c1", tool_call_id: "t2", tool_name: "calc"),
    stream.ToolCallDelta(id: "c1", tool_call_id: "t2", delta: "{}"),
    stream.ToolCallDelta(id: "c1", tool_call_id: "t1", delta: "\"x\"}"),
    // Both calls end, in the order the model started them.
    stream.ToolCallEnd(id: "c1", tool_call_id: "t1"),
    stream.ToolCallEnd(id: "c1", tool_call_id: "t2"),
  ])
  // The events alone are enough to rebuild the calls.
  stream.collect_tool_calls(events)
  |> should.equal([
    #("t1", "search", "{\"q\":\"x\"}"),
    #("t2", "calc", "{}"),
  ])
  openai_compatible.accumulated_content(acc)
  |> should.equal([
    provider.GeneratedText(text: "Let me look."),
    provider.GeneratedToolCall(
      tool_call_id: "t1",
      tool_name: "search",
      arguments_json: "{\"q\":\"x\"}",
    ),
    provider.GeneratedToolCall(
      tool_call_id: "t2",
      tool_name: "calc",
      arguments_json: "{}",
    ),
  ])
}

pub fn parts_end_once_when_done_follows_the_finish_reason_test() {
  // The finish chunk ends the parts; [DONE] must not end them again.
  let #(_acc, events) =
    run_events([delta("\"content\":\"Hi\""), finish("stop"), data("[DONE]")])
  list.count(events, fn(event) { event == stream.TextEnd(id: "c1") })
  |> should.equal(1)
}

pub fn parts_end_at_done_without_a_finish_reason_test() {
  // Some servers never send a finish_reason.
  let #(_acc, events) =
    run_events([delta("\"content\":\"Hi\""), data("[DONE]")])
  list.last(events) |> should.equal(Ok(stream.TextEnd(id: "c1")))
}

pub fn streamed_usage_details_test() {
  let #(acc, _events) =
    run_events([
      delta("\"content\":\"Hi\""),
      finish("stop"),
      data(
        "{\"id\":\"c1\",\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":50,"
        <> "\"prompt_tokens_details\":{\"cached_tokens\":80},"
        <> "\"completion_tokens_details\":{\"reasoning_tokens\":30}}}",
      ),
      data("[DONE]"),
    ])
  openai_compatible.accumulated_usage(acc)
  |> should.equal(Usage(
    input_tokens: 100,
    output_tokens: 50,
    cache_read_tokens: 80,
    cache_write_tokens: 0,
    reasoning_tokens: 30,
  ))
}
