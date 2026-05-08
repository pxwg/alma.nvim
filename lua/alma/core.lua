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
  thread.local_blocks = blocks
end

local function queue_request(thread, request, effects)
  table.insert(thread.queue, request)
  thread.status_message = "Request queued: Alma is already generating for this thread."
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
