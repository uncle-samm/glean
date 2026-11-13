//// Provider configuration shared by all provider implementations.
////
//// Model builders expose this through their `configure` function, e.g.
//// `anthropic.sonnet_5_5(key) |> anthropic.configure(config.timeout(_, 120_000))`.

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
    /// How long to wait for a response, in milliseconds: for the whole
    /// response of a non-streaming request, and for each next event of a
    /// streaming one.
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
    /// Extra top-level request fields for provider-specific options glean
    /// has no setting for, such as DeepSeek's `thinking`, Qwen's
    /// `enable_thinking` or Claude's `service_tier`. Each one replaces
    /// glean's own field of the same name.
    extra_body: List(#(String, Json)),
    /// Claude only: cache the prompt, so that a request that starts with
    /// the same tools, system prompt and messages as an earlier one reads
    /// them from the cache at a fraction of the price. Other providers
    /// cache on their own.
    prompt_caching: Bool,
  )
}

/// Create a config with defaults.
pub fn new(api_key api_key: String, model model: String) -> ProviderConfig {
  ProviderConfig(
    api_key: api_key,
    base_url: "",
    model: model,
    headers: [],
    timeout_ms: 600_000,
    max_tokens_field: "max_completion_tokens",
    max_retries: 3,
    initial_retry_delay_ms: 1000,
    send_reasoning_content: False,
    stream_usage: False,
    extra_body: [],
    prompt_caching: False,
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

/// Set how long to wait for a response, in milliseconds (default: 10
/// minutes, because a model that thinks can take minutes to answer). For a
/// streaming request this is the longest wait for the next event, not for
/// the whole response. A request that times out is tried again like any
/// other failed request, up to `max_retries` times.
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

/// Add an extra top-level request field. It replaces glean's own field of
/// the same name, and setting the same name twice keeps the last value.
pub fn extra_body_field(
  config: ProviderConfig,
  name: String,
  value: Json,
) -> ProviderConfig {
  let others = list.filter(config.extra_body, fn(field) { field.0 != name })
  ProviderConfig(..config, extra_body: list.append(others, [#(name, value)]))
}

/// Cache the prompt (Claude only; see `ProviderConfig.prompt_caching`).
/// `Usage.cache_read_tokens` and `cache_write_tokens` show what it did.
pub fn prompt_caching(config: ProviderConfig, enabled: Bool) -> ProviderConfig {
  ProviderConfig(..config, prompt_caching: enabled)
}

/// A request's top-level fields with the config's extra fields: an extra
/// field replaces glean's field of the same name, and the rest follow
/// glean's own.
@internal
pub fn with_extra_body(
  fields: List(#(String, Json)),
  config: ProviderConfig,
) -> List(#(String, Json)) {
  let extra_names = list.map(config.extra_body, fn(field) { field.0 })
  list.filter(fields, fn(field) { !list.contains(extra_names, field.0) })
  |> list.append(config.extra_body)
}
