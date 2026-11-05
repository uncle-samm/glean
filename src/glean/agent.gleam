/// Agent configuration (builder pattern).
/// Immutable config — running an agent produces a RunResult; the agent is reusable.
import glean/model.{type Model}
import glean/provider.{type ModelSettings, type Provider, type ToolChoice}
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
  )
}

import gleam/list
