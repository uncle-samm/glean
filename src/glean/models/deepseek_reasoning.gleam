//// DeepSeek reasoning models.
////
//// Covers DeepSeek-Reasoner and DeepSeek-R1 models.
//// Supported parameters: max_output_tokens only.
//// These models do not support temperature or top_p.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/deepseek as deepseek_provider

/// A DeepSeek reasoning model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type DeepseekReasoning {
  DeepseekReasoning(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
  )
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// DeepSeek Reasoner
pub fn reasoner(api_key key: String) -> DeepseekReasoning {
  new_deepseek_reasoning(key, "deepseek-reasoner")
}

/// DeepSeek R1
pub fn r1(api_key key: String) -> DeepseekReasoning {
  new_deepseek_reasoning(key, "deepseek-r1")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: DeepseekReasoning, n: Int) -> DeepseekReasoning {
  DeepseekReasoning(..m, max_output_tokens: Some(n))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this DeepSeek Reasoning configuration.
pub fn build(m: DeepseekReasoning) -> Model {
  let provider =
    deepseek_provider.new(api_key: m.api_key, model: m.model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: None,
      top_p: None,
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

fn new_deepseek_reasoning(
  api_key: String,
  model_id: String,
) -> DeepseekReasoning {
  DeepseekReasoning(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
  )
}
