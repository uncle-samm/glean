//// DeepSeek models with thinking turned on.
////
//// Thinking mode ignores sampling parameters, so this builder doesn't offer
//// them. The model's reasoning is returned as reasoning events and sent back
//// on later turns, which DeepSeek requires when tools are used.
import gleam/json
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings, type ReasoningEffort}
import glean/providers/config.{type ProviderConfig}
import glean/providers/deepseek as deepseek_provider

/// A DeepSeek (thinking) model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type DeepseekReasoning {
  DeepseekReasoning(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// DeepSeek V4.1 Flash. Model ID: `deepseek-flash`.
pub fn flash(api_key key: String) -> DeepseekReasoning {
  new(key, "deepseek-flash")
}

/// DeepSeek V4 Pro. Model ID: `deepseek-v4-pro`.
pub fn v4_pro(api_key key: String) -> DeepseekReasoning {
  new(key, "deepseek-v4-pro")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> DeepseekReasoning {
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
pub fn configure(m: DeepseekReasoning, f: fn(ProviderConfig) -> ProviderConfig) -> DeepseekReasoning {
  DeepseekReasoning(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: DeepseekReasoning, n: Int) -> DeepseekReasoning {
  let assert True = n > 0
  DeepseekReasoning(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set how much the model should think before answering.
pub fn reasoning_effort(m: DeepseekReasoning, effort: ReasoningEffort) -> DeepseekReasoning {
  DeepseekReasoning(..m, settings: ModelSettings(..m.settings, reasoning_effort: Some(effort)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: DeepseekReasoning) -> Model {
  Model(provider: deepseek_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> DeepseekReasoning {
  DeepseekReasoning(
    config: 
  deepseek_provider.default_config(api_key: key, model: model_id)
  |> config.extra_body_field("thinking", json.object([#("type", json.string("enabled"))]))
  ,
    settings: provider.default_settings(),
  )
}
