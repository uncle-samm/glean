import gleam/option.{None, Some}
import glean/agent
import glean/models/anthropic as anthropic_model
import glean/models/deepseek
import glean/models/deepseek_reasoning
import glean/models/gemini as gemini_model
import glean/models/minimax as minimax_model
import glean/models/mistral as mistral_model
import glean/models/moonshot as moonshot_model
import glean/models/openai
import glean/models/openai_reasoning
import glean/models/qwen as qwen_model
import gleeunit/should

pub fn openai_gpt_builder_test() {
  // Build a GPT model with all supported params
  let model =
    openai.gpt5_4(api_key: "test-key")
    |> openai.temperature(0.7)
    |> openai.top_p(0.9)
    |> openai.seed(42)
    |> openai.presence_penalty(0.5)
    |> openai.frequency_penalty(0.3)
    |> openai.max_output_tokens(1000)
    |> openai.stop_sequences(["END"])
    |> openai.build

  model.provider.name |> should.equal("openai")
  model.provider.model_id |> should.equal("gpt-5.4")
  model.settings.temperature |> should.equal(Some(0.7))
  model.settings.top_p |> should.equal(Some(0.9))
  model.settings.seed |> should.equal(Some(42))
  model.settings.presence_penalty |> should.equal(Some(0.5))
  model.settings.frequency_penalty |> should.equal(Some(0.3))
  model.settings.max_output_tokens |> should.equal(Some(1000))
  model.settings.stop_sequences |> should.equal(Some(["END"]))
  // top_k is not supported by OpenAI GPT
  model.settings.top_k |> should.equal(None)
}

pub fn openai_reasoning_builder_test() {
  // Reasoning model: only max_output_tokens and stop_sequences
  let model =
    openai_reasoning.gpt5_nano(api_key: "test-key")
    |> openai_reasoning.max_output_tokens(500)
    |> openai_reasoning.build

  model.provider.name |> should.equal("openai")
  model.provider.model_id |> should.equal("gpt-5-nano")
  model.settings.max_output_tokens |> should.equal(Some(500))
  // Not supported by reasoning models
  model.settings.temperature |> should.equal(None)
  model.settings.top_p |> should.equal(None)
  model.settings.top_k |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
}

