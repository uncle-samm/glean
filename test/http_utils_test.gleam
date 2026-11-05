import gleam/option.{None, Some}
import glean/providers/http_utils
import gleeunit/should

pub fn retry_after_wins_over_backoff_test() {
  http_utils.retry_delay(1000, Some("3"), 200) |> should.equal(3000)
  http_utils.retry_delay(1000, Some(" 0 "), 200) |> should.equal(0)
}

pub fn backoff_with_jitter_when_no_usable_header_test() {
  http_utils.retry_delay(1000, None, 250) |> should.equal(1250)
  // An HTTP date isn't parsed; fall back to the backoff.
  http_utils.retry_delay(1000, Some("Wed, 21 Oct 2026 07:28:00 GMT"), 0)
  |> should.equal(1000)
}

pub fn delay_is_capped_test() {
  http_utils.retry_delay(1000, Some("3600"), 0) |> should.equal(60_000)
}

pub fn retryable_statuses_test() {
  http_utils.is_retryable(429) |> should.be_true
  http_utils.is_retryable(503) |> should.be_true
  http_utils.is_retryable(529) |> should.be_true
  http_utils.is_retryable(501) |> should.be_false
  http_utils.is_retryable(400) |> should.be_false
  http_utils.is_retryable(401) |> should.be_false
}
