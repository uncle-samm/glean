//// When the final answer doesn't match the agent's JSON schema, the model
//// is told what is wrong and asked again; when that doesn't help, the error
//// says what the model wrote and what the run cost.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glean/agent
import glean/error
import glean/message
import glean/provider.{type Provider, GenerateResult, GeneratedText}
import glean/run
import glean/schema
import glean/testing/function_provider
import glean/testing/provider as test_provider
import glean/usage
import gleeunit/should

fn person() -> schema.Schema {
  schema.object(properties: [#("name", schema.string())], required: ["name"])
}

/// A model that gives `answers` in turn, one per call.
fn model_answering(answers: List(String)) -> Provider {
  function_provider.function_provider("test", fn(request) {
    let asked_before =
      list.count(request.messages, fn(msg) {
        case msg {
          message.AssistantMessage(_) -> True
          _ -> False
        }
      })
    let assert [answer, ..] = list.drop(answers, asked_before)
    Ok(test_provider.text_result(answer))
  })
}

fn person_agent(model: Provider) -> agent.Agent(Nil) {
  agent.new(model) |> agent.json_output(schema: Some(person()), name: None)
}

pub fn a_wrong_answer_is_asked_for_again_test() {
  let a = person_agent(model_answering(["{\"age\":3}", "{\"name\":\"Sam\"}"]))

  let assert Ok(result) = run.generate(a, Nil, "Who?")
  result.text |> should.equal("{\"name\":\"Sam\"}")
  result.steps |> should.equal(2)
  // Both calls are paid for.
  result.usage |> should.equal(usage.new(input_tokens: 20, output_tokens: 10))

  // The model saw its own wrong answer and what was wrong with it.
  let assert [_prompt, wrong, retry, _answer] = result.messages
  wrong |> should.equal(message.assistant("{\"age\":3}"))
  let assert message.UserMessage([message.UserText(retry_text)]) = retry
  string.contains(retry_text, "name: Missing required field")
  |> should.be_true
}

pub fn the_retry_is_used_once_by_default_test() {
  let a =
    person_agent(model_answering(["{\"age\":1}", "{\"age\":2}", "{\"age\":3}"]))

  let assert Error(error.OutputValidationError(
    errors:,
    text:,
    finish_reason:,
    messages:,
    usage: used,
  )) = run.generate(a, Nil, "Who?")
  errors
  |> should.equal([
    error.ValidationError(path: ["name"], message: "Missing required field"),
  ])
  // The error carries the last answer, the whole conversation and the
  // tokens of both calls.
  text |> should.equal("{\"age\":2}")
  finish_reason |> should.equal(error.Stop)
  list.length(messages) |> should.equal(4)
  list.last(messages) |> should.equal(Ok(message.assistant("{\"age\":2}")))
  used |> should.equal(usage.new(input_tokens: 20, output_tokens: 10))
}

pub fn retries_can_be_raised_or_turned_off_test() {
  let answers = ["{\"age\":1}", "{\"age\":2}", "{\"name\":\"Sam\"}"]

  let patient =
    person_agent(model_answering(answers)) |> agent.output_retries(2)
  let assert Ok(result) = run.generate(patient, Nil, "Who?")
  result.steps |> should.equal(3)

  let strict = person_agent(model_answering(answers)) |> agent.output_retries(0)
  let assert Error(error.OutputValidationError(text:, messages:, ..)) =
    run.generate(strict, Nil, "Who?")
  text |> should.equal("{\"age\":1}")
  list.length(messages) |> should.equal(2)
}

pub fn a_retry_never_passes_the_step_limit_test() {
  // One step allowed: the wrong answer is the result, not MaxStepsExceeded.
  let a =
    person_agent(model_answering(["{\"age\":1}", "{\"name\":\"Sam\"}"]))
    |> agent.max_steps(1)
  let assert Error(error.OutputValidationError(text:, ..)) =
    run.generate(a, Nil, "Who?")
  text |> should.equal("{\"age\":1}")
}

pub fn a_cut_off_answer_says_so_and_is_not_asked_again_test() {
  let calls = fn(request: provider.GenerateRequest) {
    list.length(request.messages)
  }
  let model =
    function_provider.function_provider("test", fn(request) {
      // Only ever asked once: the prompt is the only message.
      let assert 1 = calls(request)
      Ok(GenerateResult(
        content: [GeneratedText(text: "{\"name\":\"Sa")],
        finish_reason: error.Length,
        usage: usage.new(input_tokens: 7, output_tokens: 3),
        model_id: "test",
      ))
    })

  let assert Error(
    error.OutputValidationError(errors:, text:, finish_reason:, usage: used, ..) as err,
  ) = run.generate(person_agent(model), Nil, "Who?")
  finish_reason |> should.equal(error.Length)
  text |> should.equal("{\"name\":\"Sa")
  used |> should.equal(usage.new(input_tokens: 7, output_tokens: 3))
  let assert [error.ValidationError(path: [], message:)] = errors
  string.contains(message, "cut off at the output token limit")
  |> should.be_true
  string.contains(error.to_string(err), "cut off at the output token limit")
  |> should.be_true
}

pub fn a_refusal_is_not_asked_again_test() {
  let model =
    function_provider.function_provider("test", fn(request) {
      let assert 1 = list.length(request.messages)
      Ok(GenerateResult(
        content: [GeneratedText(text: "I can't help with that.")],
        finish_reason: error.ContentFilter,
        usage: usage.zero(),
        model_id: "test",
      ))
    })
  let assert Error(error.OutputValidationError(finish_reason:, ..)) =
    run.generate(person_agent(model), Nil, "Who?")
  finish_reason |> should.equal(error.ContentFilter)
}

pub fn a_valid_answer_needs_no_retry_test() {
  let a = person_agent(model_answering(["{\"name\":\"Sam\"}"]))
  let assert Ok(result) = run.generate(a, Nil, "Who?")
  result.steps |> should.equal(1)
}

pub fn text_agents_are_never_validated_test() {
  let a = agent.new(model_answering(["not json"]))
  let assert Ok(result) = run.generate(a, Nil, "Hi")
  result.text |> should.equal("not json")
  a.response_format |> should.equal(provider.TextFormat)
  a.output_retries |> should.equal(1)
  a.tool_timeout_ms |> should.equal(None)
}

pub fn max_steps_error_carries_the_usage_test() {
  let model =
    function_provider.function_provider("test", fn(_request) {
      Ok(test_provider.tool_call_result([#("c1", "missing", "{}")]))
    })
  let a = agent.new(model) |> agent.max_steps(2)
  let assert Error(error.MaxStepsExceeded(steps_taken:, usage: used, ..)) =
    run.generate(a, Nil, "Loop")
  steps_taken |> should.equal(2)
  used |> should.equal(usage.new(input_tokens: 20, output_tokens: 10))
}
