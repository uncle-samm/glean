//// MiniMax models.
////
//// Covers MiniMax M2.5, M2.1, M2, and M1.
//// Supported parameters: max_output_tokens, temperature, top_p.
////
//// NO top_k, NO seed, NO penalty parameters.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/minimax as minimax_provider

/// A MiniMax model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type MiniMax {
  MiniMax(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
  )
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// MiniMax M2.5
pub fn m2_5(api_key key: String) -> MiniMax {
  new_minimax(key, "MiniMax-M2.5")
}

/// MiniMax M2.1
pub fn m2_1(api_key key: String) -> MiniMax {
  new_minimax(key, "MiniMax-M2.1")
}

/// MiniMax M2.1 Lightning
pub fn m2_1_lightning(api_key key: String) -> MiniMax {
  new_minimax(key, "MiniMax-M2.1-lightning")
}

/// MiniMax M2
pub fn m2(api_key key: String) -> MiniMax {
  new_minimax(key, "MiniMax-M2")
}

/// MiniMax M1
pub fn m1(api_key key: String) -> MiniMax {
  new_minimax(key, "MiniMax-M1")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: MiniMax, n: Int) -> MiniMax {
  MiniMax(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature.
pub fn temperature(m: MiniMax, t: Float) -> MiniMax {
  MiniMax(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: MiniMax, p: Float) -> MiniMax {
  MiniMax(..m, top_p: Some(p))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this MiniMax configuration.
pub fn build(m: MiniMax) -> Model {
  let provider = minimax_provider.new(api_key: m.api_key, model: m.model_id)

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

fn new_minimax(api_key: String, model_id: String) -> MiniMax {
  MiniMax(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
  )
}
