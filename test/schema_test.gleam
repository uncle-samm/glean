import gleam/option.{None, Some}
import glean/error.{ValidationError}
import glean/schema
import gleeunit/should

pub fn string_schema_to_json_test() {
  let s = schema.string()
  let json_str = schema.to_json_string(s)
  json_str
  |> should.equal("{\"type\":\"string\"}")
}

pub fn string_with_description_test() {
  let s =
    schema.string()
    |> schema.describe("A name")
  let json_str = schema.to_json_string(s)
  json_str
  |> should.equal("{\"description\":\"A name\",\"type\":\"string\"}")
}

pub fn int_schema_test() {
  let s = schema.int()
  schema.to_json_string(s)
  |> should.equal("{\"type\":\"integer\"}")
}

pub fn int_range_test() {
  let s = schema.int_range(minimum: 0, maximum: 100)
  let json_str = schema.to_json_string(s)
  // Should contain minimum and maximum
  should.be_true(contains(json_str, "\"minimum\":0"))
  should.be_true(contains(json_str, "\"maximum\":100"))
}

pub fn float_schema_test() {
  schema.float()
  |> schema.to_json_string
  |> should.equal("{\"type\":\"number\"}")
}

pub fn bool_schema_test() {
  schema.bool()
  |> schema.to_json_string
  |> should.equal("{\"type\":\"boolean\"}")
}

pub fn string_enum_test() {
  let s = schema.string_enum(values: ["red", "green", "blue"])
  let json_str = schema.to_json_string(s)
  should.be_true(contains(json_str, "\"enum\""))
  should.be_true(contains(json_str, "\"red\""))
}

pub fn array_schema_test() {
  let s = schema.array(of: schema.string())
  let json_str = schema.to_json_string(s)
  should.be_true(contains(json_str, "\"type\":\"array\""))
  should.be_true(contains(json_str, "\"items\""))
}

pub fn object_schema_test() {
  let s =
    schema.object(
      properties: [#("name", schema.string()), #("age", schema.int())],
      required: ["name"],
    )
  let json_str = schema.to_json_string(s)
  should.be_true(contains(json_str, "\"type\":\"object\""))
  should.be_true(contains(json_str, "\"properties\""))
  should.be_true(contains(json_str, "\"required\""))
  should.be_true(contains(json_str, "\"name\""))
}

pub fn nullable_schema_test() {
  let s = schema.nullable(schema.string())
  let json_str = schema.to_json_string(s)
  should.be_true(contains(json_str, "\"anyOf\""))
  should.be_true(contains(json_str, "\"null\""))
}

pub fn string_with_length_test() {
  let s = schema.string_with_length(min_length: Some(1), max_length: Some(100))
  let json_str = schema.to_json_string(s)
  should.be_true(contains(json_str, "\"minLength\":1"))
  should.be_true(contains(json_str, "\"maxLength\":100"))
}

import gleam/string

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

pub fn empty_object_schema_test() {
  // Tools with no arguments need an object schema with no properties.
  schema.object(properties: [], required: [])
  |> schema.to_json_string
  |> should.equal("{\"type\":\"object\",\"properties\":{}}")
}

fn person() {
  schema.object(
    properties: [
      #(
        "name",
        schema.string_with_length(min_length: Some(1), max_length: None),
      ),
      #("age", schema.int_range(minimum: 0, maximum: 150)),
      #("tags", schema.array(of: schema.string_enum(values: ["a", "b"]))),
      #("nick", schema.nullable(schema.string())),
    ],
    required: ["name", "age"],
  )
}

pub fn validate_accepts_matching_json_test() {
  schema.validate_json(
    person(),
    "{\"name\":\"Sam\",\"age\":30.0,\"tags\":[\"a\"],\"nick\":null,\"extra\":1}",
  )
  |> should.be_ok
}

pub fn validate_reports_every_error_with_path_test() {
  let assert Error(errors) =
    schema.validate_json(person(), "{\"name\":\"\",\"tags\":[\"a\",\"c\",1]}")
  errors
  |> should.equal([
    ValidationError(path: ["age"], message: "Missing required field"),
    ValidationError(path: ["name"], message: "Must be at least 1 characters"),
    ValidationError(path: ["tags", "1"], message: "Must be one of: a, b"),
    ValidationError(
      path: ["tags", "2"],
      message: "Expected a string, got an integer",
    ),
  ])
}

pub fn validate_checks_ranges_and_types_test() {
  let assert Error(errors) =
    schema.validate_json(person(), "{\"name\":\"x\",\"age\":200}")
  errors
  |> should.equal([
    ValidationError(path: ["age"], message: "Must be at most 150"),
  ])

  schema.validate_json(schema.int(), "1.5")
  |> should.equal(
    Error([
      ValidationError(path: [], message: "Expected an integer, got a number"),
    ]),
  )

  schema.validate_json(schema.float(), "2")
  |> should.be_ok

  schema.validate_json(schema.object(properties: [], required: []), "[]")
  |> should.equal(
    Error([
      ValidationError(path: [], message: "Expected an object, got an array"),
    ]),
  )
}

pub fn validate_rejects_invalid_json_test() {
  schema.validate_json(schema.object(properties: [], required: []), "{not json")
  |> should.equal(
    Error([ValidationError(path: [], message: "Input is not valid JSON")]),
  )
}

pub fn one_of_accepts_any_variant_test() {
  let s = schema.one_of(variants: [schema.int(), schema.string()])
  schema.validate_json(s, "1") |> should.be_ok
  schema.validate_json(s, "\"x\"") |> should.be_ok
  schema.validate_json(s, "true")
  |> should.equal(
    Error([
      ValidationError(
        path: [],
        message: "Value matches none of the allowed variants",
      ),
    ]),
  )
}

pub fn object_keeps_property_order_test() {
  schema.object(
    properties: [#("zeta", schema.int()), #("alpha", schema.int())],
    required: [],
  )
  |> schema.to_json_string
  |> should.equal(
    "{\"type\":\"object\",\"properties\":{\"zeta\":{\"type\":\"integer\"},\"alpha\":{\"type\":\"integer\"}}}",
  )
}

pub fn strict_compatible_test() {
  let all_required =
    schema.object(
      properties: [
        #("name", schema.string()),
        #("nick", schema.nullable(schema.string())),
      ],
      required: ["name", "nick"],
    )
  schema.is_strict_compatible(all_required) |> should.be_true

  let optional_field =
    schema.object(properties: [#("name", schema.string())], required: [])
  schema.is_strict_compatible(optional_field) |> should.be_false

  schema.is_strict_compatible(schema.string()) |> should.be_false
}
