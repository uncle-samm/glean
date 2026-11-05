/// Shared utilities for provider integration tests.
import envoy
import gleam/option.{None, Some}
import gleam/string
import glean/error.{type GleanError}
import glean/provider.{type ModelSettings, ModelSettings}

/// Get an API key from the environment.
/// Returns Error(Nil) if the env var is not set.
pub fn get_api_key(env_var: String) -> Result(String, Nil) {
  envoy.get(env_var)
}

/// Panic with the actual error details included in the message.
pub fn fail(label: String, err: GleanError) -> a {
  panic as { label <> ": " <> error.to_string(err) }
}

/// Cost-optimized model settings for integration tests.
/// Low max_tokens and temperature 0 for determinism and speed.
pub fn cheap_settings() -> ModelSettings {
  ModelSettings(
    max_output_tokens: Some(1000),
    temperature: None,
    top_p: None,
    top_k: None,
    stop_sequences: None,
    seed: None,
    presence_penalty: None,
    frequency_penalty: None,
  )
}

/// Assert that text is non-empty after trimming whitespace.
pub fn assert_non_empty_text(text: String) -> Nil {
  let assert True = string.length(string.trim(text)) > 0
  Nil
}
