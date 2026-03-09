# Glean — Development Guidelines

## Philosophy

We follow the **TigerBeetle approach** to software quality:
- Assert preconditions, postconditions, and invariants everywhere
- Never silently swallow errors — always explicitly return, handle, or propagate
- Use the highest-quality typing system without exception
- Build robust testing including simulation testing

## Error Handling

- **Never silently swallow errors.** Every error must be explicitly returned, handled, or propagated.
- Use Gleam's `Result` type everywhere. No panics for recoverable errors.
- Every error path must be intentional and documented by the types.
- If a function can fail, its return type MUST reflect that.
- Errors must always be explicitly called out, returned, or handled exactly as intended.

## Type Safety

- Use Gleam's type system to its fullest — no exceptions.
- No `Dynamic` unless at system boundaries (e.g., JSON from external APIs).
- Prefer phantom types, opaque types, and custom types over stringly-typed interfaces.
- Make invalid states unrepresentable through the type system.
- Every public API should be fully typed with no escape hatches.

## Assertions

- Assert preconditions, postconditions, and invariants wherever possible.
- Use `let assert` for conditions that represent programmer errors (violated invariants), not for user input or external data.
- Assertions are documentation — they communicate what must be true.

## Testing

- Every module must have corresponding tests.
- Use property-based testing where applicable.
- Build simulation testing infrastructure for agent workflows — test multi-step tool-calling loops, provider failures, retries, and concurrent agent execution deterministically.
- Test error paths as thoroughly as happy paths.
- Use test models (mock providers) so tests never hit real APIs.
- Consider simulation testing for complex agent interaction patterns.

## FFI

- **Minimize FFI usage.** Use pure Gleam solutions wherever possible.
- JSON encoding/decoding must be done in pure Gleam using `gleam/json` and `gleam/dynamic/decode` — no Erlang FFI for JSON.
- Only use FFI when there is genuinely no Gleam-native alternative (e.g., platform-specific OS functionality).
- When FFI is unavoidable, isolate it in a dedicated module and document why it's necessary.

## Code Style

- Explicit over implicit. No magic.
- Prefer composition over deep abstraction hierarchies.
- Keep modules focused and small.
- Every public function should have a clear, single purpose.
- Use `gleam add` to add dependencies (never edit gleam.toml manually for deps).
- Always use the latest versions of all dependencies.

## Provider Support

Support all major LLM providers:
- OpenAI, Anthropic, Google Gemini, Mistral
- OpenRouter (meta-provider)
- Chinese providers: DeepSeek, Alibaba (Qwen), MiniMax, Kimi (Moonshot)
- Each provider gets its own module under `src/glean/providers/`
