/// Agent configuration (builder pattern).
/// Immutable config — running an agent produces a RunResult; the agent is reusable.
import gleam/option.{type Option}
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
/// against it: a mismatch fails the run with `OutputValidationError`.
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
  )
}

import gleam/list
