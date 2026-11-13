//// `simulation.run_agent` puts a script in front of a real agent: the
//// agent's own tools run, and the simulation fails when they don't do what
//// the script says.

import gleam/list
import gleam/option.{Some}
import gleam/string
import glean/agent
import glean/error
import glean/message
import glean/schema
import glean/testing/provider.{ScriptedToolCall}
import glean/testing/simulation.{
  AssertionError, ScriptedToolExecution, SimulationExceededMaxSteps,
  SimulationFailed, SimulationPassed, ToolFailure, ToolSuccess,
}
import glean/tool
import glean/usage
import gleeunit/should

/// The dependency the tools get: the stock on hand.
type Stock {
  Stock(apples: Int)
}

fn stock_tool() -> tool.Tool(Stock) {
  tool.new(
    name: "count_apples",
    description: "How many apples are in stock",
    input_schema: schema.object(properties: [], required: []),
    execute: fn(ctx, _args) {
      let tool.ToolContext(deps: Stock(apples:), ..) = ctx
      case apples {
        0 ->
          Error(error.ToolExecutionError(
            tool_name: "count_apples",
            tool_call_id: "c1",
            reason: "out of apples",
          ))
        n -> Ok(string.inspect(n))
      }
    },
  )
}

fn grocer() -> agent.Agent(Stock) {
  agent.new(provider.test_provider([provider.TextResponse("unused")]))
  |> agent.system("You are a grocer.")
  |> agent.tools(tool.toolset([stock_tool()]))
}

fn count_call(result: simulation.ToolExecutionResult) {
  ScriptedToolExecution(
    call: ScriptedToolCall(id: "c1", name: "count_apples", arguments: "{}"),
    result: result,
  )
}

pub fn the_agents_real_tools_run_test() {
  let state =
    simulation.new("stock", "How many apples?")
    |> simulation.then_call_tools_and_assert(
      [count_call(ToolSuccess(content: "12"))],
      fn(state) {
        // The step's assertion sees the real tool result in the
        // conversation.
        let assert Ok(message.ToolResultMessage([
          message.ToolResultOk(output: "12", ..),
        ])) = list.last(state.messages)
        Ok(Nil)
      },
    )
    |> simulation.then_respond_text("We have 12 apples.")
    |> simulation.assert_finally(fn(state) {
      state.step_count |> should.equal(2)
      Ok(Nil)
    })
    |> simulation.run_agent(grocer(), Stock(apples: 12))
    |> simulation.assert_passed

  // The agent's system prompt, the prompt, the call, the result, the answer.
  list.length(state.messages) |> should.equal(5)
  list.first(state.messages)
  |> should.equal(Ok(message.system("You are a grocer.")))
  list.last(state.messages)
  |> should.equal(Ok(message.assistant("We have 12 apples.")))
  state.tool_calls_made
  |> should.equal([
    message.ToolResultOk(
      tool_call_id: "c1",
      tool_name: "count_apples",
      output: "12",
    ),
  ])
  state.total_usage
  |> should.equal(usage.new(input_tokens: 20, output_tokens: 10))
  state.errors_encountered |> should.equal([])
}

pub fn a_tool_that_returns_something_else_fails_the_simulation_test() {
  // The script says 12; the tool, given other stock, says 7.
  let result =
    simulation.new("stock", "How many apples?")
    |> simulation.then_call_tools([count_call(ToolSuccess(content: "12"))])
    |> simulation.then_respond_text("We have 12 apples.")
    |> simulation.run_agent(grocer(), Stock(apples: 7))

  result
  |> should.equal(SimulationFailed(
    name: "stock",
    step: 0,
    error: AssertionError(
      step: 0,
      expected: "tool count_apples to give the result \"12\"",
      got: "the result \"7\"",
    ),
  ))
}

pub fn an_expected_tool_failure_passes_test() {
  // The model is shown the tool's own reason.
  let failure = "out of apples"
  let run = fn(expected) {
    simulation.new("empty", "How many apples?")
    |> simulation.then_call_tools([count_call(expected)])
    |> simulation.then_respond_text("None left.")
    |> simulation.run_agent(grocer(), Stock(apples: 0))
  }
  let assert SimulationPassed(final_state: state, ..) =
    run(ToolFailure(error: failure))
  let assert [message.ToolResultError(error_message:, ..)] =
    state.tool_calls_made
  error_message |> should.equal(failure)

  // Scripted as a success, the same run fails.
  let assert SimulationFailed(error: AssertionError(got:, ..), ..) =
    run(ToolSuccess(content: "0"))
  string.contains(got, "out of apples") |> should.be_true
}

pub fn a_tool_the_agent_lacks_fails_the_simulation_test() {
  let result =
    simulation.new("missing", "Weigh the apples")
    |> simulation.then_call_tools([
      ScriptedToolExecution(
        call: ScriptedToolCall(id: "c1", name: "weigh", arguments: "{}"),
        result: ToolSuccess(content: "3 kg"),
      ),
    ])
    |> simulation.then_respond_text("3 kg.")
    |> simulation.run_agent(grocer(), Stock(apples: 12))
  let assert SimulationFailed(step: 0, error: AssertionError(got:, ..), ..) =
    result
  string.contains(got, "Unknown tool") |> should.be_true
}

