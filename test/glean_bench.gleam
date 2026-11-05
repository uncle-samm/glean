//// Micro-benchmarks for glean's own work (encoding, decoding, validation,
//// the run loop). Network time is not measured; it dominates real runs.
////
//// Run with: gleam run -m glean_bench

import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import glean/agent
import glean/message
import glean/provider
import glean/providers/anthropic
import glean/providers/config
import glean/providers/openai_compatible
import glean/run
import glean/schema
import glean/testing/function_provider
import glean/testing/provider as test_provider
import glean/tool
import httpp/sse as httpp_sse

pub fn main() -> Nil {
  io.println("benchmark | iterations | mean per iteration")
  io.println("--- | --- | ---")
  list.each([10, 100, 1000], fn(n) {
    let request = history_request(n)
    let cfg = config.new(api_key: "k", model: "m")
    bench("openai encode " <> int.to_string(n) <> " messages", 200, fn() {
      openai_compatible.encode_request(cfg, request, False)
      Nil
    })
    bench("anthropic encode " <> int.to_string(n) <> " messages", 200, fn() {
      let _ = anthropic.encode_request("m", request, False)
      Nil
    })
  })

  let response_body = openai_response(string.repeat("word ", 2000))
  bench("openai decode 10 KB response", 1000, fn() {
    let _ = openai_compatible.decode_response("m", response_body)
    Nil
  })

  let s = person_schema()
  let input = person_json(500)
  bench("schema.validate_json 500-item array", 200, fn() {
    let _ = schema.validate_json(s, input)
    Nil
  })

  bench("stream 1000 SSE chunks", 20, fn() {
    let subject = process.new_subject()
    let manager = process.new_subject()
    list.each(numbers(1, 1000), fn(_) {
      process.send(subject, httpp_sse.Event(None, None, chunk))
    })
    process.send(subject, httpp_sse.Event(None, None, "[DONE]"))
    let _ =
      openai_compatible.stream_loop(
        subject,
        manager,
        openai_compatible.new_stream_accumulator(),
        fn(_) { Nil },
        "openai",
        "m",
        1000,
      )
    Nil
  })

  let loop_agent = tool_loop_agent(10)
  bench("10-step tool loop (test provider)", 50, fn() {
    let _ = run.generate(loop_agent, Nil, "go")
    Nil
  })
}

const chunk = "{\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"Hi \"}}]}"

fn bench(name: String, iterations: Int, f: fn() -> Nil) -> Nil {
  // Warm up once so code loading isn't measured.
  f()
  let start = timestamp.system_time()
  repeat(iterations, f)
  let elapsed =
    timestamp.difference(start, timestamp.system_time())
    |> duration.to_seconds
  let per_iteration_us = elapsed *. 1_000_000.0 /. int.to_float(iterations)
  io.println(
    name
    <> " | "
    <> int.to_string(iterations)
    <> " | "
    <> float.to_string(float.to_precision(per_iteration_us, 1))
    <> " µs",
  )
}

fn repeat(times: Int, f: fn() -> Nil) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      f()
      repeat(times - 1, f)
    }
  }
}

fn history_request(n: Int) -> provider.GenerateRequest {
  let messages =
    numbers(1, n)
    |> list.map(fn(i) {
      case i % 2 {
        0 -> message.assistant("Answer number " <> int.to_string(i))
        _ -> message.user("Question number " <> int.to_string(i))
      }
    })
  provider.GenerateRequest(
    messages: [message.system("You are terse."), ..messages],
    settings: provider.default_settings(),
    tools: [],
    tool_choice: provider.Auto,
    response_format: provider.TextFormat,
  )
}

fn openai_response(text: String) -> String {
  json.object([
    #("id", json.string("c1")),
    #(
      "choices",
      json.preprocessed_array([
        json.object([
          #(
            "message",
            json.object([
              #("role", json.string("assistant")),
              #("content", json.string(text)),
            ]),
          ),
          #("finish_reason", json.string("stop")),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

fn person_schema() -> schema.Schema {
  schema.object(
    properties: [
      #(
        "people",
        schema.array(of: schema.object(
          properties: [#("name", schema.string()), #("age", schema.int())],
          required: ["name", "age"],
        )),
      ),
    ],
    required: ["people"],
  )
}

fn person_json(n: Int) -> String {
  json.object([
    #(
      "people",
      json.array(numbers(1, n), fn(i) {
        json.object([
          #("name", json.string("Person " <> int.to_string(i))),
          #("age", json.int(i)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn tool_loop_agent(steps: Int) -> agent.Agent(Nil) {
  let p =
    function_provider.function_provider("bench", fn(request) {
      let calls =
        list.count(request.messages, fn(m) {
          case m {
            message.ToolResultMessage(..) -> True
            _ -> False
          }
        })
      case calls < steps - 1 {
        True ->
          Ok(
            test_provider.tool_call_result([
              #("c" <> int.to_string(calls), "echo", "{\"x\":\"hi\"}"),
            ]),
          )
        False -> Ok(test_provider.text_result("done"))
      }
    })
  let echo_tool =
    tool.new(
      name: "echo",
      description: "Echo",
      input_schema: schema.object(
        properties: [#("x", schema.string())],
        required: ["x"],
      ),
      execute: fn(_ctx, _args) { Ok("hi") },
    )
  agent.new(p)
  |> agent.tools(tool.toolset([echo_tool]))
  |> agent.max_steps(steps + 1)
}

/// The integers from `from` to `to`, inclusive.
fn numbers(from: Int, to: Int) -> List(Int) {
  numbers_loop(to, from, [])
}

fn numbers_loop(current: Int, from: Int, acc: List(Int)) -> List(Int) {
  case current < from {
    True -> acc
    False -> numbers_loop(current - 1, from, [current, ..acc])
  }
}
