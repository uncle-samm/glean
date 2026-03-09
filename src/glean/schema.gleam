/// JSON Schema builder for tool input/output definitions.
/// Opaque type with explicit builder functions — no macros, no reflection.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub opaque type Schema {
  ObjectSchema(
    properties: Dict(String, Schema),
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
  let assert True = !list.is_empty(properties)
  let prop_dict = dict.from_list(properties)
  // Assert all required fields exist in properties
  let prop_names = list.map(properties, fn(p) { p.0 })
  list.each(required, fn(r) {
    let assert True = list.contains(prop_names, r)
  })
  ObjectSchema(properties: prop_dict, required: required, description: None)
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
    StringSchema(_, e, mn, mx) ->
      StringSchema(Some(description), e, mn, mx)
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
  properties: Dict(String, Schema),
  required: List(String),
  description: Option(String),
) -> Json {
  let props =
    properties
    |> dict.to_list
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

fn one_of_to_json(
  variants: List(Schema),
  description: Option(String),
) -> Json {
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
  properties: Dict(String, Schema),
  required: List(String),
  description: Option(String),
) -> Json {
  let props =
    properties
    |> dict.to_list
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
    #(
      "oneOf",
      json.preprocessed_array([to_json_strict(inner), type_null()]),
    ),
  ])
}

fn one_of_to_json_strict(
  variants: List(Schema),
  description: Option(String),
) -> Json {
  let variant_jsons = list.map(variants, to_json_strict)
  [#("oneOf", json.preprocessed_array(variant_jsons))]
  |> with_description(description)
  |> json.object
}
