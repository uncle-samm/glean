//// Mistral AI models.
////
//// Covers Mistral Large, Medium, Small, Magistral, Codestral, Devstral,
//// and Ministral models.
//// Supported parameters: max_output_tokens, temperature (0–1.5), top_p.
////
//// Uses `max_tokens` field name (not `max_completion_tokens`).

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/mistral as mistral_provider

/// A Mistral model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Mistral {
  Mistral(
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

/// Mistral Large 3
pub fn large_3(api_key key: String) -> Mistral {
  new_mistral(key, "mistral-large-2512")
}

/// Mistral Medium 3.1
pub fn medium_3_1(api_key key: String) -> Mistral {
  new_mistral(key, "mistral-medium-3.1")
}

/// Mistral Small 3.2 (24B instruct)
pub fn small_3_2(api_key key: String) -> Mistral {
  new_mistral(key, "mistral-small-latest")
}

/// Magistral Medium
pub fn magistral_medium(api_key key: String) -> Mistral {
  new_mistral(key, "magistral-medium-1-2-25-09")
}

/// Magistral Small
pub fn magistral_small(api_key key: String) -> Mistral {
  new_mistral(key, "magistral-small-1-2-25-09")
}

/// Codestral
pub fn codestral(api_key key: String) -> Mistral {
  new_mistral(key, "codestral-2508")
}

/// Devstral 2
pub fn devstral_2(api_key key: String) -> Mistral {
  new_mistral(key, "devstral-2512")
}

/// Devstral Small
pub fn devstral_small(api_key key: String) -> Mistral {
  new_mistral(key, "devstral-small")
}

/// Ministral 14B
pub fn ministral_14b(api_key key: String) -> Mistral {
  new_mistral(key, "ministral-14b-2512")
}

/// Ministral 8B
pub fn ministral_8b(api_key key: String) -> Mistral {
  new_mistral(key, "ministral-8b-2512")
}

/// Ministral 3B
pub fn ministral_3b(api_key key: String) -> Mistral {
  new_mistral(key, "ministral-3b-2512")
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models
// ---------------------------------------------------------------------------

/// Mistral Nemo — deprecated, will be replaced by mistral-small-3.2 at build time.
@deprecated("Mistral Nemo is deprecated. Use small_3_2() instead.")
pub fn nemo(api_key key: String) -> Mistral {
  new_deprecated_mistral(
    key,
    "mistral-nemo",
    "mistral-small-latest",
    "deprecated",
  )
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Mistral, n: Int) -> Mistral {
  Mistral(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0–1.5).
pub fn temperature(m: Mistral, t: Float) -> Mistral {
  Mistral(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Mistral, p: Float) -> Mistral {
  Mistral(..m, top_p: Some(p))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this Mistral configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Mistral) -> Model {
  let actual_model_id = case m.deprecated_info {
    None -> m.model_id
    Some(#(replacement, shutdown)) -> {
      model.deprecation_warning(m.model_id, replacement, shutdown)
      replacement
    }
  }

  let provider =
    mistral_provider.new(api_key: m.api_key, model: actual_model_id)

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

fn new_mistral(api_key: String, model_id: String) -> Mistral {
  Mistral(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    deprecated_info: None,
  )
}

fn new_deprecated_mistral(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Mistral {
  Mistral(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
