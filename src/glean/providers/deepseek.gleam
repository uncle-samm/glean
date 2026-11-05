/// DeepSeek provider (deepseek-chat, deepseek-reasoner, etc.)
/// Fully OpenAI-compatible API.
import glean/provider.{type Provider}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai_compatible

const base_url = "https://api.deepseek.com/v1"

/// Create a DeepSeek provider.
///
/// ## Example
///
/// ```gleam
/// let provider = deepseek.new(api_key: "sk-...", model: "deepseek-chat")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
  |> from_config
}

/// Create a DeepSeek provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  openai_compatible.create(name: "deepseek", config: cfg)
}
