/// Deterministic simulation engine for testing multi-step agent workflows.
/// Script each step and assert at each point — pure functions, no external calls.

import gleam/int
import gleam/list
import gleam/string
import glean/error.{type GleanError}
import glean/message.{type Message}
import glean/stream.{type Usage, Usage}
import glean/testing/provider.{type ScriptedToolCall}

/// A step in a simulated agent workflow.
pub type SimulationStep {
  /// Provider returns text (agent loop should terminate)
  ExpectText(text: String, then_assert: AssertFn)
  /// Provider returns tool calls, tools execute, results fed back
  ExpectToolCalls(
    executions: List(ScriptedToolExecution),
    then_assert: AssertFn,
  )
  /// Provider returns an error
  ExpectError(error: GleanError, then_assert: AssertFn)
}

/// Describes a tool call and its expected result.
pub type ScriptedToolExecution {
  ScriptedToolExecution(
    call: ScriptedToolCall,
    result: ToolExecutionResult,
  )
}

/// What happens when a tool is executed.
pub type ToolExecutionResult {
  ToolSuccess(content: String)
  ToolFailure(error: String)
}

/// Optional assertion function. Use `no_assert` for no assertion.
pub type AssertFn {
  NoAssert
  Assert(fn(SimulationState) -> Result(Nil, AssertionError))
}

/// Error from a failed assertion.
pub type AssertionError {
  AssertionError(step: Int, expected: String, got: String)
}

/// State accumulated during simulation.
pub type SimulationState {
  SimulationState(
    messages: List(Message),
    step_count: Int,
    total_usage: Usage,
    tool_calls_made: List(message.ToolResult),
    errors_encountered: List(GleanError),
  )
}

/// A complete simulation scenario (opaque, built with builder pattern).
pub opaque type Simulation {
  Simulation(
    name: String,
    user_prompt: String,
    system_prompt: String,
    steps: List(SimulationStep),
    max_steps: Int,
    final_assertions: List(
      fn(SimulationState) -> Result(Nil, AssertionError),
    ),
  )
}

/// Result of running a simulation.
pub type SimulationResult {
  SimulationPassed(name: String, final_state: SimulationState)
  SimulationFailed(name: String, step: Int, error: AssertionError)
  SimulationExceededMaxSteps(
    name: String,
    max_steps: Int,
    state: SimulationState,
  )
}

// --- Builder API ---

/// Create a new simulation.
pub fn new(name: String, prompt: String) -> Simulation {
  Simulation(
    name: name,
    user_prompt: prompt,
    system_prompt: "",
    steps: [],
    max_steps: 10,
    final_assertions: [],
  )
}

/// Set the system prompt.
pub fn with_system_prompt(sim: Simulation, prompt: String) -> Simulation {
  Simulation(..sim, system_prompt: prompt)
}

/// Set max steps before the simulation is considered stuck.
pub fn with_max_steps(sim: Simulation, max: Int) -> Simulation {
  let assert True = max > 0
  Simulation(..sim, max_steps: max)
}

/// Add a step where the provider returns text.
pub fn then_respond_text(sim: Simulation, text: String) -> Simulation {
  let step = ExpectText(text: text, then_assert: NoAssert)
  Simulation(..sim, steps: list.append(sim.steps, [step]))
}

/// Add a text step with assertion.
pub fn then_respond_text_and_assert(
  sim: Simulation,
  text: String,
  assertion: fn(SimulationState) -> Result(Nil, AssertionError),
) -> Simulation {
  let step = ExpectText(text: text, then_assert: Assert(assertion))
  Simulation(..sim, steps: list.append(sim.steps, [step]))
}

/// Add a step where the provider calls tools.
pub fn then_call_tools(
  sim: Simulation,
  executions: List(ScriptedToolExecution),
) -> Simulation {
  let step =
    ExpectToolCalls(executions: executions, then_assert: NoAssert)
  Simulation(..sim, steps: list.append(sim.steps, [step]))
}

/// Add a tool call step with assertion.
pub fn then_call_tools_and_assert(
  sim: Simulation,
  executions: List(ScriptedToolExecution),
  assertion: fn(SimulationState) -> Result(Nil, AssertionError),
) -> Simulation {
  let step =
    ExpectToolCalls(executions: executions, then_assert: Assert(assertion))
  Simulation(..sim, steps: list.append(sim.steps, [step]))
}

/// Add a step where the provider returns an error.
pub fn then_provider_error(sim: Simulation, error: GleanError) -> Simulation {
  let step = ExpectError(error: error, then_assert: NoAssert)
  Simulation(..sim, steps: list.append(sim.steps, [step]))
}

