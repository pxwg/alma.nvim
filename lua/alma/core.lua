local config = require("alma.config")
local events = require("alma.events")
local request_metadata = require("alma.ui.metadata")
local util = require("alma.util")

local M = {}

local busy_states = {
  composing = true,
  submitted = true,
  waiting_backend = true,
  streaming = true,
  tool_running = true,
  reconciling = true,
  cancelling = true,
}

local persisted_response_block_types = {
  AssistantBlock = true,
  ReasoningBlock = true,
  ToolCallBlock = true,
  ToolOutputBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  ErrorBlock = true,
}

local function is_busy(thread)
  return thread.backend_generating or busy_states[thread.generation] == true
end

local function request_user_block(request)
  return request_metadata.apply_to_block({
    type = "UserBlock",
    text = request.spec.display_prompt or request.spec.prompt,
    local_only = true,
    metadata = request.spec.metadata,
    context_count = #(request.spec.ephemeral_context or {}),
  }, request_metadata.from_request(request))
end

local function request_assistant_block(request, block)
  return request_metadata.apply_to_block(block, request_metadata.from_request(request))
end

local function queued_block(request)
  local block = request_user_block(request)
  block.state = "queued"
  return block
end

local function queued_assistant_block(request)
  return request_assistant_block(request, {
    type = "QueuedBlock",
    text = "This request will send after the current response finishes.",
    state = "queued",
    local_only = true,
  })
end

local function message_text(message)
  local msg = message and (message.message or message) or {}
  if msg.role ~= "user" then
    return ""
  end
  local parts = msg.parts or {}
  local text_parts = {}
  for _, part in ipairs(parts) do
    if part.type == "text" and type(part.text) == "string" and part.text ~= "" then
      table.insert(text_parts, part.text)
    end
  end
  return util.trim(table.concat(text_parts, "\n"))
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

local function stream_delta_kind(delta)
  local delta_type = delta.type or ""
  local part_type = delta.partType or delta.part_type or delta.part and delta.part.type or ""
  if delta_type == "reasoning_delta" or delta_type == "reasoning-delta" or delta_type == "reasoning_append" then
    return "reasoning"
  end
  if delta_type == "text_append" or delta_type == "text_delta" then
    if part_type == "reasoning" or part_type == "reasoning-delta" then
      return "reasoning"
    end
    if part_type == "" or part_type == "text" then
      return "text"
    end
  end
  return nil
end

local function stream_delta_chunks(data, event_name)
  data = data or {}
  local chunks = { text = {}, reasoning = {} }
  local direct = first_string(data.delta, data.text, data.content)
  if direct ~= "" then
    local kind = event_name == "reasoning-delta" and "reasoning" or "text"
    table.insert(chunks[kind], direct)
  end

  for _, delta in ipairs(data.deltas or {}) do
    local kind = stream_delta_kind(delta)
    if kind then
      local text = first_string(delta.text, delta.delta, delta.content, delta.value)
      if text ~= "" then
        table.insert(chunks[kind], text)
      end
    end
  end
  return table.concat(chunks.text), table.concat(chunks.reasoning)
end

local subagent_ws_events = {
  subagent_message = true,
  subagent_message_added = true,
  subagent_message_delta = true,
  subagent_message_completed = true,
}

local function is_subagent_event(name)
  return subagent_ws_events[name] == true
end

local function optional_string(...)
  local value = first_string(...)
  return value ~= "" and value or nil
end

