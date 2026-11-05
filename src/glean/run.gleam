/// Agent execution loop.
/// Pure recursive function — no mutable state.
import gleam/list
import glean/agent.{type Agent}
import glean/error.{type FinishReason, type GleanError, MaxStepsExceeded}
import glean/message.{type Message}
import glean/provider.{
  type GenerateResult, type GeneratedContent, GenerateRequest, GeneratedText,
  GeneratedToolCall,
}
import glean/stream.{type StreamEvent, type Usage}
import glean/tool.{ToolContext}

/// The result of a completed agent run.
pub type RunResult {
  RunResult(
    /// The final text output (concatenated from all text content)
    text: String,
    /// All messages exchanged during the run (input + generated)
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
  let messages = build_initial_messages(agent, prompt)
  run_loop(
    RunState(
      agent: agent,
      deps: deps,
      messages: messages,
      step: 0,
      total_usage: stream.zero_usage(),
      step_results: [],
    ),
  )
}

/// Run the agent with pre-built messages (for multi-turn conversations).
pub fn generate_messages(
  agent: Agent(deps),
  deps: deps,
  messages: List(Message),
) -> Result(RunResult, GleanError) {
  let messages = prepend_system_prompts(agent, messages)
  run_loop(
    RunState(
      agent: agent,
      deps: deps,
      messages: messages,
      step: 0,
      total_usage: stream.zero_usage(),
      step_results: [],
    ),
  )
}

/// Run the agent with streaming. Calls on_event for each StreamEvent.
pub fn stream(
  agent: Agent(deps),
  deps: deps,
  prompt: String,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  let messages = build_initial_messages(agent, prompt)
  run_stream_loop(
    RunState(
      agent: agent,
      deps: deps,
      messages: messages,
      step: 0,
      total_usage: stream.zero_usage(),
      step_results: [],
    ),
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
  run_loop(
    RunState(
      agent: agent,
      deps: deps,
      messages: messages,
      step: 0,
      total_usage: stream.zero_usage(),
      step_results: [],
    ),
  )
}

// --- Internal: message building ---

fn build_initial_messages(agent: Agent(deps), prompt: String) -> List(Message) {
  let system_msgs =
    agent.system_prompts
    |> list.map(message.system)

  list.append(system_msgs, [message.user(prompt)])
}

fn prepend_system_prompts(
  agent: Agent(deps),
  messages: List(Message),
) -> List(Message) {
  let system_msgs =
    agent.system_prompts
    |> list.map(message.system)

  list.append(system_msgs, messages)
}

// --- Internal: agent loop (non-streaming) ---

fn run_loop(state: RunState(deps)) -> Result(RunResult, GleanError) {
  // Assert: step limit not exceeded
  case state.step >= state.agent.max_steps {
    True ->
      Error(MaxStepsExceeded(
        max_steps: state.agent.max_steps,
        steps_taken: state.step,
      ))
    False -> {
      // Build request
      let request =
        GenerateRequest(
          messages: state.messages,
          settings: state.agent.settings,
          tools: tool.to_specs(state.agent.tools),
          tool_choice: state.agent.tool_choice,
          response_format: provider.TextFormat,
        )

      // Call provider
      case state.agent.provider.generate(request) {
        Error(err) -> Error(err)
        Ok(result) -> process_generate_result(state, result)
      }
    }
  }
}

fn process_generate_result(
  state: RunState(deps),
  result: GenerateResult,
) -> Result(RunResult, GleanError) {
  let step_result =
    StepResult(
      step: state.step,
      content: result.content,
      finish_reason: result.finish_reason,
      usage: result.usage,
    )

  let new_usage = stream.add_usage(state.total_usage, result.usage)
  let new_step_results = list.append(state.step_results, [step_result])

  // Extract tool calls from the response
  let tool_calls = extract_tool_calls(result.content)

  case tool_calls {
    // No tool calls — return final result
    [] -> {
      let text = extract_text(result.content)
      Ok(RunResult(
        text: text,
        messages: append_assistant_message(state.messages, result.content),
        content: result.content,
        usage: new_usage,
        finish_reason: result.finish_reason,
        steps: state.step + 1,
        step_results: new_step_results,
      ))
    }
    // Tool calls present — execute them and loop
    _ -> {
      // Add assistant message with tool calls
      let messages_with_assistant =
        append_assistant_message(state.messages, result.content)

      // Execute each tool call
      case execute_tool_calls(state, tool_calls) {
        Error(err) -> Error(err)
        Ok(tool_results) -> {
          let messages_with_results =
            list.append(messages_with_assistant, [
              message.ToolResultMessage(results: tool_results),
            ])

          // Recurse with updated state
          run_loop(
            RunState(
              ..state,
              messages: messages_with_results,
              step: state.step + 1,
              total_usage: new_usage,
              step_results: new_step_results,
            ),
          )
        }
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

      let request =
        GenerateRequest(
          messages: state.messages,
          settings: state.agent.settings,
          tools: tool.to_specs(state.agent.tools),
          tool_choice: state.agent.tool_choice,
          response_format: provider.TextFormat,
        )

      case state.agent.provider.stream(request, on_event) {
        Error(err) -> Error(err)
        Ok(result) -> {
          on_event(stream.StepEnd(step: state.step))
          process_stream_result(state, result, on_event)
        }
      }
    }
  }
}

fn process_stream_result(
  state: RunState(deps),
  result: GenerateResult,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(RunResult, GleanError) {
  let step_result =
    StepResult(
      step: state.step,
      content: result.content,
      finish_reason: result.finish_reason,
      usage: result.usage,
    )

  let new_usage = stream.add_usage(state.total_usage, result.usage)
  let new_step_results = list.append(state.step_results, [step_result])
  let tool_calls = extract_tool_calls(result.content)

  case tool_calls {
    [] -> {
      let text = extract_text(result.content)
      on_event(stream.Finish(
        finish_reason: result.finish_reason,
        usage: new_usage,
      ))
      Ok(RunResult(
        text: text,
        messages: append_assistant_message(state.messages, result.content),
        content: result.content,
        usage: new_usage,
        finish_reason: result.finish_reason,
        steps: state.step + 1,
        step_results: new_step_results,
      ))
    }
    _ -> {
      let messages_with_assistant =
        append_assistant_message(state.messages, result.content)

      case execute_tool_calls_with_events(state, tool_calls, on_event) {
        Error(err) -> Error(err)
        Ok(tool_results) -> {
          let messages_with_results =
            list.append(messages_with_assistant, [
              message.ToolResultMessage(results: tool_results),
            ])

          run_stream_loop(
            RunState(
              ..state,
              messages: messages_with_results,
              step: state.step + 1,
              total_usage: new_usage,
              step_results: new_step_results,
            ),
            on_event,
          )
        }
      }
    }
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
            provider.GeneratedReasoning(text) ->
              message.AssistantReasoning(text)
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
  |> list.fold("", fn(acc, text) { acc <> text })
}

fn execute_tool_calls(
  state: RunState(deps),
  calls: List(PendingToolCall),
) -> Result(List(message.ToolResult), GleanError) {
  execute_tool_calls_loop(state, calls, [])
}

fn execute_tool_calls_loop(
  state: RunState(deps),
  calls: List(PendingToolCall),
  results: List(message.ToolResult),
) -> Result(List(message.ToolResult), GleanError) {
  case calls {
    [] -> Ok(list.reverse(results))
    [call, ..rest] -> {
      case execute_single_tool(state, call) {
        Error(err) -> Error(err)
        Ok(result) -> execute_tool_calls_loop(state, rest, [result, ..results])
      }
    }
  }
}

fn execute_tool_calls_with_events(
  state: RunState(deps),
  calls: List(PendingToolCall),
  on_event: fn(StreamEvent) -> Nil,
) -> Result(List(message.ToolResult), GleanError) {
  execute_tool_calls_with_events_loop(state, calls, [], on_event)
}

fn execute_tool_calls_with_events_loop(
  state: RunState(deps),
  calls: List(PendingToolCall),
  results: List(message.ToolResult),
  on_event: fn(StreamEvent) -> Nil,
) -> Result(List(message.ToolResult), GleanError) {
  case calls {
    [] -> Ok(list.reverse(results))
    [call, ..rest] -> {
      case execute_single_tool(state, call) {
        Error(err) -> Error(err)
        Ok(result) -> {
          // Emit tool result/error events
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
          execute_tool_calls_with_events_loop(
            state,
            rest,
            [result, ..results],
            on_event,
          )
        }
      }
    }
  }
}

fn execute_single_tool(
  state: RunState(deps),
  call: PendingToolCall,
) -> Result(message.ToolResult, GleanError) {
  case tool.find(state.agent.tools, call.tool_name) {
    Error(err) -> Error(err)
    Ok(found_tool) -> execute_tool_with_retry(state, call, found_tool, 0)
  }
}

fn execute_tool_with_retry(
  state: RunState(deps),
  call: PendingToolCall,
  found_tool: tool.Tool(deps),
  attempt: Int,
) -> Result(message.ToolResult, GleanError) {
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
      Ok(message.ToolResultOk(
        tool_call_id: call.tool_call_id,
        tool_name: call.tool_name,
        output: output,
      ))
    Error(tool_err) -> {
      // Retry on execution/validation errors if retries remain
      case attempt < found_tool.max_retries {
        True ->
          case tool_err {
            // ToolNotFound is immediately fatal — no retry
            error.ToolNotFound(_) ->
              Ok(message.ToolResultError(
                tool_call_id: call.tool_call_id,
                tool_name: call.tool_name,
                error_message: tool_error_to_string(tool_err),
              ))
            // Retryable errors
            _ -> execute_tool_with_retry(state, call, found_tool, attempt + 1)
          }
        False ->
          // All retries exhausted — return error to model for recovery
          Ok(message.ToolResultError(
            tool_call_id: call.tool_call_id,
            tool_name: call.tool_name,
            error_message: tool_error_to_string(tool_err),
          ))
      }
    }
  }
}

fn tool_error_to_string(err: GleanError) -> String {
  case err {
    error.ToolExecutionError(_, _, reason) -> reason
    error.ToolInputValidationError(_, _, errors) ->
      errors
      |> list.map(fn(e) { e.message })
      |> list.fold("Validation errors: ", fn(acc, msg) { acc <> msg <> "; " })
    _ -> "Tool execution failed"
  }
}
