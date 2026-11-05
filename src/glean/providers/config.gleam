//// Provider configuration shared by all provider implementations.
////
//// Model builders expose this through their `configure` function, e.g.
//// `anthropic.sonnet_5(key) |> anthropic.configure(config.timeout(_, 120_000))`.

import gleam/json.{type Json}
import gleam/list

/// Configuration for creating a provider.
pub type ProviderConfig {
  ProviderConfig(
    /// API key for authentication
    api_key: String,
    /// Base URL for the API (no trailing slash)
    base_url: String,
    /// Model ID to use
    model: String,
    /// Additional HTTP headers
    headers: List(#(String, String)),
    /// Request timeout in milliseconds
    timeout_ms: Int,
    /// Field name for max tokens parameter (e.g. "max_completion_tokens" or "max_tokens")
    max_tokens_field: String,
    /// Maximum retries for transient HTTP errors (429, 5xx)
    max_retries: Int,
    /// Initial retry delay in milliseconds (doubles each retry, with jitter)
    initial_retry_delay_ms: Int,
    /// OpenAI-compatible APIs only: send the model's earlier reasoning back
    /// as `reasoning_content` (DeepSeek and Kimi require it in tool loops).
    send_reasoning_content: Bool,
    /// OpenAI-compatible APIs only: ask for token usage in streaming
    /// responses with `stream_options.include_usage`.
    stream_usage: Bool,
    /// OpenAI-compatible APIs only: extra top-level request fields for
    /// provider-specific options glean has no setting for, such as
    /// DeepSeek's `thinking` or Qwen's `enable_thinking`. They are added
    /// after glean's own fields.
    extra_body: List(#(String, Json)),
  )
}

/// Create a config with defaults.
pub fn new(api_key api_key: String, model model: String) -> ProviderConfig {
  ProviderConfig(
    api_key: api_key,
    base_url: "",
    model: model,
    headers: [],
    timeout_ms: 60_000,
    max_tokens_field: "max_completion_tokens",
    max_retries: 3,
    initial_retry_delay_ms: 1000,
    send_reasoning_content: False,
    stream_usage: False,
    extra_body: [],
  )
}

/// Set the base URL.
pub fn base_url(config: ProviderConfig, url: String) -> ProviderConfig {
  ProviderConfig(..config, base_url: url)
}

/// Add extra headers.
pub fn headers(
  config: ProviderConfig,
  headers: List(#(String, String)),
) -> ProviderConfig {
  ProviderConfig(..config, headers: headers)
}

/// Set the request timeout in milliseconds.
pub fn timeout(config: ProviderConfig, ms: Int) -> ProviderConfig {
  let assert True = ms > 0
  ProviderConfig(..config, timeout_ms: ms)
}

/// Set the field name used for max tokens in API requests.
/// Defaults to "max_completion_tokens". Use "max_tokens" for providers
/// that don't support the newer field name (e.g. Mistral).
pub fn max_tokens_field(
  config: ProviderConfig,
  field: String,
) -> ProviderConfig {
  ProviderConfig(..config, max_tokens_field: field)
}

/// Set max retries for transient HTTP errors (429, 5xx).
pub fn max_retries(config: ProviderConfig, retries: Int) -> ProviderConfig {
  let assert True = retries >= 0
  ProviderConfig(..config, max_retries: retries)
}

/// Set initial retry delay in milliseconds (doubles each retry).
pub fn initial_retry_delay(config: ProviderConfig, ms: Int) -> ProviderConfig {
  let assert True = ms > 0
  ProviderConfig(..config, initial_retry_delay_ms: ms)
}

/// Send earlier reasoning back as `reasoning_content`
/// (OpenAI-compatible providers only).
pub fn send_reasoning_content(
  config: ProviderConfig,
  enabled: Bool,
) -> ProviderConfig {
  ProviderConfig(..config, send_reasoning_content: enabled)
}

/// Ask for token usage in streaming responses
/// (OpenAI-compatible providers only).
pub fn stream_usage(config: ProviderConfig, enabled: Bool) -> ProviderConfig {
  ProviderConfig(..config, stream_usage: enabled)
}

/// Add an extra top-level request field (OpenAI-compatible providers only).
/// Setting the same name twice keeps the last value.
pub fn extra_body_field(
  config: ProviderConfig,
  name: String,
  value: Json,
) -> ProviderConfig {
  let others = list.filter(config.extra_body, fn(field) { field.0 != name })
  ProviderConfig(..config, extra_body: list.append(others, [#(name, value)]))
}
