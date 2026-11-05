/// End-to-end tests exercising real tool calls, streaming, and structured output.
/// Simulates the kind of workflows used in production backends:
/// web search, web fetch, multi-tool orchestration, and structured extraction.
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import glean/agent
import glean/error
import glean/message
import glean/models/anthropic_sampling as anthropic_model
import glean/models/openai_reasoning as openai_model
import glean/provider
import glean/providers/anthropic
import glean/providers/openai
import glean/run
import glean/schema
import glean/stream
import glean/tool
import integration/integration_helpers.{fail, get_api_key}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

/// Web fetch tool — fetches a URL and returns the response body (truncated).
fn web_fetch_tool() -> tool.Tool(Nil) {
  tool.new(
    name: "web_fetch",
    description: "Fetch the content of a web page given its URL. Returns the raw HTML/text content, truncated to 2000 characters.",
    input_schema: schema.object(
      properties: [
        #(
          "url",
          schema.string()
            |> schema.describe(
              "The full URL to fetch (must start with https://)",
            ),
        ),
      ],
      required: ["url"],
    ),
    execute: fn(_ctx, args_json) {
      let decoder = {
        use url <- decode.field("url", decode.string)
        decode.success(url)
      }
      case json.parse(args_json, decoder) {
        Error(_) ->
          Error(error.ToolExecutionError(
            tool_name: "web_fetch",
            tool_call_id: "",
            reason: "Failed to parse URL from arguments",
          ))
        Ok(url) -> do_web_fetch(url)
      }
    },
  )
}

fn do_web_fetch(url: String) -> Result(String, error.GleanError) {
  case request.to(url) {
    Error(_) ->
      Error(error.ToolExecutionError(
        tool_name: "web_fetch",
        tool_call_id: "",
        reason: "Invalid URL: " <> url,
      ))
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header(
          "user-agent",
          "Mozilla/5.0 (compatible; GleanBot/1.0)",
        )
      case httpc.send(req) {
        Error(_) ->
          Error(error.ToolExecutionError(
            tool_name: "web_fetch",
            tool_call_id: "",
            reason: "HTTP request failed for: " <> url,
          ))
        Ok(resp) ->
          case resp.status >= 200 && resp.status < 400 {
            True -> Ok(string.slice(resp.body, 0, 2000))
            False ->
              Error(error.ToolExecutionError(
                tool_name: "web_fetch",
                tool_call_id: "",
                reason: "HTTP " <> int.to_string(resp.status) <> " for: " <> url,
              ))
          }
      }
    }
  }
}

/// Calculator tool for multi-tool orchestration.
fn calculator_tool() -> tool.Tool(Nil) {
  tool.new(
    name: "calculator",
    description: "Perform basic arithmetic. Supports add, subtract, multiply, divide.",
    input_schema: schema.object(
      properties: [
        #(
          "operation",
          schema.string_enum(values: ["add", "subtract", "multiply", "divide"])
            |> schema.describe("The arithmetic operation"),
        ),
        #("a", schema.float() |> schema.describe("First number")),
        #("b", schema.float() |> schema.describe("Second number")),
      ],
      required: ["operation", "a", "b"],
    ),
    execute: fn(_ctx, args_json) {
      let decoder = {
        use op <- decode.field("operation", decode.string)
        use a <- decode.field("a", decode.float)
        use b <- decode.field("b", decode.float)
        decode.success(#(op, a, b))
      }
      case json.parse(args_json, decoder) {
        Error(_) ->
          Error(error.ToolExecutionError(
            tool_name: "calculator",
            tool_call_id: "",
            reason: "Invalid calculator arguments",
          ))
        Ok(#(op, a, b)) -> {
          case op {
            "add" -> Ok(float_to_string(a +. b))
            "subtract" -> Ok(float_to_string(a -. b))
            "multiply" -> Ok(float_to_string(a *. b))
            "divide" ->
              case b {
                0.0 ->
                  Error(error.ToolExecutionError(
                    tool_name: "calculator",
                    tool_call_id: "",
                    reason: "Division by zero",
                  ))
                _ -> Ok(float_to_string(a /. b))
              }
            _ ->
              Error(error.ToolExecutionError(
                tool_name: "calculator",
                tool_call_id: "",
                reason: "Unknown operation: " <> op,
              ))
          }
        }
      }
    },
  )
}