local function copy_value(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  return value
end

local function subagent_context(data)
  data = type(data) == "table" and data or {}
  return data.context or data.task or {}
end

local function subagent_task_id(data)
  data = type(data) == "table" and data or {}
  local context = subagent_context(data)
  local message = type(data.message) == "table" and data.message or {}
  return first_string(
    context.taskId,
    context.task_id,
    context.id,
    context.subAgentId,
    context.subagentId,
    data.taskId,
    data.task_id,
    data.id,
    data.subAgentId,
    data.subagentId,
    message.id,
    context.parentToolCallId,
    data.parentToolCallId
  )
end

local function reset_subagent_streams(thread)
  thread.subagent_streams = {}
  thread.subagent_order = {}
end

local function ensure_subagent_acc(thread, data)
  data = type(data) == "table" and data or {}
  thread.subagent_streams = thread.subagent_streams or {}
  thread.subagent_order = thread.subagent_order or {}
  local context = subagent_context(data)
  local task_id = subagent_task_id(data)
  if task_id == "" then
    task_id = "subagent-" .. tostring(#thread.subagent_order + 1)
  end
  local acc = thread.subagent_streams[task_id]
  if not acc then
    acc = {
      task_id = task_id,
      context = vim.deepcopy(context),
      parts = {},
      is_streaming = true,
    }
    thread.subagent_streams[task_id] = acc
    table.insert(thread.subagent_order, task_id)
  else
    acc.context = vim.tbl_deep_extend("force", {}, acc.context or {}, context)
  end
  return acc
end

local function subagent_part_from(part, fallback_type)
  if type(part) ~= "table" then
    return nil
  end
  local typ = first_string(part.type, part.partType, part.part_type, fallback_type, "text")
  return {
    type = typ,
    text = first_string(part.text, part.content, part.delta, part.value),
    toolName = optional_string(part.toolName, part.tool_name, part.name, part.tool),
    toolCallId = optional_string(part.toolCallId, part.tool_call_id),
    state = optional_string(part.state, part.status),
    input = copy_value(part.args or part.input),
    output = copy_value(part.output),
    metadata = copy_value(part.metadata or part.userMessageMetadata),
    raw = part,
  }
end

local function subagent_message_parts(data)
  data = type(data) == "table" and data or {}
  local message = data.message or data.subagentMessage or data.subagent_message or data
  local parts = type(message) == "table" and (message.parts or message.contentParts) or nil
  if type(parts) == "table" then
    return parts
  end
  local text = type(message) == "table" and first_string(message.text, message.content, data.text, data.content) or ""
  if text ~= "" then
    return { { type = "text", text = text } }
  end
  return nil
end

local function replace_subagent_parts(acc, data)
  local parts = subagent_message_parts(data)
  if not parts then
    return false
  end
  acc.parts = {}
  for _, part in ipairs(parts) do
    local converted = subagent_part_from(part)
    if converted then
      table.insert(acc.parts, converted)
    end
  end
  return true
end

local function delta_part_index(delta)
  local index = delta.partIndex or delta.part_index or delta.index
  index = tonumber(index)
  if not index or index < 0 then
    return nil
  end
  return index + 1
end

local function ensure_subagent_part(acc, index, typ)
  typ = typ or "text"
  if not index then
    for existing_index = #acc.parts, 1, -1 do
      local part = acc.parts[existing_index]
      if part.type == typ or (typ == "text" and part.type == "text") then
        return part
      end
    end
    table.insert(acc.parts, { type = typ, text = "" })
    return acc.parts[#acc.parts]
  end
  while #acc.parts < index do
    table.insert(acc.parts, { type = typ, text = "" })
  end
  acc.parts[index].type = acc.parts[index].type or typ
  acc.parts[index].text = acc.parts[index].text or ""
  return acc.parts[index]
end

local function find_subagent_part(acc, delta)
  local index = delta_part_index(delta)
  if index and acc.parts[index] then
    return acc.parts[index]
  end
  local tool_call_id = delta.toolCallId or delta.tool_call_id
  if tool_call_id then
    for _, part in ipairs(acc.parts) do
      if part.toolCallId == tool_call_id then
        return part
      end
    end
  end
  return nil
end

local function apply_subagent_delta(acc, delta)
  if type(delta) ~= "table" then
    return
  end
  local delta_type = delta.type or ""
  if delta_type == "part_add" then
    local converted = subagent_part_from(delta.part or delta, delta.partType or delta.part_type)
    if converted then
      table.insert(acc.parts, converted)
    end
  elseif delta_type == "text_append"
    or delta_type == "text_delta"
    or delta_type == "reasoning_delta"
    or delta_type == "reasoning_append"
  then
    local kind = stream_delta_kind(delta) or (delta_type:find("reasoning", 1, true) and "reasoning" or "text")
    local part = ensure_subagent_part(acc, delta_part_index(delta), kind)
    part.type = kind
    part.text = (part.text or "") .. first_string(delta.text, delta.delta, delta.content, delta.value)
  elseif delta_type == "tool_input_append" then
    local part = find_subagent_part(acc, delta)
      or ensure_subagent_part(acc, nil, first_string(delta.partType, delta.part_type, "tool"))
    part.type = part.type or "tool"
    part.input = type(part.input) == "table" and part.input or {}
    local key = first_string(delta.inputKey, delta.input_key, delta.key, "input")
    local input_delta = first_string(delta.text, delta.delta, delta.content, delta.value)
    part.input[key] = tostring(part.input[key] or "") .. input_delta
  elseif delta_type == "tool_output_set"
    or delta_type == "tool_output_append"
    or delta_type == "tool_output_streaming"
  then
    local part = find_subagent_part(acc, delta)
      or ensure_subagent_part(acc, nil, first_string(delta.partType, delta.part_type, "tool"))
    part.type = part.type or "tool"
    if delta.state or delta.status then
      part.state = delta.state or delta.status
    end
    local output = first_string(delta.output, delta.text, delta.delta, delta.content, delta.value)
    if output ~= "" then
      if delta_type == "tool_output_append" or delta_type == "tool_output_streaming" then
        part.output = tostring(part.output or "") .. output
      else
        part.output = output
      end
    end
  elseif delta_type == "part_update" then
    local part = find_subagent_part(acc, delta)
    if not part then
      return
    end
    local updates = delta.updates or delta.part or delta
    if type(updates) ~= "table" then
      return
    end
    part.state = updates.state or updates.status or part.state
    part.toolName = updates.toolName or updates.tool_name or updates.name or part.toolName
    part.toolCallId = updates.toolCallId or updates.tool_call_id or part.toolCallId
    part.input = copy_value(updates.args or updates.input) or part.input
    part.output = copy_value(updates.output) or part.output
    local text = first_string(updates.text, updates.content, updates.delta, updates.value)
    if text ~= "" then
      part.text = text
    end
  elseif delta_type == "text_done" or delta_type == "part_done" then
    local part = find_subagent_part(acc, delta)
    if part then
      part.state = part.state or "done"
    end
  end
end

local function apply_subagent_event(thread, event)
  local data = event.data or {}
  local acc = ensure_subagent_acc(thread, data)
  local message = type(data.message) == "table" and data.message or {}
  acc.message_role = optional_string(message.role, data.role, acc.message_role)
  local replaced = false
  if event.name == "subagent_message"
    or event.name == "subagent_message_added"
    or (event.name == "subagent_message_completed" and subagent_message_parts(data) ~= nil)
  then
    replaced = replace_subagent_parts(acc, data)
  end
  if type(data.deltas) == "table" then
    for _, delta in ipairs(data.deltas) do
      apply_subagent_delta(acc, delta)
    end
  elseif not replaced then
    local text_delta, reasoning_delta = stream_delta_chunks(data, event.name)
    if reasoning_delta ~= "" then
      apply_subagent_delta(acc, { type = "reasoning_delta", text = reasoning_delta })
    end
    if text_delta ~= "" then
      apply_subagent_delta(acc, { type = "text_append", text = text_delta })
    end
  end
  if event.name == "subagent_message_completed" or data.completed == true or data.status == "completed" then
    acc.is_streaming = false
  else
    acc.is_streaming = true
  end
end

local function subagent_metadata(acc, part)
  local context = acc.context or {}
  return vim.tbl_deep_extend("force", {
    source = "subagent",
    role = acc.message_role or context.role,
    messageRole = acc.message_role,
    subAgentId = context.subAgentId or context.subagentId or context.taskId or context.task_id or acc.task_id,
    subAgentName = context.subAgentName or context.subagentName or context.agentProfileName or context.agentName,
    subAgentRole = context.subAgentRole or context.subagentRole or context.agentProfileName,
    subAgentType = context.subAgentType or context.subagentType or context.agentProfileId,
    subAgentTaskId = context.taskId or context.task_id or context.id or acc.task_id,
    subAgentMessageId = context.subagentMessageId or context.subagent_message_id or context.messageId,
    parentMessageId = context.parentMessageId or context.parent_message_id,
    parentToolCallId = context.parentToolCallId or context.parent_tool_call_id,
    parentThreadId = context.parentThreadId or context.parent_thread_id or context.threadId or context.thread_id,
  }, part and part.metadata or {})
end

local function subagent_tool_name(part)
  local typ = part.type or "tool"
  return first_string(part.toolName, part.tool_name, part.name, part.tool, typ:gsub("^tool%-", ""), "tool")
end

local function apply_request_metadata(thread, block)
  return request_metadata.apply_to_block(block, request_metadata.from_request(thread.pending_request))
end

local function subagent_blocks(thread)
  local blocks = {}
  for _, task_id in ipairs(thread.subagent_order or {}) do
    local acc = thread.subagent_streams and thread.subagent_streams[task_id]
    if acc then
      local message_id = "subagent-" .. tostring(task_id)
      local start_count = #blocks
      for index, part in ipairs(acc.parts or {}) do
        local typ = part.type or "text"
        local metadata = subagent_metadata(acc, part)
        local state = part.state or (acc.is_streaming and "streaming" or "done")
        if typ == "text" then
          if part.text and part.text ~= "" then
            table.insert(blocks, apply_request_metadata(thread, {
              type = "AssistantBlock",
              message_id = message_id,
              metadata = metadata,
              event_type = "subagent_message",
              text = part.text,
              state = state,
              local_only = true,
              raw = { type = "subagent_message", context = acc.context, part = part, part_index = index },
            }))
          end
        elseif typ == "reasoning" then
          table.insert(blocks, apply_request_metadata(thread, {
            type = "ReasoningBlock",
            message_id = message_id,
            metadata = metadata,
            event_type = "subagent_message",
            text = part.text or "",
            state = state,
            local_only = true,
            raw = { type = "subagent_message", context = acc.context, part = part, part_index = index },
          }))
        elseif vim.startswith(typ, "tool") then
          table.insert(blocks, apply_request_metadata(thread, {
            type = "ToolCallBlock",
            message_id = message_id,
            metadata = metadata,
            event_type = "subagent_message",
            tool = subagent_tool_name(part),
            state = state,
            tool_call_id = part.toolCallId,
            input = part.input,
            output = part.output,
            text = part.text or "",
            local_only = true,
            raw = { type = "subagent_message", context = acc.context, part = part, part_index = index },
          }))
        elseif part.text and part.text ~= "" then
          table.insert(blocks, apply_request_metadata(thread, {
            type = "AssistantBlock",
            message_id = message_id,
            metadata = metadata,
            event_type = "subagent_message",
            text = part.text,
            state = state,
            local_only = true,
            raw = { type = "subagent_message", context = acc.context, part = part, part_index = index },
          }))
        end
      end
      if #blocks == start_count then
        table.insert(blocks, apply_request_metadata(thread, {
          type = "AgentTimelineBlock",
          message_id = message_id,
          metadata = subagent_metadata(acc),
          event_type = "subagent_message",
          title = acc.is_streaming and "subagent-started" or "subagent-completed",
          text = acc.is_streaming and "Subagent is streaming..." or "Subagent completed.",
          state = acc.is_streaming and "streaming" or "done",
          local_only = true,
          raw = { type = "subagent_message", context = acc.context },
        }))
      end
    end
  end
  return blocks
end

local function request_prompt(request)
  return util.trim(request and request.spec and request.spec.prompt or "")
end

local function request_original_text(request)
  return util.trim(request and request.spec and request.spec.metadata and request.spec.metadata.original_text or "")
end

local function has_persisted_user_prompt(thread, request)
  local prompt = request_prompt(request)
  local original_text = request_original_text(request)
  if prompt == "" and original_text == "" then
    return false
  end
  for _, message in ipairs(thread.messages or {}) do
    local metadata = message.metadata or {}
    local persisted_original = util.trim(metadata.original_text or metadata.originalText or "")
    if original_text ~= "" and persisted_original == original_text then
      return true
    end
    if prompt ~= "" and (persisted_original == prompt or message_text(message) == prompt) then
      return true
    end
  end
  return false
end

local function user_block_matches_request(block, request)
  local prompt = request_prompt(request)
  local original_text = request_original_text(request)
  local metadata = block.metadata or {}
  local persisted_original = util.trim(metadata.original_text or metadata.originalText or "")
  if original_text ~= "" and persisted_original == original_text then
    return true
  end
  return prompt ~= "" and (util.trim(block.text or "") == prompt or persisted_original == prompt)
end

local function block_has_persisted_response_content(block)
  if not persisted_response_block_types[block.type] then
    return false
  end
  if block.type ~= "AssistantBlock" then
    return true
  end
  return events.block_text(block) ~= ""
end

local function has_persisted_response_for_request(thread, request)
  local after_current_user = false
  for _, block in ipairs(thread.blocks or {}) do
    if block.type == "UserBlock" then
      after_current_user = user_block_matches_request(block, request)
    elseif after_current_user and block_has_persisted_response_content(block) then
      return true
    end
  end
  return false
end

local function clear_local_stream(thread)
  thread.streaming_text = nil
  thread.streaming_reasoning_text = nil
end

local function active_blocks(thread, request)
  local blocks = {}
  local has_persisted_response = has_persisted_response_for_request(thread, request)
  if not has_persisted_user_prompt(thread, request) then
    table.insert(blocks, request_user_block(request))
  end
  if has_persisted_response then
    return blocks
  end
  if thread.streaming_reasoning_text and thread.streaming_reasoning_text ~= "" then
    table.insert(blocks, request_assistant_block(request, {
      type = "ReasoningBlock",
      text = thread.streaming_reasoning_text,
      state = "streaming",
      local_only = true,
    }))
  end
  if thread.streaming_text and thread.streaming_text ~= "" then
    table.insert(blocks, request_assistant_block(request, {
      type = "AssistantBlock",
      text = thread.streaming_text,
      state = "streaming",
      local_only = true,
    }))
  end
  return blocks
end

local function rebuild_local_blocks(thread)
  local blocks = {}
  if thread.pending_request and thread.generation ~= "idle" then
    util.list_extend(blocks, active_blocks(thread, thread.pending_request))
  end
  for _, request in ipairs(thread.queue or {}) do
    table.insert(blocks, queued_block(request))
    table.insert(blocks, queued_assistant_block(request))
  end
  util.list_extend(blocks, subagent_blocks(thread))
  thread.local_blocks = blocks
end

local function queue_request(thread, request, effects)
  table.insert(thread.queue, request)
  thread.status_message = "Request queued: Alma is already generating for this thread."
  table.insert(effects, {
    type = "notify",
    level = vim.log.levels.INFO,
    message = thread.status_message,
  })
  thread.prompt_lines = { "" }
  rebuild_local_blocks(thread)
  if thread.backend_generating and not thread.pending_request and thread.generation == "idle" then
    table.insert(effects, { type = "rest_fetch_thread", thread_id = thread.id })
  end
  table.insert(effects, { type = "render", thread_id = thread.id })
end

local function start_request(thread, request, effects)
  thread.generation = "submitted"
  thread.sync = "dirty"
  thread.pending_request = request
  thread.streaming_text = nil
  thread.streaming_reasoning_text = nil
  reset_subagent_streams(thread)
  thread.status_message = "Alma is thinking..."
  thread.last_error = nil
  thread.prompt_lines = { "" }
  rebuild_local_blocks(thread)
  table.insert(effects, { type = "ws_send", thread_id = thread.id, payload = request.payload })
  table.insert(effects, {
    type = "start_timer",
    thread_id = thread.id,
    name = "ack_timeout",
    delay = config.get().ack_timeout_ms,
  })
  table.insert(effects, { type = "render", thread_id = thread.id })
end

local function finish_reconcile(thread, effects)
  thread.generation = "reconciling"
  thread.status_message = "Reconciling with Alma REST state..."
  table.insert(effects, { type = "stop_timer", thread_id = thread.id, name = "poll" })
  table.insert(effects, { type = "rest_fetch_messages", thread_id = thread.id })
  table.insert(effects, { type = "render", thread_id = thread.id })
end

local function pop_queue_if_ready(thread, effects)
  if is_busy(thread) or #thread.queue == 0 then
    return
  end
  local next_request = table.remove(thread.queue, 1)
  rebuild_local_blocks(thread)
  table.insert(effects, {
    type = "dispatch",
    thread_id = thread.id,
    event = { type = "submit", request = next_request, from_queue = true },
  })
end

local function configured_reasoning_effort(thread, source)
  local configured = config.get().reasoning_effort
  local current = thread.config.reasoning_effort
  local source_reasoning = source.reasoningEffort or source.reasoning_effort
  if configured then
    if not current or current == source_reasoning then
      return configured
    end
    return current
  end
  return source_reasoning or current
end

local function apply_thread_metadata(thread, payload)
  local data = payload or {}
  local source = data.thread or data
  thread.lifecycle = "ready"
  thread.title = source.title or thread.title
  thread.workspace_id = source.workspaceId or source.workspace_id or thread.workspace_id
  thread.cwd = source.cwd or source.projectPath or source.workspacePath or thread.cwd
  if source.workspace or source.workspacePath or source.projectPath then
    local workspace = source.workspace or {}
    thread.workspace = {
      id = workspace.id or thread.workspace_id,
      name = workspace.name or (thread.cwd and vim.fn.fnamemodify(thread.cwd, ":t")) or nil,
      path = workspace.path or source.workspacePath or source.projectPath or thread.cwd,
    }
  end
  thread.config.workspace_id = thread.workspace_id
  thread.config.model = source.model or thread.config.model
  thread.config.reasoning_effort = configured_reasoning_effort(thread, source)
  thread.config.tools = source.tools or thread.config.tools
  thread.config.skills = source.skillIds or source.skills or thread.config.skills
  local was_backend_generating = thread.backend_generating
  thread.backend_generating = util.truthy(source.isGenerating) or util.truthy(source.generating)
  if thread.backend_generating and thread.generation == "idle" then
    thread.generation = "streaming"
    thread.status_message = "Alma GUI/backend is generating for this thread."
  elseif was_backend_generating and not thread.backend_generating and not thread.pending_request then
    if thread.generation == "streaming" or thread.generation == "tool_running" then
      thread.generation = "idle"
    end
    if thread.generation == "idle" then
      thread.status_message = nil
    end
  end
end

function M.reduce_thread(thread, event)
  local effects = {}
  event = event or {}

  if event.type == "buffer_visible" then
    thread.visibility = "visible"
    if thread.sync ~= "clean" then
      table.insert(effects, { type = "rest_fetch_messages", thread_id = thread.id })
    end
    table.insert(effects, { type = "render", thread_id = thread.id })
  elseif event.type == "buffer_hidden" then
    thread.visibility = "hidden"
  elseif event.type == "transport" then
    thread.transport = event.status
    if event.message and event.message ~= "" then
      thread.status_message = event.message
    end
    table.insert(effects, { type = "render", thread_id = thread.id })
  elseif event.type == "submit" then
    if is_busy(thread) and not event.from_queue then
      queue_request(thread, event.request, effects)
    else
      start_request(thread, event.request, effects)
    end
  elseif event.type == "ack_timeout" then
    if thread.pending_request and (thread.generation == "submitted" or thread.generation == "waiting_backend") then
      thread.generation = "waiting_backend"
      thread.status_message = "Alma is still thinking. Polling REST fallback..."
      table.insert(effects, { type = "rest_fetch_messages", thread_id = thread.id })
      table.insert(effects, {
        type = "start_timer",
        thread_id = thread.id,
        name = "poll",
        delay = config.get().poll_interval_ms,
      })
      table.insert(effects, { type = "render", thread_id = thread.id })
    end
  elseif event.type == "poll_tick" then
    if is_busy(thread) or thread.pending_request then
      table.insert(effects, { type = "rest_fetch_messages", thread_id = thread.id })
      table.insert(effects, {
        type = "start_timer",
        thread_id = thread.id,
        name = "poll",
        delay = config.get().poll_interval_ms,
      })
    end
  elseif event.type == "rest_thread_loaded" then
    apply_thread_metadata(thread, event.thread)
    table.insert(effects, { type = "render", thread_id = thread.id })
    pop_queue_if_ready(thread, effects)
  elseif event.type == "rest_messages_loaded" then
    thread.messages = event.messages or {}
    thread.blocks = events.normalize_messages(thread.messages)
    if thread.pending_request and has_persisted_response_for_request(thread, thread.pending_request) then
      clear_local_stream(thread)
    end
    thread.sync = "clean"
    thread.last_refetch_at = util.now_ms()
    local finalizing = thread.generation == "reconciling"
      or thread.generation == "completed"
      or thread.generation == "failed"
      or thread.generation == "cancelled"
      or thread.pending_request == nil
    if not thread.backend_generating and finalizing then
      thread.generation = "idle"
      thread.pending_request = nil
      thread.streaming_text = nil
      thread.streaming_reasoning_text = nil
      thread.status_message = nil
    end
    rebuild_local_blocks(thread)
    table.insert(effects, { type = "stop_timer", thread_id = thread.id, name = "ack_timeout" })
    table.insert(effects, { type = "render", thread_id = thread.id })
    pop_queue_if_ready(thread, effects)
  elseif event.type == "rest_error" then
    thread.sync = "stale"
    thread.last_error = event.error
    thread.status_message = "REST refetch failed; keeping visible local state."
    table.insert(effects, {
      type = "notify",
      level = vim.log.levels.WARN,
      message = "Alma REST error for " .. util.short_id(thread.id) .. ": " .. tostring(event.error),
    })
    table.insert(effects, { type = "render", thread_id = thread.id })
  elseif event.type == "ws_send_failed" then
    thread.generation = "waiting_backend"
    thread.last_error = event.error
    thread.status_message = "WebSocket send failed. Polling REST fallback..."
    table.insert(effects, { type = "rest_fetch_messages", thread_id = thread.id })
    table.insert(effects, {
      type = "start_timer",
      thread_id = thread.id,
      name = "poll",
      delay = config.get().poll_interval_ms,
    })
    table.insert(effects, { type = "render", thread_id = thread.id })
  elseif event.type == "ws_event" then
    thread.last_event_at = util.now_ms()
    thread.sync = "dirty"
    table.insert(effects, { type = "append_event_log", thread_id = thread.id, event = event.raw or event })

    if not event.known then
      table.insert(thread.raw_blocks, {
        type = "RawEventBlock",
        title = "Unknown WS event: " .. tostring(event.name),
        raw = event.raw,
      })
      if #thread.raw_blocks > 50 then
        table.remove(thread.raw_blocks, 1)
      end
    end

    if event.name == "thread_generating" then
      local generating = util.truthy(event.data.isGenerating) or util.truthy(event.data.generating)
      thread.backend_generating = generating
      if generating then
        thread.generation = thread.generation == "submitted" and "streaming" or thread.generation
        thread.status_message = "Alma is generating..."
      else
        finish_reconcile(thread, effects)
      end
    elseif event.name == "generation_completed" then
      thread.backend_generating = false
      thread.generation = "completed"
      finish_reconcile(thread, effects)
    elseif event.name == "generation_error" then
      thread.backend_generating = false
      thread.generation = "failed"
      thread.last_error = event.data.error or event.data.message or "generation_error"
      finish_reconcile(thread, effects)
    elseif event.name == "context_usage_update" then
      thread.context_usage = event.data
      table.insert(effects, { type = "render", thread_id = thread.id })
    elseif is_subagent_event(event.name) then
      thread.generation = "streaming"
      apply_subagent_event(thread, event)
      rebuild_local_blocks(thread)
      table.insert(effects, { type = "render", thread_id = thread.id })
      table.insert(effects, {
        type = "start_timer",
        thread_id = thread.id,
        name = "refetch_debounce",
        delay = config.get().refetch_debounce_ms,
      })
    elseif event.name == "text_delta" or event.name == "message_delta" or event.name == "reasoning-delta" then
      thread.generation = "streaming"
      local text_delta, reasoning_delta = stream_delta_chunks(event.data, event.name)
      if thread.pending_request and (text_delta ~= "" or reasoning_delta ~= "") then
        if has_persisted_response_for_request(thread, thread.pending_request) then
          clear_local_stream(thread)
        else
          if reasoning_delta ~= "" then
            thread.streaming_reasoning_text = (thread.streaming_reasoning_text or "") .. reasoning_delta
          end
          if text_delta ~= "" then
            thread.streaming_text = (thread.streaming_text or "") .. text_delta
          end
        end
        rebuild_local_blocks(thread)
      end
      table.insert(effects, { type = "render", thread_id = thread.id })
      table.insert(effects, {
        type = "start_timer",
        thread_id = thread.id,
        name = "refetch_debounce",
        delay = config.get().refetch_debounce_ms,
      })
    elseif vim.startswith(event.name, "tool_") or event.name == "part_update" or event.name == "part_add" then
      thread.generation = vim.startswith(event.name, "tool_") and "tool_running" or thread.generation
      table.insert(effects, { type = "render", thread_id = thread.id })
      table.insert(effects, {
        type = "start_timer",
        thread_id = thread.id,
        name = "refetch_debounce",
        delay = config.get().refetch_debounce_ms,
      })
    else
      table.insert(effects, { type = "render", thread_id = thread.id })
    end
  elseif event.type == "stop_requested" then
    thread.generation = "cancelling"
    table.insert(effects, {
      type = "ws_send",
      thread_id = thread.id,
      payload = { type = "stop_generation", data = { threadId = thread.id } },
    })
    table.insert(effects, { type = "render", thread_id = thread.id })
  end

  return thread, effects
end

M.is_busy = is_busy

return M
