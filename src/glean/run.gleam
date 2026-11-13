//// Agent execution loop.
////
//// A pure recursive loop: call the model, run any tools it asked for, feed
//// the results back, and repeat until the model answers without calling a
//// tool (or `max_steps` is reached).
////
//// Every tool call runs in a process of its own, so a tool that panics, or
//// takes longer than `agent.tool_timeout` allows, can't take the run down
//// with it: the model gets an error result and can try something else.
//// When the process running the agent is itself stopped, its tools are
//// stopped with it.
//// The tool therefore does not run in the process that called `run`:
//// `process.self()` is another process there, and a tool can't receive on
//// a subject the caller made. Give tools what they need through `deps`.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/agent.{type Agent}
import glean/error.{type FinishReason, type GleanError, MaxStepsExceeded}
import glean/message.{type Message}
import glean/provider.{
  type GenerateResult, type GeneratedContent, GenerateRequest, GeneratedText,
  GeneratedToolCall,
}
import glean/schema
import glean/stream.{type StreamEvent, type Usage}
import glean/tool.{ToolContext}

/// The result of a completed agent run.
pub type RunResult {
  RunResult(
    /// The final text output (concatenated from all text content)
    text: String,
    /// The whole conversation: input messages, every tool call and result,
    /// and the model's final answer. Pass the result to `continue` to keep
    /// talking.
    messages: List(Message),
    /// All generated content from the final step
    content: List(GeneratedContent),
    /// Total token usage across all steps
    usage: Usage,
    /// Why the model stopped
    finish_reason: FinishReason,
    /// Number of steps taken
    steps: Int,
    /// Results from each individual step
    step_results: List(StepResult),
  )
}

/// The result of a single step in the agent loop.
pub type StepResult {
  StepResult(
    step: Int,
    content: List(GeneratedContent),
    finish_reason: FinishReason,
    usage: Usage,
  )
}

/// Internal state threaded through the agent loop.
type RunState(deps) {
  RunState(
    agent: Agent(deps),
    deps: deps,
    messages: List(Message),
    step: Int,
    total_usage: Usage,
    step_results: List(StepResult),
    /// How often the model was asked again for a final answer that
    /// matches the schema.
    output_retries_used: Int,
  )
}

// --- Public API ---

/// Run the agent with a simple text prompt.
pub fn generate(
  agent: Agent(deps),
  deps: deps,
  prompt: String,
) -> Result(RunResult, GleanError) {
  run_loop(initial_state(agent, deps, build_initial_messages(agent, prompt)))
}

/// Run the agent with pre-built messages (for multi-turn conversations).
///
/// The agent's system prompts are prepended unless `messages` already
/// contains a system message, so a history taken from `RunResult.messages`
/// doesn't get them twice.
pub fn generate_messages(
  agent: Agent(deps),
  deps: deps,
  messages: List(Message),
) -> Result(RunResult, GleanError) {
  run_loop(initial_state(agent, deps, prepend_system_prompts(agent, messages)))
}

/// Run the agent with streaming. Calls on_event for each StreamEvent.
pub fn stream(
  agent: Agent(deps),
  deps: deps,
  prompt: String,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  run_stream_loop(
    initial_state(agent, deps, build_initial_messages(agent, prompt)),
    on_event,
  )
}

/// Run the agent with streaming and pre-built messages (for multi-turn
/// conversations). The streaming version of `generate_messages`.
///
/// The agent's system prompts are prepended unless `messages` already
/// contains a system message, so a history taken from `RunResult.messages`
/// doesn't get them twice.
pub fn stream_messages(
  agent: Agent(deps),
  deps: deps,
  messages: List(Message),
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  run_stream_loop(
    initial_state(agent, deps, prepend_system_prompts(agent, messages)),
    on_event,
  )
}

/// Continue a previous run with additional user input.
pub fn continue(
  agent: Agent(deps),
  deps: deps,
  previous: RunResult,
  prompt: String,
) -> Result(RunResult, GleanError) {
  let messages = list.append(previous.messages, [message.user(prompt)])
  run_loop(initial_state(agent, deps, messages))
}

/// Continue a previous run with additional user input, streaming the
/// response. The streaming version of `continue`.
pub fn continue_stream(
  agent: Agent(deps),
  deps: deps,
  previous: RunResult,
  prompt: String,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  let messages = list.append(previous.messages, [message.user(prompt)])
  run_stream_loop(initial_state(agent, deps, messages), on_event)
}

