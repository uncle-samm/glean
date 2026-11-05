//// A configured model, ready to pass to `agent.new`.
////
//// Build one with a model module, e.g.
//// `glean/models/anthropic.opus_5_5(key) |> anthropic.build`.

import glean/provider.{type ModelSettings, type Provider}

/// A provider plus the settings the model builder chose for it.
pub type Model {
  Model(provider: Provider, settings: ModelSettings)
}
