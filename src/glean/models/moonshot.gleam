//// Moonshot Kimi models.
////
//// The `kimi-k2` series was retired on May 25, 2026 and `kimi-k2.5` and
//// `moonshot-v1` on Aug 31, 2026. Reasoning is returned as reasoning events
//// and sent back on later turns.
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/moonshot as moonshot_provider

/// A Kimi model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Moonshot {
  Moonshot(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Kimi K3. Model ID: `kimi-k3`.
pub fn kimi_k3(api_key key: String) -> Moonshot {
  new(key, "kimi-k3")
}

/// Kimi K2.7 Code. Model ID: `kimi-k2.7-code`.
pub fn kimi_k2_7_code(api_key key: String) -> Moonshot {
  new(key, "kimi-k2.7-code")
}

/// Kimi K2.7 Code, high-speed. Model ID: `kimi-k2.7-code-highspeed`.
pub fn kimi_k2_7_code_highspeed(api_key key: String) -> Moonshot {
  new(key, "kimi-k2.7-code-highspeed")
}

/// Kimi K2.6. Model ID: `kimi-k2.6`.
pub fn kimi_k2_6(api_key key: String) -> Moonshot {
  new(key, "kimi-k2.6")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Moonshot {
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
pub fn configure(m: Moonshot, f: fn(ProviderConfig) -> ProviderConfig) -> Moonshot {
  Moonshot(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Moonshot, n: Int) -> Moonshot {
  let assert True = n > 0
  Moonshot(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Set the sampling temperature.
pub fn temperature(m: Moonshot, t: Float) -> Moonshot {
  Moonshot(..m, settings: ModelSettings(..m.settings, temperature: Some(t)))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Moonshot, p: Float) -> Moonshot {
  Moonshot(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Moonshot, stops: List(String)) -> Moonshot {
  Moonshot(..m, settings: ModelSettings(..m.settings, stop_sequences: Some(stops)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Moonshot) -> Model {
  Model(provider: moonshot_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> Moonshot {
  Moonshot(
    config: moonshot_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
