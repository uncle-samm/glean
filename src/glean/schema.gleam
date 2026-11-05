//// JSON Schema builder for tool input and structured output definitions.
//// Opaque type with explicit builder functions — no macros, no reflection.
////
//// Schemas are sent to the model and also used to validate what the model
//// sends back (see `validate`).

import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glean/error.{type ValidationError, ValidationError}
import glean/json_value.{type JsonValue}

pub opaque type Schema {
  ObjectSchema(
    /// Kept in the order the caller wrote them.
    properties: List(#(String, Schema)),
    required: List(String),
    description: Option(String),
  )
  StringSchema(
    description: Option(String),
    enum_values: Option(List(String)),
    min_length: Option(Int),
    max_length: Option(Int),
  )
  IntSchema(
    description: Option(String),
    minimum: Option(Int),
    maximum: Option(Int),
  )
  FloatSchema(description: Option(String))
  BoolSchema(description: Option(String))
  ArraySchema(items: Schema, description: Option(String))
  NullableSchema(inner: Schema)
  OneOfSchema(variants: List(Schema), description: Option(String))
}

// --- Builder functions ---

pub fn object(
  properties properties: List(#(String, Schema)),
  required required: List(String),
) -> Schema {
  // An empty object is valid: tools that take no arguments use it.
  let prop_names = list.map(properties, fn(p) { p.0 })
  // Property names must be unique.
  let assert True = list.length(list.unique(prop_names)) == list.length(prop_names)
  // Every required field must be a declared property.
  list.each(required, fn(r) {
    let assert True = list.contains(prop_names, r)
  })
  ObjectSchema(properties: properties, required: required, description: None)
}

pub fn string() -> Schema {
  StringSchema(
    description: None,
    enum_values: None,
    min_length: None,
    max_length: None,
  )
}

pub fn string_enum(values values: List(String)) -> Schema {
  let assert True = !list.is_empty(values)
  StringSchema(
    description: None,
    enum_values: Some(values),
    min_length: None,
    max_length: None,
  )
}

pub fn int() -> Schema {
  IntSchema(description: None, minimum: None, maximum: None)
}

pub fn int_range(minimum minimum: Int, maximum maximum: Int) -> Schema {
  let assert True = minimum <= maximum
  IntSchema(description: None, minimum: Some(minimum), maximum: Some(maximum))
}

pub fn float() -> Schema {
  FloatSchema(description: None)
}

pub fn bool() -> Schema {
  BoolSchema(description: None)
}

pub fn array(of items: Schema) -> Schema {
  ArraySchema(items: items, description: None)
}

pub fn nullable(schema: Schema) -> Schema {
  NullableSchema(inner: schema)
}

pub fn one_of(variants variants: List(Schema)) -> Schema {
  let assert True = list.length(variants) >= 2
  OneOfSchema(variants: variants, description: None)
}

pub fn describe(schema: Schema, description description: String) -> Schema {
  case schema {
    ObjectSchema(p, r, _) -> ObjectSchema(p, r, Some(description))
    StringSchema(_, e, mn, mx) -> StringSchema(Some(description), e, mn, mx)
    IntSchema(_, mn, mx) -> IntSchema(Some(description), mn, mx)
    FloatSchema(_) -> FloatSchema(Some(description))
    BoolSchema(_) -> BoolSchema(Some(description))
    ArraySchema(i, _) -> ArraySchema(i, Some(description))
    NullableSchema(inner) -> NullableSchema(describe(inner, description))
    OneOfSchema(v, _) -> OneOfSchema(v, Some(description))
  }
}

pub fn string_with_length(
  min_length min_length: Option(Int),
  max_length max_length: Option(Int),
) -> Schema {
  StringSchema(
    description: None,
    enum_values: None,
    min_length: min_length,
    max_length: max_length,
  )
}

// --- JSON conversion ---

pub fn to_json(schema: Schema) -> Json {
  case schema {
    ObjectSchema(properties, required, description) ->
      object_to_json(properties, required, description)
    StringSchema(description, enum_values, min_length, max_length) ->
      string_to_json(description, enum_values, min_length, max_length)
    IntSchema(description, minimum, maximum) ->
      int_to_json(description, minimum, maximum)
    FloatSchema(description) -> float_to_json(description)
    BoolSchema(description) -> bool_to_json(description)
    ArraySchema(items, description) -> array_to_json(items, description)
    NullableSchema(inner) -> nullable_to_json(inner)
    OneOfSchema(variants, description) -> one_of_to_json(variants, description)
  }
}

pub fn to_json_string(schema: Schema) -> String {
  schema
  |> to_json
  |> json.to_string
}

/// Convert to JSON with `additionalProperties: false` on all object schemas.
/// Required by OpenAI strict structured outputs.
pub fn to_json_strict(schema: Schema) -> Json {
  case schema {
    ObjectSchema(properties, required, description) ->
      object_to_json_strict(properties, required, description)
    StringSchema(description, enum_values, min_length, max_length) ->
      string_to_json(description, enum_values, min_length, max_length)
    IntSchema(description, minimum, maximum) ->
      int_to_json(description, minimum, maximum)
    FloatSchema(description) -> float_to_json(description)
    BoolSchema(description) -> bool_to_json(description)
    ArraySchema(items, description) -> array_to_json_strict(items, description)
    NullableSchema(inner) -> nullable_to_json_strict(inner)
    OneOfSchema(variants, description) ->
      one_of_to_json_strict(variants, description)
  }
}

/// Whether this schema can be sent with OpenAI's `strict: true`.
///
/// Strict mode needs an object at the root, every object property listed as
/// required (optional fields are expressed with `nullable`), and no string
/// length limits. Schemas that don't qualify are still sent, just without
/// `strict`, and glean validates the model's output itself either way.
pub fn is_strict_compatible(schema: Schema) -> Bool {
  case schema {
    ObjectSchema(..) -> strict_ok(schema)
    _ -> False
  }
}

fn strict_ok(schema: Schema) -> Bool {
  case schema {
    ObjectSchema(properties, required, _) ->
      list.all(properties, fn(p) {
        list.contains(required, p.0) && strict_ok(p.1)
      })
    StringSchema(min_length: None, max_length: None, ..) -> True
    StringSchema(..) -> False
    IntSchema(..) | FloatSchema(..) | BoolSchema(..) -> True
    ArraySchema(items, _) -> strict_ok(items)
    NullableSchema(inner) -> strict_ok(inner)
    OneOfSchema(variants, _) -> list.all(variants, strict_ok)
  }
}

// --- Internal JSON helpers ---

fn with_description(
  fields: List(#(String, Json)),
  description: Option(String),
) -> List(#(String, Json)) {
  case description {
    None -> fields
    Some(d) -> [#("description", json.string(d)), ..fields]
  }
}

fn object_to_json(
  properties: List(#(String, Schema)),
  required: List(String),
  description: Option(String),
) -> Json {
  let props =
    properties
    |> list.map(fn(entry) { #(entry.0, to_json(entry.1)) })
    |> json.object

  let fields = [
    #("type", json.string("object")),
    #("properties", props),
  ]

  let fields = case required {
    [] -> fields
    _ ->
      list.append(fields, [
        #("required", json.array(required, json.string)),
      ])
  }

  fields
  |> with_description(description)
  |> json.object
}

fn string_to_json(
  description: Option(String),
  enum_values: Option(List(String)),
  min_length: Option(Int),
  max_length: Option(Int),
) -> Json {
  let fields = [#("type", json.string("string"))]

  let fields = case enum_values {
    None -> fields
    Some(values) ->
      list.append(fields, [
        #("enum", json.array(values, json.string)),
      ])
  }

  let fields = case min_length {
    None -> fields
    Some(ml) -> list.append(fields, [#("minLength", json.int(ml))])
  }

  let fields = case max_length {
    None -> fields
    Some(ml) -> list.append(fields, [#("maxLength", json.int(ml))])
  }

  fields
  |> with_description(description)
  |> json.object
}

fn int_to_json(
  description: Option(String),
  minimum: Option(Int),
  maximum: Option(Int),
) -> Json {
  let fields = [#("type", json.string("integer"))]

  let fields = case minimum {
    None -> fields
    Some(m) -> list.append(fields, [#("minimum", json.int(m))])
  }

  let fields = case maximum {
    None -> fields
    Some(m) -> list.append(fields, [#("maximum", json.int(m))])
  }

  fields
  |> with_description(description)
  |> json.object
}

fn float_to_json(description: Option(String)) -> Json {
  [#("type", json.string("number"))]
  |> with_description(description)
  |> json.object
}

fn bool_to_json(description: Option(String)) -> Json {
  [#("type", json.string("boolean"))]
  |> with_description(description)
  |> json.object
}

fn array_to_json(items: Schema, description: Option(String)) -> Json {
  [#("type", json.string("array")), #("items", to_json(items))]
  |> with_description(description)
  |> json.object
}

fn nullable_to_json(inner: Schema) -> Json {
  json.object([
    #("oneOf", json.preprocessed_array([to_json(inner), type_null()])),
  ])
}

fn one_of_to_json(variants: List(Schema), description: Option(String)) -> Json {
  let variant_jsons = list.map(variants, to_json)
  [#("oneOf", json.preprocessed_array(variant_jsons))]
  |> with_description(description)
  |> json.object
}

fn type_null() -> Json {
  json.object([#("type", json.string("null"))])
}

// --- Strict variants (with additionalProperties: false) ---

fn object_to_json_strict(
  properties: List(#(String, Schema)),
  required: List(String),
  description: Option(String),
) -> Json {
  let props =
    properties
    |> list.map(fn(entry) { #(entry.0, to_json_strict(entry.1)) })
    |> json.object

  let fields = [
    #("type", json.string("object")),
    #("properties", props),
  ]

  let fields = case required {
    [] -> fields
    _ ->
      list.append(fields, [
        #("required", json.array(required, json.string)),
      ])
  }

  let fields =
    list.append(fields, [#("additionalProperties", json.bool(False))])

  fields
  |> with_description(description)
  |> json.object
}

fn array_to_json_strict(items: Schema, description: Option(String)) -> Json {
  [#("type", json.string("array")), #("items", to_json_strict(items))]
  |> with_description(description)
  |> json.object
}

fn nullable_to_json_strict(inner: Schema) -> Json {
  json.object([
    #("anyOf", json.preprocessed_array([to_json_strict(inner), type_null()])),
  ])
}

fn one_of_to_json_strict(
  variants: List(Schema),
  description: Option(String),
) -> Json {
  let variant_jsons = list.map(variants, to_json_strict)
  [#("anyOf", json.preprocessed_array(variant_jsons))]
  |> with_description(description)
  |> json.object
}

// --- Validation ---

/// Check a JSON value against this schema.
///
/// Returns every violation found, each with the path to the offending value
/// (object keys and array indexes). Objects may carry keys the schema doesn't
/// declare; they are not checked. Integers are accepted where a number is
/// expected, and whole-number floats (e.g. `3.0`) where an integer is.
pub fn validate(
  schema: Schema,
  value: JsonValue,
) -> Result(Nil, List(ValidationError)) {
  case validate_at(schema, value, []) {
    [] -> Ok(Nil)
    errors -> Error(errors)
  }
}

/// Parse a JSON string and validate it against this schema.
/// Invalid JSON is reported as a single validation error at the root.
pub fn validate_json(
  schema: Schema,
  json_string: String,
) -> Result(JsonValue, List(ValidationError)) {
  case json.parse(json_string, json_value.decoder()) {
    Error(_) ->
      Error([ValidationError(path: [], message: "Input is not valid JSON")])
    Ok(value) ->
      case validate(schema, value) {
        Ok(Nil) -> Ok(value)
        Error(errors) -> Error(errors)
      }
  }
}

/// Errors are collected in reverse path order while walking, then each
/// error's path is reversed once at the end.
fn validate_at(
  schema: Schema,
  value: JsonValue,
  path: List(String),
) -> List(ValidationError) {
  case schema, value {
    NullableSchema(_), json_value.JsonNull -> []
    NullableSchema(inner), _ -> validate_at(inner, value, path)

    OneOfSchema(variants, _), _ ->
      case list.any(variants, fn(v) { validate_at(v, value, path) == [] }) {
        True -> []
        False -> [error_at(path, "Value matches none of the allowed variants")]
      }

    ObjectSchema(properties, required, _), json_value.JsonObject(fields) -> {
      let missing =
        required
        |> list.filter(fn(key) { !is_ok(list.key_find(fields, key)) })
        |> list.map(fn(key) {
          error_at([key, ..path], "Missing required field")
        })
      let nested =
        list.flat_map(properties, fn(prop) {
          let #(key, prop_schema) = prop
          case list.key_find(fields, key) {
            Ok(field_value) ->
              validate_at(prop_schema, field_value, [key, ..path])
            Error(Nil) -> []
          }
        })
      list.append(missing, nested)
    }
    ObjectSchema(..), _ -> [type_error(path, "an object", value)]

    StringSchema(_, enum_values, min_length, max_length),
      json_value.JsonString(text)
    -> {
      let length = string.length(text)
      let enum_errors = case enum_values {
        Some(allowed) ->
          case list.contains(allowed, text) {
            True -> []
            False -> [
              error_at(
                path,
                "Must be one of: " <> string.join(allowed, ", "),
              ),
            ]
          }
        None -> []
      }
      let min_errors = case min_length {
        Some(min) if length < min -> [
          error_at(
            path,
            "Must be at least " <> int.to_string(min) <> " characters",
          ),
        ]
        _ -> []
      }
      let max_errors = case max_length {
        Some(max) if length > max -> [
          error_at(
            path,
            "Must be at most " <> int.to_string(max) <> " characters",
          ),
        ]
        _ -> []
      }
      list.flatten([enum_errors, min_errors, max_errors])
    }
    StringSchema(..), _ -> [type_error(path, "a string", value)]

    IntSchema(_, minimum, maximum), json_value.JsonInt(n) ->
      check_int_range(n, minimum, maximum, path)
    IntSchema(_, minimum, maximum), json_value.JsonFloat(f) ->
      case int.to_float(float.truncate(f)) == f {
        True -> check_int_range(float.truncate(f), minimum, maximum, path)
        False -> [type_error(path, "an integer", value)]
      }
    IntSchema(..), _ -> [type_error(path, "an integer", value)]

    FloatSchema(_), json_value.JsonFloat(_) -> []
    FloatSchema(_), json_value.JsonInt(_) -> []
    FloatSchema(_), _ -> [type_error(path, "a number", value)]

    BoolSchema(_), json_value.JsonBool(_) -> []
    BoolSchema(_), _ -> [type_error(path, "a boolean", value)]

    ArraySchema(items, _), json_value.JsonArray(elements) ->
      elements
      |> list.index_map(fn(element, index) {
        validate_at(items, element, [int.to_string(index), ..path])
      })
      |> list.flatten
    ArraySchema(..), _ -> [type_error(path, "an array", value)]
  }
}

fn check_int_range(
  n: Int,
  minimum: Option(Int),
  maximum: Option(Int),
  path: List(String),
) -> List(ValidationError) {
  let min_errors = case minimum {
    Some(min) if n < min -> [
      error_at(path, "Must be at least " <> int.to_string(min)),
    ]
    _ -> []
  }
  let max_errors = case maximum {
    Some(max) if n > max -> [
      error_at(path, "Must be at most " <> int.to_string(max)),
    ]
    _ -> []
  }
  list.append(min_errors, max_errors)
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn error_at(reversed_path: List(String), message: String) -> ValidationError {
  ValidationError(path: list.reverse(reversed_path), message: message)
}

fn type_error(
  reversed_path: List(String),
  expected: String,
  value: JsonValue,
) -> ValidationError {
  error_at(reversed_path, "Expected " <> expected <> ", got " <> kind(value))
}

fn kind(value: JsonValue) -> String {
  case value {
    json_value.JsonNull -> "null"
    json_value.JsonBool(_) -> "a boolean"
    json_value.JsonInt(_) -> "an integer"
    json_value.JsonFloat(_) -> "a number"
    json_value.JsonString(_) -> "a string"
    json_value.JsonArray(_) -> "an array"
    json_value.JsonObject(_) -> "an object"
  }
}
