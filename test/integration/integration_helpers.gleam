/// Shared utilities for provider integration tests.
import envoy
import gleam/io
import gleam/option.{Some}
import gleam/string
import glean/error.{type GleanError}
import glean/provider.{type ModelSettings, ModelSettings, default_settings}

/// Get an API key from the environment.
/// Returns Error(Nil) if the env var is not set, and says the test is
/// skipped so a passing run without keys isn't mistaken for real coverage.
pub fn get_api_key(env_var: String) -> Result(String, Nil) {
  case envoy.get(env_var) {
    Ok(key) -> Ok(key)
    Error(Nil) -> {
      io.println_error("skipped: " <> env_var <> " is not set")
      Error(Nil)
    }
  }
}

/// Panic with the actual error details included in the message.
pub fn fail(label: String, err: GleanError) -> a {
  panic as { label <> ": " <> error.to_string(err) }
}

/// Cost-optimized model settings for integration tests.
/// Low max_tokens and temperature 0 for determinism and speed.
pub fn cheap_settings() -> ModelSettings {
  ModelSettings(..default_settings(), max_output_tokens: Some(1000))
}

/// Assert that text is non-empty after trimming whitespace.
pub fn assert_non_empty_text(text: String) -> Nil {
  let assert True = string.length(string.trim(text)) > 0
  Nil
}
