/// Streaming event types.
/// Follows the start/delta/end pattern from Vercel AI SDK.
///
/// Every provider sends each piece of text, reasoning and tool call as a
/// start event, any number of deltas, and an end event, all with the same
/// `id`.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string_tree
import glean/error.{type FinishReason}
import glean/usage

/// Token usage. Defined in `glean/usage`, which has its constructor.
pub type Usage =
  usage.Usage

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
  /// The run finished. Sent once, after the last step.
  Finish(finish_reason: FinishReason, usage: Usage)
  /// The run failed: the provider returned an error, or the final answer
  /// did not pass validation. Sent once, just before `run.stream` returns
  /// the error; `message` is `error.to_string` of it.
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
    /// Its position among the completed calls, once it has ended.
    ended: Option(Int),
  )
}

/// Extract all completed tool calls from stream events.
/// Returns a list of (tool_call_id, tool_name, arguments_json) tuples, in
/// the order the calls ended. Deltas are matched to their call by
/// `tool_call_id`, so calls that stream at the same time don't mix. A call
/// that never got its `ToolCallEnd` is left out.
pub fn collect_tool_calls(
  events: List(StreamEvent),
) -> List(#(String, String, String)) {
  let calls =
    list.fold(events, [], fn(calls: List(ToolCallAccumulator), event) {
      case event {
        ToolCallStart(_, tool_call_id, tool_name) -> [
          ToolCallAccumulator(
            tool_call_id: tool_call_id,
            tool_name: tool_name,
            args: string_tree.new(),
            ended: None,
          ),
          ..calls
        ]
        ToolCallDelta(_, tool_call_id, delta) ->
          update_open_call(calls, tool_call_id, fn(call) {
            ToolCallAccumulator(
              ..call,
              args: string_tree.append(call.args, delta),
            )
          })
        ToolCallEnd(_, tool_call_id) -> {
          let position = list.count(calls, fn(call) { call.ended != None })
          update_open_call(calls, tool_call_id, fn(call) {
            ToolCallAccumulator(..call, ended: Some(position))
          })
        }
        _ -> calls
      }
    })
  calls
  |> list.filter_map(fn(call) {
    case call.ended {
      Some(position) ->
        Ok(#(
          position,
          #(call.tool_call_id, call.tool_name, string_tree.to_string(call.args)),
        ))
      None -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

/// Change the newest call with this id that hasn't ended yet. `calls` is
/// newest first.
fn update_open_call(
  calls: List(ToolCallAccumulator),
  tool_call_id: String,
  change: fn(ToolCallAccumulator) -> ToolCallAccumulator,
) -> List(ToolCallAccumulator) {
  case calls {
    [] -> []
    [call, ..rest] ->
      case call.tool_call_id == tool_call_id && call.ended == None {
        True -> [change(call), ..rest]
        False -> [call, ..update_open_call(rest, tool_call_id, change)]
      }
  }
}

/// Add usage from two Usage values together.
pub fn add_usage(a: Usage, b: Usage) -> Usage {
  usage.add(a, b)
}

/// Zero usage (useful as initial accumulator).
pub fn zero_usage() -> Usage {
  usage.zero()
}
