import gleam/list
import glean/agent
import glean/run
import glean/schema
import glean/stream
import glean/testing/provider.{ScriptedToolCall, TextResponse, ToolCallResponse}
import glean/tool
import gleeunit/should

pub fn collect_text_test() {
  let events = [
    stream.TextStart(id: "1"),
    stream.TextDelta(id: "1", delta: "Hello"),
    stream.TextDelta(id: "1", delta: " world"),
    stream.TextEnd(id: "1"),
  ]
  stream.collect_text(events) |> should.equal("Hello world")
}

pub fn collect_text_empty_test() {
  let events = [stream.StepStart(step: 0), stream.StepEnd(step: 0)]
  stream.collect_text(events) |> should.equal("")
}

pub fn collect_tool_calls_test() {
  let events = [
    stream.ToolCallStart(id: "1", tool_call_id: "tc1", tool_name: "calc"),
    stream.ToolCallDelta(id: "1", tool_call_id: "tc1", delta: "{\"a\":"),
    stream.ToolCallDelta(id: "1", tool_call_id: "tc1", delta: "1}"),
    stream.ToolCallEnd(id: "1", tool_call_id: "tc1"),
  ]
  let calls = stream.collect_tool_calls(events)
  list.length(calls) |> should.equal(1)
  case calls {
    [#(id, name, args)] -> {
      id |> should.equal("tc1")
      name |> should.equal("calc")
      args |> should.equal("{\"a\":1}")
    }
    _ -> panic as "Expected exactly 1 tool call"
  }
}

pub fn collect_multiple_tool_calls_test() {
  let events = [
    stream.ToolCallStart(id: "1", tool_call_id: "tc1", tool_name: "search"),
    stream.ToolCallDelta(id: "1", tool_call_id: "tc1", delta: "{\"q\":\"x\"}"),
    stream.ToolCallEnd(id: "1", tool_call_id: "tc1"),
    stream.ToolCallStart(id: "2", tool_call_id: "tc2", tool_name: "calc"),
    stream.ToolCallDelta(id: "2", tool_call_id: "tc2", delta: "{\"n\":1}"),
    stream.ToolCallEnd(id: "2", tool_call_id: "tc2"),
  ]
  let calls = stream.collect_tool_calls(events)
  list.length(calls) |> should.equal(2)
}

pub fn stream_run_emits_events_test() {
  let p = provider.test_provider([TextResponse("Hi")])
  let a = agent.new(p)

  case run.stream(a, Nil, "Hello", fn(_event) { Nil }) {
    Ok(result) -> {
      result.text |> should.equal("Hi")
      result.steps |> should.equal(1)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn stream_with_tool_calls_test() {
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "add", arguments: "{\"a\":1}"),
      ]),
      TextResponse("Result: 1"),
    ])

  let add_tool =
    tool.new(
      name: "add",
      description: "Add",
      input_schema: schema.object(properties: [#("a", schema.int())], required: [
        "a",
      ]),
      execute: fn(_ctx, _args) { Ok("1") },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([add_tool]))

  case run.stream(a, Nil, "Add 1", fn(_event) { Nil }) {
    Ok(result) -> {
      result.text |> should.equal("Result: 1")
      result.steps |> should.equal(2)
    }
    Error(_) -> panic as "Expected Ok"
  }
}
