import gleam/json
import glean/json_value
import gleeunit/should

pub fn round_trip_test() {
  let assert Ok(value) =
    json.parse(
      "{\"a\":[1,2.5,\"x\",true,null],\"b\":{\"c\":-3}}",
      json_value.decoder(),
    )
  let assert Ok(again) = json.parse(json_value.to_string(value), json_value.decoder())
  again |> should.equal(value)
}

pub fn arguments_object_is_kept_test() {
  json_value.arguments_to_object("{\"city\":\"Tokyo\"}")
  |> json.to_string
  |> should.equal("{\"city\":\"Tokyo\"}")
}

pub fn invalid_arguments_are_wrapped_not_dropped_test() {
  json_value.arguments_to_object("{not json")
  |> json.to_string
  |> should.equal("{\"invalid_arguments\":\"{not json\"}")

  // Valid JSON that isn't an object can't be sent as tool input either.
  json_value.arguments_to_object("[1]")
  |> json.to_string
  |> should.equal("{\"invalid_arguments\":\"[1]\"}")
}
