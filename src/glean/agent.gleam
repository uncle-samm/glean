/// Agent configuration (builder pattern).
/// Immutable config — running an agent produces a RunResult; the agent is reusable.
import gleam/option.{type Option, None, Some}
import glean/model.{type Model}
import glean/provider.{
  type ModelSettings, type Provider, type ResponseFormat, type ToolChoice,
}
import glean/schema.{type Schema}
import glean/tool.{type Toolset}

/// An agent definition. Generic over `deps` — the dependency type
/// threaded through to tools during execution.
pub type Agent(deps) {
  Agent(
    /// The provider to use for generation
    provider: Provider,
    /// System prompt(s) prepended to every conversation
    system_prompts: List(String),
    /// Available tools
    tools: Toolset(deps),
    /// Default model settings
    settings: ModelSettings,
    /// Tool choice strategy
    tool_choice: ToolChoice,
    /// Maximum number of generate-tool-loop steps (safety limit)
    max_steps: Int,
    /// Plain text, or JSON (optionally constrained by a schema).
    /// With a schema, the final answer is validated against it.
    response_format: ResponseFormat,
    /// Run several tool calls from one model response concurrently
    /// (default: True). Results are always returned in the model's order.
    parallel_tool_calls: Bool,
    /// The longest one tool call may take, retries included, in
    /// milliseconds (default: no limit). A call that takes longer is
    /// stopped and reported to the model as an error.
    tool_timeout_ms: Option(Int),
    /// How many times the model is asked again when its final answer
    /// doesn't match the JSON schema (default: 1).
    output_retries: Int,
  )
}

/// Create a new agent with the given provider.
/// All other fields get sensible defaults.
pub fn new(provider: Provider) -> Agent(deps) {
  Agent(
    provider: provider,
    system_prompts: [],
    tools: tool.empty_toolset(),
    settings: provider.default_settings(),
    tool_choice: provider.Auto,
    max_steps: 10,
    response_format: provider.TextFormat,
    parallel_tool_calls: True,
    tool_timeout_ms: None,
    output_retries: 1,
  )
}

/// Add a system prompt to the agent.
pub fn system(agent: Agent(deps), prompt: String) -> Agent(deps) {
  let assert True = prompt != ""
  Agent(..agent, system_prompts: list.append(agent.system_prompts, [prompt]))
}

/// Set the tools available to this agent.
pub fn tools(agent: Agent(deps), tools: Toolset(deps)) -> Agent(deps) {
  Agent(..agent, tools: tools)
}

/// Set model settings.
pub fn settings(agent: Agent(deps), settings: ModelSettings) -> Agent(deps) {
  Agent(..agent, settings: settings)
}

/// Set the tool choice strategy.
pub fn tool_choice(agent: Agent(deps), choice: ToolChoice) -> Agent(deps) {
  Agent(..agent, tool_choice: choice)
}

/// Ask for JSON output. With a schema, the provider is asked to follow it
/// (where the API supports schemas) and the final answer is validated
/// against it. On a mismatch the model is told what is wrong and asked
/// again, as often as `output_retries` allows (once by default); after that
/// the run fails with `OutputValidationError`, which carries the answer,
/// the conversation and the tokens used.
///
/// ```gleam
/// agent.from(model)
/// |> agent.json_output(schema: Some(person_schema), name: Some("person"))
/// ```
pub fn json_output(
  agent: Agent(deps),
  schema schema: Option(Schema),
  name name: Option(String),
) -> Agent(deps) {
  Agent(..agent, response_format: provider.JsonFormat(schema:, name:))
}

/// Run tool calls one after another instead of concurrently. Use this when
/// your tools must not run at the same time (e.g. they share a resource).
pub fn sequential_tool_calls(agent: Agent(deps)) -> Agent(deps) {
  Agent(..agent, parallel_tool_calls: False)
}

/// Limit how long one tool call may take, retries included. A call that
/// takes longer is stopped, and the model gets an error result saying so,
/// like any other tool failure. Without a limit, a tool that never returns
/// keeps the run waiting forever.
pub fn tool_timeout(agent: Agent(deps), ms: Int) -> Agent(deps) {
  let assert True = ms > 0
  Agent(..agent, tool_timeout_ms: Some(ms))
}

/// Set how many times the model is asked again when its final answer
/// doesn't match the schema given to `json_output` (default: 1; 0 fails the
/// run on the first mismatch). Each retry is one more step, so it also
/// counts towards `max_steps`. An answer cut off at the output token limit
/// is never retried: it would be cut off again.
pub fn output_retries(agent: Agent(deps), retries: Int) -> Agent(deps) {
  let assert True = retries >= 0
  Agent(..agent, output_retries: retries)
}

/// Set the maximum number of agent loop steps.
pub fn max_steps(agent: Agent(deps), max: Int) -> Agent(deps) {
  let assert True = max > 0
  Agent(..agent, max_steps: max)
}

/// Create an agent from a type-safe Model.
/// The Model carries both the provider and validated settings.
pub fn from(model: Model) -> Agent(deps) {
  Agent(
    provider: model.provider,
    system_prompts: [],
    tools: tool.empty_toolset(),
    settings: model.settings,
    tool_choice: provider.Auto,
    max_steps: 10,
    response_format: provider.TextFormat,
    parallel_tool_calls: True,
    tool_timeout_ms: None,
    output_retries: 1,
  )
}

import gleam/list
