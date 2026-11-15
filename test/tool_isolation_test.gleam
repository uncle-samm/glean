//// A tool that crashes or hangs must not take the run with it: every tool
//// call runs in its own process, and the model is told what happened.

import gleam/erlang/process
import gleam/list
import gleam/string
import glean/agent
import glean/error
import glean/message
import glean/provider.{type Provider}
import glean/run
import glean/schema
import glean/testing/function_provider
import glean/testing/provider as test_provider
import glean/tool
import gleeunit/should

fn no_arguments() -> schema.Schema {
  schema.object(properties: [], required: [])
}

fn crashing_tool() -> tool.Tool(Nil) {
  tool.new(
    name: "crash",
    description: "Always crashes",
    input_schema: no_arguments(),
    execute: fn(_ctx, _args) { panic as "the tool blew up" },
  )
}

fn echo_tool(name: String, wait_ms: Int) -> tool.Tool(Nil) {
  tool.new(
    name: name,
    description: "Answers with its own name",
    input_schema: no_arguments(),
    execute: fn(_ctx, _args) {
      process.sleep(wait_ms)
      Ok(name <> " done")
    },
  )
}

/// A model that asks for `calls` first, then answers with the tool results
/// it was given, one per line, in the order it received them.
fn model_calling(calls: List(#(String, String, String))) -> Provider {
  function_provider.function_provider("test", fn(request) {
    case tool_results(request.messages) {
      [] -> Ok(test_provider.tool_call_result(calls))
      results ->
        Ok(test_provider.text_result(
          results
          |> list.map(fn(result) {
            case result {
              message.ToolResultOk(tool_call_id:, output:, ..) ->
                tool_call_id <> " ok: " <> output
              message.ToolResultError(tool_call_id:, error_message:, ..) ->
                tool_call_id <> " error: " <> error_message
            }
          })
          |> string.join("\n"),
        ))
    }
  })
}

fn tool_results(messages: List(message.Message)) -> List(message.ToolResult) {
  list.flat_map(messages, fn(msg) {
    case msg {
      message.ToolResultMessage(results:) -> results
      _ -> []
    }
  })
}

fn lines(text: String) -> List(String) {
  string.split(text, "\n")
}

pub fn crashing_tool_is_reported_and_the_others_finish_test() {
  let a =
    agent.new(
      model_calling([
        #("c1", "first", "{}"),
        #("c2", "crash", "{}"),
        #("c3", "third", "{}"),
      ]),
    )
    |> agent.tools(
      tool.toolset([
        echo_tool("first", 20),
        crashing_tool(),
        echo_tool("third", 0),
      ]),
    )

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  result.steps |> should.equal(2)
  let assert [first, crashed, third] = lines(result.text)
  first |> should.equal("c1 ok: first done")
  third |> should.equal("c3 ok: third done")
  // The model is told the tool crashed, and why.
  string.starts_with(crashed, "c2 error: The tool crashed: ")
  |> should.be_true
  string.contains(crashed, "the tool blew up") |> should.be_true
}

pub fn crashing_tool_is_reported_in_sequential_mode_test() {
  let a =
    agent.new(model_calling([#("c1", "crash", "{}"), #("c2", "second", "{}")]))
    |> agent.tools(tool.toolset([crashing_tool(), echo_tool("second", 0)]))
    |> agent.sequential_tool_calls

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  let assert [crashed, second] = lines(result.text)
  string.starts_with(crashed, "c1 error: The tool crashed: ")
  |> should.be_true
  second |> should.equal("c2 ok: second done")
}

pub fn a_tool_that_exits_is_reported_test() {
  // Not a panic: the tool's process is killed from outside while it runs.
  let exiting =
    tool.new(
      name: "exit",
      description: "Kills its own process",
      input_schema: no_arguments(),
      execute: fn(_ctx, _args) {
        process.kill(process.self())
        process.sleep(1000)
        Ok("never")
      },
    )
  let a =
    agent.new(model_calling([#("c1", "exit", "{}")]))
    |> agent.tools(tool.toolset([exiting]))

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  result.text |> should.equal("c1 error: The tool crashed: it was killed")
}

pub fn results_keep_the_models_order_test() {
  // The first call finishes last.
  let a =
    agent.new(
      model_calling([
        #("c1", "slow", "{}"),
        #("c2", "fast", "{}"),
      ]),
    )
    |> agent.tools(tool.toolset([echo_tool("slow", 60), echo_tool("fast", 0)]))

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  lines(result.text)
  |> should.equal(["c1 ok: slow done", "c2 ok: fast done"])
}

pub fn tool_past_its_timeout_is_stopped_test() {
  // The tool reports its process, so the test can see it was stopped.
  let started = process.new_subject()
  let hanging =
    tool.new(
      name: "hang",
      description: "Never finishes",
      input_schema: no_arguments(),
      execute: fn(_ctx, _args) {
        process.send(started, process.self())
        process.sleep(60_000)
        Ok("never")
      },
    )
  let a =
    agent.new(model_calling([#("c1", "hang", "{}"), #("c2", "fast", "{}")]))
    |> agent.tools(tool.toolset([hanging, echo_tool("fast", 0)]))
    |> agent.tool_timeout(50)

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  lines(result.text)
  |> should.equal([
    "c1 error: The tool did not finish within 50 ms and was stopped",
    "c2 ok: fast done",
  ])
  let assert Ok(pid) = process.receive(started, 0)
  process.is_alive(pid) |> should.be_false
}

pub fn timeout_applies_in_sequential_mode_test() {
  let a =
    agent.new(model_calling([#("c1", "slow", "{}"), #("c2", "fast", "{}")]))
    |> agent.tools(
      tool.toolset([echo_tool("slow", 60_000), echo_tool("fast", 0)]),
    )
    |> agent.sequential_tool_calls
    |> agent.tool_timeout(30)

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  lines(result.text)
  |> should.equal([
    "c1 error: The tool did not finish within 30 ms and was stopped",
    "c2 ok: fast done",
  ])
}

pub fn a_tool_within_its_timeout_is_untouched_test() {
  let a =
    agent.new(model_calling([#("c1", "quick", "{}")]))
    |> agent.tools(tool.toolset([echo_tool("quick", 5)]))
    |> agent.tool_timeout(5000)

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  result.text |> should.equal("c1 ok: quick done")
}

pub fn nothing_is_left_in_the_callers_mailbox_test() {
  // Crashes, timeouts and normal results all clean up after themselves:
  // no monitor message, timer message or late result stays behind.
  let a =
    agent.new(
      model_calling([
        #("c1", "crash", "{}"),
        #("c2", "slow", "{}"),
        #("c3", "fast", "{}"),
      ]),
    )
    |> agent.tools(
      tool.toolset([
        crashing_tool(),
        echo_tool("slow", 60_000),
        echo_tool("fast", 0),
      ]),
    )
    |> agent.tool_timeout(30)

  let assert Ok(_) = quietly(fn() { run.generate(a, Nil, "Go") })
  process.sleep(20)
  mailbox_length() |> should.equal(0)
}

pub fn stopping_the_run_stops_its_tools_test() {
  // The run is in a process of its own, which is killed while its tool
  // is still at work.
  let started = process.new_subject()
  let hanging =
    tool.new(
      name: "hang",
      description: "Never finishes",
      input_schema: no_arguments(),
      execute: fn(_ctx, _args) {
        process.send(started, process.self())
        process.sleep(60_000)
        Ok("never")
      },
    )
  let a =
    agent.new(model_calling([#("c1", "hang", "{}")]))
    |> agent.tools(tool.toolset([hanging]))
  let runner =
    process.spawn_unlinked(fn() {
      let _ = run.generate(a, Nil, "Go")
      Nil
    })

  let assert Ok(tool_pid) = process.receive(started, 2000)
  process.is_alive(tool_pid) |> should.be_true
  let monitor = process.monitor(tool_pid)
  process.kill(runner)
  // The tool goes down with the run instead of working on for a minute.
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
  process.is_alive(tool_pid) |> should.be_false
}

pub fn tool_errors_still_reach_the_model_test() {
  // An ordinary error result is unchanged by the isolation.
  let failing =
    tool.new(
      name: "fail",
      description: "Returns an error",
      input_schema: no_arguments(),
      execute: fn(_ctx, _args) {
        Error(error.ToolExecutionError(
          tool_name: "fail",
          tool_call_id: "c1",
          reason: "no such record",
        ))
      },
    )
  let a =
    agent.new(model_calling([#("c1", "fail", "{}")]))
    |> agent.tools(tool.toolset([failing]))

  let assert Ok(result) = quietly(fn() { run.generate(a, Nil, "Go") })
  string.contains(result.text, "no such record") |> should.be_true
}

@external(erlang, "glean_test_ffi", "mailbox_length")
fn mailbox_length() -> Int

/// A crashing process logs a crash report, which is right for an
/// application and noise in a test run.
@external(erlang, "glean_test_ffi", "without_crash_reports")
fn quietly(run: fn() -> a) -> a
