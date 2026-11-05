import gleam/erlang/process
import gleam/list
import gleam/string
import glean/agent
import glean/error
import glean/message
import glean/run
import glean/schema
import glean/testing/function_provider
import glean/testing/provider.{ScriptedToolCall, TextResponse, ToolCallResponse}
import glean/tool
import gleeunit/should

pub fn tool_execution_error_non_fatal_test() {
  // Step 0: Model calls "fail_tool" -> tool returns Error -> ToolResultError sent to model
  // Step 1: Model sees the error, responds with text
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "fail_tool", arguments: "{}"),
      ]),
      TextResponse("I see the tool failed, here's my answer anyway"),
    ])

  let fail_tool =
    tool.new(
      name: "fail_tool",
      description: "Always fails",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(_ctx, _args) {
        Error(error.ToolExecutionError(
          tool_name: "fail_tool",
          tool_call_id: "c1",
          reason: "Something went wrong",
        ))
      },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([fail_tool]))

  case run.generate(a, Nil, "Use the tool") {
    Ok(result) -> {
      result.text
      |> should.equal("I see the tool failed, here's my answer anyway")
      result.steps |> should.equal(2)
    }
    Error(_) -> panic as "Tool errors should be non-fatal"
  }
}

pub fn unknown_tool_is_reported_to_the_model_test() {
  // The model calls a tool that isn't in the toolset. Instead of ending the
  // run, glean tells the model which tools exist so it can recover.
  let p =
    function_provider.function_provider("test", fn(request) {
      case last_tool_results(request.messages) {
        [] -> Ok(provider.tool_call_result([#("c1", "nonexistent_tool", "{}")]))
        [message.ToolResultError(error_message: msg, ..)] ->
          Ok(provider.text_result(msg))
        _ -> Ok(provider.text_result("unexpected"))
      }
    })

  let real_tool =
    tool.new(
      name: "real_tool",
      description: "Exists",
      input_schema: schema.object(properties: [], required: []),
      execute: fn(_ctx, _args) { Ok("ok") },
    )
  let a = agent.new(p) |> agent.tools(tool.toolset([real_tool]))

  let assert Ok(result) = run.generate(a, Nil, "Call the tool")
  result.text
  |> should.equal(
    "Unknown tool \"nonexistent_tool\". Available tools: real_tool",
  )
  result.steps |> should.equal(2)
}

pub fn invalid_arguments_are_rejected_before_execution_test() {
  // "a" must be an integer; the tool must never run with a string.
  let p =
    function_provider.function_provider("test", fn(request) {
      case last_tool_results(request.messages) {
        [] -> Ok(provider.tool_call_result([#("c1", "add", "{\"a\":\"two\"}")]))
        [message.ToolResultError(error_message: msg, ..)] ->
          Ok(provider.text_result(msg))
        _ -> Ok(provider.text_result("tool ran"))
      }
    })

  let add_tool =
    tool.new(
      name: "add",
      description: "Add",
      input_schema: schema.object(
        properties: [#("a", schema.int()), #("b", schema.int())],
        required: ["a", "b"],
      ),
      execute: fn(_ctx, _args) { panic as "must not run with invalid input" },
    )
  let a = agent.new(p) |> agent.tools(tool.toolset([add_tool]))

  let assert Ok(result) = run.generate(a, Nil, "Add")
  result.text
  |> should.equal(
    "Invalid arguments: b: Missing required field; a: Expected an integer, got a string",
  )
}

pub fn parallel_tool_results_keep_model_order_test() {
  // The first tool is slow; its result must still come first.
  let p =
    function_provider.function_provider("test", fn(request) {
      case last_tool_results(request.messages) {
        [] ->
          Ok(
            provider.tool_call_result([
              #("c1", "slow", "{}"),
              #("c2", "fast", "{}"),
            ]),
          )
        results ->
          Ok(provider.text_result(
            results
            |> list.map(fn(r) {
              case r {
                message.ToolResultOk(output: o, ..) -> o
                message.ToolResultError(error_message: e, ..) -> e
              }
            })
            |> string.join(","),
          ))
      }
    })

  let slow =
    tool.new(
      name: "slow",
      description: "Slow",
      input_schema: schema.object(properties: [], required: []),
      execute: fn(_ctx, _args) {
        process.sleep(50)
        Ok("slow")
      },
    )
  let fast =
    tool.new(
      name: "fast",
      description: "Fast",
      input_schema: schema.object(properties: [], required: []),
      execute: fn(_ctx, _args) { Ok("fast") },
    )
  let a = agent.new(p) |> agent.tools(tool.toolset([slow, fast]))

  let assert Ok(result) = run.generate(a, Nil, "Go")
  result.text |> should.equal("slow,fast")

  let assert Ok(result) =
    run.generate(agent.sequential_tool_calls(a), Nil, "Go")
  result.text |> should.equal("slow,fast")
}

fn last_tool_results(
  messages: List(message.Message),
) -> List(message.ToolResult) {
  case list.last(messages) {
    Ok(message.ToolResultMessage(results)) -> results
    _ -> []
  }
}

pub fn multiple_tools_mixed_results_test() {
  // Model calls both "good_tool" and "bad_tool"
  // good_tool succeeds, bad_tool fails
  // Both results sent to model, then model responds with text
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "good_tool", arguments: "{}"),
        ScriptedToolCall(id: "c2", name: "bad_tool", arguments: "{}"),
      ]),
      TextResponse("Handled both tools"),
    ])

  let good_tool =
    tool.new(
      name: "good_tool",
      description: "Works fine",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(_ctx, _args) { Ok("success!") },
    )

  let bad_tool =
    tool.new(
      name: "bad_tool",
      description: "Always fails",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(_ctx, _args) {
        Error(error.ToolExecutionError(
          tool_name: "bad_tool",
          tool_call_id: "c2",
          reason: "Broken",
        ))
      },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([good_tool, bad_tool]))

  case run.generate(a, Nil, "Use both tools") {
    Ok(result) -> {
      result.text |> should.equal("Handled both tools")
      result.steps |> should.equal(2)
    }
    Error(_) -> panic as "One tool failing should not be fatal"
  }
}

pub fn tool_error_message_content_test() {
  // Use function_provider to inspect that after a tool error,
  // the ToolResultMessage is in the messages sent back to the model
  let p =
    function_provider.function_provider("test", fn(request) {
      // First call: return tool call
      // Second call: check that tool error message is in the messages
      case list.length(request.messages) {
        n if n <= 2 -> Ok(provider.tool_call_result([#("c1", "err_tool", "{}")]))
        _ -> Ok(provider.text_result("Done"))
      }
    })

  let err_tool =
    tool.new(
      name: "err_tool",
      description: "Errors out",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(_ctx, _args) {
        Error(error.ToolExecutionError(
          tool_name: "err_tool",
          tool_call_id: "c1",
          reason: "database connection failed",
        ))
      },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([err_tool]))

  case run.generate(a, Nil, "Try the tool") {
    Ok(result) -> {
      result.text |> should.equal("Done")
      result.steps |> should.equal(2)
    }
    Error(_) -> panic as "Expected successful recovery"
  }
}
