//// Google Gemini models.
////
//// Supported parameters: max_output_tokens, temperature, top_p, top_k,
//// seed, stop_sequences.

import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/gemini as gemini_provider

/// A Gemini model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Gemini {
  Gemini(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Gemini 3.1 Pro (preview). Model ID: `gemini-3.1-pro-preview`.
pub fn pro_3_1(api_key key: String) -> Gemini {
  new(key, "gemini-3.1-pro-preview")
}

/// Gemini 3.8 Flash. Model ID: `gemini-3.8-flash`.
pub fn flash_3_8(api_key key: String) -> Gemini {
  new(key, "gemini-3.8-flash")
}

/// Gemini 3.6 Flash. Model ID: `gemini-3.6-flash`.
pub fn flash_3_6(api_key key: String) -> Gemini {
  new(key, "gemini-3.6-flash")
}

/// Gemini 3.5 Flash-Lite. Model ID: `gemini-3.5-flash-lite`.
pub fn flash_lite_3_5(api_key key: String) -> Gemini {
  new(key, "gemini-3.5-flash-lite")
}

/// Gemini 3.1 Flash-Lite. Model ID: `gemini-3.1-flash-lite`.
pub fn flash_lite_3_1(api_key key: String) -> Gemini {
  new(key, "gemini-3.1-flash-lite")
}

/// Gemini 3 Flash (preview). Model ID: `gemini-3-flash-preview`.
pub fn flash_3(api_key key: String) -> Gemini {
  new(key, "gemini-3-flash-preview")
}

/// Gemini 2.5 Pro. Model ID: `gemini-2.5-pro`.
pub fn pro_2_5(api_key key: String) -> Gemini {
  new(key, "gemini-2.5-pro")
}

/// Gemini 2.5 Flash. Model ID: `gemini-2.5-flash`.
pub fn flash_2_5(api_key key: String) -> Gemini {
  new(key, "gemini-2.5-flash")
}

/// Gemini 2.5 Flash-Lite. Model ID: `gemini-2.5-flash-lite`.
pub fn flash_lite_2_5(api_key key: String) -> Gemini {
  new(key, "gemini-2.5-flash-lite")
}

/// Gemini 3.1 Flash Image (preview). Model ID: `gemini-3.1-flash-image-preview`.
pub fn flash_image_3_1(api_key key: String) -> Gemini {
  new(key, "gemini-3.1-flash-image-preview")
}

/// Gemini 3 Pro Image (preview). Model ID: `gemini-3-pro-image-preview`.
pub fn pro_image_3(api_key key: String) -> Gemini {
  new(key, "gemini-3-pro-image-preview")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Gemini {
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
pub fn configure(m: Gemini, f: fn(ProviderConfig) -> ProviderConfig) -> Gemini {
  Gemini(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Gemini, n: Int) -> Gemini {
  let assert True = n > 0
  Gemini(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set the sampling temperature.
pub fn temperature(m: Gemini, t: Float) -> Gemini {
  Gemini(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Gemini, p: Float) -> Gemini {
  Gemini(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Set the top-k sampling value.
pub fn top_k(m: Gemini, k: Int) -> Gemini {
  Gemini(..m, settings: ModelSettings(..m.settings, top_k: Some(k)))
}

/// Set the random seed for more repeatable output.
pub fn seed(m: Gemini, s: Int) -> Gemini {
  Gemini(..m, settings: ModelSettings(..m.settings, seed: Some(s)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Gemini, stops: List(String)) -> Gemini {
  Gemini(
    ..m,
    settings: ModelSettings(..m.settings, stop_sequences: Some(stops)),
  )
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Gemini) -> Model {
  Model(provider: gemini_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Gemini {
  Gemini(
    config: gemini_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
