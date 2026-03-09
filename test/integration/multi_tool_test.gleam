import glean/agent
import glean/providers/anthropic
import glean/providers/openai
import glean/run
import glean/schema
import glean/tool
import integration/integration_helpers.{assert_non_empty_text, cheap_settings,
  fail, get_api_key}

fn make_weather_tool() {
  tool.new(
    name: "get_weather",
    description: "Get the current weather for a location",
    input_schema: schema.object(
      properties: [
        #("location", schema.string() |> schema.describe("City name")),
      ],
      required: ["location"],
    ),
    execute: fn(_ctx, _args) { Ok("72°F and sunny") },
  )
}

fn make_time_tool() {
  tool.new(
    name: "get_time",
    description: "Get the current time in a timezone",
    input_schema: schema.object(
      properties: [
        #(
          "timezone",
          schema.string() |> schema.describe("Timezone like UTC, EST"),
        ),
      ],
      required: ["timezone"],
    ),
    execute: fn(_ctx, _args) { Ok("2:30 PM EST") },
  )
}

pub fn multi_tool_openai_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.tools(tool.toolset([make_weather_tool(), make_time_tool()]))
        |> agent.settings(cheap_settings())

      case
        run.generate(
          a,
          Nil,
          "What's the weather in Paris and what time is it in EST? Use both tools.",
        )
      {
        Ok(result) -> {
          // Should have called at least one tool (ideally both)
          let assert True = result.steps >= 2
          assert_non_empty_text(result.text)
        }
        Error(err) -> fail("Multi-tool OpenAI", err)
      }
    }
  }
}

pub fn multi_tool_anthropic_test() {
  case get_api_key("ANTHROPIC_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider =
        anthropic.new(
          api_key: api_key,
          model: "claude-haiku-4-5-20251001",
        )
      let a =
        agent.new(provider)
        |> agent.tools(tool.toolset([make_weather_tool(), make_time_tool()]))
        |> agent.settings(cheap_settings())

      case
        run.generate(
          a,
          Nil,
          "What's the weather in London and what time is it in UTC? Use both tools.",
        )
      {
        Ok(result) -> {
          let assert True = result.steps >= 2
          assert_non_empty_text(result.text)
        }
        Error(err) -> fail("Multi-tool Anthropic", err)
      }
    }
  }
}

pub fn multi_tool_sequential_test() {
  // Two tools where tool B depends on tool A's output
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let search_tool =
        tool.new(
          name: "search",
          description: "Search for information about a topic",
          input_schema: schema.object(
            properties: [
              #("query", schema.string() |> schema.describe("Search query")),
            ],
            required: ["query"],
          ),
          execute: fn(_ctx, _args) {
            Ok("Gleam is a type-safe language for the BEAM VM.")
          },
        )

      let summarize_tool =
        tool.new(
          name: "summarize",
          description: "Summarize a piece of text into one sentence",
          input_schema: schema.object(
            properties: [
              #(
                "text",
                schema.string() |> schema.describe("Text to summarize"),
              ),
            ],
            required: ["text"],
          ),
          execute: fn(_ctx, _args) { Ok("Gleam: type-safe BEAM language.") },
        )

      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.tools(tool.toolset([search_tool, summarize_tool]))
        |> agent.settings(cheap_settings())
        |> agent.max_steps(5)

      case
        run.generate(
          a,
          Nil,
          "Search for info about 'Gleam programming language', then summarize what you found. Use the search tool first, then the summarize tool.",
        )
      {
        Ok(result) -> {
          // Should have at least 2 tool-calling steps + 1 final response
          let assert True = result.steps >= 2
          assert_non_empty_text(result.text)
        }
        Error(err) -> fail("Multi-tool sequential", err)
      }
    }
  }
}
