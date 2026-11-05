//// Glean — a Gleam-native AI agent SDK for the BEAM.
////
//// ## Quick start
////
//// ```gleam
//// import gleam/io
//// import glean/agent
//// import glean/models/anthropic
//// import glean/run
//// import glean/schema
//// import glean/tool
////
//// pub fn main() {
////   let add =
////     tool.new(
////       name: "add",
////       description: "Add two numbers",
////       input_schema: schema.object(
////         properties: [#("a", schema.int()), #("b", schema.int())],
////         required: ["a", "b"],
////       ),
////       execute: fn(_ctx, _args_json) { Ok("4") },
////     )
////
////   let my_agent =
////     anthropic.sonnet_5_5(api_key: "sk-ant-...")
////     |> anthropic.build
////     |> agent.from
////     |> agent.system("You are a helpful calculator.")
////     |> agent.tools(tool.toolset([add]))
////
////   case run.generate(my_agent, Nil, "What is 2 + 2?") {
////     Ok(result) -> io.println(result.text)
////     Error(_) -> io.println("failed")
////   }
//// }
//// ```

/// The version of glean.
pub fn version() -> String {
  "0.2.0"
}
