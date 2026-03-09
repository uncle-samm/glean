/// Glean — A Gleam-native AI agent SDK for the BEAM.
///
/// ## Quick Start
///
/// ```gleam
/// import glean/agent
/// import glean/run
/// import glean/tool
/// import glean/schema
///
/// // 1. Create a provider (e.g., from glean/providers/openai)
/// let provider = my_provider()
///
/// // 2. Define tools
/// let calculator = tool.new(
///   name: "add",
///   description: "Add two numbers",
///   input_schema: schema.object(
///     properties: [#("a", schema.int()), #("b", schema.int())],
///     required: ["a", "b"],
///   ),
///   execute: fn(_ctx, args_json) { Ok("42") },
/// )
///
/// // 3. Build an agent
/// let my_agent = agent.new(provider)
///   |> agent.system("You are a helpful calculator.")
///   |> agent.tools(tool.toolset([calculator]))
///
/// // 4. Run it
/// let result = run.generate(my_agent, Nil, "What is 2 + 2?")
/// ```
pub fn version() -> String {
  "0.1.0"
}
