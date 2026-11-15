//// Current Anthropic Claude models.
////
//// These models choose their own sampling: the API rejects `temperature`,
//// `top_p` and `top_k`, so this builder doesn't offer them.
////
//// Thinking is adaptive: the model decides how much to think, and
//// `reasoning_effort` (sent as `output_config.effort`) sets how deep it
//// goes. The Claude 5 models think without being asked. Opus 4.7 and 4.8
//// only think when `reasoning_effort` or `show_reasoning` is set. No model
//// returns the text of its thinking unless `show_reasoning` asks for it.
////
//// For older Claude models that still take sampling parameters, see
//// `glean/models/anthropic_sampling`.

import gleam/option.{Some}
import glean/model.{type Model, Model}
import glean/provider.{type ModelSettings, type ReasoningEffort, ModelSettings}
import glean/providers/anthropic as anthropic_provider
import glean/providers/config.{type ProviderConfig}

/// A Claude model builder. Pick a model with one of the constructors
/// (or `custom`), chain setters, then call `build()`.
pub opaque type Claude {
  Claude(config: ProviderConfig, settings: ModelSettings)
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Claude Fable 5.2, the most capable generally available Claude model.
/// Rejects forced tool choice. Model ID: `claude-fable-5-2`.
pub fn fable_5_2(api_key key: String) -> Claude {
  new(key, "claude-fable-5-2")
}

/// Claude Fable 5.1. Rejects forced tool choice. Model ID: `claude-fable-5-1`.
pub fn fable_5_1(api_key key: String) -> Claude {
  new(key, "claude-fable-5-1")
}

/// Claude Fable 5. Model ID: `claude-fable-5`.
pub fn fable_5(api_key key: String) -> Claude {
  new(key, "claude-fable-5")
}

/// Claude Opus 5.5. Rejects forced tool choice. Model ID: `claude-opus-5-5`.
pub fn opus_5_5(api_key key: String) -> Claude {
  new(key, "claude-opus-5-5")
}

/// Claude Opus 5. Model ID: `claude-opus-5`.
pub fn opus_5(api_key key: String) -> Claude {
  new(key, "claude-opus-5")
}

/// Claude Opus 4.8. Model ID: `claude-opus-4-8`.
pub fn opus_4_8(api_key key: String) -> Claude {
  new(key, "claude-opus-4-8")
}

/// Claude Opus 4.7. Model ID: `claude-opus-4-7`.
pub fn opus_4_7(api_key key: String) -> Claude {
  new(key, "claude-opus-4-7")
}

/// Claude Sonnet 5.5. Rejects forced tool choice. Model ID: `claude-sonnet-5-5`.
pub fn sonnet_5_5(api_key key: String) -> Claude {
  new(key, "claude-sonnet-5-5")
}

/// Claude Sonnet 5. Model ID: `claude-sonnet-5`.
pub fn sonnet_5(api_key key: String) -> Claude {
  new(key, "claude-sonnet-5")
}

/// Claude Haiku 5.5. Model ID: `claude-haiku-5-5`.
pub fn haiku_5_5(api_key key: String) -> Claude {
  new(key, "claude-haiku-5-5")
}

/// Any other model ID served by this API, such as one released after this
/// version of glean. Only this module's setters are available, so check the
/// model accepts them.
pub fn custom(api_key key: String, model model_id: String) -> Claude {
  let assert True = model_id != ""
  new(key, model_id)
}

// ---------------------------------------------------------------------------
// Setters
// ---------------------------------------------------------------------------

/// Change the provider configuration: base URL, timeout, headers, retries.
///
/// ```gleam
/// |> configure(config.timeout(_, 120_000))
/// ```
pub fn configure(m: Claude, f: fn(ProviderConfig) -> ProviderConfig) -> Claude {
  Claude(..m, config: f(m.config))
}

/// Set the maximum number of output tokens.
pub fn max_output_tokens(m: Claude, n: Int) -> Claude {
  let assert True = n > 0
  Claude(..m, settings: ModelSettings(..m.settings, max_output_tokens: Some(n)))
}

/// Stop generating when the model writes any of these strings.
pub fn stop_sequences(m: Claude, stops: List(String)) -> Claude {
  Claude(
    ..m,
    settings: ModelSettings(..m.settings, stop_sequences: Some(stops)),
  )
}

/// Set how much the model should think before answering.
pub fn reasoning_effort(m: Claude, effort: ReasoningEffort) -> Claude {
  Claude(
    ..m,
    settings: ModelSettings(..m.settings, reasoning_effort: Some(effort)),
  )
}

/// Ask for the model's reasoning as text: a summary of its thinking, in
/// the result's reasoning content and the stream's reasoning events.
/// Without this Claude thinks but the reasoning text comes back empty.
pub fn show_reasoning(m: Claude) -> Claude {
  Claude(..m, settings: ModelSettings(..m.settings, include_reasoning: True))
}

/// Cache the prompt: the tools, the system prompt and the conversation so
/// far are read from Claude's cache on the next call at a fraction of the
/// input price, for a little more on the call that writes them. Worth it
/// for agents that take several steps or share a long system prompt. The
/// cached amounts are in `Usage.cache_read_tokens` and
/// `Usage.cache_write_tokens`.
pub fn prompt_caching(m: Claude) -> Claude {
  Claude(..m, config: config.prompt_caching(m.config, True))
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// Build a `Model` to use with `agent.new`.
pub fn build(m: Claude) -> Model {
  Model(
    provider: anthropic_provider.from_config(m.config),
    settings: m.settings,
  )
}

fn new(key: String, model_id: String) -> Claude {
  Claude(
    config: anthropic_provider.default_config(api_key: key, model: model_id),
    settings: provider.default_settings(),
  )
}
