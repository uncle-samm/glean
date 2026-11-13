//// Token usage.

/// The tokens one model call used, or the sum over a whole run.
///
/// Providers count differently; glean puts their numbers on one scale:
/// `input_tokens` and `output_tokens` are totals, and the other fields say
/// how much of each total was cached or spent on reasoning.
pub type Usage {
  Usage(
    /// Every input token, including the ones read from or written to a
    /// prompt cache.
    input_tokens: Int,
    /// Every output token, including the ones spent on reasoning.
    output_tokens: Int,
    /// Of the input tokens, those read from a prompt cache, which providers
    /// bill at a discount.
    cache_read_tokens: Int,
    /// Of the input tokens, those written to a prompt cache, which Claude
    /// bills at a premium. 0 for providers that don't report it.
    cache_write_tokens: Int,
    /// Of the output tokens, those spent on reasoning. 0 for providers that
    /// don't report it separately, such as Claude.
    reasoning_tokens: Int,
  )
}

/// Usage with nothing cached and no reasoning reported.
pub fn new(input_tokens input: Int, output_tokens output: Int) -> Usage {
  let assert True = input >= 0 && output >= 0
  Usage(
    input_tokens: input,
    output_tokens: output,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    reasoning_tokens: 0,
  )
}

/// No tokens: the starting point for a sum.
pub fn zero() -> Usage {
  new(input_tokens: 0, output_tokens: 0)
}

/// Add two usages together.
pub fn add(a: Usage, b: Usage) -> Usage {
  Usage(
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
    cache_read_tokens: a.cache_read_tokens + b.cache_read_tokens,
    cache_write_tokens: a.cache_write_tokens + b.cache_write_tokens,
    reasoning_tokens: a.reasoning_tokens + b.reasoning_tokens,
  )
}