pub fn anthropic_claude_builder_test() {
  let model =
    anthropic_model.haiku_4_5(api_key: "test-key")
    |> anthropic_model.temperature(0.5)
    |> anthropic_model.top_p(0.8)
    |> anthropic_model.top_k(40)
    |> anthropic_model.stop_sequences(["STOP", "END"])
    |> anthropic_model.max_output_tokens(2000)
    |> anthropic_model.build

  model.provider.name |> should.equal("anthropic")
  model.provider.model_id |> should.equal("claude-haiku-4-5-20251001")
  model.settings.temperature |> should.equal(Some(0.5))
  model.settings.top_p |> should.equal(Some(0.8))
  model.settings.top_k |> should.equal(Some(40))
  model.settings.stop_sequences |> should.equal(Some(["STOP", "END"]))
  model.settings.max_output_tokens |> should.equal(Some(2000))
  // Not supported by Anthropic
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn gemini_builder_test() {
  let model =
    gemini_model.flash_2_5(api_key: "test-key")
    |> gemini_model.temperature(1.0)
    |> gemini_model.top_p(0.95)
    |> gemini_model.top_k(50)
    |> gemini_model.seed(123)
    |> gemini_model.stop_sequences(["<END>"])
    |> gemini_model.max_output_tokens(4096)
    |> gemini_model.build

  model.provider.name |> should.equal("gemini")
  model.provider.model_id |> should.equal("gemini-2.5-flash")
  model.settings.temperature |> should.equal(Some(1.0))
  model.settings.top_p |> should.equal(Some(0.95))
  model.settings.top_k |> should.equal(Some(50))
  model.settings.seed |> should.equal(Some(123))
  model.settings.stop_sequences |> should.equal(Some(["<END>"]))
  model.settings.max_output_tokens |> should.equal(Some(4096))
  // Not supported by Gemini
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn mistral_builder_test() {
  let model =
    mistral_model.small_3_2(api_key: "test-key")
    |> mistral_model.temperature(0.8)
    |> mistral_model.top_p(0.9)
    |> mistral_model.max_output_tokens(512)
    |> mistral_model.build

  model.provider.name |> should.equal("mistral")
  model.provider.model_id |> should.equal("mistral-small-latest")
  model.settings.temperature |> should.equal(Some(0.8))
  model.settings.top_p |> should.equal(Some(0.9))
  model.settings.max_output_tokens |> should.equal(Some(512))
  // Not supported by Mistral
  model.settings.top_k |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn deepseek_chat_builder_test() {
  let model =
    deepseek.chat(api_key: "test-key")
    |> deepseek.temperature(1.2)
    |> deepseek.top_p(0.85)
    |> deepseek.stop_sequences(["###"])
    |> deepseek.max_output_tokens(800)
    |> deepseek.build

  model.provider.name |> should.equal("deepseek")
  model.provider.model_id |> should.equal("deepseek-chat")
  model.settings.temperature |> should.equal(Some(1.2))
  model.settings.top_p |> should.equal(Some(0.85))
  model.settings.stop_sequences |> should.equal(Some(["###"]))
  model.settings.max_output_tokens |> should.equal(Some(800))
  // Not supported by DeepSeek chat
  model.settings.top_k |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn deepseek_reasoning_builder_test() {
  let model =
    deepseek_reasoning.reasoner(api_key: "test-key")
    |> deepseek_reasoning.max_output_tokens(1500)
    |> deepseek_reasoning.build

  model.provider.name |> should.equal("deepseek")
  model.provider.model_id |> should.equal("deepseek-reasoner")
  model.settings.max_output_tokens |> should.equal(Some(1500))
  // Not supported by DeepSeek reasoning
  model.settings.temperature |> should.equal(None)
  model.settings.top_p |> should.equal(None)
  model.settings.top_k |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn qwen_builder_test() {
  let model =
    qwen_model.qwen_turbo(api_key: "test-key")
    |> qwen_model.temperature(0.6)
    |> qwen_model.top_p(0.7)
    |> qwen_model.top_k(20)
    |> qwen_model.seed(99)
    |> qwen_model.stop_sequences(["<|endoftext|>"])
    |> qwen_model.max_output_tokens(2048)
    |> qwen_model.build

  model.provider.name |> should.equal("qwen")
  model.provider.model_id |> should.equal("qwen-turbo")
  model.settings.temperature |> should.equal(Some(0.6))
  model.settings.top_p |> should.equal(Some(0.7))
  model.settings.top_k |> should.equal(Some(20))
  model.settings.seed |> should.equal(Some(99))
  model.settings.stop_sequences |> should.equal(Some(["<|endoftext|>"]))
  model.settings.max_output_tokens |> should.equal(Some(2048))
  // Not supported by Qwen
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn moonshot_builder_test() {
  let model =
    moonshot_model.kimi_k2_5(api_key: "test-key")
    |> moonshot_model.temperature(0.3)
    |> moonshot_model.top_p(0.6)
    |> moonshot_model.max_output_tokens(3000)
    |> moonshot_model.build

  model.provider.name |> should.equal("moonshot")
  model.provider.model_id |> should.equal("kimi-k2.5")
  model.settings.temperature |> should.equal(Some(0.3))
  model.settings.top_p |> should.equal(Some(0.6))
  model.settings.max_output_tokens |> should.equal(Some(3000))
  // Not supported by Moonshot
  model.settings.top_k |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

pub fn minimax_builder_test() {
  let model =
    minimax_model.m2_5(api_key: "test-key")
    |> minimax_model.temperature(0.9)
    |> minimax_model.top_p(0.75)
    |> minimax_model.max_output_tokens(1024)
    |> minimax_model.build

  model.provider.name |> should.equal("minimax")
  model.provider.model_id |> should.equal("MiniMax-M2.5")
  model.settings.temperature |> should.equal(Some(0.9))
  model.settings.top_p |> should.equal(Some(0.75))
  model.settings.max_output_tokens |> should.equal(Some(1024))
  // Not supported by MiniMax
  model.settings.top_k |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}

@deprecated("Testing deprecated model — suppressing compiler warning.")
pub fn deprecated_model_fallback_test() {
  // Deprecated models swap to replacement model_id at build time
  let model = openai.gpt4o(api_key: "test-key") |> openai.build
  // Should use gpt-5 as the replacement
  model.provider.model_id |> should.equal("gpt-5")
}

pub fn agent_from_model_test() {
  let model =
    openai_reasoning.gpt5_nano(api_key: "test-key")
    |> openai_reasoning.max_output_tokens(1000)
    |> openai_reasoning.build

  let a = agent.from(model)
  a.provider.name |> should.equal("openai")
  a.provider.model_id |> should.equal("gpt-5-nano")
  a.settings.max_output_tokens |> should.equal(Some(1000))
}

pub fn model_defaults_test() {
  let model = openai.gpt5(api_key: "test-key") |> openai.build
  model.settings.temperature |> should.equal(None)
  model.settings.top_p |> should.equal(None)
  model.settings.seed |> should.equal(None)
  model.settings.max_output_tokens |> should.equal(None)
  model.settings.stop_sequences |> should.equal(None)
  model.settings.top_k |> should.equal(None)
  model.settings.presence_penalty |> should.equal(None)
  model.settings.frequency_penalty |> should.equal(None)
}
