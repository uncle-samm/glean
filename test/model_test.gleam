import gleam/json
import gleam/option.{None, Some}
import gleam/string
import glean/agent
import glean/message
import glean/models/anthropic as anthropic_model
import glean/models/anthropic_sampling
import glean/models/deepseek
import glean/models/deepseek_reasoning
import glean/models/gemini as gemini_model
import glean/models/minimax as minimax_model
import glean/models/mistral as mistral_model
import glean/models/moonshot as moonshot_model
import glean/models/openai
import glean/models/openai_reasoning
import glean/models/qwen as qwen_model
import glean/provider
import glean/providers/config
import glean/providers/deepseek as deepseek_provider
import glean/providers/openai_compatible
import gleeunit/should

pub fn openai_gpt_builder_test() {
  let model =
    openai.gpt4_1(api_key: "test-key")
    |> openai.temperature(0.7)
    |> openai.top_p(0.9)
    |> openai.seed(42)
    |> openai.presence_penalty(0.5)
    |> openai.frequency_penalty(0.3)
    |> openai.max_output_tokens(1000)
    |> openai.stop_sequences(["END"])
    |> openai.build

  model.provider.name |> should.equal("openai")
  model.provider.model_id |> should.equal("gpt-4.1")
  model.settings.temperature |> should.equal(Some(0.7))
  model.settings.top_p |> should.equal(Some(0.9))
  model.settings.seed |> should.equal(Some(42))
  model.settings.presence_penalty |> should.equal(Some(0.5))
  model.settings.frequency_penalty |> should.equal(Some(0.3))
  model.settings.max_output_tokens |> should.equal(Some(1000))
  model.settings.stop_sequences |> should.equal(Some(["END"]))
  model.settings.top_k |> should.equal(None)
}

pub fn openai_reasoning_builder_test() {
  let model =
    openai_reasoning.gpt5_5(api_key: "test-key")
    |> openai_reasoning.max_output_tokens(500)
    |> openai_reasoning.reasoning_effort(provider.HighEffort)
    |> openai_reasoning.build

  model.provider.name |> should.equal("openai")
  model.provider.model_id |> should.equal("gpt-5.5")
  model.settings.max_output_tokens |> should.equal(Some(500))
  model.settings.reasoning_effort |> should.equal(Some(provider.HighEffort))
  model.settings.temperature |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
}

pub fn anthropic_current_builder_test() {
  let model =
    anthropic_model.opus_5_5(api_key: "test-key")
    |> anthropic_model.max_output_tokens(2000)
    |> anthropic_model.stop_sequences(["STOP"])
    |> anthropic_model.reasoning_effort(provider.LowEffort)
    |> anthropic_model.build

  model.provider.name |> should.equal("anthropic")
  model.provider.model_id |> should.equal("claude-opus-5-5")
  model.settings.max_output_tokens |> should.equal(Some(2000))
  model.settings.reasoning_effort |> should.equal(Some(provider.LowEffort))
  // Current Claude models reject sampling parameters.
  model.settings.temperature |> should.equal(None)
  model.settings.top_p |> should.equal(None)
  model.settings.top_k |> should.equal(None)
}

pub fn anthropic_sampling_builder_test() {
  let model =
    anthropic_sampling.haiku_4_5(api_key: "test-key")
    |> anthropic_sampling.temperature(0.5)
    |> anthropic_sampling.top_p(0.8)
    |> anthropic_sampling.top_k(40)
    |> anthropic_sampling.build

  model.provider.model_id |> should.equal("claude-haiku-4-5")
  model.settings.temperature |> should.equal(Some(0.5))
  model.settings.top_p |> should.equal(Some(0.8))
  model.settings.top_k |> should.equal(Some(40))
  model.settings.seed |> should.equal(None)
}

pub fn gemini_builder_test() {
  let model =
    gemini_model.flash_3_8(api_key: "test-key")
    |> gemini_model.temperature(0.2)
    |> gemini_model.top_k(20)
    |> gemini_model.seed(7)
    |> gemini_model.build

  model.provider.name |> should.equal("gemini")
  model.provider.model_id |> should.equal("gemini-3.8-flash")
  model.settings.top_k |> should.equal(Some(20))
  model.settings.seed |> should.equal(Some(7))
}

pub fn mistral_builder_test() {
  let model =
    mistral_model.medium_3_5(api_key: "test-key")
    |> mistral_model.temperature(0.3)
    |> mistral_model.build
  model.provider.name |> should.equal("mistral")
  model.provider.model_id |> should.equal("mistral-medium-2604")
  model.settings.temperature |> should.equal(Some(0.3))
}

pub fn moonshot_minimax_qwen_builders_test() {
  let kimi = moonshot_model.kimi_k3(api_key: "k") |> moonshot_model.build
  kimi.provider.model_id |> should.equal("kimi-k3")

  let mm =
    minimax_model.m3(api_key: "k")
    |> minimax_model.max_output_tokens(100)
    |> minimax_model.build
  mm.provider.model_id |> should.equal("MiniMax-M3")
  mm.settings.temperature |> should.equal(None)

  let q =
    qwen_model.qwen3_7_plus(api_key: "k")
    |> qwen_model.top_k(10)
    |> qwen_model.build
  q.provider.model_id |> should.equal("qwen3.7-plus")
  q.settings.top_k |> should.equal(Some(10))
}

pub fn custom_model_id_test() {
  let model =
    anthropic_model.custom(api_key: "k", model: "claude-next")
    |> anthropic_model.build
  model.provider.model_id |> should.equal("claude-next")

  let model =
    openai.custom(api_key: "k", model: "my-fine-tune")
    |> openai.configure(config.base_url(_, "http://localhost:8080/v1"))
    |> openai.build
  model.provider.model_id |> should.equal("my-fine-tune")
}

fn deepseek_body(cfg: config.ProviderConfig) -> String {
  let request =
    provider.GenerateRequest(
      messages: [message.user("hi")],
      tools: [],
      tool_choice: provider.Auto,
      settings: provider.default_settings(),
      response_format: provider.TextFormat,
    )
  openai_compatible.encode_request(cfg, request, False)
}

pub fn deepseek_thinking_toggle_test() {
  // The builders differ only in the `thinking` field they send.
  let off =
    deepseek_provider.default_config(api_key: "k", model: "deepseek-flash")
    |> config.extra_body_field(
      "thinking",
      json.object([#("type", json.string("disabled"))]),
    )
  deepseek_body(off)
  |> string.contains("\"thinking\":{\"type\":\"disabled\"}")
  |> should.be_true

  // Setting the same extra field twice keeps only the last value.
  let on =
    off
    |> config.extra_body_field(
      "thinking",
      json.object([#("type", json.string("enabled"))]),
    )
  let body = deepseek_body(on)
  body |> string.contains("\"enabled\"") |> should.be_true
  body |> string.contains("\"disabled\"") |> should.be_false

  // Both builders still compile and point at the same model IDs.
  let a = deepseek.flash(api_key: "k") |> deepseek.temperature(0.1) |> deepseek.build
  a.provider.model_id |> should.equal("deepseek-flash")
  let b =
    deepseek_reasoning.v4_pro(api_key: "k")
    |> deepseek_reasoning.reasoning_effort(provider.MediumEffort)
    |> deepseek_reasoning.build
  b.provider.model_id |> should.equal("deepseek-v4-pro")
  b.settings.temperature |> should.equal(None)
}

pub fn agent_from_model_test() {
  let model = openai_reasoning.gpt5_nano(api_key: "k") |> openai_reasoning.build
  let a = agent.from(model)
  a.provider.model_id |> should.equal("gpt-5-nano")
}