// --- Internal: message building ---

fn initial_state(
  agent: Agent(deps),
  deps: deps,
  messages: List(Message),
) -> RunState(deps) {
  RunState(
    agent: agent,
    deps: deps,
    messages: messages,
    step: 0,
    total_usage: stream.zero_usage(),
    step_results: [],
    output_retries_used: 0,
  )
}

fn build_initial_messages(agent: Agent(deps), prompt: String) -> List(Message) {
  let system_msgs = list.map(agent.system_prompts, message.system)
  list.append(system_msgs, [message.user(prompt)])
}

fn prepend_system_prompts(
  agent: Agent(deps),
  messages: List(Message),
) -> List(Message) {
  let has_system =
    list.any(messages, fn(msg) {
      case msg {
        message.SystemMessage(_) -> True
        _ -> False
      }
    })
  case has_system {
    True -> messages
    False ->
      list.append(list.map(agent.system_prompts, message.system), messages)
  }
}

fn build_request(state: RunState(deps)) -> provider.GenerateRequest {
  GenerateRequest(
    messages: state.messages,
    settings: state.agent.settings,
    tools: tool.to_specs(state.agent.tools),
    tool_choice: state.agent.tool_choice,
    response_format: state.agent.response_format,
  )
}

// --- Internal: agent loop (non-streaming) ---

fn run_loop(state: RunState(deps)) -> Result(RunResult, GleanError) {
  case state.step >= state.agent.max_steps {
    True ->
      Error(MaxStepsExceeded(
        max_steps: state.agent.max_steps,
        steps_taken: state.step,
        messages: state.messages,
        usage: state.total_usage,
      ))
    False ->
      case state.agent.provider.generate(build_request(state)) {
        Error(err) -> Error(err)
        Ok(result) ->
          case advance(state, result, fn(_) { Nil }) {
            Finished(run_result) -> Ok(run_result)
            Failed(err) -> Error(err)
            Continue(next_state) -> run_loop(next_state)
          }
      }
  }
}

// --- Internal: agent loop (streaming) ---

fn run_stream_loop(
  state: RunState(deps),
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  // Every way the run can fail ends with a `StreamError` event, so a
  // consumer that only watches events sees the failure too.
  let fail = fn(err: GleanError) {
    on_event(stream.StreamError(message: error.to_string(err)))
    Error(err)
  }
  case state.step >= state.agent.max_steps {
    True ->
      fail(MaxStepsExceeded(
        max_steps: state.agent.max_steps,
        steps_taken: state.step,
        messages: state.messages,
        usage: state.total_usage,
      ))
    False -> {
      on_event(stream.StepStart(step: state.step))
      case state.agent.provider.stream(build_request(state), on_event) {
        Error(err) -> fail(err)
        Ok(result) -> {
          on_event(stream.StepEnd(step: state.step))
          case advance(state, result, on_event) {
            Finished(run_result) -> {
              on_event(stream.Finish(
                finish_reason: run_result.finish_reason,
                usage: run_result.usage,
              ))
              Ok(run_result)
            }
            Failed(err) -> fail(err)
            Continue(next_state) -> run_stream_loop(next_state, on_event)
          }
        }
      }
    }
  }
}

// --- Internal: one step ---

type StepOutcome(deps) {
  Finished(RunResult)
  Failed(GleanError)
  Continue(RunState(deps))
}

/// Handle one model response: finish the run if it has no tool calls,
/// otherwise run the tools and return the state for the next step.
fn advance(
  state: RunState(deps),
  result: GenerateResult,
  on_event: fn(StreamEvent) -> Nil,
) -> StepOutcome(deps) {
  let step_result =
    StepResult(
      step: state.step,
      content: result.content,
      finish_reason: result.finish_reason,
      usage: result.usage,
    )
  let new_usage = stream.add_usage(state.total_usage, result.usage)
  let new_step_results = list.append(state.step_results, [step_result])
  let messages_with_answer =
    append_assistant_message(state.messages, result.content)

  case extract_tool_calls(result.content) {
    [] -> {
      let text = extract_text(result.content)
      case validate_output(state.agent, text, result.finish_reason) {
        Ok(Nil) ->
          Finished(RunResult(
            text: text,
            messages: messages_with_answer,
            content: result.content,
            usage: new_usage,
            finish_reason: result.finish_reason,
            steps: state.step + 1,
            step_results: new_step_results,
          ))
        Error(errors) ->
          case can_retry_output(state, result.finish_reason) {
            // Tell the model what is wrong with its answer and ask again.
            True ->
              Continue(
                RunState(
                  ..state,
                  messages: list.append(messages_with_answer, [
                    message.user(output_retry_prompt(errors)),
                  ]),
                  step: state.step + 1,
                  total_usage: new_usage,
                  step_results: new_step_results,
                  output_retries_used: state.output_retries_used + 1,
                ),
              )
            False ->
              Failed(error.OutputValidationError(
                errors: errors,
                text: text,
                finish_reason: result.finish_reason,
                messages: messages_with_answer,
                usage: new_usage,
              ))
          }
      }
    }
    tool_calls -> {
      let tool_results = execute_tool_calls(state, tool_calls)
      list.each(tool_results, fn(result) { emit_tool_event(result, on_event) })
      Continue(
        RunState(
          ..state,
          messages: list.append(messages_with_answer, [
            message.ToolResultMessage(results: tool_results),
          ]),
          step: state.step + 1,
          total_usage: new_usage,
          step_results: new_step_results,
        ),
      )
    }
  }
}

