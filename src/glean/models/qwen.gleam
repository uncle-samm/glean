//// Alibaba Qwen models (DashScope, international endpoint).
////
//// Hybrid thinking models take `enable_thinking`; set it with
//// `configure(config.extra_body_field(_, "enable_thinking", json.bool(True)))`.
//// For the China endpoint or a workspace URL, set `config.base_url`.

import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/qwen as qwen_provider

/// A Qwen model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Qwen {
  Qwen(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Qwen3.8 Max. Model ID: `qwen3.8-max`.
pub fn qwen3_8_max(api_key key: String) -> Qwen {
  new(key, "qwen3.8-max")
}

/// Qwen3.7 Plus. Model ID: `qwen3.7-plus`.
pub fn qwen3_7_plus(api_key key: String) -> Qwen {
  new(key, "qwen3.7-plus")
}

/// Qwen3.8 Flash. Model ID: `qwen3.8-flash`.
pub fn qwen3_8_flash(api_key key: String) -> Qwen {
  new(key, "qwen3.8-flash")
}

/// Qwen3.5 Plus. Model ID: `qwen3.5-plus`.
pub fn qwen3_5_plus(api_key key: String) -> Qwen {
  new(key, "qwen3.5-plus")
}

/// Qwen3.5 Flash. Model ID: `qwen3.5-flash`.
pub fn qwen3_5_flash(api_key key: String) -> Qwen {
  new(key, "qwen3.5-flash")
}

/// Qwen3 Max. Model ID: `qwen3-max`.
pub fn qwen3_max(api_key key: String) -> Qwen {
  new(key, "qwen3-max")
}

/// Qwen3 Coder Plus. Model ID: `qwen3-coder-plus`.
pub fn qwen3_coder_plus(api_key key: String) -> Qwen {
  new(key, "qwen3-coder-plus")
}

/// QwQ Plus. Model ID: `qwq-plus`.
pub fn qwq_plus(api_key key: String) -> Qwen {
  new(key, "qwq-plus")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Qwen {
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
pub fn configure(m: Qwen, f: fn(ProviderConfig) -> ProviderConfig) -> Qwen {
  Qwen(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Qwen, n: Int) -> Qwen {
  let assert True = n > 0
  Qwen(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set the sampling temperature.
pub fn temperature(m: Qwen, t: Float) -> Qwen {
  Qwen(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Qwen, p: Float) -> Qwen {
  Qwen(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Set the top-k sampling value.
pub fn top_k(m: Qwen, k: Int) -> Qwen {
  Qwen(..m, settings: ModelSettings(..m.settings, top_k: Some(k)))
}

/// Set the random seed for more repeatable output.
pub fn seed(m: Qwen, s: Int) -> Qwen {
  Qwen(..m, settings: ModelSettings(..m.settings, seed: Some(s)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Qwen, stops: List(String)) -> Qwen {
  Qwen(..m, settings: ModelSettings(..m.settings, stop_sequences: Some(stops)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Qwen) -> Model {
  Model(provider: qwen_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Qwen {
  Qwen(
    config: qwen_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
