import gleam/list
import glean/agent
import glean/error
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

pub fn tool_not_found_is_fatal_test() {
  // Model calls "nonexistent_tool" which isn't in the toolset
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "nonexistent_tool", arguments: "{}"),
      ]),
    ])

  // No tools registered!
  let a = agent.new(p)

  case run.generate(a, Nil, "Call the tool") {
    Ok(_) -> panic as "Expected ToolNotFound error"
    Error(err) ->
      case err {
        error.ToolNotFound(name) -> name |> should.equal("nonexistent_tool")
        _ -> panic as "Expected ToolNotFound"
      }
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
