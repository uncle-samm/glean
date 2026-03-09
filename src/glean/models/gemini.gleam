//// Google Gemini chat models.
////
//// Covers Gemini Pro, Flash, and Flash Lite families.
//// Supported parameters: max_output_tokens, temperature, top_p, top_k,
//// seed, stop_sequences.
////
//// No penalty parameters are available.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/gemini as gemini_provider

/// A Gemini model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Gemini {
  Gemini(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    top_k: Option(Int),
    seed: Option(Int),
    stop_sequences: Option(List(String)),
    deprecated_info: Option(#(String, String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors — current models
// ---------------------------------------------------------------------------

/// Gemini 3.1 Pro — latest flagship model.
pub fn pro_3_1(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-3.1-pro-preview")
}

/// Gemini 3 Flash — fast next-gen model.
pub fn flash_3(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-3-flash-preview")
}

/// Gemini 3.1 Flash Lite — lightweight next-gen model.
pub fn flash_lite_3_1(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-3.1-flash-lite-preview")
}

/// Gemini 2.5 Pro — high-capability model.
pub fn pro_2_5(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-2.5-pro")
}

/// Gemini 2.5 Flash — balanced performance and speed.
pub fn flash_2_5(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-2.5-flash")
}

/// Gemini 2.5 Flash Lite — cost-effective model.
pub fn flash_lite_2_5(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-2.5-flash-lite")
}

/// Gemini 3.1 Flash Image — image generation model.
pub fn flash_image_3_1(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-3.1-flash-image-preview")
}

/// Gemini 3 Pro Image — pro image generation model.
pub fn pro_image_3(api_key key: String) -> Gemini {
  new_gemini(key, "gemini-3-pro-image-preview")
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models
// ---------------------------------------------------------------------------

/// Gemini 3 Pro — deprecated, will be replaced by gemini-3.1-pro-preview.
@deprecated("gemini-3-pro-preview is deprecated (shutdown: Mar 9, 2026). Use pro_3_1() instead.")
pub fn pro_3(api_key key: String) -> Gemini {
  new_deprecated_gemini(
    key,
    "gemini-3-pro-preview",
    "gemini-3.1-pro-preview",
    "Mar 9, 2026",
  )
}

/// Gemini 2.0 Flash — deprecated, will be replaced by gemini-2.5-flash.
@deprecated("gemini-2.0-flash is deprecated (shutdown: Jun 1, 2026). Use flash_2_5() instead.")
pub fn flash_2(api_key key: String) -> Gemini {
  new_deprecated_gemini(
    key,
    "gemini-2.0-flash",
    "gemini-2.5-flash",
    "Jun 1, 2026",
  )
}

/// Gemini 2.0 Flash Lite — deprecated, will be replaced by gemini-2.5-flash-lite.
@deprecated("gemini-2.0-flash-lite is deprecated (shutdown: Jun 1, 2026). Use flash_lite_2_5() instead.")
pub fn flash_lite_2(api_key key: String) -> Gemini {
  new_deprecated_gemini(
    key,
    "gemini-2.0-flash-lite",
    "gemini-2.5-flash-lite",
    "Jun 1, 2026",
  )
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Gemini, n: Int) -> Gemini {
  Gemini(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0-2).
pub fn temperature(m: Gemini, t: Float) -> Gemini {
  Gemini(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Gemini, p: Float) -> Gemini {
  Gemini(..m, top_p: Some(p))
}

/// Set the top-k sampling value.
pub fn top_k(m: Gemini, k: Int) -> Gemini {
  Gemini(..m, top_k: Some(k))
}

/// Set the random seed for deterministic generation.
pub fn seed(m: Gemini, s: Int) -> Gemini {
  Gemini(..m, seed: Some(s))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: Gemini, stops: List(String)) -> Gemini {
  Gemini(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this Gemini configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Gemini) -> Model {
  let actual_model_id = case m.deprecated_info {
    None -> m.model_id
    Some(#(replacement, shutdown)) -> {
      model.deprecation_warning(m.model_id, replacement, shutdown)
      replacement
    }
  }

  let provider =
    gemini_provider.new(api_key: m.api_key, model: actual_model_id)

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

fn new_gemini(api_key: String, model_id: String) -> Gemini {
  Gemini(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    top_k: None,
    seed: None,
    stop_sequences: None,
    deprecated_info: None,
  )
}

fn new_deprecated_gemini(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Gemini {
  Gemini(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    top_k: None,
    seed: None,
    stop_sequences: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
