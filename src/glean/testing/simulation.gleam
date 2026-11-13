//// Deterministic simulation of multi-step agent workflows.
////
//// A simulation is a script of what the model says at each step. There are
//// two ways to run it:
////
//// - `run_agent` puts the script in front of a real agent: the steps are
////   the model's replies, and the real agent loop runs the agent's own
////   tools, step limit and output validation. Use it to test an agent.
//// - `run` walks the script alone. No agent and no tool runs: the tool
////   results are the scripted ones. Use it to try out assertions on a
////   conversation shape.
////
//// Neither makes a network call.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glean/agent.{type Agent, Agent}
import glean/error.{type GleanError}
import glean/message.{type Message}
import glean/provider.{type GenerateResult, Provider} as glean_provider
import glean/run
import glean/testing/provider.{type ScriptedToolCall}
import glean/usage.{type Usage}

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
  ScriptedToolExecution(call: ScriptedToolCall, result: ToolExecutionResult)
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
    final_assertions: List(fn(SimulationState) -> Result(Nil, AssertionError)),
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
  let step = ExpectToolCalls(executions: executions, then_assert: NoAssert)
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

/// Walk the script on its own. A pure function: no agent and no tool
/// runs, and every tool result is the scripted one, so this tests the
/// assertions and not an agent. To test an agent, use `run_agent`.
pub fn run(sim: Simulation) -> SimulationResult {
  let initial_messages = case sim.system_prompt {
    "" -> [message.user(sim.user_prompt)]
    prompt -> [message.system(prompt), message.user(sim.user_prompt)]
  }

  let initial_state =
    SimulationState(
      messages: initial_messages,
      step_count: 0,
      total_usage: usage.zero(),
      tool_calls_made: [],
      errors_encountered: [],
    )

  run_steps(sim, sim.steps, initial_state)
}

/// Run the script against a real agent.
///
/// The steps are the model's replies, in order. Everything else is real:
/// the agent loop, the agent's own tools called with `deps`, its settings,
/// its step limit (not `with_max_steps`) and its output validation. The
/// simulation's system prompt, when set, is added after the agent's own.
///
/// The simulation fails when:
///
/// - a tool returns something other than its scripted result
///   (`ToolSuccess` is the output the tool must return, `ToolFailure` the
///   error the model must be shown),
/// - the agent stops before the script ends, or asks the model for more
///   replies than the script has,
/// - the run fails with an error the script doesn't end with, or
/// - an assertion fails.
///
/// Each step's assertion sees the conversation as it stood after that
/// step, tool results included.
pub fn run_agent(
  sim: Simulation,
  agent: Agent(deps),
  deps: deps,
) -> SimulationResult {
  case sim.steps {
    [] ->
      SimulationFailed(
        name: sim.name,
        step: 0,
        error: AssertionError(
          step: 0,
          expected: "a script with at least one step",
          got: "no steps",
        ),
      )
    steps -> {
      // Every model call reports what it was asked and what it answered,
      // so the conversation can be followed step by step afterwards, also
      // when the run fails.
      let calls = process.new_subject()
      let scripted = provider.test_provider(list.map(steps, step_response))
      let observed = fn(request: glean_provider.GenerateRequest) {
        let answer = scripted.generate(request)
        process.send(calls, ModelCall(asked: request.messages, answer: answer))
        answer
      }
      let agent =
        Agent(
          ..agent,
          provider: Provider(
            ..scripted,
            generate: observed,
            stream: fn(request, _on_event) { observed(request) },
          ),
          system_prompts: case sim.system_prompt {
            "" -> agent.system_prompts
            prompt -> list.append(agent.system_prompts, [prompt])
          },
        )

      let outcome = run.generate(agent, deps, sim.user_prompt)
      let calls = drain(calls, [])
      // The provider is called in this process, so every call is here.
      let assert [first_call, ..] = calls

      let state =
        SimulationState(
          messages: first_call.asked,
          step_count: 0,
          total_usage: usage.zero(),
          tool_calls_made: [],
          errors_encountered: [],
        )
      check_agent_run(sim, steps, calls, outcome, state)
    }
  }
}

/// One call the agent made to the scripted model.
type ModelCall {
  ModelCall(asked: List(Message), answer: Result(GenerateResult, GleanError))
}

