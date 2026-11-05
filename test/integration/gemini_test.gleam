import gleam/string
import glean/agent
import glean/error
import glean/providers/gemini
import glean/run
import glean/schema
import glean/tool
import integration/integration_helpers.{
  assert_non_empty_text, cheap_settings, fail, get_api_key,
}

const env_var = "GEMINI_API_KEY"

const model = "gemini-3.5-flash-lite"

pub fn gemini_text_generation_test() {
  case get_api_key(env_var) {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = gemini.new(api_key: api_key, model: model)
      let a =
        agent.new(provider)
        |> agent.settings(cheap_settings())

      case run.generate(a, Nil, "What is 2+2? Reply with just the number.") {
        Ok(result) -> {
          assert_non_empty_text(result.text)
          let assert True = result.steps == 1
          let assert True = result.usage.input_tokens > 0
          let assert True = result.usage.output_tokens > 0
          Nil
        }
        Error(err) -> fail("Gemini text generation", err)
      }
    }
  }
}

pub fn gemini_system_prompt_test() {
  case get_api_key(env_var) {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = gemini.new(api_key: api_key, model: model)
      let a =
        agent.new(provider)
        |> agent.system(
          "You must respond with exactly the word PINEAPPLE, nothing else.",
        )
        |> agent.settings(cheap_settings())

      case run.generate(a, Nil, "Say something.") {
        Ok(result) -> {
          let assert True =
            string.contains(string.lowercase(result.text), "pineapple")
          Nil
        }
        Error(err) -> fail("Gemini system prompt", err)
      }
    }
  }
}

pub fn gemini_tool_calling_test() {
  case get_api_key(env_var) {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = gemini.new(api_key: api_key, model: model)
      let weather_tool =
        tool.new(
          name: "get_weather",
          description: "Get the current weather for a location",
          input_schema: schema.object(
            properties: [
              #("location", schema.string() |> schema.describe("City name")),
            ],
            required: ["location"],
          ),
          execute: fn(_ctx, _args) { Ok("72 degrees and sunny") },
        )

      let a =
        agent.new(provider)
        |> agent.tools(tool.toolset([weather_tool]))
        |> agent.settings(cheap_settings())

      case
        run.generate(
          a,
          Nil,
          "What's the weather in Paris? Use the get_weather tool.",
        )
      {
        Ok(result) -> {
          let assert True = result.steps >= 2
          assert_non_empty_text(result.text)
        }
        Error(err) -> fail("Gemini tool calling", err)
      }
    }
  }
}

pub fn gemini_invalid_key_test() {
  let provider = gemini.new(api_key: "invalid-key-12345", model: model)
  let a =
    agent.new(provider)
    |> agent.settings(cheap_settings())

  case run.generate(a, Nil, "Hello") {
    Ok(_) -> panic as "Expected error with invalid key"
    Error(err) ->
      case err {
        error.ProviderError(_, _, status, _) -> {
          let assert True = status == 400 || status == 401 || status == 403
          Nil
        }
        _ -> fail("Expected ProviderError, got", err)
      }
  }
}

pub fn gemini_multi_turn_test() {
  case get_api_key(env_var) {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = gemini.new(api_key: api_key, model: model)
      let a =
        agent.new(provider)
        |> agent.settings(cheap_settings())

      case run.generate(a, Nil, "My name is Gleam. Remember it.") {
        Ok(result1) ->
          case run.continue(a, Nil, result1, "What is my name?") {
            Ok(result2) -> {
              let assert True =
                string.contains(string.lowercase(result2.text), "gleam")
              Nil
            }
            Error(err) -> fail("Gemini multi-turn continuation", err)
          }
        Error(err) -> fail("Gemini multi-turn initial", err)
      }
    }
  }
}
