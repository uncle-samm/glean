//// MiniMax models.
////
//// MiniMax documents `temperature` and `top_p` as having no effect, so this
//// builder doesn't offer them.
import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/config.{type ProviderConfig}
import glean/providers/minimax as minimax_provider

/// A MiniMax model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type MiniMax {
  MiniMax(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// MiniMax M3. Model ID: `MiniMax-M3`.
pub fn m3(api_key key: String) -> MiniMax {
  new(key, "MiniMax-M3")
}

/// MiniMax M3.1 Flash. Model ID: `MiniMax-M3.1-Flash`.
pub fn m3_1_flash(api_key key: String) -> MiniMax {
  new(key, "MiniMax-M3.1-Flash")
}

/// MiniMax M2.7. Model ID: `MiniMax-M2.7`.
@deprecated("MiniMax-M2.7 retires for pay-as-you-go on Nov 18, 2026. Use minimax.m3() instead.")
pub fn m2_7(api_key key: String) -> MiniMax {
  new(key, "MiniMax-M2.7")
}

/// MiniMax M2.5. Model ID: `MiniMax-M2.5`.
@deprecated("MiniMax-M2.5 retires for pay-as-you-go on Nov 18, 2026. Use minimax.m3() instead.")
pub fn m2_5(api_key key: String) -> MiniMax {
  new(key, "MiniMax-M2.5")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> MiniMax {
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
pub fn configure(m: MiniMax, f: fn(ProviderConfig) -> ProviderConfig) -> MiniMax {
  MiniMax(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: MiniMax, n: Int) -> MiniMax {
  let assert True = n > 0
  MiniMax(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: MiniMax, stops: List(String)) -> MiniMax {
  MiniMax(..m, settings: ModelSettings(..m.settings, stop_sequences: Some(stops)))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: MiniMax) -> Model {
  Model(provider: minimax_provider.from_config(m.config), settings: m.settings)
}

fn new(key: String, model_id: String) -> MiniMax {
  MiniMax(
    config: minimax_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
