import gleam/option.{Some}
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
  should.be_true(contains(json_str, "\"oneOf\""))
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
