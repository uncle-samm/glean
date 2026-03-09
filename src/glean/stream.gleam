/// Streaming event types.
/// Follows the start/delta/end pattern from Vercel AI SDK.

import gleam/list
import gleam/string_tree
import glean/error.{type FinishReason}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

pub type StreamEvent {
  // --- Text ---
  TextStart(id: String)
  TextDelta(id: String, delta: String)
  TextEnd(id: String)
  // --- Reasoning ---
  ReasoningStart(id: String)
  ReasoningDelta(id: String, delta: String)
  ReasoningEnd(id: String)
  // --- Tool calls ---
  ToolCallStart(id: String, tool_call_id: String, tool_name: String)
  ToolCallDelta(id: String, tool_call_id: String, delta: String)
  ToolCallEnd(id: String, tool_call_id: String)
  // --- Tool results (emitted by the agent loop, not the provider) ---
  ToolResultEvent(tool_call_id: String, tool_name: String, output: String)
  ToolErrorEvent(tool_call_id: String, tool_name: String, error: String)
  // --- Lifecycle ---
  StepStart(step: Int)
  StepEnd(step: Int)
  Finish(finish_reason: FinishReason, usage: Usage)
  StreamError(message: String)
}

/// Accumulate all text deltas from a list of stream events into a single string.
pub fn collect_text(events: List(StreamEvent)) -> String {
  events
  |> list.fold(string_tree.new(), fn(acc, event) {
    case event {
      TextDelta(_, delta) -> string_tree.append(acc, delta)
      _ -> acc
    }
  })
  |> string_tree.to_string
}

/// A tool call being accumulated from stream events.
type ToolCallAccumulator {
  ToolCallAccumulator(
    tool_call_id: String,
    tool_name: String,
    args: string_tree.StringTree,
  )
}

/// Extract all completed tool calls from stream events.
/// Returns a list of (tool_call_id, tool_name, arguments_json) tuples.
pub fn collect_tool_calls(
  events: List(StreamEvent),
) -> List(#(String, String, String)) {
  collect_tool_calls_loop(events, [], None)
}

import gleam/option.{type Option, None, Some}

fn collect_tool_calls_loop(
  events: List(StreamEvent),
  completed: List(#(String, String, String)),
  current: Option(ToolCallAccumulator),
) -> List(#(String, String, String)) {
  case events {
    [] -> list.reverse(completed)
    [event, ..rest] ->
      case event {
        ToolCallStart(_, tool_call_id, tool_name) ->
          collect_tool_calls_loop(
            rest,
            completed,
            Some(ToolCallAccumulator(
              tool_call_id: tool_call_id,
              tool_name: tool_name,
              args: string_tree.new(),
            )),
          )
        ToolCallDelta(_, _, delta) ->
          case current {
            Some(acc) ->
              collect_tool_calls_loop(
                rest,
                completed,
                Some(
                  ToolCallAccumulator(
                    ..acc,
                    args: string_tree.append(acc.args, delta),
                  ),
                ),
              )
            None -> collect_tool_calls_loop(rest, completed, current)
          }
        ToolCallEnd(_, _) ->
          case current {
            Some(acc) -> {
              let entry = #(
                acc.tool_call_id,
                acc.tool_name,
                string_tree.to_string(acc.args),
              )
              collect_tool_calls_loop(rest, [entry, ..completed], None)
            }
            None -> collect_tool_calls_loop(rest, completed, current)
          }
        _ -> collect_tool_calls_loop(rest, completed, current)
      }
  }
}

/// Add usage from two Usage values together.
pub fn add_usage(a: Usage, b: Usage) -> Usage {
  Usage(
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
  )
}

/// Zero usage (useful as initial accumulator).
pub fn zero_usage() -> Usage {
  Usage(input_tokens: 0, output_tokens: 0)
}
