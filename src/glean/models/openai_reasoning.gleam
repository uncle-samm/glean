//// OpenAI reasoning models (o-series and GPT-5 mini/nano).
////
//// These models use chain-of-thought reasoning and do NOT support
//// temperature, top_p, seed, presence_penalty, or frequency_penalty.
//// Supported parameters: max_output_tokens, stop_sequences.
////
//// For standard GPT models that support the full set of sampling
//// parameters, see `glean/models/openai`.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/openai as openai_provider

/// A reasoning model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Reasoning {
  Reasoning(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    stop_sequences: Option(List(String)),
    deprecated_info: Option(#(String, String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors — current models
// ---------------------------------------------------------------------------

/// GPT-5 Nano — lightweight reasoning model
pub fn gpt5_nano(api_key key: String) -> Reasoning {
  new_reasoning(key, "gpt-5-nano")
}

/// GPT-5 Mini — compact reasoning model
pub fn gpt5_mini(api_key key: String) -> Reasoning {
  new_reasoning(key, "gpt-5-mini")
}

/// o3
pub fn o3(api_key key: String) -> Reasoning {
  new_reasoning(key, "o3")
}

/// o3-mini
pub fn o3_mini(api_key key: String) -> Reasoning {
  new_reasoning(key, "o3-mini")
}

/// o3-pro
pub fn o3_pro(api_key key: String) -> Reasoning {
  new_reasoning(key, "o3-pro")
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models
// ---------------------------------------------------------------------------

/// o1 — deprecated, will be replaced by o3 at build time.
@deprecated("o1 is deprecated (already deprecated). Use o3() instead.")
pub fn o1(api_key key: String) -> Reasoning {
  new_deprecated_reasoning(key, "o1", "o3", "already deprecated")
}

/// o4-mini — deprecated, will be replaced by o3-mini at build time.
@deprecated("o4-mini is deprecated (shutdown: Feb 16, 2026). Use o3_mini() instead.")
pub fn o4_mini(api_key key: String) -> Reasoning {
  new_deprecated_reasoning(key, "o4-mini", "o3-mini", "Feb 16, 2026")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Reasoning, n: Int) -> Reasoning {
  Reasoning(..m, max_output_tokens: Some(n))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: Reasoning, stops: List(String)) -> Reasoning {
  Reasoning(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this reasoning model configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Reasoning) -> Model {
  let actual_model_id = case m.deprecated_info {
    None -> m.model_id
    Some(#(replacement, shutdown)) -> {
      model.deprecation_warning(m.model_id, replacement, shutdown)
      replacement
    }
  }

  let provider = openai_provider.new(api_key: m.api_key, model: actual_model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: None,
      top_p: None,
      top_k: None,
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

fn new_reasoning(api_key: String, model_id: String) -> Reasoning {
  Reasoning(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    stop_sequences: None,
    deprecated_info: None,
  )
}

fn new_deprecated_reasoning(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Reasoning {
  Reasoning(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    stop_sequences: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
