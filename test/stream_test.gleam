import gleam/erlang/process
import gleam/int
import gleam/list
import glean/agent
import glean/error
import glean/message
import glean/run
import glean/schema
import glean/stream
import glean/testing/function_provider
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

pub fn continue_stream_sends_previous_answer_test() {
  // The test provider picks its response by counting assistant messages,
  // so the second turn only gets "second" if the first answer is in history.
  let p =
    provider.test_provider([TextResponse("first"), TextResponse("second")])
  let a = agent.new(p)

  let assert Ok(first) = run.stream(a, Nil, "one", fn(_event) { Nil })
  case run.continue_stream(a, Nil, first, "two", fn(_event) { Nil }) {
    Ok(second) -> {
      second.text |> should.equal("second")
      list.length(second.messages) |> should.equal(4)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn continue_stream_passes_events_to_callback_test() {
  let p =
    provider.test_provider([
      TextResponse("first"),
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
  let events = process.new_subject()

  let assert Ok(first) = run.generate(a, Nil, "one")
  let assert Ok(second) =
    run.continue_stream(a, Nil, first, "Add 1", fn(event) {
      process.send(events, event)
    })
  second.text |> should.equal("Result: 1")
  drain(events, [])
  |> list.contains(stream.ToolResultEvent(
    tool_call_id: "c1",
    tool_name: "add",
    output: "1",
  ))
  |> should.be_true
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

pub fn stream_messages_does_not_duplicate_system_prompts_test() {
  let p =
    function_provider.function_provider("test", fn(request) {
      Ok(provider.text_result(int.to_string(list.length(request.messages))))
    })
  let a = agent.new(p) |> agent.system("Be brief.")

  let assert Ok(first) = run.stream(a, Nil, "Hi", fn(_event) { Nil })
  // [system, user, assistant] + [user] = 4 messages, not 5
  let assert Ok(second) =
    run.stream_messages(
      a,
      Nil,
      list.append(first.messages, [message.user("Again")]),
      fn(_event) { Nil },
    )
  second.text |> should.equal("4")
}

pub fn stream_messages_adds_system_prompts_to_fresh_history_test() {
  let p =
    function_provider.function_provider("test", fn(request) {
      Ok(provider.text_result(int.to_string(list.length(request.messages))))
    })
  let a = agent.new(p) |> agent.system("Be brief.")

  // [system] + [user] = 2 messages
  let assert Ok(result) =
    run.stream_messages(a, Nil, [message.user("Hi")], fn(_event) { Nil })
  result.text |> should.equal("2")
}

pub fn collect_tool_calls_keeps_interleaved_calls_apart_test() {
  // Two calls streaming at once: every delta goes to its own call.
  let events = [
    stream.ToolCallStart(id: "1", tool_call_id: "a", tool_name: "search"),
    stream.ToolCallStart(id: "2", tool_call_id: "b", tool_name: "calc"),
    stream.ToolCallDelta(id: "1", tool_call_id: "a", delta: "{\"q\":"),
    stream.ToolCallDelta(id: "2", tool_call_id: "b", delta: "{\"n\":"),
    stream.ToolCallDelta(id: "1", tool_call_id: "a", delta: "\"x\"}"),
    stream.ToolCallDelta(id: "2", tool_call_id: "b", delta: "1}"),
    stream.ToolCallEnd(id: "2", tool_call_id: "b"),
    stream.ToolCallEnd(id: "1", tool_call_id: "a"),
  ]
  // In the order the calls ended.
  stream.collect_tool_calls(events)
  |> should.equal([
    #("b", "calc", "{\"n\":1}"),
    #("a", "search", "{\"q\":\"x\"}"),
  ])
}

pub fn collect_tool_calls_leaves_out_a_call_that_never_ended_test() {
  let events = [
    stream.ToolCallStart(id: "1", tool_call_id: "a", tool_name: "search"),
    stream.ToolCallDelta(id: "1", tool_call_id: "a", delta: "{\"q\":"),
    stream.ToolCallStart(id: "2", tool_call_id: "b", tool_name: "calc"),
    stream.ToolCallDelta(id: "2", tool_call_id: "b", delta: "{}"),
    stream.ToolCallEnd(id: "2", tool_call_id: "b"),
  ]
  stream.collect_tool_calls(events) |> should.equal([#("b", "calc", "{}")])
}

pub fn collect_tool_calls_handles_a_reused_id_test() {
  // The same id used for two calls, one after the other.
  let events = [
    stream.ToolCallStart(id: "1", tool_call_id: "a", tool_name: "one"),
    stream.ToolCallDelta(id: "1", tool_call_id: "a", delta: "1"),
    stream.ToolCallEnd(id: "1", tool_call_id: "a"),
    stream.ToolCallStart(id: "2", tool_call_id: "a", tool_name: "two"),
    stream.ToolCallDelta(id: "2", tool_call_id: "a", delta: "2"),
    stream.ToolCallEnd(id: "2", tool_call_id: "a"),
  ]
  stream.collect_tool_calls(events)
  |> should.equal([#("a", "one", "1"), #("a", "two", "2")])
}

pub fn a_failed_stream_ends_with_a_stream_error_event_test() {
  let failure =
    error.ProviderError(
      provider: "test",
      model: "m",
      status: 500,
      message: "overloaded",
    )
  let p =
    function_provider.function_provider("test", fn(_request) { Error(failure) })
  let events = process.new_subject()

  run.stream(agent.new(p), Nil, "Hi", fn(event) { process.send(events, event) })
  |> should.equal(Error(failure))
  // The callback hears about the failure too, as the last event.
  drain(events, [])
  |> should.equal([
    stream.StepStart(step: 0),
    stream.StreamError(message: error.to_string(failure)),
  ])
}

pub fn a_stream_that_runs_out_of_steps_ends_with_a_stream_error_event_test() {
  let p =
    function_provider.function_provider("test", fn(_request) {
      Ok(provider.tool_call_result([#("c1", "missing", "{}")]))
    })
  let events = process.new_subject()
  let assert Error(error.MaxStepsExceeded(..) as err) =
    run.stream(agent.new(p) |> agent.max_steps(1), Nil, "Hi", fn(event) {
      process.send(events, event)
    })
  list.last(drain(events, []))
  |> should.equal(Ok(stream.StreamError(message: error.to_string(err))))
}

pub fn a_successful_stream_has_no_stream_error_event_test() {
  let p = provider.test_provider([TextResponse("Hi")])
  let events = process.new_subject()
  let assert Ok(_) =
    run.stream(agent.new(p), Nil, "Hello", fn(event) {
      process.send(events, event)
    })
  list.any(drain(events, []), fn(event) {
    case event {
      stream.StreamError(..) -> True
      _ -> False
    }
  })
  |> should.be_false
}
