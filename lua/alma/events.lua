local util = require("alma.util")

local M = {}

M.known_ws_events = {
  thread_created = true,
  thread_updated = true,
  thread_deleted = true,
  thread_generating = true,
  thread_workspace_set = true,
  message_added = true,
  message_updated = true,
  message_delta = true,
  message_deleted = true,
  message_rollback = true,
  part_add = true,
  part_update = true,
  text_delta = true,
  ["reasoning-delta"] = true,
  ["step-start"] = true,
  tool_input_append = true,
  tool_output_set = true,
  tool_output_streaming = true,
  tool_analysis_progress = true,
  context_usage_update = true,
  memory_retrieval_progress = true,
  skill_analysis_progress = true,
  generation_completed = true,
  generation_error = true,
  stop_generation = true,
}

local function data_of(raw)
  if type(raw) ~= "table" then
    return {}
  end
  return raw.data or raw.payload or raw
end

local function composite_thread_id(...)
  for _, value in ipairs({ ... }) do
    if type(value) == "string" then
      local thread_id = value:match("^(.-)%-%-")
      if thread_id and thread_id ~= "" then
        return thread_id
      end
    end
  end
  return nil
end

function M.is_thread_scoped_event(name)
  return M.known_ws_events[name] == true
end

function M.thread_id_from(raw)
  local data = data_of(raw)
  local message = data.message or raw.message or {}
  local thread = data.thread or raw.thread or {}
  local name = raw.type or raw.event or raw.name
  local direct = data.threadId
    or data.thread_id
    or data.threadID
    or thread.id
    or thread.threadId
    or message.threadId
    or message.thread_id
    or raw.threadId
    or raw.thread_id
  if direct then
    return direct
  end
  if type(name) == "string" and vim.startswith(name, "thread_") then
    return data.id or raw.id
  end
  return composite_thread_id(data.id, data.parentId, data.parent_id, data.slotId, data.slot_id, raw.id, raw.parentId, raw.slotId)
end

function M.normalize_ws_event(raw)
  if type(raw) == "string" then
    local decoded = util.json_decode(raw)
    raw = decoded or { type = "raw_text", data = raw }
  end

  local name = raw.type or raw.event or raw.name or "unknown"
  local data = data_of(raw)
  return {
    type = "ws_event",
    name = name,
    thread_id = M.thread_id_from(raw),
    data = data,
    raw = raw,
    known = M.known_ws_events[name] == true,
  }
end

local function first_text(...)
  for _, value in ipairs({ ... }) do
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return ""
end

local function message_of(item)
  if type(item) ~= "table" then
    return {}
  end
  return item.message or item
end

local function part_text(part)
  return first_text(part.text, part.content, part.delta, part.value, part.output)
end

local function tool_name(part)
  local typ = part.type or "tool"
  return typ:gsub("^tool%-", "")
end

local function metadata_of(item)
  if type(item) ~= "table" then
    return {}
  end
  return item.metadata or item.userMessageMetadata or {}
end

local function parts_text(parts)
  local text_parts = {}
  for _, part in ipairs(parts or {}) do
    local text = part_text(part)
    if text ~= "" then
      table.insert(text_parts, text)
    end
  end
  return table.concat(text_parts, "\n")
end

local function looks_like_user_message(item, msg, id)
  if msg.role == "user" or item.role == "user" then
    return true
  end
  if type(id) == "string" and (vim.startswith(id, "user-") or id:find("%-%-user%-") ~= nil) then
    return true
  end
  return first_text(metadata_of(item).original_text, metadata_of(item).originalText) ~= ""
end

local function block_from_message(item, index)
  local msg = message_of(item)
  local id = msg.id or item.id or ("message-" .. index)
  local role = msg.role or msg.type or item.role
  if not role then
    role = looks_like_user_message(item, msg, id) and "user" or "assistant"
  end
  local parts = msg.parts or item.parts or {}
  local blocks = {}
  local metadata = metadata_of(item)

  local content = first_text(msg.content, msg.text, item.content, item.text)
  if content == "" and #parts > 0 then
    content = parts_text(parts)
  end
  if role == "user" and content == "" then
    content = first_text(metadata.original_text, metadata.originalText, metadata.userMessage, metadata.prompt)
  end

  if role == "user" then
    table.insert(blocks, {
      type = "UserBlock",
      message_id = id,
      text = content,
      raw = item,
    })
    return blocks
  end

  if #parts == 0 then
    table.insert(blocks, {
      type = "AssistantBlock",
      message_id = id,
      text = content,
      raw = item,
    })
    return blocks
  end

  local assistant_text = {}
  for _, part in ipairs(parts) do
    local typ = part.type or "text"
    if typ == "text" then
      local text = part_text(part)
      if text ~= "" then
        table.insert(assistant_text, text)
      end
    elseif typ == "reasoning" then
      table.insert(blocks, {
        type = "ReasoningBlock",
        message_id = id,
        text = part_text(part),
        state = part.state,
        raw = part,
      })
    elseif typ == "step-start" then
      table.insert(blocks, {
        type = "AgentTimelineBlock",
        message_id = id,
        title = first_text(part.title, part.label, part.id, "step-start"),
        text = part_text(part),
        raw = part,
      })
    elseif vim.startswith(typ, "tool-") then
      table.insert(blocks, {
        type = "ToolCallBlock",
        message_id = id,
        tool = tool_name(part),
        state = part.state,
        tool_call_id = part.toolCallId or part.tool_call_id,
        input = part.input,
        output = part.output,
        text = part_text(part),
        raw = part,
      })
    else
      table.insert(blocks, {
        type = "RawEventBlock",
        message_id = id,
        title = "Unknown message part: " .. tostring(typ),
        raw = part,
      })
    end
  end

  if #assistant_text > 0 then
    table.insert(blocks, 1, {
      type = "AssistantBlock",
      message_id = id,
      text = table.concat(assistant_text, "\n"),
      raw = item,
    })
  end

  return blocks
end

function M.normalize_messages(messages)
  local blocks = {}
  if type(messages) ~= "table" then
    return blocks
  end
  for index, item in ipairs(messages) do
    util.list_extend(blocks, block_from_message(item, index))
  end
  return blocks
end

function M.block_text(block)
  if not block then
    return ""
  end
  if type(block.text) == "string" and block.text ~= "" then
    return block.text
  end
  if block.output ~= nil then
    if type(block.output) == "string" then
      return block.output
    end
    return vim.inspect(block.output)
  end
  if block.input ~= nil then
    if type(block.input) == "string" then
      return block.input
    end
    return vim.inspect(block.input)
  end
  if block.raw ~= nil then
    return vim.inspect(block.raw)
  end
  return ""
end

return M
