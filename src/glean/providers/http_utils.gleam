//// Shared HTTP request utilities with timeout and retry logic.
//// Used by all provider implementations.

import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import glean/error.{type GleanError}
import glean/providers/config.{type ProviderConfig}

/// The longest we wait before one retry, whatever `Retry-After` says.
const max_retry_delay_ms = 60_000

/// Why a request got no response.
type PostError {
  TimedOut
  RequestFailed(String)
}

/// A response: status, the `retry-after-ms` header, the `retry-after`
/// header, body.
type Response =
  #(Int, Option(String), Option(String), BitArray)

/// The request goes through glean's own FFI (`src/glean_http_ffi.erl`)
/// because it returns every transport failure as a value; see that file.
@external(erlang, "glean_http_ffi", "post")
fn ffi_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> Result(Response, PostError)

/// Send an HTTP POST request with timeout and retry for transient errors.
///
/// Retries 408, 409, 429, 5xx and 529 responses, requests that failed
/// without a response (no connection, a connection the server dropped) and
/// requests that got no response within the timeout, with exponential
/// backoff plus jitter. When the server says how long to wait
/// (`retry-after-ms` or `Retry-After`), that is used instead of the backoff.
///
/// Every failure is returned as an error; nothing here raises.
pub fn send_post(
  config: ProviderConfig,
  provider_name: String,
  url: String,
  body: String,
  extra_headers: List(#(String, String)),
) -> Result(String, GleanError) {
  case is_http_url(url) {
    False -> Error(error.ConfigError(message: "Invalid URL: " <> url))
    True -> {
      send_with_retry(
        url,
        request_headers(list.append(extra_headers, config.headers)),
        body,
        config,
        provider_name,
        0,
        config.initial_retry_delay_ms,
      )
    }
  }
}

/// The headers of a request: a `user-agent` naming glean unless the given
/// headers have one, and one value per header name, where a later header
/// replaces an earlier one of the same name. The FFI adds the JSON
/// `content-type`.
pub fn request_headers(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.fold([#("user-agent", "glean"), ..headers], [], fn(headers, header) {
    list.key_set(headers, string.lowercase(header.0), header.1)
  })
}

fn is_http_url(url: String) -> Bool {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some("http"), host: Some(host), ..))
    | Ok(uri.Uri(scheme: Some("https"), host: Some(host), ..)) -> host != ""
    _ -> False
  }
}

fn send_with_retry(
  url: String,
  headers: List(#(String, String)),
  body: String,
  config: ProviderConfig,
  provider_name: String,
  attempt: Int,
  delay_ms: Int,
) -> Result(String, GleanError) {
  let can_retry = attempt < config.max_retries
  let retry = fn(server_delay_ms: Option(Int)) {
    process.sleep(retry_delay(
      delay_ms,
      server_delay_ms,
      int.random(delay_ms / 2 + 1),
    ))
    send_with_retry(
      url,
      headers,
      body,
      config,
      provider_name,
      attempt + 1,
      delay_ms * 2,
    )
  }
  let failed = fn(status, message) {
    Error(error.ProviderError(
      provider: provider_name,
      model: config.model,
      status: status,
      message: message,
    ))
  }

  case ffi_post(url, headers, body, config.timeout_ms) {
    // A request that timed out or lost its connection is tried again: the
    // provider may have dropped it under load.
    Error(_) if can_retry -> retry(None)
    Error(TimedOut) -> Error(error.Timeout(after_ms: config.timeout_ms))
    Error(RequestFailed(reason)) -> failed(0, "HTTP request failed: " <> reason)
    Ok(#(status, _, _, response_body)) if status >= 200 && status < 300 ->
      case bit_array.to_string(response_body) {
        Ok(text) -> Ok(text)
        Error(Nil) -> failed(status, "The response body is not UTF-8 text")
      }
    Ok(#(status, retry_after_ms, retry_after, response_body)) ->
      case is_retryable(status) && can_retry {
        True ->
          retry(server_retry_delay_ms(
            retry_after_ms: retry_after_ms,
            retry_after: retry_after,
          ))
        False ->
          failed(status, case bit_array.to_string(response_body) {
            Ok(text) -> text
            Error(Nil) -> "<non-UTF-8 response body>"
          })
      }
  }
}

/// How long the server asked for before the next attempt, in milliseconds.
///
/// `retry-after-ms` (milliseconds; OpenAI and Anthropic send it) wins over
/// `Retry-After` (seconds, whole or fractional). A header that is neither
/// form, such as an HTTP date, gives None, as does no header at all.
pub fn server_retry_delay_ms(
  retry_after_ms retry_after_ms: Option(String),
  retry_after retry_after: Option(String),
) -> Option(Int) {
  let milliseconds = option.then(retry_after_ms, parse_number)
  let seconds =
    option.then(retry_after, parse_number)
    |> option.map(fn(seconds) { seconds *. 1000.0 })
  option.or(milliseconds, seconds)
  |> option.map(float.round)
}

/// A header value as a number that is not negative.
fn parse_number(value: String) -> Option(Float) {
  let value = string.trim(value)
  let parsed = case int.parse(value) {
    Ok(whole) -> Ok(int.to_float(whole))
    Error(Nil) -> float.parse(value)
  }
  case parsed {
    Ok(number) if number >=. 0.0 -> Some(number)
    Ok(_) | Error(Nil) -> None
  }
}

/// How long to wait before the next attempt.
///
/// The delay the server asked for (see `server_retry_delay_ms`) wins over
/// the backoff. Otherwise the backoff delay plus `jitter_ms` is used.
/// Either way the wait is capped at one minute. Public for tests.
pub fn retry_delay(
  backoff_ms: Int,
  server_delay_ms: Option(Int),
  jitter_ms: Int,
) -> Int {
  let assert True = backoff_ms >= 0 && jitter_ms >= 0
  let wait = case server_delay_ms {
    Some(wait) if wait >= 0 -> wait
    Some(_) | None -> backoff_ms + jitter_ms
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
