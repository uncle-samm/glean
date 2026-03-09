//// Anthropic Claude models.
////
//// Covers Claude Opus, Sonnet, and Haiku families.
//// Supported parameters: max_output_tokens, temperature, top_p, top_k,
//// stop_sequences.
////
//// All Claude models share the same parameter support. No seed or penalty
//// parameters are available.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/anthropic as anthropic_provider

/// A Claude model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Claude {
  Claude(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    top_k: Option(Int),
    stop_sequences: Option(List(String)),
    deprecated_info: Option(#(String, String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors — current models
// ---------------------------------------------------------------------------

/// Claude Opus 4.6 — latest and most capable model.
pub fn opus_4_6(api_key key: String) -> Claude {
  new_claude(key, "claude-opus-4-6")
}

/// Claude Sonnet 4.6 — balanced performance and speed.
pub fn sonnet_4_6(api_key key: String) -> Claude {
  new_claude(key, "claude-sonnet-4-6")
}

/// Claude Haiku 4.5 — fast and cost-effective.
pub fn haiku_4_5(api_key key: String) -> Claude {
  new_claude(key, "claude-haiku-4-5-20251001")
}

// ---------------------------------------------------------------------------
// Constructors — legacy models (still active, will be retired)
// ---------------------------------------------------------------------------

/// Claude Opus 4.5 — legacy, will be replaced by claude-opus-4-6.
@deprecated("claude-opus-4-5 is deprecated (shutdown: Nov 24, 2026). Use opus_4_6() instead.")
pub fn opus_4_5(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-opus-4-5-20251101",
    "claude-opus-4-6",
    "Nov 24, 2026",
  )
}

/// Claude Sonnet 4.5 — legacy, will be replaced by claude-sonnet-4-6.
@deprecated("claude-sonnet-4-5 is deprecated (shutdown: Sep 29, 2026). Use sonnet_4_6() instead.")
pub fn sonnet_4_5(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-sonnet-4-5-20250929",
    "claude-sonnet-4-6",
    "Sep 29, 2026",
  )
}

/// Claude Opus 4.1 — legacy, will be replaced by claude-opus-4-6.
@deprecated("claude-opus-4-1 is deprecated (shutdown: Aug 5, 2026). Use opus_4_6() instead.")
pub fn opus_4_1(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-opus-4-1-20250805",
    "claude-opus-4-6",
    "Aug 5, 2026",
  )
}

/// Claude Sonnet 4 — legacy, will be replaced by claude-sonnet-4-6.
@deprecated("claude-sonnet-4 is deprecated (shutdown: May 14, 2026). Use sonnet_4_6() instead.")
pub fn sonnet_4(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-sonnet-4-20250514",
    "claude-sonnet-4-6",
    "May 14, 2026",
  )
}

/// Claude Opus 4 — legacy, will be replaced by claude-opus-4-6.
@deprecated("claude-opus-4 is deprecated (shutdown: May 14, 2026). Use opus_4_6() instead.")
pub fn opus_4(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-opus-4-20250514",
    "claude-opus-4-6",
    "May 14, 2026",
  )
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models (already retired or retiring soon)
// ---------------------------------------------------------------------------

/// Claude 3 Haiku — deprecated, will be replaced by claude-haiku-4-5.
@deprecated("claude-3-haiku is deprecated (shutdown: Apr 20, 2026). Use haiku_4_5() instead.")
pub fn haiku_3(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-3-haiku-20240307",
    "claude-haiku-4-5-20251001",
    "Apr 20, 2026",
  )
}

/// Claude 3.5 Haiku — deprecated, already retired.
@deprecated("claude-3-5-haiku is deprecated (shutdown: Feb 2026 (retired)). Use haiku_4_5() instead.")
pub fn haiku_3_5(api_key key: String) -> Claude {
  new_deprecated_claude(
    key,
    "claude-3-5-haiku-20241022",
    "claude-haiku-4-5-20251001",
    "Feb 2026 (retired)",
  )
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Claude, n: Int) -> Claude {
  Claude(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0-1).
pub fn temperature(m: Claude, t: Float) -> Claude {
  Claude(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value (0-1).
pub fn top_p(m: Claude, p: Float) -> Claude {
  Claude(..m, top_p: Some(p))
}

/// Set the top-k sampling value.
pub fn top_k(m: Claude, k: Int) -> Claude {
  Claude(..m, top_k: Some(k))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: Claude, stops: List(String)) -> Claude {
  Claude(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this Claude configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Claude) -> Model {
  let actual_model_id = case m.deprecated_info {
    None -> m.model_id
    Some(#(replacement, shutdown)) -> {
      model.deprecation_warning(m.model_id, replacement, shutdown)
      replacement
    }
  }

  let provider =
    anthropic_provider.new(api_key: m.api_key, model: actual_model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: m.temperature,
      top_p: m.top_p,
      top_k: m.top_k,
      stop_sequences: m.stop_sequences,
      seed: None,
      presence_penalty: None,
      frequency_penalty: None,
    )

  Model(provider: provider, settings: settings)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn new_claude(api_key: String, model_id: String) -> Claude {
  Claude(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
    deprecated_info: None,
  )
}

fn new_deprecated_claude(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Claude {
  Claude(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
