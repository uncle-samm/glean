//// OpenAI reasoning models: GPT-5 and later, and the o-series.
////
//// These reject sampling parameters and `stop`, so this builder only offers
//// `max_output_tokens` and `reasoning_effort`. The "pro" models are only
//// served by the Responses API, which glean doesn't speak yet, so they are
//// not listed.
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings, type ReasoningEffort}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai as openai_provider

/// A OpenAI reasoning model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Reasoning {
  Reasoning(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// GPT-6.1 Terra. Model ID: `gpt-6.1-terra`.
pub fn gpt6_1_terra(api_key key: String) -> Reasoning {
  new(key, "gpt-6.1-terra")
}

/// GPT-5.5. Model ID: `gpt-5.5`.
pub fn gpt5_5(api_key key: String) -> Reasoning {
  new(key, "gpt-5.5")
}

/// GPT-5.4. Model ID: `gpt-5.4`.
pub fn gpt5_4(api_key key: String) -> Reasoning {
  new(key, "gpt-5.4")
}

/// GPT-5.4 mini. Model ID: `gpt-5.4-mini`.
pub fn gpt5_4_mini(api_key key: String) -> Reasoning {
  new(key, "gpt-5.4-mini")
}

/// GPT-5.4 nano. Model ID: `gpt-5.4-nano`.
pub fn gpt5_4_nano(api_key key: String) -> Reasoning {
  new(key, "gpt-5.4-nano")
}

/// GPT-5.2. Model ID: `gpt-5.2`.
pub fn gpt5_2(api_key key: String) -> Reasoning {
  new(key, "gpt-5.2")
}

/// GPT-5.1. Model ID: `gpt-5.1`.
pub fn gpt5_1(api_key key: String) -> Reasoning {
  new(key, "gpt-5.1")
}

/// GPT-5. Model ID: `gpt-5`.
pub fn gpt5(api_key key: String) -> Reasoning {
  new(key, "gpt-5")
}

/// GPT-5 mini. Model ID: `gpt-5-mini`.
pub fn gpt5_mini(api_key key: String) -> Reasoning {
  new(key, "gpt-5-mini")
}

/// GPT-5 nano. Model ID: `gpt-5-nano`.
pub fn gpt5_nano(api_key key: String) -> Reasoning {
  new(key, "gpt-5-nano")
}

/// o3. Model ID: `o3`.
pub fn o3(api_key key: String) -> Reasoning {
  new(key, "o3")
}

/// o4-mini. Model ID: `o4-mini`.
pub fn o4_mini(api_key key: String) -> Reasoning {
  new(key, "o4-mini")
}

/// o3-mini. Model ID: `o3-mini`.
pub fn o3_mini(api_key key: String) -> Reasoning {
  new(key, "o3-mini")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Reasoning {
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
pub fn configure(m: Reasoning, f: fn(ProviderConfig) -> ProviderConfig) -> Reasoning {
  Reasoning(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Reasoning, n: Int) -> Reasoning {
  let assert True = n > 0
  Reasoning(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set how much the model should think before answering.
pub fn reasoning_effort(m: Reasoning, effort: ReasoningEffort) -> Reasoning {
  Reasoning(..m, settings: ModelSettings(..m.settings, reasoning_effort: Some(effort)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Reasoning) -> Model {
  Model(provider: openai_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Reasoning {
  Reasoning(
    config: openai_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
