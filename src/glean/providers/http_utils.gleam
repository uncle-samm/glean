//// Shared HTTP request utilities with timeout and retry logic.
//// Used by all provider implementations.

import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glean/error.{type GleanError}
import glean/providers/config.{type ProviderConfig}

/// The longest we wait before one retry, whatever `Retry-After` says.
const max_retry_delay_ms = 60_000

/// Send an HTTP POST request with timeout and retry for transient errors.
///
/// Retries 408, 409, 429, 5xx and 529 responses and failed connections, with
/// exponential backoff plus jitter. A `Retry-After` header (in seconds) is
/// used instead of the backoff when present.
pub fn send_post(
  config: ProviderConfig,
  provider_name: String,
  url: String,
  body: String,
  extra_headers: List(#(String, String)),
) -> Result(String, GleanError) {
  use req <- result.try(
    request.to(url)
    |> result.replace_error(error.ConfigError(message: "Invalid URL: " <> url)),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
    |> apply_headers(extra_headers)
    |> apply_headers(list.map(config.headers, fn(h) { #(h.0, h.1) }))

  send_with_retry(req, config, provider_name, 0, config.initial_retry_delay_ms)
}

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

  let can_retry = attempt < config.max_retries
  let retry = fn(retry_after: Option(String)) {
    process.sleep(retry_delay(
      delay_ms,
      retry_after,
      int.random(delay_ms / 2 + 1),
    ))
    send_with_retry(req, config, provider_name, attempt + 1, delay_ms * 2)
  }

  case http_result {
    Error(httpc.ResponseTimeout) ->
      Error(error.Timeout(after_ms: config.timeout_ms))
    Error(httpc.FailedToConnect(..)) if can_retry -> retry(None)
    Error(err) ->
      Error(error.ProviderError(
        provider: provider_name,
        model: config.model,
        status: 0,
        message: "HTTP request failed: " <> string.inspect(err),
      ))
    Ok(resp) if resp.status >= 200 && resp.status < 300 -> Ok(resp.body)
    Ok(resp) ->
      case is_retryable(resp.status) && can_retry {
        True ->
          retry(option.from_result(response.get_header(resp, "retry-after")))
        False ->
          Error(error.ProviderError(
            provider: provider_name,
            model: config.model,
            status: resp.status,
            message: resp.body,
          ))
      }
  }
}

/// How long to wait before the next attempt.
///
/// A numeric `Retry-After` (seconds) wins over the backoff. Otherwise the
/// backoff delay plus `jitter_ms` is used. Either way the wait is capped at
/// one minute. Public for tests.
pub fn retry_delay(
  backoff_ms: Int,
  retry_after: Option(String),
  jitter_ms: Int,
) -> Int {
  let assert True = backoff_ms >= 0 && jitter_ms >= 0
  let wait = case retry_after {
    Some(value) ->
      case int.parse(string.trim(value)) {
        Ok(seconds) if seconds >= 0 -> seconds * 1000
        _ -> backoff_ms + jitter_ms
      }
    None -> backoff_ms + jitter_ms
  }
  int.min(wait, max_retry_delay_ms)
}

/// Whether a status code is worth retrying.
pub fn is_retryable(status: Int) -> Bool {
  status == 408
  || status == 409
  || status == 429
  || status == 529
  || { status >= 500 && status <= 599 && status != 501 }
}
