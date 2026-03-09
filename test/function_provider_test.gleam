import gleam/list
import glean/agent
import glean/error
import glean/run
import glean/testing/function_provider
import glean/testing/provider
import gleeunit/should

pub fn function_provider_basic_test() {
  // Handler returns fixed text
  let p =
    function_provider.function_provider("test", fn(_request) {
      Ok(provider.text_result("Hello from function!"))
    })
  let a = agent.new(p)
  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("Hello from function!")
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn function_provider_conditional_test() {
  // Handler changes response based on number of messages
  let p =
    function_provider.function_provider("test", fn(request) {
      case list.length(request.messages) {
        n if n <= 2 -> Ok(provider.text_result("First"))
        _ -> Ok(provider.text_result("Later"))
      }
    })
  let a = agent.new(p)
  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("First")
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn function_provider_error_test() {
  let p =
    function_provider.function_provider("test", fn(_request) {
      Error(error.ProviderError(
        provider: "test",
        model: "test",
        status: 503,
        message: "Unavailable",
      ))
    })
  let a = agent.new(p)
  case run.generate(a, Nil, "Hi") {
    Ok(_) -> panic as "Expected Error"
    Error(err) ->
      case err {
        error.ProviderError(_, _, status, _) -> status |> should.equal(503)
        _ -> panic as "Expected ProviderError"
      }
  }
}