fn drain(
  calls: process.Subject(ModelCall),
  acc: List(ModelCall),
) -> List(ModelCall) {
  case process.receive(calls, 0) {
    Ok(call) -> drain(calls, [call, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn step_response(step: SimulationStep) -> provider.ScriptedResponse {
  case step {
    ExpectText(text:, ..) -> provider.TextResponse(text: text)
    ExpectToolCalls(executions:, ..) ->
      provider.ToolCallResponse(
        calls: list.map(executions, fn(execution) { execution.call }),
      )
    ExpectError(error:, ..) -> provider.ErrorResponse(error: error)
  }
}

/// The conversation at the end of the run, when the run kept one.
fn final_messages(
  outcome: Result(run.RunResult, GleanError),
) -> Option(List(Message)) {
  case outcome {
    Ok(result) -> Some(result.messages)
    Error(error.MaxStepsExceeded(messages:, ..)) -> Some(messages)
    Error(error.OutputValidationError(messages:, ..)) -> Some(messages)
    Error(_) -> None
  }
}

/// Follow the run call by call, next to the script.
fn check_agent_run(
  sim: Simulation,
  steps: List(SimulationStep),
  calls: List(ModelCall),
  outcome: Result(run.RunResult, GleanError),
  state: SimulationState,
) -> SimulationResult {
  let failed = fn(expected, got) {
    SimulationFailed(
      name: sim.name,
      step: state.step_count,
      error: AssertionError(
        step: state.step_count,
        expected: expected,
        got: got,
      ),
    )
  }
  case steps, calls {
    [step, ..steps], [call, ..calls] -> {
      // What this step added: the conversation the next call was asked
      // with, or the run's last conversation, less what this call was
      // asked with.
      let after = case calls {
        [next, ..] -> next.asked
        [] -> option.unwrap(final_messages(outcome), call.asked)
      }
      let added = list.drop(after, list.length(call.asked))
      let results = tool_results(added)
      let state =
        SimulationState(
          messages: after,
          step_count: state.step_count + 1,
          total_usage: case call.answer {
            Ok(answer) -> usage.add(state.total_usage, answer.usage)
            Error(_) -> state.total_usage
          },
          tool_calls_made: list.append(state.tool_calls_made, results),
          errors_encountered: case call.answer {
            Ok(_) -> state.errors_encountered
            Error(err) -> list.append(state.errors_encountered, [err])
          },
        )
      let checked = case step {
        ExpectToolCalls(executions:, ..) ->
          list.try_each(executions, check_execution(_, results, state))
        ExpectText(..) | ExpectError(..) -> Ok(Nil)
      }
      case
        checked |> result_then(fn() { run_assert(state, step.then_assert) })
      {
        Error(err) ->
          SimulationFailed(
            name: sim.name,
            step: state.step_count - 1,
            error: err,
          )
        Ok(state) -> check_agent_run(sim, steps, calls, outcome, state)
      }
    }

    [_, ..], [] ->
      failed(
        "the agent to reach step "
          <> int.to_string(state.step_count)
          <> " of the script",
        case outcome {
          Ok(_) -> "the run ended with an answer before it"
          Error(err) -> "the run failed before it: " <> error.to_string(err)
        },
      )

    [], [_, ..] ->
      case outcome {
        Error(error.MaxStepsExceeded(max_steps:, ..)) ->
          SimulationExceededMaxSteps(
            name: sim.name,
            max_steps: max_steps,
            state: state,
          )
        _ ->
          failed(
            "the run to end with the script",
            "the agent asked the model for "
              <> int.to_string(list.length(calls))
              <> " more replies",
          )
      }

    [], [] ->
      case outcome, list.last(state.errors_encountered) {
        Ok(_), _ -> run_final_assertions(sim, state, sim.final_assertions)
        // The script ends with this error.
        Error(err), Ok(expected) if err == expected ->
          run_final_assertions(sim, state, sim.final_assertions)
        Error(error.MaxStepsExceeded(max_steps:, ..)), _ ->
          SimulationExceededMaxSteps(
            name: sim.name,
            max_steps: max_steps,
            state: state,
          )
        Error(err), _ -> failed("the run to succeed", error.to_string(err))
      }
  }
}

fn result_then(
  checked: Result(Nil, AssertionError),
  next: fn() -> Result(SimulationState, AssertionError),
) -> Result(SimulationState, AssertionError) {
  case checked {
    Ok(Nil) -> next()
    Error(err) -> Error(err)
  }
}

fn tool_results(messages: List(Message)) -> List(message.ToolResult) {
  list.flat_map(messages, fn(msg) {
    case msg {
      message.ToolResultMessage(results:) -> results
      _ -> []
    }
  })
}

/// Compare what a tool really returned with what the script says.
fn check_execution(
  execution: ScriptedToolExecution,
  results: List(message.ToolResult),
  state: SimulationState,
) -> Result(Nil, AssertionError) {
  let call = execution.call
  let expected = case execution.result {
    ToolSuccess(content:) -> "the result " <> string.inspect(content)
    ToolFailure(error:) -> "the error " <> string.inspect(error)
  }
  let actual = list.find(results, fn(result) { result.tool_call_id == call.id })
  let matches = case actual, execution.result {
    Ok(message.ToolResultOk(output:, ..)), ToolSuccess(content:) ->
      output == content
    Ok(message.ToolResultError(error_message:, ..)), ToolFailure(error:) ->
      error_message == error
    _, _ -> False
  }
  case matches {
    True -> Ok(Nil)
    False ->
      Error(AssertionError(
        // step_count already counts this step.
        step: state.step_count - 1,
        expected: "tool " <> call.name <> " to give " <> expected,
        got: case actual {
          Ok(message.ToolResultOk(output:, ..)) ->
            "the result " <> string.inspect(output)
          Ok(message.ToolResultError(error_message:, ..)) ->
            "the error " <> string.inspect(error_message)
          Error(Nil) -> "no result for call " <> call.id
        },
      ))
  }
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
          SimulationFailed(name: sim.name, step: state.step_count, error: err)
      }
  }
}
