//// Alibaba Qwen models.
////
//// Covers Qwen3.5, Qwen3, Qwen, QwQ, and coder variants.
//// Supported parameters: max_output_tokens, temperature, top_p, top_k,
//// seed, stop_sequences.
////
//// NO penalty parameters.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/qwen as qwen_provider

/// A Qwen model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Qwen {
  Qwen(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    top_k: Option(Int),
    seed: Option(Int),
    stop_sequences: Option(List(String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Qwen3.5 Plus
pub fn qwen3_5_plus(api_key key: String) -> Qwen {
  new_qwen(key, "qwen3.5-plus")
}

/// Qwen3.5 Flash
pub fn qwen3_5_flash(api_key key: String) -> Qwen {
  new_qwen(key, "qwen3.5-flash")
}

/// Qwen3 Max
pub fn qwen3_max(api_key key: String) -> Qwen {
  new_qwen(key, "qwen3-max")
}

/// Qwen3 Plus
pub fn qwen3_plus(api_key key: String) -> Qwen {
  new_qwen(key, "qwen3-plus")
}

/// Qwen Plus
pub fn qwen_plus(api_key key: String) -> Qwen {
  new_qwen(key, "qwen-plus")
}

/// Qwen Max
pub fn qwen_max(api_key key: String) -> Qwen {
  new_qwen(key, "qwen-max")
}

/// Qwen Turbo
pub fn qwen_turbo(api_key key: String) -> Qwen {
  new_qwen(key, "qwen-turbo")
}

/// Qwen Flash
pub fn qwen_flash(api_key key: String) -> Qwen {
  new_qwen(key, "qwen-flash")
}

/// QwQ Plus
pub fn qwq_plus(api_key key: String) -> Qwen {
  new_qwen(key, "qwq-plus")
}

/// Qwen3 Coder
pub fn qwen3_coder(api_key key: String) -> Qwen {
  new_qwen(key, "qwen3-coder")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Qwen, n: Int) -> Qwen {
  Qwen(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0–2).
pub fn temperature(m: Qwen, t: Float) -> Qwen {
  Qwen(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Qwen, p: Float) -> Qwen {
  Qwen(..m, top_p: Some(p))
}

/// Set the top-k value.
pub fn top_k(m: Qwen, k: Int) -> Qwen {
  Qwen(..m, top_k: Some(k))
}

/// Set the random seed for deterministic generation.
pub fn seed(m: Qwen, s: Int) -> Qwen {
  Qwen(..m, seed: Some(s))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: Qwen, stops: List(String)) -> Qwen {
  Qwen(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this Qwen configuration.
pub fn build(m: Qwen) -> Model {
  let provider = qwen_provider.new(api_key: m.api_key, model: m.model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: m.temperature,
      top_p: m.top_p,
      top_k: m.top_k,
      stop_sequences: m.stop_sequences,
      seed: m.seed,
      presence_penalty: None,
      frequency_penalty: None,
    )

  Model(provider: provider, settings: settings)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn new_qwen(api_key: String, model_id: String) -> Qwen {
  Qwen(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    top_k: None,
    seed: None,
    stop_sequences: None,
  )
}
