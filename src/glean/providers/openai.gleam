/// OpenAI provider (GPT-4o, GPT-4, o1, o3, etc.)
import glean/provider.{type Provider}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai_compatible

const base_url = "https://api.openai.com/v1"

/// Create an OpenAI provider.
///
/// ## Example
///
/// ```gleam
/// let provider = openai.new(api_key: "sk-...", model: "gpt-4o")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
  |> from_config
}

/// Create an OpenAI provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  openai_compatible.create(name: "openai", config: cfg)
}
