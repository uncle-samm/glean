/// Middleware hooks for transforming provider requests and results.
/// Inspired by Vercel AI SDK's LanguageModelMiddleware.

import gleam/list
import gleam/option.{type Option, None, Some}
import glean/error.{type GleanError}
import glean/provider.{
  type GenerateRequest, type GenerateResult, type Provider, Provider,
}
import glean/stream.{type StreamEvent}

/// Middleware that can intercept and transform provider calls.
pub type Middleware {
  Middleware(
    /// Transform the request before it's sent to the provider
    transform_request: Option(fn(GenerateRequest) -> GenerateRequest),
    /// Transform the result after it's returned from the provider
    transform_result: Option(fn(GenerateResult) -> GenerateResult),
  )
}

/// Create a middleware that only transforms requests.
pub fn request_middleware(
  transform: fn(GenerateRequest) -> GenerateRequest,
) -> Middleware {
  Middleware(transform_request: Some(transform), transform_result: None)
}

/// Create a middleware that only transforms results.
pub fn result_middleware(
  transform: fn(GenerateResult) -> GenerateResult,
) -> Middleware {
  Middleware(transform_request: None, transform_result: Some(transform))
}

/// Chain multiple middlewares into one. Applied left-to-right:
/// first middleware's request transform runs first,
/// last middleware's result transform runs last.
pub fn chain(middlewares: List(Middleware)) -> Middleware {
  list.fold(middlewares, identity_middleware(), fn(acc, mw) {
    Middleware(
      transform_request: compose_option(acc.transform_request, mw.transform_request),
      transform_result: compose_option(acc.transform_result, mw.transform_result),
    )
  })
}

/// Wrap a provider with middleware, producing a new provider.
pub fn apply(provider: Provider, middleware: Middleware) -> Provider {
  let transform_req = middleware.transform_request
  let transform_res = middleware.transform_result

  let new_generate = fn(request: GenerateRequest) -> Result(GenerateResult, GleanError) {
    let request = apply_transform(request, transform_req)
    case provider.generate(request) {
      Ok(result) -> Ok(apply_transform(result, transform_res))
      Error(err) -> Error(err)
    }
  }

  let new_stream = fn(
    request: GenerateRequest,
    on_event: fn(StreamEvent) -> Nil,
  ) -> Result(GenerateResult, GleanError) {
    let request = apply_transform(request, transform_req)
    case provider.stream(request, on_event) {
      Ok(result) -> Ok(apply_transform(result, transform_res))
      Error(err) -> Error(err)
    }
  }

  Provider(
    ..provider,
    generate: new_generate,
    stream: new_stream,
  )
}

// --- Internal helpers ---

fn identity_middleware() -> Middleware {
  Middleware(transform_request: None, transform_result: None)
}

fn apply_transform(value: a, transform: Option(fn(a) -> a)) -> a {
  case transform {
    None -> value
    Some(f) -> f(value)
  }
}

fn compose_option(
  first: Option(fn(a) -> a),
  second: Option(fn(a) -> a),
) -> Option(fn(a) -> a) {
  case first, second {
    None, None -> None
    Some(f), None -> Some(f)
    None, Some(g) -> Some(g)
    Some(f), Some(g) -> Some(fn(x) { g(f(x)) })
  }
}