fn float_to_string(f: Float) -> String {
  // Return a clean string representation
  json.object([#("result", json.float(f))]) |> json.to_string
}

/// Get current date/time tool.
fn get_current_info_tool() -> tool.Tool(Nil) {
  tool.new(
    name: "get_current_info",
    description: "Get current date and basic system information.",
    input_schema: schema.object(
      properties: [
        #(
          "info_type",
          schema.string_enum(values: ["date", "time", "timezone"])
            |> schema.describe("What information to retrieve"),
        ),
      ],
      required: ["info_type"],
    ),
    execute: fn(_ctx, args_json) {
      let decoder = {
        use info_type <- decode.field("info_type", decode.string)
        decode.success(info_type)
      }
      case json.parse(args_json, decoder) {
        Error(_) -> Ok("2026-03-08")
        Ok(info_type) ->
          case info_type {
            "date" -> Ok("2026-03-08")
            "time" -> Ok("14:30:00 UTC")
            "timezone" -> Ok("UTC")
            _ -> Ok("2026-03-08")
          }
      }
    },
  )
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

fn test_settings() -> provider.ModelSettings {
  provider.ModelSettings(..provider.default_settings(), max_output_tokens: Some(1500))
}

// ---------------------------------------------------------------------------
// Tests: Web Fetch
// ---------------------------------------------------------------------------

/// Agent fetches a URL and summarizes the content (OpenAI).
pub fn e2e_web_fetch_openai_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.system(
          "You are a web research assistant. When asked about a website, use the web_fetch tool to retrieve it, then summarize what you find. Be concise.",
        )
        |> agent.tools(tool.toolset([web_fetch_tool()]))
        |> agent.settings(test_settings())
        |> agent.max_steps(5)

      case
        run.generate(
          a,
          Nil,
          "Fetch https://httpbin.org/json and tell me what keys are in the JSON response.",
        )
      {
        Ok(result) -> {
          io.println(
            "[e2e_web_fetch_openai] Steps: "
            <> int.to_string(result.steps)
            <> " | Tokens: "
            <> int.to_string(
              result.usage.input_tokens + result.usage.output_tokens,
            ),
          )
          io.println("[e2e_web_fetch_openai] Response: " <> result.text)
          let assert True = result.steps >= 2
          integration_helpers.assert_non_empty_text(result.text)
        }
        Error(err) -> fail("e2e web fetch OpenAI", err)
      }
    }
  }
}