/// Add a final assertion that runs after all steps complete.
pub fn assert_finally(
  sim: Simulation,
  assertion: fn(SimulationState) -> Result(Nil, AssertionError),
) -> Simulation {
  Simulation(
    ..sim,
    final_assertions: list.append(sim.final_assertions, [assertion]),
  )
}

// --- Execution ---

/// Run the simulation. Pure function — all responses come from the script.
pub fn run(sim: Simulation) -> SimulationResult {
  let initial_messages = case sim.system_prompt {
    "" -> [message.user(sim.user_prompt)]
    prompt -> [message.system(prompt), message.user(sim.user_prompt)]
  }

  let initial_state =
    SimulationState(
      messages: initial_messages,
      step_count: 0,
      total_usage: Usage(input_tokens: 0, output_tokens: 0),
      tool_calls_made: [],
      errors_encountered: [],
    )

  run_steps(sim, sim.steps, initial_state)
}

/// Assert that a simulation passed. Panics with descriptive message if not.
pub fn assert_passed(result: SimulationResult) -> SimulationState {
  case result {
    SimulationPassed(_, state) -> state
    SimulationFailed(name, step, err) ->
      panic as string.concat([
        "Simulation '",
        name,
        "' failed at step ",
        int.to_string(step),
        ": expected ",
        err.expected,
        " but got ",
        err.got,
      ])
    SimulationExceededMaxSteps(name, max, _) ->
      panic as string.concat([
        "Simulation '",
        name,
        "' exceeded max steps (",
        int.to_string(max),
        ")",
      ])
  }
}

// --- Internal ---

fn run_steps(
  sim: Simulation,
  remaining: List(SimulationStep),
  state: SimulationState,
) -> SimulationResult {
  case state.step_count >= sim.max_steps {
    True ->
      SimulationExceededMaxSteps(
        name: sim.name,
        max_steps: sim.max_steps,
        state: state,
      )
    False ->
      case remaining {
        [] -> run_final_assertions(sim, state, sim.final_assertions)
        [step, ..rest] ->
          case execute_step(state, step) {
            Error(err) ->
              SimulationFailed(
                name: sim.name,
                step: state.step_count,
                error: err,
              )
            Ok(new_state) -> run_steps(sim, rest, new_state)
          }
      }
  }
}

fn execute_step(
  state: SimulationState,
  step: SimulationStep,
) -> Result(SimulationState, AssertionError) {
  case step {
    ExpectText(text, then_assert) -> {
      let new_state =
        SimulationState(
          ..state,
          messages: list.append(state.messages, [message.assistant(text)]),
          step_count: state.step_count + 1,
        )
      run_assert(new_state, then_assert)
    }

    ExpectToolCalls(executions, then_assert) -> {
      let tool_calls =
        list.map(executions, fn(exec) {
          message.AssistantToolCall(
            tool_call_id: exec.call.id,
            tool_name: exec.call.name,
            arguments_json: exec.call.arguments,
          )
        })

      let tool_results =
        list.map(executions, fn(exec) {
          case exec.result {
            ToolSuccess(content) ->
              message.ToolResultOk(
                tool_call_id: exec.call.id,
                tool_name: exec.call.name,
                output: content,
              )
            ToolFailure(err) ->
              message.ToolResultError(
                tool_call_id: exec.call.id,
                tool_name: exec.call.name,
                error_message: err,
              )
          }
        })

      let new_state =
        SimulationState(
          ..state,
          messages: list.append(state.messages, [
            message.AssistantMessage(content: tool_calls),
            message.ToolResultMessage(results: tool_results),
          ]),
          step_count: state.step_count + 1,
          tool_calls_made: list.append(state.tool_calls_made, tool_results),
        )
      run_assert(new_state, then_assert)
    }

    ExpectError(error, then_assert) -> {
      let new_state =
        SimulationState(
          ..state,
          step_count: state.step_count + 1,
          errors_encountered: list.append(state.errors_encountered, [error]),
        )
      run_assert(new_state, then_assert)
    }
  }
}

fn run_assert(
  state: SimulationState,
  assert_fn: AssertFn,
) -> Result(SimulationState, AssertionError) {
  case assert_fn {
    NoAssert -> Ok(state)
    Assert(f) ->
      case f(state) {
        Ok(Nil) -> Ok(state)
        Error(err) -> Error(err)
      }
  }
}

fn run_final_assertions(
  sim: Simulation,
  state: SimulationState,
  assertions: List(fn(SimulationState) -> Result(Nil, AssertionError)),
) -> SimulationResult {
  case assertions {
    [] -> SimulationPassed(name: sim.name, final_state: state)
    [assertion, ..rest] ->
      case assertion(state) {
        Ok(Nil) -> run_final_assertions(sim, state, rest)
        Error(err) ->
          SimulationFailed(
            name: sim.name,
            step: state.step_count,
            error: err,
          )
      }
  }
}
