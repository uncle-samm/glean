//// OpenAI GPT models that accept sampling parameters (GPT-4.1 and GPT-4o
//// families).
////
//// GPT-5 and later are reasoning models that reject a non-default
//// `temperature`; use `glean/models/openai_reasoning` for those.
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai as openai_provider

/// A GPT (non-reasoning) model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Gpt {
  Gpt(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// GPT-4.1. Model ID: `gpt-4.1`.
pub fn gpt4_1(api_key key: String) -> Gpt {
  new(key, "gpt-4.1")
}

/// GPT-4.1 mini. Model ID: `gpt-4.1-mini`.
pub fn gpt4_1_mini(api_key key: String) -> Gpt {
  new(key, "gpt-4.1-mini")
}

/// GPT-4.1 nano. Model ID: `gpt-4.1-nano`.
pub fn gpt4_1_nano(api_key key: String) -> Gpt {
  new(key, "gpt-4.1-nano")
}

/// GPT-4o. Model ID: `gpt-4o`.
pub fn gpt4o(api_key key: String) -> Gpt {
  new(key, "gpt-4o")
}

/// GPT-4o mini. Model ID: `gpt-4o-mini`.
pub fn gpt4o_mini(api_key key: String) -> Gpt {
  new(key, "gpt-4o-mini")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Gpt {
  let assert True = model_id != ""
  new(key, model_id)
}

// ---------------------------------------------------------------------------
// Setters
// ---------------------------------------------------------------------------

/// Change the provider configuration: base URL, timeout, headers, retries.
///
/// ```gleam
/// |> configure(config.timeout(_, 120_000))
/// ```
pub fn configure(m: Gpt, f: fn(ProviderConfig) -> ProviderConfig) -> Gpt {
  Gpt(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Gpt, n: Int) -> Gpt {
  let assert True = n > 0
  Gpt(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set the sampling temperature.
pub fn temperature(m: Gpt, t: Float) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Gpt, p: Float) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Set the random seed for more repeatable output.
pub fn seed(m: Gpt, s: Int) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, seed: Some(s)))
}

/// Set the presence penalty.
pub fn presence_penalty(m: Gpt, pp: Float) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, presence_penalty: Some(pp)))
}

/// Set the frequency penalty.
pub fn frequency_penalty(m: Gpt, fp: Float) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, frequency_penalty: Some(fp)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Gpt, stops: List(String)) -> Gpt {
  Gpt(..m, settings: ModelSettings(..m.settings, stop_sequences: Some(stops)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Gpt) -> Model {
  Model(provider: openai_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Gpt {
  Gpt(
    config: openai_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
