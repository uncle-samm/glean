/// Pure Gleam JSON value type for encoding/decoding arbitrary JSON.
/// Replaces Erlang FFI for dynamic-to-JSON-string conversion.
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option

/// A generic JSON value that can represent any JSON data.
pub type JsonValue {
  JsonNull
  JsonBool(Bool)
  JsonInt(Int)
  JsonFloat(Float)
  JsonString(String)
  JsonArray(List(JsonValue))
  JsonObject(List(#(String, JsonValue)))
}

/// Decoder for arbitrary JSON values.
pub fn decoder() -> decode.Decoder(JsonValue) {
  decode.recursive(fn() {
    use opt <- decode.then(decode.optional(non_null_decoder()))
    case opt {
      option.None -> decode.success(JsonNull)
      option.Some(val) -> decode.success(val)
    }
  })
}

fn non_null_decoder() -> decode.Decoder(JsonValue) {
  decode.one_of(decode.string |> decode.map(JsonString), [
    decode.int |> decode.map(JsonInt),
    decode.float |> decode.map(JsonFloat),
    decode.bool |> decode.map(JsonBool),
    decode.list(decoder()) |> decode.map(JsonArray),
    decode.dict(decode.string, decoder())
      |> decode.map(fn(d) { JsonObject(dict.to_list(d)) }),
  ])
}

/// Convert a JsonValue to a gleam/json Json for embedding in JSON output.
pub fn to_json(value: JsonValue) -> json.Json {
  case value {
    JsonNull -> json.null()
    JsonBool(b) -> json.bool(b)
    JsonInt(i) -> json.int(i)
    JsonFloat(f) -> json.float(f)
    JsonString(s) -> json.string(s)
    JsonArray(items) -> json.preprocessed_array(list.map(items, to_json))
    JsonObject(fields) ->
      json.object(list.map(fields, fn(kv) { #(kv.0, to_json(kv.1)) }))
  }
}

/// Convert a JsonValue to a JSON string.
pub fn to_string(value: JsonValue) -> String {
  to_json(value) |> json.to_string
}

/// Turn a tool call's argument string into a JSON object for APIs that
/// take arguments as an object (Anthropic `input`, Gemini `args`).
///
/// Arguments that aren't a JSON object can't be sent as-is. They were
/// already reported to the model as invalid when the tool call ran, so they
/// are sent back wrapped as `{"invalid_arguments": "<original text>"}`
/// rather than dropped, keeping the history truthful.
pub fn arguments_to_object(arguments_json: String) -> json.Json {
  case json.parse(arguments_json, decoder()) {
    Ok(JsonObject(_) as value) -> to_json(value)
    _ -> json.object([#("invalid_arguments", json.string(arguments_json))])
  }
}
