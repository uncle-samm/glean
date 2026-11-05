//// Standard OpenAI GPT models.
////
//// Covers GPT-5.x, GPT-OSS, and legacy GPT-4.x models.
//// Supported parameters: max_output_tokens, temperature, top_p, seed,
//// presence_penalty, frequency_penalty, stop_sequences.
////
//// For reasoning models (o-series, gpt-5-mini, gpt-5-nano) see
//// `glean/models/openai_reasoning`.

import gleam/option.{type Option, None, Some}
import glean/model.{type Model, Model}
import glean/provider.{ModelSettings}
import glean/providers/openai as openai_provider

/// A standard GPT model builder.
/// Use one of the constructor functions to create a value, chain builder
/// functions to set parameters, then call `build()` to get a `Model`.
pub opaque type Gpt {
  Gpt(
    api_key: String,
    model_id: String,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    seed: Option(Int),
    presence_penalty: Option(Float),
    frequency_penalty: Option(Float),
    stop_sequences: Option(List(String)),
    deprecated_info: Option(#(String, String)),
  )
}

// ---------------------------------------------------------------------------
// Constructors — current models
// ---------------------------------------------------------------------------

/// GPT-5.4
pub fn gpt5_4(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.4")
}

/// GPT-5.4 Pro
pub fn gpt5_4_pro(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.4-pro")
}

/// GPT-5.3
pub fn gpt5_3(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.3-chat")
}

/// GPT-5.2
pub fn gpt5_2(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.2")
}

/// GPT-5.2 Pro
pub fn gpt5_2_pro(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.2-pro")
}

/// GPT-5.1
pub fn gpt5_1(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5.1")
}

/// GPT-5
pub fn gpt5(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5")
}

/// GPT-5 Pro
pub fn gpt5_pro(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-5-pro")
}

/// GPT-OSS 120B — open-source 120 billion parameter model
pub fn gpt_oss_120b(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-oss-120b")
}

/// GPT-OSS 20B — open-source 20 billion parameter model
pub fn gpt_oss_20b(api_key key: String) -> Gpt {
  new_gpt(key, "gpt-oss-20b")
}

// ---------------------------------------------------------------------------
// Constructors — deprecated models
// ---------------------------------------------------------------------------

/// GPT-4.1 — deprecated, will be replaced by gpt-5 at build time.
@deprecated("gpt-4.1 is deprecated (shutdown: Feb 16, 2026). Use gpt5() instead.")
pub fn gpt4_1(api_key key: String) -> Gpt {
  new_deprecated_gpt(key, "gpt-4.1", "gpt-5", "Feb 16, 2026")
}

/// GPT-4.1 Mini — deprecated, will be replaced by gpt-5-mini at build time.
@deprecated("gpt-4.1-mini is deprecated (shutdown: Feb 16, 2026). Use openai_reasoning.gpt5_mini() instead.")
pub fn gpt4_1_mini(api_key key: String) -> Gpt {
  new_deprecated_gpt(key, "gpt-4.1-mini", "gpt-5-mini", "Feb 16, 2026")
}

/// GPT-4.1 Nano — deprecated, will be replaced by gpt-5-nano at build time.
@deprecated("gpt-4.1-nano is deprecated (shutdown: Feb 16, 2026). Use openai_reasoning.gpt5_nano() instead.")
pub fn gpt4_1_nano(api_key key: String) -> Gpt {
  new_deprecated_gpt(key, "gpt-4.1-nano", "gpt-5-nano", "Feb 16, 2026")
}

/// GPT-4o — deprecated, will be replaced by gpt-5 at build time.
@deprecated("gpt-4o is deprecated (shutdown: Feb 16, 2026). Use gpt5() instead.")
pub fn gpt4o(api_key key: String) -> Gpt {
  new_deprecated_gpt(key, "gpt-4o", "gpt-5", "Feb 16, 2026")
}

/// GPT-4o Mini — deprecated, will be replaced by gpt-5-mini at build time.
@deprecated("gpt-4o-mini is deprecated (shutdown: Feb 16, 2026). Use openai_reasoning.gpt5_mini() instead.")
pub fn gpt4o_mini(api_key key: String) -> Gpt {
  new_deprecated_gpt(key, "gpt-4o-mini", "gpt-5-mini", "Feb 16, 2026")
}

// ---------------------------------------------------------------------------
// Builder functions
// ---------------------------------------------------------------------------

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Gpt, n: Int) -> Gpt {
  Gpt(..m, max_output_tokens: Some(n))
}

/// Set the sampling temperature.
pub fn temperature(m: Gpt, t: Float) -> Gpt {
  Gpt(..m, temperature: Some(t))
}

/// Set the top-p (nucleus sampling) value.
pub fn top_p(m: Gpt, p: Float) -> Gpt {
  Gpt(..m, top_p: Some(p))
}

/// Set the random seed for deterministic generation.
pub fn seed(m: Gpt, s: Int) -> Gpt {
  Gpt(..m, seed: Some(s))
}

/// Set the presence penalty.
pub fn presence_penalty(m: Gpt, pp: Float) -> Gpt {
  Gpt(..m, presence_penalty: Some(pp))
}

/// Set the frequency penalty.
pub fn frequency_penalty(m: Gpt, fp: Float) -> Gpt {
  Gpt(..m, frequency_penalty: Some(fp))
}

/// Set stop sequences — the model will stop generating when it encounters
/// any of these strings.
pub fn stop_sequences(m: Gpt, stops: List(String)) -> Gpt {
  Gpt(..m, stop_sequences: Some(stops))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` from this GPT configuration.
///
/// If the model is deprecated, a warning is printed and the replacement
/// model ID is used instead.
pub fn build(m: Gpt) -> Model {
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
      temperature: m.temperature,
      top_p: m.top_p,
      top_k: None,
      stop_sequences: m.stop_sequences,
      seed: m.seed,
      presence_penalty: m.presence_penalty,
      frequency_penalty: m.frequency_penalty,
    )

  Model(provider: provider, settings: settings)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn new_gpt(api_key: String, model_id: String) -> Gpt {
  Gpt(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    seed: None,
    presence_penalty: None,
    frequency_penalty: None,
    stop_sequences: None,
    deprecated_info: None,
  )
}

fn new_deprecated_gpt(
  api_key: String,
  model_id: String,
  replacement: String,
  shutdown: String,
) -> Gpt {
  Gpt(
    api_key: api_key,
    model_id: model_id,
    max_output_tokens: None,
    temperature: None,
    top_p: None,
    seed: None,
    presence_penalty: None,
    frequency_penalty: None,
    stop_sequences: None,
    deprecated_info: Some(#(replacement, shutdown)),
  )
}
