/// OpenRouter provider — routes to any model via unified API.
/// Fully OpenAI-compatible API.
import glean/provider.{type Provider}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai_compatible

const base_url = "https://openrouter.ai/api/v1"

/// Create an OpenRouter provider.
/// Model names are prefixed with provider, e.g. "openai/gpt-4o", "anthropic/claude-sonnet-4-20250514".
///
/// ## Example
///
/// ```gleam
/// let provider = openrouter.new(api_key: "sk-or-...", model: "anthropic/claude-sonnet-4-20250514")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
  |> from_config
}

/// Create an OpenRouter provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  openai_compatible.create(name: "openrouter", config: cfg)
}
