import gleam/option.{Some}
import glean/agent
import glean/middleware
import glean/provider.{GenerateRequest, GenerateResult, GeneratedText, ModelSettings}
import glean/run
import glean/testing/function_provider
import glean/testing/provider as test_provider
import gleeunit/should

pub fn request_middleware_transforms_test() {
  // Middleware adds max_output_tokens to the request
  let mw =
    middleware.request_middleware(fn(req: provider.GenerateRequest) {
      let new_settings =
        ModelSettings(..req.settings, max_output_tokens: Some(42))
      GenerateRequest(..req, settings: new_settings)
    })

  // Function provider that checks the request was transformed
  let p =
    function_provider.function_provider("test", fn(request) {
      case request.settings.max_output_tokens {
        Some(42) -> Ok(test_provider.text_result("Transformed!"))
        _ -> Ok(test_provider.text_result("Not transformed"))
      }
    })

  let wrapped = middleware.apply(p, mw)
  let a = agent.new(wrapped)

  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("Transformed!")
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn result_middleware_transforms_test() {
  // Middleware modifies the result text content
  let mw =
    middleware.result_middleware(fn(result: provider.GenerateResult) {
      let new_content = [GeneratedText(text: "Modified!")]
      GenerateResult(..result, content: new_content)
    })

  let p = test_provider.test_provider([test_provider.TextResponse("Original")])
  let wrapped = middleware.apply(p, mw)
  let a = agent.new(wrapped)

  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("Modified!")
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn chain_middleware_order_test() {
  // Chain 2 middlewares — request transforms should compose left-to-right
  let mw1 =
    middleware.request_middleware(fn(req: provider.GenerateRequest) {
      let new_settings =
        ModelSettings(..req.settings, max_output_tokens: Some(100))
      GenerateRequest(..req, settings: new_settings)
    })
  let mw2 =
    middleware.request_middleware(fn(req: provider.GenerateRequest) {
      // Second middleware should see max_output_tokens=100 from first
      let final_val = case req.settings.max_output_tokens {
        Some(100) -> Some(200)
        _ -> Some(999)
      }
      let new_settings =
        ModelSettings(..req.settings, max_output_tokens: final_val)
      GenerateRequest(..req, settings: new_settings)
    })

  let chained = middleware.chain([mw1, mw2])
  let p =
    function_provider.function_provider("test", fn(request) {
      case request.settings.max_output_tokens {
        Some(200) -> Ok(test_provider.text_result("Chained!"))
        _ -> Ok(test_provider.text_result("Wrong value"))
      }
    })

  let wrapped = middleware.apply(p, chained)
  let a = agent.new(wrapped)

  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("Chained!")
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn apply_middleware_preserves_provider_test() {
  // Middleware shouldn't change provider name/model_id
  let mw =
    middleware.result_middleware(fn(r: provider.GenerateResult) { r })
  let p = test_provider.test_provider([test_provider.TextResponse("Hi")])
  let wrapped = middleware.apply(p, mw)

  wrapped.name |> should.equal(p.name)
  wrapped.model_id |> should.equal(p.model_id)
}

pub fn identity_middleware_test() {
  // Empty chain does nothing
  let mw = middleware.chain([])
  let p = test_provider.test_provider([test_provider.TextResponse("Untouched")])
  let wrapped = middleware.apply(p, mw)
  let a = agent.new(wrapped)

  case run.generate(a, Nil, "Hi") {
    Ok(result) -> result.text |> should.equal("Untouched")
    Error(_) -> panic as "Expected Ok"
  }
}
