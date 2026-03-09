/// Conversation message types.
/// Discriminated union by role with typed content parts.

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: List(UserContent))
  AssistantMessage(content: List(AssistantContent))
  ToolResultMessage(results: List(ToolResult))
}

pub type UserContent {
  UserText(text: String)
  UserFile(data: FileData, media_type: String)
}

pub type AssistantContent {
  AssistantText(text: String)
  AssistantReasoning(text: String)
  AssistantToolCall(
    tool_call_id: String,
    tool_name: String,
    arguments_json: String,
  )
}

pub type ToolResult {
  ToolResultOk(tool_call_id: String, tool_name: String, output: String)
  ToolResultError(
    tool_call_id: String,
    tool_name: String,
    error_message: String,
  )
}

pub type FileData {
  Base64Data(data: String)
  UrlData(url: String)
}

// --- Convenience constructors ---

pub fn system(content: String) -> Message {
  SystemMessage(content: content)
}

pub fn user(text: String) -> Message {
  UserMessage(content: [UserText(text: text)])
}

pub fn user_parts(content: List(UserContent)) -> Message {
  UserMessage(content: content)
}

pub fn assistant(text: String) -> Message {
  AssistantMessage(content: [AssistantText(text: text)])
}

pub fn tool_results(results: List(ToolResult)) -> Message {
  let assert True = !{
    results
    |> list.is_empty
  }
  ToolResultMessage(results: results)
}

import gleam/list