/// When the agent asked for JSON with a schema, the final answer must parse
/// and match it.
fn validate_output(
  agent: Agent(deps),
  text: String,
  finish_reason: FinishReason,
) -> Result(Nil, List(error.ValidationError)) {
  case agent.response_format {
    provider.JsonFormat(schema: Some(output_schema), ..) ->
      case schema.validate_json(output_schema, text), finish_reason {
        Ok(_), _ -> Ok(Nil)
        // "Not valid JSON" would hide what really happened.
        Error(_), error.Length ->
          Error([
            error.ValidationError(
              path: [],
              message: "The answer was cut off at the output token limit, so its JSON is incomplete. Raise max_output_tokens.",
            ),
          ])
        Error(errors), _ -> Error(errors)
      }
    _ -> Ok(Nil)
  }
}

/// Whether an answer that failed validation is worth asking for again: the
/// agent has retries left, there is a step left to take, and the answer
/// wasn't cut off or refused, which asking again wouldn't change.
fn can_retry_output(
  state: RunState(deps),
  finish_reason: FinishReason,
) -> Bool {
  let answered = case finish_reason {
    error.Length | error.ContentFilter -> False
    _ -> True
  }
  answered
  && state.output_retries_used < state.agent.output_retries
  && state.step + 1 < state.agent.max_steps
}

fn output_retry_prompt(errors: List(error.ValidationError)) -> String {
  "Your answer does not match the required JSON schema: "
  <> error.validation_errors_to_string(errors)
  <> ". Answer again with only the corrected JSON."
}

fn emit_tool_event(
  result: message.ToolResult,
  on_event: fn(StreamEvent) -> Nil,
) -> Nil {
  case result {
    message.ToolResultOk(tool_call_id, tool_name, output) ->
      on_event(stream.ToolResultEvent(
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        output: output,
      ))
    message.ToolResultError(tool_call_id, tool_name, error_message) ->
      on_event(stream.ToolErrorEvent(
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        error: error_message,
      ))
  }
}

// --- Internal: history ---

/// Append the model's response to the conversation history, so that
/// `RunResult.messages` holds the full conversation (including the final
/// answer) and `continue` sends it back to the model.
fn append_assistant_message(
  messages: List(Message),
  content: List(GeneratedContent),
) -> List(Message) {
  case content {
    [] -> messages
    _ -> {
      let assistant_content =
        list.map(content, fn(c) {
          case c {
            GeneratedToolCall(id, name, args) ->
              message.AssistantToolCall(
                tool_call_id: id,
                tool_name: name,
                arguments_json: args,
              )
            GeneratedText(text) -> message.AssistantText(text)
            provider.GeneratedReasoning(text, signature) ->
              message.AssistantReasoning(text, signature)
            provider.GeneratedRedactedReasoning(data) ->
              message.AssistantRedactedReasoning(data)
            provider.GeneratedFile(media_type, data, signature) ->
              message.AssistantFile(media_type, data, signature)
          }
        })
      list.append(messages, [
        message.AssistantMessage(content: assistant_content),
      ])
    }
  }
}

// --- Internal: tool execution ---

type PendingToolCall {
  PendingToolCall(
    tool_call_id: String,
    tool_name: String,
    arguments_json: String,
  )
}

