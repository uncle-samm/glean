//// Moonshot / Kimi models.
////
//// Covers Kimi K2.5, K2, and legacy Moonshot V1.
//// Supported parameters: max_output_tokens, temperature, top_p.
////
//// NO top_k, NO seed, NO penalty parameters.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/moonshot as moonshot_provider

/// A Moonshot/Kimi model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Moonshot {
  Moonshot(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    deprecated_info: Option(#(String, String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors — current models
// ---------------------------------------------------------------------------

/// Kimi K2.5
pub fn kimi_k2_5(api_key key: String) -> Moonshot {
  new_moonshot(key, "kimi-k2.5")
}

/// Kimi K2
pub fn kimi_k2(api_key key: String) -> Moonshot {
  new_moonshot(key, "kimi-k2")
}

/// Kimi K2 Thinking
pub fn kimi_k2_thinking(api_key key: String) -> Moonshot {
  new_moonshot(key, "kimi-k2-thinking")
}

/// Kimi K2 0905
pub fn kimi_k2_0905(api_key key: String) -> Moonshot {
  new_moonshot(key, "kimi-k2-0905")
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models
// ---------------------------------------------------------------------------

/// Moonshot V1 128K — deprecated, will be replaced by kimi-k2.5 at build time.
@deprecated("moonshot-v1-128k is deprecated. Use kimi_k2_5() instead.")
pub fn moonshot_v1_128k(api_key key: String) -> Moonshot {
  new_deprecated_moonshot(key, "moonshot-v1-128k", "kimi-k2.5", "deprecated")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Moonshot, n: Int) -> Moonshot {
  Moonshot(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0–1).
pub fn temperature(m: Moonshot, t: Float) -> Moonshot {
  Moonshot(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Moonshot, p: Float) -> Moonshot {
  Moonshot(..m, top_p: Some(p))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this Moonshot/Kimi configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Moonshot) -> Model {
  let actual_model_id = case m.deprecated_info {
    None -> m.model_id
    Some(#(replacement, shutdown)) -> {
      model.deprecation_warning(m.model_id, replacement, shutdown)
      replacement
    }
  }

  let provider =
    moonshot_provider.new(api_key: m.api_key, model: actual_model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: m.temperature,
      top_p: m.top_p,
      top_k: None,
      stop_sequences: None,
      seed: None,
      presence_penalty: None,
      frequency_penalty: None,
    )

  Model(provider: provider, settings: settings)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn new_moonshot(api_key: String, model_id: String) -> Moonshot {
  Moonshot(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    deprecated_info: None,
  )
}

fn new_deprecated_moonshot(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Moonshot {
  Moonshot(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