/// Agent fetches a URL and summarizes the content (Anthropic).
pub fn e2e_web_fetch_anthropic_test() {
  case get_api_key("ANTHROPIC_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider =
        anthropic.new(api_key: api_key, model: "claude-haiku-4-5-20251001")
      let a =
        agent.new(provider)
        |> agent.system(
          "You are a web research assistant. Use the web_fetch tool to retrieve web pages. Be concise.",
        )
        |> agent.tools(tool.toolset([web_fetch_tool()]))
        |> agent.settings(test_settings())
        |> agent.max_steps(5)

      case
        run.generate(
          a,
          Nil,
          "Fetch https://httpbin.org/get and tell me what the response contains.",
        )
      {
        Ok(result) -> {
          io.println(
            "[e2e_web_fetch_anthropic] Steps: "
            <> int.to_string(result.steps)
            <> " | Tokens: "
            <> int.to_string(
              result.usage.input_tokens + result.usage.output_tokens,
            ),
          )
          io.println("[e2e_web_fetch_anthropic] Response: " <> result.text)
          let assert True = result.steps >= 2
          integration_helpers.assert_non_empty_text(result.text)
        }
        Error(err) -> fail("e2e web fetch Anthropic", err)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tests: Multi-tool orchestration
// ---------------------------------------------------------------------------

/// Agent has fetch + calculator + info tools — must chain them.
pub fn e2e_multi_tool_orchestration_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.system(
          "You are a helpful assistant with access to a calculator, current info, and web fetch tools. Use the appropriate tools to answer questions. Be concise.",
        )
        |> agent.tools(
          tool.toolset([
            calculator_tool(),
            get_current_info_tool(),
            web_fetch_tool(),
          ]),
        )
        |> agent.settings(test_settings())
        |> agent.max_steps(6)

      case
        run.generate(
          a,
          Nil,
          "What is today's date? Also calculate 847 * 23 for me.",
        )
      {
        Ok(result) -> {
          io.println(
            "[e2e_multi_tool] Steps: "
            <> int.to_string(result.steps)
            <> " | Tokens: "
            <> int.to_string(
              result.usage.input_tokens + result.usage.output_tokens,
            ),
          )
          io.println("[e2e_multi_tool] Response: " <> result.text)
          let assert True = result.steps >= 2
          integration_helpers.assert_non_empty_text(result.text)
          // Response should contain the calculation result (19481)
          let assert True =
            string.contains(result.text, "19481")
            || string.contains(result.text, "19,481")
          Nil
        }
        Error(err) -> fail("e2e multi-tool orchestration", err)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tests: Streaming with tools
// ---------------------------------------------------------------------------

/// Streaming with tool calls — verify we get results and tool usage.
pub fn e2e_streaming_with_tools_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.system(
          "You are a helpful assistant. Use the calculator tool when asked to compute. Be concise.",
        )
        |> agent.tools(tool.toolset([calculator_tool()]))
        |> agent.settings(test_settings())
        |> agent.max_steps(5)

      // Use stream — even though provider currently falls back to non-streaming,
      // the agent loop still emits StepStart/StepEnd/ToolResult/Finish events.
      // Log events as they arrive.
      case
        run.stream(a, Nil, "What is 15 multiplied by 7?", fn(event) {
          case event {
            stream.StepStart(step) ->
              io.println("[e2e_streaming] StepStart: " <> int.to_string(step))
            stream.StepEnd(step) ->
              io.println("[e2e_streaming] StepEnd: " <> int.to_string(step))
            stream.ToolResultEvent(_, tool_name, output) ->
              io.println(
                "[e2e_streaming] ToolResult(" <> tool_name <> "): " <> output,
              )
            stream.Finish(_, finish_usage) ->
              io.println(
                "[e2e_streaming] Finish — tokens: "
                <> int.to_string(
                  finish_usage.input_tokens + finish_usage.output_tokens,
                ),
              )
            _ -> Nil
          }
        })
      {
        Ok(result) -> {
          io.println(
            "[e2e_streaming] Steps: "
            <> int.to_string(result.steps)
            <> " | Response: "
            <> result.text,
          )

          // Should have used the tool (at least 2 steps)
          let assert True = result.steps >= 2

          // Final result should contain 105
          let assert True = string.contains(result.text, "105")
          Nil
        }
        Error(err) -> fail("e2e streaming with tools", err)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tests: Structured output
// ---------------------------------------------------------------------------

/// Structured output via JSON response format — agent returns valid JSON.
pub fn e2e_structured_output_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let response_schema =
        schema.object(
          properties: [
            #("name", schema.string() |> schema.describe("Country name")),
            #(
              "capital",
              schema.string() |> schema.describe("Capital city name"),
            ),
            #(
              "population_millions",
              schema.float()
                |> schema.describe("Approximate population in millions"),
            ),
            #(
              "continent",
              schema.string_enum(values: [
                "Africa", "Asia", "Europe", "North America", "South America",
                "Oceania", "Antarctica",
              ]),
            ),
          ],
          required: ["name", "capital", "population_millions", "continent"],
        )

      let oai_provider = openai.new(api_key: api_key, model: "gpt-5-nano")

      // Call the provider directly with structured output format
      let request =
        provider.GenerateRequest(
          messages: [
            message.system(
              "You extract country information into structured JSON. Only output JSON.",
            ),
            message.user("Extract info about France."),
          ],
          settings: test_settings(),
          tools: [],
          tool_choice: provider.Auto,
          response_format: provider.JsonFormat(
            schema: Some(response_schema),
            name: Some("country_info"),
          ),
        )

      case oai_provider.generate(request) {
        Ok(result) -> {
          let text = provider.result_text(result)
          io.println("[e2e_structured_output] Response: " <> text)

          // Should be valid JSON matching our schema
          // population_millions may come back as int or float from the API
          let number_decoder =
            decode.one_of(decode.float, [
              decode.int |> decode.map(int.to_float),
            ])
          let decoder = {
            use name <- decode.field("name", decode.string)
            use capital <- decode.field("capital", decode.string)
            use _population <- decode.field(
              "population_millions",
              number_decoder,
            )
            use continent <- decode.field("continent", decode.string)
            decode.success(#(name, capital, continent))
          }
          case json.parse(text, decoder) {
            Ok(#(name, capital, continent)) -> {
              io.println(
                "[e2e_structured_output] Parsed: "
                <> name
                <> ", "
                <> capital
                <> ", "
                <> continent,
              )
              let assert True =
                string.contains(string.lowercase(name), "france")
              let assert True =
                string.contains(string.lowercase(capital), "paris")
              let assert True = continent == "Europe"
              Nil
            }
            Error(_) ->
              panic as "Structured output was not valid JSON matching schema"
          }
        }
        Error(err) -> fail("e2e structured output", err)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tests: Model type builder -> agent.from -> tools
// ---------------------------------------------------------------------------

/// Type-safe model builder -> agent.from -> tool calling (OpenAI).
pub fn e2e_model_type_with_tools_openai_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        openai_model.gpt5(api_key: api_key)
        |> openai_model.max_output_tokens(1500)
        |> openai_model.build

      let a =
        agent.from(model)
        |> agent.system(
          "You are a helpful assistant. Use tools when appropriate. Be concise.",
        )
        |> agent.tools(
          tool.toolset([calculator_tool(), get_current_info_tool()]),
        )
        |> agent.max_steps(5)

      case
        run.generate(
          a,
          Nil,
          "What's today's date? And what is 256 divided by 16?",
        )
      {
        Ok(result) -> {
          io.println(
            "[e2e_model_type_tools_openai] Steps: "
            <> int.to_string(result.steps)
            <> " | Response: "
            <> result.text,
          )
          let assert True = result.steps >= 2
          integration_helpers.assert_non_empty_text(result.text)
          // Should contain 16 (256/16 = 16)
          let assert True = string.contains(result.text, "16")
          Nil
        }
        Error(err) -> fail("e2e model type with tools (OpenAI)", err)
      }
    }
  }
}

/// Type-safe model builder -> agent.from -> tool calling (Anthropic).
pub fn e2e_model_type_with_tools_anthropic_test() {
  case get_api_key("ANTHROPIC_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let model =
        anthropic_model.haiku_4_5(api_key: api_key)
        |> anthropic_model.max_output_tokens(1500)
        |> anthropic_model.build

      let a =
        agent.from(model)
        |> agent.system(
          "You are a concise assistant. Use the calculator when asked to compute.",
        )
        |> agent.tools(tool.toolset([calculator_tool()]))
        |> agent.max_steps(5)

      case
        run.generate(
          a,
          Nil,
          "Calculate 99 times 101 using the calculator tool.",
        )
      {
        Ok(result) -> {
          io.println(
            "[e2e_model_type_tools_anthropic] Steps: "
            <> int.to_string(result.steps)
            <> " | Response: "
            <> result.text,
          )
          let assert True = result.steps >= 2
          // 99 * 101 = 9999
          let assert True =
            string.contains(result.text, "9999")
            || string.contains(result.text, "9,999")
          Nil
        }
        Error(err) -> fail("e2e model type with tools (Anthropic)", err)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Tests: Multi-turn with tools
// ---------------------------------------------------------------------------

/// Multi-turn conversation with tool calls — verify context persists.
pub fn e2e_multi_turn_with_tools_test() {
  case get_api_key("OPENAI_API_KEY") {
    Error(Nil) -> Nil
    Ok(api_key) -> {
      let provider = openai.new(api_key: api_key, model: "gpt-5-nano")
      let a =
        agent.new(provider)
        |> agent.system(
          "You are a math tutor. Use the calculator tool for computations. Be concise.",
        )
        |> agent.tools(tool.toolset([calculator_tool()]))
        |> agent.settings(test_settings())
        |> agent.max_steps(5)

      // Turn 1: Ask for a calculation
      case run.generate(a, Nil, "What is 42 * 38?") {
        Ok(result1) -> {
          io.println("[e2e_multi_turn] Turn 1: " <> result1.text)
          let assert True =
            string.contains(result1.text, "1596")
            || string.contains(result1.text, "1,596")

          // Turn 2: Follow-up referencing previous result
          case run.continue(a, Nil, result1, "Now divide that result by 6.") {
            Ok(result2) -> {
              io.println("[e2e_multi_turn] Turn 2: " <> result2.text)
              // 1596 / 6 = 266
              let assert True = string.contains(result2.text, "266")
              Nil
            }
            Error(err) -> fail("e2e multi-turn turn 2", err)
          }
        }
        Error(err) -> fail("e2e multi-turn turn 1", err)
      }
    }
  }
}
