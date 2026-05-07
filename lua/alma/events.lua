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
  context_compaction_started = true,
  context_compaction_completed = true,
  memory_retrieval_progress = true,
  skill_analysis_progress = true,
  generation_completed = true,
  generation_error = true,
  stop_generation = true,
  subagent_message_delta = true,
}

M.global_ws_events = {}

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

function M.is_global_ws_event(name)
  return M.global_ws_events[name] == true
end

function M.thread_id_from(raw)
  local data = data_of(raw)
  local message = data.message or raw.message or {}
  local thread = data.thread or raw.thread or {}
  local context = data.context or raw.context or {}
  local name = raw.type or raw.event or raw.name
  local direct = data.threadId
    or data.thread_id
    or data.threadID
    or thread.id
    or thread.threadId
    or message.threadId
    or message.thread_id
    or context.threadId
    or context.thread_id
    or raw.threadId
    or raw.thread_id
  if direct then
    return direct
  end
  for _, delta in ipairs(data.deltas or raw.deltas or {}) do
    local delta_thread_id = delta.threadId or delta.thread_id or delta.threadID
    if delta_thread_id then
      return delta_thread_id
    end
  end
  if type(name) == "string" and vim.startswith(name, "thread_") then
    return data.id or raw.id
  end
  return composite_thread_id(
    data.id,
    data.parentId,
    data.parent_id,
    data.slotId,
    data.slot_id,
    context.parentMessageId,
    context.parent_message_id,
    raw.id,
    raw.parentId,
    raw.slotId
  )
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
  for index = 1, select("#", ...) do
    local value = select(index, ...)
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

local function token_metadata_from_original(metadata)
  local original = first_text(metadata.original_text, metadata.originalText)
  local found = {}
  for _, line in ipairs(util.split_lines(original)) do
    local trimmed = util.trim(line)
    found.model = found.model or trimmed:match("^%$model:%s*(.+)$")
    found.reasoning_effort = found.reasoning_effort or trimmed:match("^%$reasoning:%s*(.+)$")
  end
  if found.model then
    found.model = util.trim(found.model)
  end
  if found.reasoning_effort then
    found.reasoning_effort = util.trim(found.reasoning_effort)
  end
  return found
end

local function request_metadata(metadata)
  local legacy = token_metadata_from_original(metadata)
  local model = first_text(metadata.model, metadata.request_model, metadata.requestModel, metadata.ephemeralModel, legacy.model)
  local reasoning = first_text(metadata.reasoning_effort, metadata.reasoningEffort, legacy.reasoning_effort)
  if model == "" and reasoning == "" then
    return nil
  end
  return {
    model = model ~= "" and model or nil,
    reasoning_effort = reasoning ~= "" and reasoning or nil,
    model_override = metadata.modelOverride == true,
    reasoning_override = metadata.reasoningOverride == true,
  }
end

local function apply_request_metadata(block, metadata)
  if not block or not metadata then
    return block
  end
  block.request_model = metadata.model
  block.request_reasoning_effort = metadata.reasoning_effort
  block.model_override = metadata.model_override
  block.reasoning_override = metadata.reasoning_override
  return block
end

local function block_from_message(item, index, context)
  context = context or {}
  local msg = message_of(item)
  local id = msg.id or item.id or ("message-" .. index)
  local role = msg.role or msg.type or item.role
  if not role then
    role = looks_like_user_message(item, msg, id) and "user" or "assistant"
  end
  local parts = msg.parts or item.parts or {}
  local blocks = {}
  local metadata = metadata_of(item)
  local parent_request_metadata = context.request_metadata_by_id and context.request_metadata_by_id[item.parentId or item.parent_id]

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
    table.insert(blocks, apply_request_metadata({
      type = "AssistantBlock",
      message_id = id,
      text = content,
      raw = item,
    }, parent_request_metadata))
    return blocks
  end

  local assistant_text = {}
  local function flush_assistant_text()
    if #assistant_text == 0 then
      return
    end
    table.insert(blocks, apply_request_metadata({
      type = "AssistantBlock",
      message_id = id,
      text = table.concat(assistant_text, "\n"),
      raw = item,
    }, parent_request_metadata))
    assistant_text = {}
  end

  for _, part in ipairs(parts) do
    local typ = part.type or "text"
    if typ == "text" then
      local text = part_text(part)
      if text ~= "" then
        table.insert(assistant_text, text)
      end
    elseif typ == "reasoning" then
      flush_assistant_text()
      table.insert(blocks, apply_request_metadata({
        type = "ReasoningBlock",
        message_id = id,
        text = part_text(part),
        state = part.state,
        raw = part,
      }, parent_request_metadata))
    elseif typ == "step-start" then
      flush_assistant_text()
      table.insert(blocks, apply_request_metadata({
        type = "AgentTimelineBlock",
        message_id = id,
        title = first_text(part.title, part.label, part.id, "step-start"),
        text = part_text(part),
        raw = part,
      }, parent_request_metadata))
    elseif vim.startswith(typ, "tool-") then
      flush_assistant_text()
      table.insert(blocks, apply_request_metadata({
        type = "ToolCallBlock",
        message_id = id,
        tool = tool_name(part),
        state = part.state,
        tool_call_id = part.toolCallId or part.tool_call_id,
        input = part.input,
        output = part.output,
        text = part_text(part),
        raw = part,
      }, parent_request_metadata))
    else
      flush_assistant_text()
      table.insert(blocks, apply_request_metadata({
        type = "RawEventBlock",
        message_id = id,
        title = "Unknown message part: " .. tostring(typ),
        raw = part,
      }, parent_request_metadata))
    end
  end
  flush_assistant_text()

  return blocks
end

function M.normalize_messages(messages)
  local blocks = {}
  if type(messages) ~= "table" then
    return blocks
  end

  local context = { request_metadata_by_id = {} }
  for _, item in ipairs(messages) do
    local msg = message_of(item)
    local id = msg.id or item.id
    if looks_like_user_message(item, msg, id) then
      local metadata = request_metadata(metadata_of(item))
      if metadata then
        if item.id then
          context.request_metadata_by_id[item.id] = metadata
        end
        if msg.id then
          context.request_metadata_by_id[msg.id] = metadata
        end
      end
    end
  end

  for index, item in ipairs(messages) do
    util.list_extend(blocks, block_from_message(item, index, context))
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
