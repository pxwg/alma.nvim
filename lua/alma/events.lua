local request_metadata = require("alma.ui.metadata")
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
  proposal_received = true,
  stop_generation = true,
  subagent_message = true,
  subagent_message_added = true,
  subagent_message_delta = true,
  subagent_message_completed = true,
}

M.global_ws_events = {}

local function data_of(raw)
  if type(raw) ~= "table" then
    return {}
  end
  return raw.data or raw.payload or raw
end

local function first_string(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return ""
end

local function first_table(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "table" then
      return value
    end
  end
  return nil
end

local function table_list(value)
  if type(value) ~= "table" then
    return {}
  end
  if #value > 0 then
    return value
  end
  local out = {}
  for _, item in pairs(value) do
    if type(item) == "table" then
      table.insert(out, item)
    end
  end
  return out
end

local function normalize_proposal_file(item)
  if type(item) ~= "table" then
    return nil
  end
  local diff = first_string(item.diff, item.patch, item.unified_diff, item.unifiedDiff)
  local path = first_string(item.path, item.file, item.filename, item.name)
  local relative_path = first_string(item.relative_path, item.relativePath, item.relpath)
  if path == "" and relative_path == "" and diff == "" and type(item.hunks) ~= "table" then
    return nil
  end
  return {
    path = path ~= "" and path or nil,
    relative_path = relative_path ~= "" and relative_path or nil,
    diff = diff ~= "" and diff or nil,
    hunks = type(item.hunks) == "table" and vim.deepcopy(item.hunks) or {},
    raw = item,
  }
end

local function proposal_payload(data)
  data = type(data) == "table" and data or {}
  return first_table(data.proposal, data.change, data.patchProposal, data.diffProposal) or data
end

local function proposal_files(source)
  local files = {}
  local list = table_list(first_table(source.files, source.changes, source.diffs, source.patches) or {})
  for _, item in ipairs(list) do
    local file = normalize_proposal_file(item)
    if file then
      table.insert(files, file)
    end
  end
  local top_level_file = normalize_proposal_file(source)
  if top_level_file and #files == 0 then
    table.insert(files, top_level_file)
  end
  return files
end

local function proposal_like_name(name)
  if type(name) ~= "string" then
    return false
  end
  return name == "proposal_received" or name:find("proposal", 1, true) ~= nil
end

function M.normalize_proposal(data, fallback_thread_id)
  local source = proposal_payload(data)
  local files = proposal_files(source)
  local id = first_string(source.id, source.proposal_id, source.proposalId, source.change_id, source.changeId)
  local thread_id = first_string(
    source.thread_id,
    source.threadId,
    source.parent_thread_id,
    source.parentThreadId,
    fallback_thread_id
  )
  local kind = first_string(source.kind, source.proposal_kind, source.proposalKind, source.format)
  if kind == "" then
    kind = #files > 0 and "diff" or "proposal"
  end
  local title = first_string(source.title, source.name, source.summary, source.subject)
  if title == "" then
    title = id ~= "" and ("Proposal " .. util.short_id(id)) or "Proposal"
  end
  local base_snapshot_id = first_string(
    source.base_snapshot_id,
    source.baseSnapshotId,
    source.base_id,
    source.baseId,
    source.snapshot_id,
    source.snapshotId
  )

  return {
    id = id ~= "" and id or nil,
    thread_id = thread_id ~= "" and thread_id or nil,
    kind = kind,
    title = title,
    base_snapshot_id = base_snapshot_id ~= "" and base_snapshot_id or nil,
    files = files,
    raw = data,
  }
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
  local task = data.task or raw.task or {}
  local name = raw.type or raw.event or raw.name
  local direct = data.threadId
    or data.thread_id
    or data.threadID
    or data.parentThreadId
    or data.parent_thread_id
    or thread.id
    or thread.threadId
    or thread.thread_id
    or thread.parentThreadId
    or thread.parent_thread_id
    or message.threadId
    or message.thread_id
    or message.parentThreadId
    or message.parent_thread_id
    or context.threadId
    or context.thread_id
    or context.parentThreadId
    or context.parent_thread_id
    or task.threadId
    or task.thread_id
    or task.threadID
    or task.parentThreadId
    or task.parent_thread_id
    or raw.threadId
    or raw.thread_id
    or raw.parentThreadId
    or raw.parent_thread_id
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
    data.parentThreadId,
    data.parent_thread_id,
    data.slotId,
    data.slot_id,
    message.parentThreadId,
    message.parent_thread_id,
    context.parentMessageId,
    context.parent_message_id,
    context.parentThreadId,
    context.parent_thread_id,
    task.parentThreadId,
    task.parent_thread_id,
    raw.id,
    raw.parentId,
    raw.parentThreadId,
    raw.parent_thread_id,
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
  local thread_id = M.thread_id_from(raw)
  if proposal_like_name(name) then
    data = M.normalize_proposal(data, thread_id)
    thread_id = data.thread_id or thread_id
    name = "proposal_received"
  end
  return {
    type = "ws_event",
    name = name,
    thread_id = thread_id,
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
  local msg = type(item.message) == "table" and item.message or {}
  return vim.tbl_deep_extend(
    "force",
    {},
    msg.metadata or {},
    msg.userMessageMetadata or {},
    item.metadata or {},
    item.userMessageMetadata or {}
  )
end

local function parent_id_of(item)
  if type(item) ~= "table" then
    return nil
  end
  local msg = message_of(item)
  return item.parentId or item.parent_id or msg.parentId or msg.parent_id
end

local function message_ids(item)
  if type(item) ~= "table" then
    return {}
  end
  local msg = message_of(item)
  local ids = {}
  local seen = {}
  for _, id in ipairs({ item.id, msg.id }) do
    if type(id) == "string" and id ~= "" and not seen[id] then
      table.insert(ids, id)
      seen[id] = true
    end
  end
  return ids
end

local function part_metadata(parent_metadata, part)
  if type(part) ~= "table" then
    return parent_metadata or {}
  end
  return vim.tbl_deep_extend("force", {}, parent_metadata or {}, part.metadata or {}, part.userMessageMetadata or {})
end

local function parts_text(parts)
  local text_parts = {}
  for _, part in ipairs(parts or {}) do
    local typ = part.type or "text"
    local text = part_text(part)
    if text ~= "" then
      table.insert(text_parts, text)
    elseif typ == "file" or typ == "image" then
      local filename = first_text(part.filename, part.name, "image")
      local url = first_text(part.path, part.url, part.uri, "attachment")
      if url:match("^data:") then
        url = "attachment"
      end
      table.insert(text_parts, "![" .. filename .. "](" .. url .. ")")
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
  local parent_id = parent_id_of(item)
  local parent_request_metadata = context.request_metadata_by_id and context.request_metadata_by_id[parent_id]
  local own_request_metadata = request_metadata.from_message(item)
  local inherited_request_metadata = own_request_metadata or parent_request_metadata

  local content = first_text(msg.content, msg.text, item.content, item.text)
  if content == "" and #parts > 0 then
    content = parts_text(parts)
  end
  if role == "user" and content == "" then
    content = first_text(metadata.original_text, metadata.originalText, metadata.userMessage, metadata.prompt)
  end

  if role == "user" then
    table.insert(blocks, request_metadata.apply_to_block({
      type = "UserBlock",
      message_id = id,
      metadata = metadata,
      text = content,
      raw = item,
    }, own_request_metadata))
    return blocks
  end

  if #parts == 0 then
    table.insert(blocks, request_metadata.apply_to_block({
      type = "AssistantBlock",
      message_id = id,
      metadata = metadata,
      text = content,
      raw = item,
    }, inherited_request_metadata))
    return blocks
  end

  local assistant_text = {}
  local function flush_assistant_text()
    if #assistant_text == 0 then
      return
    end
    table.insert(blocks, request_metadata.apply_to_block({
      type = "AssistantBlock",
      message_id = id,
      metadata = metadata,
      text = table.concat(assistant_text, "\n"),
      raw = item,
    }, inherited_request_metadata))
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
      table.insert(blocks, request_metadata.apply_to_block({
        type = "ReasoningBlock",
        message_id = id,
        metadata = part_metadata(metadata, part),
        text = part_text(part),
        state = part.state,
        raw = part,
      }, inherited_request_metadata))
    elseif typ == "step-start" then
      local text = part_text(part)
      if text ~= "" then
        flush_assistant_text()
        table.insert(blocks, request_metadata.apply_to_block({
          type = "AgentTimelineBlock",
          message_id = id,
          metadata = part_metadata(metadata, part),
          title = first_text(part.title, part.label, part.id, "step-start"),
          text = text,
          raw = part,
        }, inherited_request_metadata))
      end
    elseif vim.startswith(typ, "tool-") then
      flush_assistant_text()
      table.insert(blocks, request_metadata.apply_to_block({
        type = "ToolCallBlock",
        message_id = id,
        metadata = part_metadata(metadata, part),
        tool = tool_name(part),
        state = part.state,
        tool_call_id = part.toolCallId or part.tool_call_id,
        input = part.input,
        output = part.output,
        text = part_text(part),
        raw = part,
      }, inherited_request_metadata))
    else
      flush_assistant_text()
      table.insert(blocks, request_metadata.apply_to_block({
        type = "RawEventBlock",
        message_id = id,
        metadata = part_metadata(metadata, part),
        title = "Unknown message part: " .. tostring(typ),
        raw = part,
      }, inherited_request_metadata))
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
  local item_by_id = {}
  for _, item in ipairs(messages) do
    for _, id in ipairs(message_ids(item)) do
      item_by_id[id] = item
    end
  end

  local resolving = {}
  local function cache_request_metadata(item, metadata)
    if not metadata then
      return
    end
    for _, id in ipairs(message_ids(item)) do
      context.request_metadata_by_id[id] = metadata
    end
  end

  local resolve_by_id
  local function resolve_item_request_metadata(item)
    if type(item) ~= "table" then
      return nil
    end
    local own = request_metadata.from_message(item)
    if own then
      cache_request_metadata(item, own)
      return own
    end
    return resolve_by_id(parent_id_of(item))
  end

  resolve_by_id = function(id)
    if type(id) ~= "string" or id == "" then
      return nil
    end
    if context.request_metadata_by_id[id] then
      return context.request_metadata_by_id[id]
    end
    if resolving[id] then
      return nil
    end
    local item = item_by_id[id]
    if not item then
      return nil
    end
    resolving[id] = true
    local metadata = resolve_item_request_metadata(item)
    resolving[id] = nil
    if metadata then
      cache_request_metadata(item, metadata)
      if not context.request_metadata_by_id[id] then
        context.request_metadata_by_id[id] = metadata
      end
    end
    return metadata
  end

  for _, item in ipairs(messages) do
    local metadata = resolve_item_request_metadata(item)
    if metadata then
      cache_request_metadata(item, metadata)
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
