//// Older Anthropic Claude models that still accept `temperature`, `top_p`
//// and `top_k` under the API version glean sends (`2023-06-01`).
////
//// For current models, see `glean/models/anthropic`.

import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, ModelSettings}
import glean/providers/anthropic as anthropic_provider
import glean/providers/config.{type ProviderConfig}

/// A Claude (with sampling parameters) model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type ClaudeSampling {
  ClaudeSampling(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Claude Opus 4.6. Model ID: `claude-opus-4-6`.
pub fn opus_4_6(api_key key: String) -> ClaudeSampling {
  new(key, "claude-opus-4-6")
}

/// Claude Sonnet 4.6. Model ID: `claude-sonnet-4-6`.
pub fn sonnet_4_6(api_key key: String) -> ClaudeSampling {
  new(key, "claude-sonnet-4-6")
}

/// Claude Haiku 4.5. Model ID: `claude-haiku-4-5`.
pub fn haiku_4_5(api_key key: String) -> ClaudeSampling {
  new(key, "claude-haiku-4-5")
}

/// Claude Opus 4.5. Model ID: `claude-opus-4-5`.
pub fn opus_4_5(api_key key: String) -> ClaudeSampling {
  new(key, "claude-opus-4-5")
}

/// Claude Sonnet 4.5. Model ID: `claude-sonnet-4-5`.
@deprecated("claude-sonnet-4-5 retires on Nov 30, 2026. Use anthropic.sonnet_5_5() instead.")
pub fn sonnet_4_5(api_key key: String) -> ClaudeSampling {
  new(key, "claude-sonnet-4-5")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> ClaudeSampling {
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
  m: ClaudeSampling,
  f: fn(ProviderConfig) -> ProviderConfig,
) -> ClaudeSampling {
  ClaudeSampling(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: ClaudeSampling, n: Int) -> ClaudeSampling {
  let assert True = n > 0
  ClaudeSampling(
    ..m,
    settings: ModelSettings(..m.settings, max_output_tokens: Some(n)),
  )
}

/// Set the sampling temperature.
pub fn temperature(m: ClaudeSampling, t: Float) -> ClaudeSampling {
  ClaudeSampling(
    ..m,
    settings: ModelSettings(..m.settings, temperature: Some(t)),
  )
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: ClaudeSampling, p: Float) -> ClaudeSampling {
  ClaudeSampling(..m, settings: ModelSettings(..m.settings, top_p: Some(p)))
}

/// Set the top-k sampling value.
pub fn top_k(m: ClaudeSampling, k: Int) -> ClaudeSampling {
  ClaudeSampling(..m, settings: ModelSettings(..m.settings, top_k: Some(k)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(
  m: ClaudeSampling,
  stops: List(String),
) -> ClaudeSampling {
  ClaudeSampling(
    ..m,
    settings: ModelSettings(..m.settings, stop_sequences: Some(stops)),
  )
}

/// Cache the prompt: the tools, the system prompt and the conversation so
/// far are read from Claude's cache on the next call. See
/// `glean/models/anthropic.prompt_caching`.
pub fn prompt_caching(m: ClaudeSampling) -> ClaudeSampling {
  ClaudeSampling(..m, config: config.prompt_caching(m.config, True))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: ClaudeSampling) -> Model {
  Model(
    provider: anthropic_provider.from_config(m.config),
    settings: m.settings,
  )
}

fn new(key: String, model_id: String) -> ClaudeSampling {
  ClaudeSampling(
    config: anthropic_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
