/// Tool definition, toolset, and execution context.
/// Generic over `deps` for dependency injection (from Pydantic AI's RunContext pattern).

import gleam/dict.{type Dict}
import gleam/list
import glean/error.{type GleanError, ToolNotFound}
import glean/provider.{type ToolSpec, ToolSpec}
import glean/schema.{type Schema}

/// A tool that can be called by the model.
/// Generic over `deps` — the dependency type threaded from agent to tool execution.
///
/// The execute function receives the raw JSON arguments string — each tool
/// decodes it internally using its own decoder. This is explicit and type-safe:
/// the tool knows its schema and how to decode it.
pub type Tool(deps) {
  Tool(
    /// Unique name used by the model to call this tool
    name: String,
    /// Description for the model explaining what this tool does
    description: String,
    /// JSON Schema for the tool's input parameters
    input_schema: Schema,
    /// Execute function: takes context + raw JSON arguments string, returns output or error
    execute: fn(ToolContext(deps), String) -> Result(String, GleanError),
    /// Maximum retries for this tool on validation failure (default: 0)
    max_retries: Int,
  )
}

/// Context passed to tool execute functions.
/// Carries dependencies and execution metadata.
pub type ToolContext(deps) {
  ToolContext(
    /// User-provided dependencies
    deps: deps,
    /// Unique ID for this tool call
    tool_call_id: String,
    /// Name of the tool being executed
    tool_name: String,
    /// Current retry attempt (0 = first attempt)
    retry: Int,
    /// Maximum retries allowed
    max_retries: Int,
    /// Current step in the agent loop
    step: Int,
  )
}

/// A collection of tools keyed by name.
/// Opaque to enforce the invariant that tool names are unique.
pub opaque type Toolset(deps) {
  Toolset(tools: Dict(String, Tool(deps)))
}

// --- Builders ---

/// Create a tool with the required fields.
pub fn new(
  name name: String,
  description description: String,
  input_schema input_schema: Schema,
  execute execute: fn(ToolContext(deps), String) -> Result(String, GleanError),
) -> Tool(deps) {
  let assert True = name != ""
  let assert True = description != ""
  Tool(
    name: name,
    description: description,
    input_schema: input_schema,
    execute: execute,
    max_retries: 0,
  )
}

/// Set max retries on a tool.
pub fn with_max_retries(tool: Tool(deps), max_retries: Int) -> Tool(deps) {
  let assert True = max_retries >= 0
  Tool(..tool, max_retries: max_retries)
}

/// Create a Toolset from a list of tools.
/// Asserts that all tool names are unique.
pub fn toolset(tools: List(Tool(deps))) -> Toolset(deps) {
  let names = list.map(tools, fn(t) { t.name })
  let unique_names = list.unique(names)
  let assert True = list.length(names) == list.length(unique_names)
  let tool_dict =
    tools
    |> list.map(fn(t) { #(t.name, t) })
    |> dict.from_list
  Toolset(tools: tool_dict)
}

/// Create an empty toolset.
pub fn empty_toolset() -> Toolset(deps) {
  Toolset(tools: dict.new())
}

/// Look up a tool by name.
pub fn find(
  toolset: Toolset(deps),
  name: String,
) -> Result(Tool(deps), GleanError) {
  case dict.get(toolset.tools, name) {
    Ok(tool) -> Ok(tool)
    Error(Nil) -> Error(ToolNotFound(tool_name: name))
  }
}

/// Convert all tools in the toolset to ToolSpecs for sending to the provider.
pub fn to_specs(toolset: Toolset(deps)) -> List(ToolSpec) {
  toolset.tools
  |> dict.values
  |> list.map(fn(t) {
    ToolSpec(
      name: t.name,
      description: t.description,
      input_schema: t.input_schema,
    )
  })
}

/// Get the list of tool names in this toolset.
pub fn names(toolset: Toolset(deps)) -> List(String) {
  dict.keys(toolset.tools)
}

/// Check if a toolset is empty (has no tools).
pub fn is_empty(toolset: Toolset(deps)) -> Bool {
  dict.is_empty(toolset.tools)
}

/// Get the number of tools in the toolset.
pub fn size(toolset: Toolset(deps)) -> Int {
  dict.size(toolset.tools)
}
