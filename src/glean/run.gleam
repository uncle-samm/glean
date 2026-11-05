//// Agent execution loop.
////
//// A pure recursive loop: call the model, run any tools it asked for, feed
//// the results back, and repeat until the model answers without calling a
//// tool (or `max_steps` is reached).

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
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
    False -> list.append(list.map(agent.system_prompts, message.system), messages)
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
  case state.step >= state.agent.max_steps {
    True ->
      Error(MaxStepsExceeded(
        max_steps: state.agent.max_steps,
        steps_taken: state.step,
      ))
    False -> {
      on_event(stream.StepStart(step: state.step))
      case state.agent.provider.stream(build_request(state), on_event) {
        Error(err) -> Error(err)
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
            Failed(err) -> Error(err)
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
      case validate_output(state.agent, text) {
        Error(err) -> Failed(err)
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
fn validate_output(agent: Agent(deps), text: String) -> Result(Nil, GleanError) {
  case agent.response_format {
    provider.JsonFormat(schema: Some(output_schema), ..) ->
      case schema.validate_json(output_schema, text) {
        Ok(_) -> Ok(Nil)
        Error(errors) -> Error(error.OutputValidationError(errors: errors))
      }
    _ -> Ok(Nil)
  }
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

fn extract_tool_calls(content: List(GeneratedContent)) -> List(PendingToolCall) {
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

/// Run every tool call from one model response. When the model asks for
/// several tools at once (and the agent allows it), they run concurrently,
/// each in its own process. Results always come back in the order the model
/// asked for them.
fn execute_tool_calls(
  state: RunState(deps),
  calls: List(PendingToolCall),
) -> List(message.ToolResult) {
  case calls, state.agent.parallel_tool_calls {
    [_, _, ..], True -> execute_concurrently(state, calls)
    _, _ -> list.map(calls, execute_single_tool(state, _))
  }
}

fn execute_concurrently(
  state: RunState(deps),
  calls: List(PendingToolCall),
) -> List(message.ToolResult) {
  let subject = process.new_subject()
  list.index_map(calls, fn(call, index) {
    process.spawn(fn() {
      process.send(subject, #(index, execute_single_tool(state, call)))
    })
  })
  let results = collect_results(subject, list.length(calls), [])
  // Postcondition: exactly one result per call.
  let assert True = list.length(results) == list.length(calls)
  results
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

fn collect_results(
  subject: process.Subject(#(Int, message.ToolResult)),
  remaining: Int,
  acc: List(#(Int, message.ToolResult)),
) -> List(#(Int, message.ToolResult)) {
  case remaining {
    0 -> acc
    _ ->
      collect_results(subject, remaining - 1, [
        process.receive_forever(subject),
        ..acc
      ])
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
      "Invalid arguments: "
      <> string.join(
        list.map(errors, fn(e) {
          case e.path {
            [] -> e.message
            path -> string.join(path, ".") <> ": " <> e.message
          }
        }),
        "; ",
      )
    other -> error.to_string(other)
  }
}
