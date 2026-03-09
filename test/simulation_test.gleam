import gleam/list
import glean/testing/provider.{ScriptedToolCall}
import glean/testing/simulation.{
  ScriptedToolExecution, SimulationPassed, ToolSuccess,
}

pub fn simple_text_simulation_test() {
  simulation.new("simple_text", "Hello")
  |> simulation.then_respond_text("Hi there!")
  |> simulation.run
  |> simulation.assert_passed
}

pub fn tool_call_simulation_test() {
  simulation.new("calculator", "What is 2 + 3?")
  |> simulation.then_call_tools([
    ScriptedToolExecution(
      call: ScriptedToolCall(id: "c1", name: "add", arguments: "{\"a\":2,\"b\":3}"),
      result: ToolSuccess(content: "5"),
    ),
  ])
  |> simulation.then_respond_text("2 + 3 = 5")
  |> simulation.run
  |> simulation.assert_passed
}

pub fn multi_tool_simulation_test() {
  simulation.new("multi_tool", "Search and summarize")
  |> simulation.then_call_tools([
    ScriptedToolExecution(
      call: ScriptedToolCall(
        id: "c1",
        name: "search",
        arguments: "{\"query\":\"gleam lang\"}",
      ),
      result: ToolSuccess(content: "Gleam is a type-safe language"),
    ),
  ])
  |> simulation.then_call_tools([
    ScriptedToolExecution(
      call: ScriptedToolCall(
        id: "c2",
        name: "summarize",
        arguments: "{\"text\":\"Gleam is a type-safe language\"}",
      ),
      result: ToolSuccess(content: "A type-safe BEAM language"),
    ),
  ])
  |> simulation.then_respond_text("Gleam is a type-safe BEAM language")
  |> simulation.run
  |> simulation.assert_passed
}

pub fn simulation_with_final_assertions_test() {
  let state =
    simulation.new("with_assertions", "Test")
    |> simulation.then_call_tools([
      ScriptedToolExecution(
        call: ScriptedToolCall(id: "c1", name: "tool1", arguments: "{}"),
        result: ToolSuccess(content: "ok"),
      ),
    ])
    |> simulation.then_respond_text("Done")
    |> simulation.assert_finally(fn(state) {
      let assert True = state.step_count == 2
      let assert True = list.length(state.tool_calls_made) == 1
      Ok(Nil)
    })
    |> simulation.run
    |> simulation.assert_passed

  // Verify returned state
  let assert True = state.step_count == 2
}

pub fn simulation_max_steps_test() {
  let result =
    simulation.new("max_steps", "Loop forever")
    |> simulation.with_max_steps(2)
    |> simulation.then_call_tools([
      ScriptedToolExecution(
        call: ScriptedToolCall(id: "c1", name: "t", arguments: "{}"),
        result: ToolSuccess(content: "ok"),
      ),
    ])
    |> simulation.then_call_tools([
      ScriptedToolExecution(
        call: ScriptedToolCall(id: "c2", name: "t", arguments: "{}"),
        result: ToolSuccess(content: "ok"),
      ),
    ])
    |> simulation.then_respond_text("Never reached")
    |> simulation.run

  case result {
    simulation.SimulationExceededMaxSteps(_, max, _) -> {
      let assert True = max == 2
    }
    SimulationPassed(_, _) -> panic as "Should have exceeded max steps"
    _ -> panic as "Unexpected result"
  }
}
