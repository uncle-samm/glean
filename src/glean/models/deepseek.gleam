//// DeepSeek chat models.
////
//// Covers DeepSeek-Chat and DeepSeek-V3.1 models.
//// Supported parameters: max_output_tokens, temperature (0–2), top_p,
//// stop_sequences.
////
//// For reasoning models (deepseek-reasoner, deepseek-r1) see
//// `glean/models/deepseek_reasoning`.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/deepseek as deepseek_provider

/// A DeepSeek chat model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type DeepseekChat {
  DeepseekChat(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    stop_sequences: Option(List(String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// DeepSeek Chat
pub fn chat(api_key key: String) -> DeepseekChat {
  new_deepseek_chat(key, "deepseek-chat")
}

/// DeepSeek V3.1 Terminus
pub fn v3_1(api_key key: String) -> DeepseekChat {
  new_deepseek_chat(key, "deepseek-v3.1-terminus")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: DeepseekChat, n: Int) -> DeepseekChat {
  DeepseekChat(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature (0–2).
pub fn temperature(m: DeepseekChat, t: Float) -> DeepseekChat {
  DeepseekChat(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: DeepseekChat, p: Float) -> DeepseekChat {
  DeepseekChat(..m, top_p: Some(p))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: DeepseekChat, stops: List(String)) -> DeepseekChat {
  DeepseekChat(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this DeepSeek Chat configuration.
pub fn build(m: DeepseekChat) -> Model {
  let provider =
    deepseek_provider.new(api_key: m.api_key, model: m.model_id)

  let settings =
    ModelSettings(
      max_output_tokens: m.max_output_tokens,
      temperature: m.temperature,
      top_p: m.top_p,
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

fn new_deepseek_chat(api_key: String, model_id: String) -> DeepseekChat {
  DeepseekChat(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    stop_sequences: None,
  )
}
