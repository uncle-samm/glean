import gleam/option.{None, Some}
import glean/providers/http_utils
import gleeunit/should

pub fn server_delay_wins_over_backoff_test() {
  http_utils.retry_delay(1000, Some(3000), 200) |> should.equal(3000)
  http_utils.retry_delay(1000, Some(0), 200) |> should.equal(0)
}

pub fn backoff_with_jitter_when_the_server_names_no_delay_test() {
  http_utils.retry_delay(1000, None, 250) |> should.equal(1250)
}

pub fn delay_is_capped_test() {
  http_utils.retry_delay(1000, Some(3_600_000), 0) |> should.equal(60_000)
}

pub fn retry_after_is_seconds_test() {
  let seconds = fn(value) {
    http_utils.server_retry_delay_ms(
      retry_after_ms: None,
      retry_after: Some(value),
    )
  }
  seconds("3") |> should.equal(Some(3000))
  seconds(" 0 ") |> should.equal(Some(0))
  // Fractions of a second are kept.
  seconds("1.5") |> should.equal(Some(1500))
  seconds("0.25") |> should.equal(Some(250))
  // An HTTP date isn't parsed, and a negative wait is no wait at all:
  // both fall back to the backoff.
  seconds("Wed, 21 Oct 2026 07:28:00 GMT") |> should.equal(None)
  seconds("-2") |> should.equal(None)
}

pub fn retry_after_ms_wins_over_retry_after_test() {
  http_utils.server_retry_delay_ms(
    retry_after_ms: Some("750"),
    retry_after: Some("2"),
  )
  |> should.equal(Some(750))
  http_utils.server_retry_delay_ms(
    retry_after_ms: Some("412.6"),
    retry_after: None,
  )
  |> should.equal(Some(413))
  // An unreadable retry-after-ms leaves Retry-After in charge.
  http_utils.server_retry_delay_ms(
    retry_after_ms: Some("soon"),
    retry_after: Some("2"),
  )
  |> should.equal(Some(2000))
  http_utils.server_retry_delay_ms(retry_after_ms: None, retry_after: None)
  |> should.equal(None)
}

pub fn retryable_statuses_test() {
  http_utils.is_retryable(429) |> should.be_true
  http_utils.is_retryable(503) |> should.be_true
  http_utils.is_retryable(529) |> should.be_true
  http_utils.is_retryable(501) |> should.be_false
  http_utils.is_retryable(400) |> should.be_false
  http_utils.is_retryable(401) |> should.be_false
}
