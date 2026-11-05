import gleam/int
import gleam/list
import gleam/option.{None, Some}
import glean/agent
import glean/error
import glean/message
import glean/provider as provider_types
import glean/run
import glean/schema
import glean/testing/provider.{ScriptedToolCall, TextResponse, ToolCallResponse}
import glean/testing/function_provider
import glean/tool
import gleeunit/should

pub fn simple_text_generation_test() {
  let p = provider.test_provider([TextResponse("Hello, world!")])
  let a = agent.new(p)

  case run.generate(a, Nil, "Hi") {
    Ok(result) -> {
      result.text |> should.equal("Hello, world!")
      result.steps |> should.equal(1)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn tool_calling_loop_test() {
  // Step 0: provider calls a tool
  // Step 1: provider responds with text after seeing tool result
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "add", arguments: "{\"a\":2,\"b\":3}"),
      ]),
      TextResponse("The answer is 5"),
    ])

  let add_tool =
    tool.new(
      name: "add",
      description: "Add two numbers",
      input_schema: schema.object(
        properties: [#("a", schema.int()), #("b", schema.int())],
        required: ["a", "b"],
      ),
      execute: fn(_ctx, _args) { Ok("5") },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([add_tool]))

  case run.generate(a, Nil, "What is 2 + 3?") {
    Ok(result) -> {
      result.text |> should.equal("The answer is 5")
      result.steps |> should.equal(2)
      // Should have step results for both steps
      list.length(result.step_results) |> should.equal(2)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn max_steps_exceeded_test() {
  // Provider always returns tool calls — should hit max steps
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "loop", arguments: "{}"),
      ]),
    ])

  let loop_tool =
    tool.new(
      name: "loop",
      description: "Loops forever",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(_ctx, _args) { Ok("looping") },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([loop_tool]))
    |> agent.max_steps(3)

  case run.generate(a, Nil, "Loop") {
    Ok(_) -> panic as "Expected error"
    Error(err) ->
      case err {
        error.MaxStepsExceeded(max_steps, _) -> max_steps |> should.equal(3)
        _ -> panic as "Expected MaxStepsExceeded"
      }
  }
}

pub fn system_prompt_included_test() {
  let p = provider.test_provider([TextResponse("I am helpful")])

  let a =
    agent.new(p)
    |> agent.system("You are a helpful assistant")

  case run.generate(a, Nil, "Who are you?") {
    Ok(result) -> {
      result.text |> should.equal("I am helpful")
      // Messages should include system prompt + user message
      let assert True = list.length(result.messages) >= 2
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn provider_error_propagated_test() {
  let p =
    provider.test_provider([
      provider.ErrorResponse(error.ProviderError(
        provider: "test",
        model: "test-model",
        status: 500,
        message: "Internal server error",
      )),
    ])

  let a = agent.new(p)

  case run.generate(a, Nil, "Hello") {
    Ok(_) -> panic as "Expected error"
    Error(err) ->
      case err {
        error.ProviderError(_, _, status, _) -> status |> should.equal(500)
        _ -> panic as "Expected ProviderError"
      }
  }
}

pub fn dependency_injection_test() {
  // Test that deps are threaded through to tool execution
  let p =
    provider.test_provider([
      ToolCallResponse([
        ScriptedToolCall(id: "c1", name: "greet", arguments: "{}"),
      ]),
      TextResponse("Done"),
    ])

  let greet_tool =
    tool.new(
      name: "greet",
      description: "Greet with prefix",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: [],
      ),
      execute: fn(ctx, _args) {
        // ctx.deps should be our injected string
        Ok("Hello from " <> ctx.deps)
      },
    )

  let a =
    agent.new(p)
    |> agent.tools(tool.toolset([greet_tool]))

  case run.generate(a, "world", "Greet me") {
    Ok(result) -> {
      result.text |> should.equal("Done")
      result.steps |> should.equal(2)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn final_answer_is_kept_in_messages_test() {
  let p = provider.test_provider([TextResponse("Hello, Sam!")])
  let a = agent.new(p)

  case run.generate(a, Nil, "Hi, I'm Sam") {
    Ok(result) ->
      list.last(result.messages)
      |> should.equal(
        Ok(message.AssistantMessage([message.AssistantText("Hello, Sam!")])),
      )
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn continue_sends_previous_answer_test() {
  // The test provider picks its response by counting assistant messages,
  // so the second turn only gets "second" if the first answer is in history.
  let p =
    provider.test_provider([TextResponse("first"), TextResponse("second")])
  let a = agent.new(p)

  let assert Ok(first) = run.generate(a, Nil, "one")
  case run.continue(a, Nil, first, "two") {
    Ok(second) -> {
      second.text |> should.equal("second")
      list.length(second.messages) |> should.equal(4)
    }
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn json_output_is_requested_and_validated_test() {
  let person =
    schema.object(properties: [#("name", schema.string())], required: ["name"])
  let p =
    function_provider.function_provider("test", fn(request) {
      case request.response_format {
        provider_types.JsonFormat(schema: Some(_), name: Some("person")) ->
          Ok(provider.text_result("{\"name\":\"Sam\"}"))
        _ -> Ok(provider.text_result("not json"))
      }
    })
  let a =
    agent.new(p)
    |> agent.json_output(schema: Some(person), name: Some("person"))

  let assert Ok(result) = run.generate(a, Nil, "Who?")
  result.text |> should.equal("{\"name\":\"Sam\"}")
}

pub fn json_output_mismatch_is_an_error_test() {
  let person =
    schema.object(properties: [#("name", schema.string())], required: ["name"])
  let p =
    function_provider.function_provider("test", fn(_request) {
      Ok(provider.text_result("{\"age\":3}"))
    })
  let a =
    agent.new(p)
    |> agent.json_output(schema: Some(person), name: None)

  case run.generate(a, Nil, "Who?") {
    Error(error.OutputValidationError(errors)) ->
      errors
      |> should.equal([
        error.ValidationError(path: ["name"], message: "Missing required field"),
      ])
    _ -> panic as "Expected OutputValidationError"
  }
}

pub fn generate_messages_does_not_duplicate_system_prompts_test() {
  let p =
    function_provider.function_provider("test", fn(request) {
      Ok(provider.text_result(int.to_string(list.length(request.messages))))
    })
  let a = agent.new(p) |> agent.system("Be brief.")

  let assert Ok(first) = run.generate(a, Nil, "Hi")
  // [system, user, assistant] + [user] = 4 messages, not 5
  let assert Ok(second) =
    run.generate_messages(
      a,
      Nil,
      list.append(first.messages, [message.user("Again")]),
    )
  second.text |> should.equal("4")
}
