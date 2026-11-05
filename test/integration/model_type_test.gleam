import glean/agent
import glean/models/anthropic_sampling as anthropic_model
import glean/models/gemini as gemini_model
import glean/models/mistral as mistral_model
import glean/models/openai_reasoning
import glean/run
import integration/integration_helpers.{assert_non_empty_text, fail, get_api_key}

pub fn model_type_openai_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        openai_reasoning.gpt5_nano(api_key: api_key)
        |> openai_reasoning.max_output_tokens(1000)
        |> openai_reasoning.build

      let a = agent.from(model)

      case run.generate(a, Nil, "What is 2+2? Reply with just the number.") {
        Ok(result) -> {
          assert_non_empty_text(result.text)
          let assert True = result.steps == 1
          let assert True = result.usage.input_tokens > 0
          Nil
        }
        Error(err) -> fail("Model type OpenAI", err)
      }
    }
  }
}

pub fn model_type_anthropic_test() {
  case get_api_key("ANTHROPIC_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        anthropic_model.haiku_4_5(api_key: api_key)
        |> anthropic_model.max_output_tokens(1000)
        |> anthropic_model.temperature(0.0)
        |> anthropic_model.build

      let a = agent.from(model)

      case run.generate(a, Nil, "What is 2+2? Reply with just the number.") {
        Ok(result) -> {
          assert_non_empty_text(result.text)
          let assert True = result.steps == 1
          Nil
        }
        Error(err) -> fail("Model type Anthropic", err)
      }
    }
  }
}

pub fn model_type_gemini_test() {
  case get_api_key("GEMINI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        gemini_model.flash_2_5(api_key: api_key)
        |> gemini_model.max_output_tokens(1000)
        |> gemini_model.temperature(0.0)
        |> gemini_model.build

      let a = agent.from(model)

      case run.generate(a, Nil, "What is 2+2? Reply with just the number.") {
        Ok(result) -> {
          assert_non_empty_text(result.text)
          let assert True = result.steps == 1
          Nil
        }
        Error(err) -> fail("Model type Gemini", err)
      }
    }
  }
}

pub fn model_type_mistral_test() {
  case get_api_key("MISTRAL_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        mistral_model.small_4(api_key: api_key)
        |> mistral_model.max_output_tokens(1000)
        |> mistral_model.temperature(0.3)
        |> mistral_model.build

      let a = agent.from(model)

      case run.generate(a, Nil, "What is 2+2? Reply with just the number.") {
        Ok(result) -> {
          assert_non_empty_text(result.text)
          let assert True = result.steps == 1
          Nil
        }
        Error(err) -> fail("Model type Mistral", err)
      }
    }
  }
}
