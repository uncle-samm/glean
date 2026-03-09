/// Shared HTTP request utilities with timeout and retry logic.
/// Used by all provider implementations.

import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/list
import glean/error.{type GleanError}
import glean/providers/config.{type ProviderConfig}

/// Send an HTTP POST request with timeout and retry for transient errors.
/// Retries on 429 (rate limit) and 5xx (server errors) with exponential backoff.
pub fn send_post(
  config: ProviderConfig,
  provider_name: String,
  url: String,
  body: String,
  extra_headers: List(#(String, String)),
) -> Result(String, GleanError) {
  let req_result =
    request.to(url)
    |> result.map_error(fn(_) {
      error.ConfigError(message: "Invalid URL: " <> url)
    })

  case req_result {
    Error(err) -> Error(err)
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_header("content-type", "application/json")
        |> request.set_body(body)
        |> apply_headers(extra_headers)
        |> apply_headers(
          list.map(config.headers, fn(h) { #(h.0, h.1) }),
        )

      send_with_retry(
        req,
        config,
        provider_name,
        0,
        config.initial_retry_delay_ms,
      )
    }
  }
}

import gleam/result

fn apply_headers(
  req: request.Request(String),
  headers: List(#(String, String)),
) -> request.Request(String) {
  list.fold(headers, req, fn(r, header) {
    request.set_header(r, header.0, header.1)
  })
}

fn send_with_retry(
  req: request.Request(String),
  config: ProviderConfig,
  provider_name: String,
  attempt: Int,
  delay_ms: Int,
) -> Result(String, GleanError) {
  let http_result =
    httpc.configure()
    |> httpc.timeout(config.timeout_ms)
    |> httpc.dispatch(req)

  case http_result {
    Error(httpc.ResponseTimeout) ->
      Error(error.Timeout(after_ms: config.timeout_ms))
    Error(_) ->
      Error(error.ProviderError(
        provider: provider_name,
        model: config.model,
        status: 0,
        message: "HTTP request failed",
      ))
    Ok(resp) -> {
      case resp.status {
        200 -> Ok(resp.body)
        status -> {
          case is_retryable(status) && attempt < config.max_retries {
            True -> {
              process.sleep(delay_ms)
              send_with_retry(
                req,
                config,
                provider_name,
                attempt + 1,
                delay_ms * 2,
              )
            }
            False ->
              Error(error.ProviderError(
                provider: provider_name,
                model: config.model,
                status: status,
                message: resp.body,
              ))
          }
        }
      }
    }
  }
}

fn is_retryable(status: Int) -> Bool {
  status == 429
  || status == 500
  || status == 502
  || status == 503
  || status == 504
}
