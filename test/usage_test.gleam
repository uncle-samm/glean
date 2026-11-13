import glean/stream
import glean/usage.{Usage}
import gleeunit/should

pub fn new_has_nothing_cached_and_no_reasoning_test() {
  usage.new(input_tokens: 10, output_tokens: 5)
  |> should.equal(Usage(
    input_tokens: 10,
    output_tokens: 5,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    reasoning_tokens: 0,
  ))
  usage.zero() |> should.equal(usage.new(input_tokens: 0, output_tokens: 0))
}

pub fn add_sums_every_field_test() {
  let a =
    Usage(
      input_tokens: 100,
      output_tokens: 20,
      cache_read_tokens: 60,
      cache_write_tokens: 10,
      reasoning_tokens: 5,
    )
  let b =
    Usage(
      input_tokens: 1,
      output_tokens: 2,
      cache_read_tokens: 3,
      cache_write_tokens: 4,
      reasoning_tokens: 5,
    )
  let sum =
    Usage(
      input_tokens: 101,
      output_tokens: 22,
      cache_read_tokens: 63,
      cache_write_tokens: 14,
      reasoning_tokens: 10,
    )
  usage.add(a, b) |> should.equal(sum)
  usage.add(a, usage.zero()) |> should.equal(a)
  // The stream module's helpers are the same functions.
  stream.add_usage(a, b) |> should.equal(sum)
  stream.zero_usage() |> should.equal(usage.zero())
}