pub fn a_script_longer_than_the_run_fails_test() {
  // The agent stops at the first text answer; the script goes on.
  let result =
    simulation.new("too long", "Hi")
    |> simulation.then_respond_text("Hello.")
    |> simulation.then_respond_text("Anything else?")
    |> simulation.run_agent(grocer(), Stock(apples: 1))
  let assert SimulationFailed(step: 1, error: AssertionError(expected:, ..), ..) =
    result
  string.contains(expected, "step 1") |> should.be_true
}

pub fn the_agents_step_limit_applies_test() {
  // The script never answers in text, so the agent runs out of steps.
  let result =
    simulation.new("loop", "How many apples?")
    |> simulation.then_call_tools([count_call(ToolSuccess(content: "12"))])
    |> simulation.run_agent(grocer() |> agent.max_steps(3), Stock(apples: 12))
  let assert SimulationExceededMaxSteps(max_steps: 3, state:, ..) = result
  // The script's one step was checked before the run went on alone.
  state.step_count |> should.equal(1)
}

pub fn a_script_can_end_with_a_provider_error_test() {
  let outage =
    error.ProviderError(
      provider: "test",
      model: "m",
      status: 529,
      message: "overloaded",
    )
  let state =
    simulation.new("outage", "How many apples?")
    |> simulation.then_call_tools([count_call(ToolSuccess(content: "12"))])
    |> simulation.then_provider_error(outage)
    |> simulation.run_agent(grocer(), Stock(apples: 12))
    |> simulation.assert_passed
  state.errors_encountered |> should.equal([outage])
  state.step_count |> should.equal(2)
  // The conversation up to the failed call is kept.
  list.length(state.messages) |> should.equal(4)
}

pub fn an_unscripted_failure_fails_the_simulation_test() {
  // The agent wants JSON; the scripted answers are not JSON, and the
  // script doesn't say the run fails.
  let strict =
    grocer()
    |> agent.json_output(
      schema: Some(
        schema.object(properties: [#("apples", schema.int())], required: [
          "apples",
        ]),
      ),
      name: Some("stock"),
    )
  let result =
    simulation.new("not json", "How many apples?")
    |> simulation.then_respond_text("Twelve.")
    |> simulation.then_respond_text("Still twelve.")
    |> simulation.run_agent(strict, Stock(apples: 12))
  let assert SimulationFailed(
    error: AssertionError(expected: "the run to succeed", got:, ..),
    ..,
  ) = result
  string.contains(got, "OutputValidationError") |> should.be_true
}

pub fn the_agents_output_retry_runs_test() {
  // The first answer is not valid; the agent asks again and the second
  // scripted answer passes.
  let strict =
    grocer()
    |> agent.json_output(
      schema: Some(
        schema.object(properties: [#("apples", schema.int())], required: [
          "apples",
        ]),
      ),
      name: Some("stock"),
    )
  let state =
    simulation.new("retry", "How many apples?")
    |> simulation.then_respond_text("Twelve.")
    |> simulation.then_respond_text("{\"apples\":12}")
    |> simulation.run_agent(strict, Stock(apples: 12))
    |> simulation.assert_passed
  state.step_count |> should.equal(2)
}

pub fn a_failing_step_assertion_fails_the_simulation_test() {
  let result =
    simulation.new("assert", "Hi")
    |> simulation.then_respond_text_and_assert("Hello.", fn(_state) {
      Error(AssertionError(step: 0, expected: "a greeting", got: "Hello."))
    })
    |> simulation.run_agent(grocer(), Stock(apples: 1))
  result
  |> should.equal(SimulationFailed(
    name: "assert",
    step: 0,
    error: AssertionError(step: 0, expected: "a greeting", got: "Hello."),
  ))
}

pub fn the_simulations_system_prompt_is_added_test() {
  let state =
    simulation.new("prompt", "Hi")
    |> simulation.with_system_prompt("Answer in French.")
    |> simulation.then_respond_text("Bonjour.")
    |> simulation.run_agent(grocer(), Stock(apples: 1))
    |> simulation.assert_passed
  state.messages
  |> should.equal([
    message.system("You are a grocer."),
    message.system("Answer in French."),
    message.user("Hi"),
    message.assistant("Bonjour."),
  ])
}

pub fn an_empty_script_fails_test() {
  let assert SimulationFailed(step: 0, ..) =
    simulation.new("empty", "Hi")
    |> simulation.run_agent(grocer(), Stock(apples: 1))
}

pub fn run_alone_never_calls_a_tool_test() {
  // `run` walks the script only: the scripted result stands, whatever a
  // real tool would have said.
  let state =
    simulation.new("script only", "How many apples?")
    |> simulation.then_call_tools([count_call(ToolSuccess(content: "999"))])
    |> simulation.then_respond_text("999.")
    |> simulation.run
    |> simulation.assert_passed
  let assert [message.ToolResultOk(output: "999", ..)] = state.tool_calls_made
  state.total_usage |> should.equal(usage.zero())
}
