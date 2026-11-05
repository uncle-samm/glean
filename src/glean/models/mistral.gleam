//// Mistral AI models.
////
//// Supported parameters: max_output_tokens, temperature, top_p,
//// stop_sequences.

import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/mistral as mistral_provider

/// A Mistral model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Mistral {
  Mistral(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Mistral Large 4 (preview). Model ID: `mistral-large-4`.
pub fn large_4(api_key key: String) -> Mistral {
  new(key, "mistral-large-4")
}

/// Mistral Medium 3.5. Model ID: `mistral-medium-2604`.
pub fn medium_3_5(api_key key: String) -> Mistral {
  new(key, "mistral-medium-2604")
}

/// Mistral Small 4. Model ID: `mistral-small-2603`.
pub fn small_4(api_key key: String) -> Mistral {
  new(key, "mistral-small-2603")
}

/// Mistral Large 3. Model ID: `mistral-large-2512`.
pub fn large_3(api_key key: String) -> Mistral {
  new(key, "mistral-large-2512")
}

/// Magistral Medium (latest). Model ID: `magistral-medium-latest`.
pub fn magistral_medium(api_key key: String) -> Mistral {
  new(key, "magistral-medium-latest")
}

/// Magistral Small (latest). Model ID: `magistral-small-latest`.
pub fn magistral_small(api_key key: String) -> Mistral {
  new(key, "magistral-small-latest")
}

/// Codestral (latest). Model ID: `codestral-latest`.
pub fn codestral(api_key key: String) -> Mistral {
  new(key, "codestral-latest")
}

/// Devstral (latest). Model ID: `devstral-latest`.
pub fn devstral(api_key key: String) -> Mistral {
  new(key, "devstral-latest")
}

/// Ministral 14B. Model ID: `ministral-14b-2512`.
pub fn ministral_14b(api_key key: String) -> Mistral {
  new(key, "ministral-14b-2512")
}

/// Ministral 8B. Model ID: `ministral-8b-2512`.
pub fn ministral_8b(api_key key: String) -> Mistral {
  new(key, "ministral-8b-2512")
}

/// Ministral 3B. Model ID: `ministral-3b-2512`.
pub fn ministral_3b(api_key key: String) -> Mistral {
  new(key, "ministral-3b-2512")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Mistral {
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
pub fn configure(
  m: Mistral,
  f: fn(ProviderConfig) -> ProviderConfig,
) -> Mistral {
  Mistral(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Mistral, n: Int) -> Mistral {
  let assert True = n > 0
  Mistral(
    ..m,
    settings: ModelSettings(..m.settings, max_output_tokens: Some(n)),
  )
}

/// Set the sampling temperature.
pub fn temperature(m: Mistral, t: Float) -> Mistral {
  Mistral(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Mistral, p: Float) -> Mistral {
  Mistral(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Mistral, stops: List(String)) -> Mistral {
  Mistral(
    ..m,
    settings: ModelSettings(..m.settings, stop_sequences: Some(stops)),
  )
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Mistral) -> Model {
  Model(provider: mistral_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Mistral {
  Mistral(
    config: mistral_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
