/// Alibaba Qwen provider via DashScope (qwen-plus, qwen-turbo, qwen-max, etc.)
/// OpenAI-compatible API endpoint.

import glean/provider.{type Provider}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai_compatible

/// International endpoint
const base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

/// Create a Qwen provider (international endpoint).
///
/// ## Example
///
/// ```gleam
/// let provider = qwen.new(api_key: "...", model: "qwen-plus")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
  |> from_config
}

/// Create a Qwen provider using the China endpoint.
pub fn new_china(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url("https://dashscope.aliyuncs.com/compatible-mode/v1")
  |> from_config
}

/// Create a Qwen provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  openai_compatible.create(name: "qwen", config: cfg)
}
