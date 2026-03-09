/// Provider configuration types shared across all provider implementations.

import gleam/http.{type Header}

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
    headers: List(Header),
    /// Request timeout in milliseconds
    timeout_ms: Int,
    /// Field name for max tokens parameter (e.g. "max_completion_tokens" or "max_tokens")
    max_tokens_field: String,
    /// Maximum retries for transient HTTP errors (429, 5xx)
    max_retries: Int,
    /// Initial retry delay in milliseconds (doubles each retry)
    initial_retry_delay_ms: Int,
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
  )
}

/// Set the base URL.
pub fn base_url(config: ProviderConfig, url: String) -> ProviderConfig {
  ProviderConfig(..config, base_url: url)
}

/// Add extra headers.
pub fn headers(
  config: ProviderConfig,
  headers: List(Header),
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
