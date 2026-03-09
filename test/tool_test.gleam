import glean/error
import glean/schema
import glean/tool
import gleeunit/should

pub fn create_tool_test() {
  let t =
    tool.new(
      name: "greet",
      description: "Greet someone",
      input_schema: schema.object(
        properties: [#("name", schema.string())],
        required: ["name"],
      ),
      execute: fn(_ctx, _args) { Ok("Hello!") },
    )
  t.name |> should.equal("greet")
  t.description |> should.equal("Greet someone")
  t.max_retries |> should.equal(0)
}

pub fn tool_with_max_retries_test() {
  let t =
    tool.new(
      name: "fetch",
      description: "Fetch data",
      input_schema: schema.object(
        properties: [#("url", schema.string())],
        required: ["url"],
      ),
      execute: fn(_ctx, _args) { Ok("data") },
    )
    |> tool.with_max_retries(3)
  t.max_retries |> should.equal(3)
}

pub fn toolset_creation_test() {
  let t1 =
    tool.new(
      name: "add",
      description: "Add numbers",
      input_schema: schema.object(
        properties: [#("a", schema.int()), #("b", schema.int())],
        required: ["a", "b"],
      ),
      execute: fn(_ctx, _args) { Ok("42") },
    )
  let t2 =
    tool.new(
      name: "subtract",
      description: "Subtract numbers",
      input_schema: schema.object(
        properties: [#("a", schema.int()), #("b", schema.int())],
        required: ["a", "b"],
      ),
      execute: fn(_ctx, _args) { Ok("0") },
    )
  let ts = tool.toolset([t1, t2])
  tool.size(ts) |> should.equal(2)
  tool.is_empty(ts) |> should.be_false
}

pub fn toolset_find_test() {
  let t =
    tool.new(
      name: "search",
      description: "Search the web",
      input_schema: schema.object(
        properties: [#("query", schema.string())],
        required: ["query"],
      ),
      execute: fn(_ctx, _args) { Ok("results") },
    )
  let ts = tool.toolset([t])

  // Found
  case tool.find(ts, "search") {
    Ok(found) -> found.name |> should.equal("search")
    Error(_) -> panic as "Expected to find tool"
  }

  // Not found
  case tool.find(ts, "nonexistent") {
    Ok(_) -> panic as "Expected error"
    Error(err) ->
      case err {
        error.ToolNotFound(name) -> name |> should.equal("nonexistent")
        _ -> panic as "Expected ToolNotFound"
      }
  }
}

pub fn toolset_to_specs_test() {
  let t =
    tool.new(
      name: "calc",
      description: "Calculate",
      input_schema: schema.object(
        properties: [#("expr", schema.string())],
        required: ["expr"],
      ),
      execute: fn(_ctx, _args) { Ok("0") },
    )
  let ts = tool.toolset([t])
  let specs = tool.to_specs(ts)
  let assert 1 = list.length(specs)
}

pub fn empty_toolset_test() {
  let ts = tool.empty_toolset()
  tool.is_empty(ts) |> should.be_true
  tool.size(ts) |> should.equal(0)
}

import gleam/list
