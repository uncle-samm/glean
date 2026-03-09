import glean/message
import gleeunit/should

pub fn system_message_test() {
  let msg = message.system("You are helpful")
  case msg {
    message.SystemMessage(content) ->
      content |> should.equal("You are helpful")
    _ -> panic as "Expected SystemMessage"
  }
}

pub fn user_message_test() {
  let msg = message.user("Hello")
  case msg {
    message.UserMessage(content) -> {
      let assert [message.UserText(text)] = content
      text |> should.equal("Hello")
    }
    _ -> panic as "Expected UserMessage"
  }
}

pub fn assistant_message_test() {
  let msg = message.assistant("Hi there")
  case msg {
    message.AssistantMessage(content) -> {
      let assert [message.AssistantText(text)] = content
      text |> should.equal("Hi there")
    }
    _ -> panic as "Expected AssistantMessage"
  }
}

pub fn user_parts_message_test() {
  let msg =
    message.user_parts([
      message.UserText(text: "Look at this"),
      message.UserFile(
        data: message.UrlData(url: "https://example.com/img.png"),
        media_type: "image/png",
      ),
    ])
  case msg {
    message.UserMessage(content) -> {
      let assert 2 = list.length(content)
    }
    _ -> panic as "Expected UserMessage"
  }
}

import gleam/list
