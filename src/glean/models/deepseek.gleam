//// DeepSeek models with thinking turned off.
////
//// `deepseek-chat` and `deepseek-reasoner` were retired on Jul 24, 2026.
//// The current models switch thinking on per request; for thinking mode see
//// `glean/models/deepseek_reasoning`.
import gleam/json
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/deepseek as deepseek_provider

/// A DeepSeek (non-thinking) model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Deepseek {
  Deepseek(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// DeepSeek V4.1 Flash. Model ID: `deepseek-flash`.
pub fn flash(api_key key: String) -> Deepseek {
  new(key, "deepseek-flash")
}

/// DeepSeek V4 Pro. Model ID: `deepseek-v4-pro`.
pub fn v4_pro(api_key key: String) -> Deepseek {
  new(key, "deepseek-v4-pro")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Deepseek {
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
pub fn configure(m: Deepseek, f: fn(ProviderConfig) -> ProviderConfig) -> Deepseek {
  Deepseek(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Deepseek, n: Int) -> Deepseek {
  let assert True = n > 0
  Deepseek(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set the sampling temperature.
pub fn temperature(m: Deepseek, t: Float) -> Deepseek {
  Deepseek(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Deepseek, p: Float) -> Deepseek {
  Deepseek(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Set the presence penalty.
pub fn presence_penalty(m: Deepseek, pp: Float) -> Deepseek {
  Deepseek(..m, settings: ModelSettings(..m.settings, presence_penalty: Some(pp)))
}

/// Set the frequency penalty.
pub fn frequency_penalty(m: Deepseek, fp: Float) -> Deepseek {
  Deepseek(..m, settings: ModelSettings(..m.settings, frequency_penalty: Some(fp)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Deepseek, stops: List(String)) -> Deepseek {
  Deepseek(..m, settings: ModelSettings(..m.settings, stop_sequences: Some(stops)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Deepseek) -> Model {
  Model(provider: deepseek_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Deepseek {
  Deepseek(
    config: 
  deepseek_provider.default_config(api_key: key, model: model_id)
  |> config.extra_body_field("thinking", json.object([#("type", json.string("disabled"))]))
  ,
    settings: provider.default_settings(),
  )
}
