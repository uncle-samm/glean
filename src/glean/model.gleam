/// Model type — the output of per-model builder types.
/// Bridges type-safe model configuration to the Agent system.
import gleam/io
import glean/provider.{type ModelSettings, type Provider}

/// A configured model ready to be used with an agent.
/// Created by calling `build()` on a per-model builder type.
pub type Model {
  Model(provider: Provider, settings: ModelSettings)
}

/// Log a deprecation warning at runtime.
/// Called by deprecated model modules in their `build()` function
/// before swapping to the replacement model.
pub fn deprecation_warning(
  deprecated_model: String,
  replacement_model: String,
  shutdown_date: String,
) -> Nil {
  io.println(
    "[glean] WARNING: "
    <> deprecated_model
    <> " is deprecated (shutdown: "
    <> shutdown_date
    <> "). Using "
    <> replacement_model
    <> " instead.",
  )
}
