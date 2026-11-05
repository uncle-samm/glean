/// Mistral AI provider (mistral-large, mistral-medium, mistral-small, etc.)
/// Fully OpenAI-compatible API.
import glean/provider.{type Provider}
import glean/providers/config.{type ProviderConfig}
import glean/providers/openai_compatible

const base_url = "https://api.mistral.ai/v1"

/// The default configuration for this provider. Change it with the
/// `glean/providers/config` setters, then pass it to `from_config`.
pub fn default_config(
  api_key api_key: String,
  model model: String,
) -> ProviderConfig {
  config.new(api_key: api_key, model: model)
  |> config.base_url(base_url)
  |> config.max_tokens_field("max_tokens")
}

/// Create a Mistral provider.
///
/// ## Example
///
/// ```gleam
/// let provider = mistral.new(api_key: "...", model: "mistral-large-latest")
/// ```
pub fn new(api_key api_key: String, model model: String) -> Provider {
  default_config(api_key: api_key, model: model)
  |> from_config
}

/// Create a Mistral provider from a full config.
pub fn from_config(cfg: ProviderConfig) -> Provider {
  let cfg = case cfg.base_url {
    "" -> config.base_url(cfg, base_url)
    _ -> cfg
  }
  openai_compatible.create(name: "mistral", config: cfg)
}