fn extract_tool_calls(
  content: List(GeneratedContent),
) -> List(PendingToolCall) {
  list.filter_map(content, fn(c) {
    case c {
      GeneratedToolCall(id, name, args) ->
        Ok(PendingToolCall(
          tool_call_id: id,
          tool_name: name,
          arguments_json: args,
        ))
      _ -> Error(Nil)
    }
  })
}

fn extract_text(content: List(GeneratedContent)) -> String {
  content
  |> list.filter_map(fn(c) {
    case c {
      GeneratedText(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.concat
}

/// Run every tool call from one model response, each in a process of its
/// own. When the model asks for several tools at once (and the agent allows
/// it), they run concurrently. Results always come back in the order the
/// model asked for them.
fn execute_tool_calls(
  state: RunState(deps),
  calls: List(PendingToolCall),
) -> List(message.ToolResult) {
  case state.agent.parallel_tool_calls {
    True -> run_isolated(state, calls)
    False -> list.flat_map(calls, fn(call) { run_isolated(state, [call]) })
  }
}

/// A tool call running in its own process.
type RunningToolCall {
  RunningToolCall(
    index: Int,
    call: PendingToolCall,
    pid: process.Pid,
    monitor: process.Monitor,
  )
}

/// What the caller hears while it waits for tool calls.
type ToolCallNews {
  ToolCallDone(index: Int, result: message.ToolResult)
  ToolCallExited(index: Int, reason: process.ExitReason)
  ToolCallsOutOfTime
}

/// Start every call in a process that is monitored, not linked, so one that
/// crashes is reported and takes nothing else with it, then wait for all of
/// them, at most as long as the agent's tool timeout.
fn run_isolated(
  state: RunState(deps),
  calls: List(PendingToolCall),
) -> List(message.ToolResult) {
  let results = process.new_subject()
  let running =
    list.index_map(calls, fn(call, index) {
      let pid =
        process.spawn_unlinked(fn() {
          process.send(results, #(index, execute_single_tool(state, call)))
        })
      RunningToolCall(index:, call:, pid:, monitor: process.monitor(pid))
    })
  let guard = stop_with_caller(list.map(running, fn(call) { call.pid }))
  let out_of_time = process.new_subject()
  let timer =
    option.map(state.agent.tool_timeout_ms, fn(ms) {
      process.send_after(out_of_time, ms, Nil)
    })

  let finished = await_tool_calls(state, results, out_of_time, running, [])

  process.kill(guard)

  case timer {
    Some(timer) -> {
      process.cancel_timer(timer)
      // If it fired just before it was cancelled, take its message out of
      // the mailbox.
      let _ = process.receive(out_of_time, 0)
      Nil
    }
    None -> Nil
  }
  // A call that finished just as the time ran out left its result behind.
  discard_results(results)
  // Postcondition: exactly one result per call.
  let assert True = list.length(finished) == list.length(calls)
  finished
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

/// The tool processes are not linked to the caller, so they would outlive
/// it. This starts a process that waits for the calling process to die and
/// then stops the tools, so that stopping a run stops its tools too. The
/// caller kills it once the tools are done.
fn stop_with_caller(tools: List(process.Pid)) -> process.Pid {
  let caller = process.self()
  process.spawn_unlinked(fn() {
    let monitor = process.monitor(caller)
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
    list.each(tools, process.kill)
  })
}

/// Take what is left of a finished batch out of the mailbox.
fn discard_results(
  results: process.Subject(#(Int, message.ToolResult)),
) -> Nil {
  case process.receive(results, 0) {
    Ok(_) -> discard_results(results)
    Error(Nil) -> Nil
  }
}

fn await_tool_calls(
  state: RunState(deps),
  results: process.Subject(#(Int, message.ToolResult)),
  out_of_time: process.Subject(Nil),
  running: List(RunningToolCall),
  finished: List(#(Int, message.ToolResult)),
) -> List(#(Int, message.ToolResult)) {
  case running {
    [] -> finished
    _ -> {
      let selector =
        process.new_selector()
        |> process.select_map(results, fn(done) {
          ToolCallDone(index: done.0, result: done.1)
        })
        |> process.select_map(out_of_time, fn(_) { ToolCallsOutOfTime })
      let selector =
        list.fold(running, selector, fn(selector, tool_call) {
          process.select_specific_monitor(selector, tool_call.monitor, fn(down) {
            ToolCallExited(tool_call.index, down.reason)
          })
        })
      case process.selector_receive_forever(selector) {
        ToolCallDone(index, result) -> {
          let #(done, still_running) =
            list.partition(running, fn(tool_call) { tool_call.index == index })
          list.each(done, fn(tool_call) {
            process.demonitor_process(tool_call.monitor)
          })
          await_tool_calls(state, results, out_of_time, still_running, [
            #(index, result),
            ..finished
          ])
        }
        // A process sends its result before it exits, and the result is
        // read first, so one that exits while it is still listed here
        // crashed without a result.
        ToolCallExited(index, reason) -> {
          let #(crashed, still_running) =
            list.partition(running, fn(tool_call) { tool_call.index == index })
          let reports =
            list.map(crashed, fn(tool_call) {
              #(
                tool_call.index,
                tool_error(
                  tool_call.call,
                  "The tool crashed: " <> exit_reason_to_string(reason),
                ),
              )
            })
          await_tool_calls(
            state,
            results,
            out_of_time,
            still_running,
            list.append(reports, finished),
          )
        }
        ToolCallsOutOfTime -> {
          let limit = case state.agent.tool_timeout_ms {
            Some(ms) -> int.to_string(ms) <> " ms"
            None -> panic as "glean: a tool timer fired without a tool timeout"
          }
          let reports =
            list.map(running, fn(tool_call) {
              // Kill cannot be caught, so the process is certain to go
              // down. Waiting for that means nothing it sends can arrive
              // after this function returns.
              process.kill(tool_call.pid)
              process.new_selector()
              |> process.select_specific_monitor(tool_call.monitor, fn(_) {
                Nil
              })
              |> process.selector_receive_forever
              #(
                tool_call.index,
                tool_error(
                  tool_call.call,
                  "The tool did not finish within "
                    <> limit
                    <> " and was stopped",
                ),
              )
            })
          list.append(reports, finished)
        }
      }
    }
  }
}

fn exit_reason_to_string(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "it exited without a result"
    process.Killed -> "it was killed"
    process.Abnormal(reason) -> string.slice(string.inspect(reason), 0, 500)
  }
}

/// Run one tool call. Every failure — unknown tool, arguments that don't
/// match the tool's schema, or an error from the tool itself once retries
/// run out — becomes an error result sent back to the model, so it can
/// correct itself.
fn execute_single_tool(
  state: RunState(deps),
  call: PendingToolCall,
) -> message.ToolResult {
  case tool.find(state.agent.tools, call.tool_name) {
    Error(_) ->
      tool_error(
        call,
        "Unknown tool \""
          <> call.tool_name
          <> "\". Available tools: "
          <> string.join(tool.names(state.agent.tools), ", "),
      )
    Ok(found_tool) ->
      case schema.validate_json(found_tool.input_schema, call.arguments_json) {
        Error(errors) ->
          tool_error(
            call,
            tool_error_to_string(error.ToolInputValidationError(
              tool_name: call.tool_name,
              tool_call_id: call.tool_call_id,
              errors: errors,
            )),
          )
        Ok(_) -> execute_tool_with_retry(state, call, found_tool, 0)
      }
  }
}

fn execute_tool_with_retry(
  state: RunState(deps),
  call: PendingToolCall,
  found_tool: tool.Tool(deps),
  attempt: Int,
) -> message.ToolResult {
  let ctx =
    ToolContext(
      deps: state.deps,
      tool_call_id: call.tool_call_id,
      tool_name: call.tool_name,
      retry: attempt,
      max_retries: found_tool.max_retries,
      step: state.step,
    )

  case found_tool.execute(ctx, call.arguments_json) {
    Ok(output) ->
      message.ToolResultOk(
        tool_call_id: call.tool_call_id,
        tool_name: call.tool_name,
        output: output,
      )
    Error(tool_err) ->
      case attempt < found_tool.max_retries {
        True -> execute_tool_with_retry(state, call, found_tool, attempt + 1)
        // All retries exhausted — return the error to the model for recovery
        False -> tool_error(call, tool_error_to_string(tool_err))
      }
  }
}

fn tool_error(call: PendingToolCall, message: String) -> message.ToolResult {
  message.ToolResultError(
    tool_call_id: call.tool_call_id,
    tool_name: call.tool_name,
    error_message: message,
  )
}

fn tool_error_to_string(err: GleanError) -> String {
  case err {
    error.ToolExecutionError(_, _, reason) -> reason
    error.ToolInputValidationError(_, _, errors) ->
      "Invalid arguments: " <> error.validation_errors_to_string(errors)
    other -> error.to_string(other)
  }
}
