local util = require("alma.util")

local M = {}

local hook_order = {
  "thread_opened",
  "thread_changed",
  "before_submit",
  "request_compiled",
  "after_submit",
  "generation_completed",
  "generation_error",
  "proposal_received",
}

local autocmd_names = {
  thread_opened = "AlmaThreadOpened",
  thread_changed = "AlmaThreadChanged",
  before_submit = "AlmaBeforeSubmit",
  request_compiled = "AlmaRequestCompiled",
  after_submit = "AlmaAfterSubmit",
  generation_completed = "AlmaGenerationCompleted",
  generation_error = "AlmaGenerationError",
  proposal_received = "AlmaProposalReceived",
}

local valid_hooks = {}
local callbacks = {}
local next_id = 0

for _, name in ipairs(hook_order) do
  valid_hooks[name] = true
  callbacks[name] = {}
end

local function assert_hook_name(name)
  if not valid_hooks[name] then
    error("unknown Alma hook: " .. tostring(name))
  end
end

local function event_data(name, data)
  local data_type = type(data)
  local event = data_type == "table" and data or { value = data }
  event.hook = event.hook or name
  event.autocmd = event.autocmd or autocmd_names[name]
  return event
end

local function slim_thread(thread)
  if type(thread) ~= "table" then
    return thread
  end
  return {
    id = thread.id,
    bufnr = thread.bufnr,
    cwd = thread.cwd,
    workspace_id = thread.workspace_id,
    title = thread.title,
    lifecycle = thread.lifecycle,
    generation = thread.generation,
    sync = thread.sync,
    visibility = thread.visibility,
    transport = thread.transport,
    backend_generating = thread.backend_generating,
    pending_request = thread.pending_request ~= nil,
    last_event_at = thread.last_event_at,
    last_refetch_at = thread.last_refetch_at,
    last_error = thread.last_error,
    status_message = thread.status_message,
  }
end

local function slim_effect(effect)
  if type(effect) ~= "table" then
    return effect
  end
  return {
    type = effect.type,
    thread_id = effect.thread_id,
    name = effect.name,
    delay = effect.delay,
    level = effect.level,
    message = effect.message,
  }
end

local function slim_effects(effects)
  if type(effects) ~= "table" then
    return effects
  end
  local out = {}
  for index, effect in ipairs(effects) do
    out[index] = slim_effect(effect)
  end
  return out
end

local function slim_ws_data(data)
  if type(data) ~= "table" then
    return data
  end
  return {
    id = data.id,
    threadId = data.threadId,
    thread_id = data.thread_id,
    isGenerating = data.isGenerating,
    generating = data.generating,
    error = data.error,
    message = data.message,
  }
end

local function slim_event(event)
  if type(event) ~= "table" then
    return event
  end
  return {
    type = event.type,
    name = event.name,
    known = event.known,
    thread_id = event.thread_id,
    error = event.error,
    data = slim_ws_data(event.data),
    message_count = type(event.messages) == "table" and #event.messages or nil,
    agent_crew_count = type(event.agent_crew) == "table" and #event.agent_crew or nil,
  }
end

local function autocmd_event_data(name, event)
  local out = {}
  for key, value in pairs(event) do
    if key == "thread" then
      out.thread = slim_thread(value)
    elseif key == "event" then
      out.event = slim_event(value)
    elseif key == "effects" then
      out.effects = slim_effects(value)
    elseif key == "proposal" and name == "proposal_received" then
      out.proposal = value
    else
      out[key] = value
    end
  end
  return out
end

local function record_error(errors, where, err)
  table.insert(errors, {
    where = where,
    error = tostring(err),
  })
  util.notify("Alma hook failed (" .. where .. "): " .. tostring(err), vim.log.levels.ERROR)
end

function M.names()
  return vim.deepcopy(hook_order)
end

function M.autocmd_name(name)
  assert_hook_name(name)
  return autocmd_names[name]
end

function M.on(name, callback, opts)
  assert_hook_name(name)
  if type(callback) ~= "function" then
    error("Alma hook callback must be a function")
  end
  opts = opts or {}
  next_id = next_id + 1
  local item = {
    id = next_id,
    callback = callback,
    once = opts.once == true,
    active = true,
  }
  table.insert(callbacks[name], item)
  return {
    id = item.id,
    name = name,
    unsubscribe = function()
      M.off(name, item.id)
    end,
  }
end

M.register = M.on

function M.off(name, handle)
  assert_hook_name(name)
  local id = type(handle) == "table" and handle.id or handle
  for _, item in ipairs(callbacks[name]) do
    if item.id == id then
      item.active = false
      return true
    end
  end
  return false
end

M.unregister = M.off

function M.clear(name)
  if name then
    assert_hook_name(name)
    callbacks[name] = {}
    return
  end
  for _, hook_name in ipairs(hook_order) do
    callbacks[hook_name] = {}
  end
end

function M.dispatch(name, data)
  assert_hook_name(name)
  local event = event_data(name, data)
  local errors = {}

  for _, item in ipairs(callbacks[name]) do
    if item.active then
      local ok, err = pcall(item.callback, event)
      if not ok then
        record_error(errors, name .. "#" .. tostring(item.id), err)
      end
      if item.once then
        item.active = false
      end
    end
  end

  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = autocmd_names[name],
    data = autocmd_event_data(name, event),
    modeline = false,
  })
  if not ok then
    record_error(errors, autocmd_names[name], err)
  end

  return {
    ok = #errors == 0,
    errors = errors,
    data = event,
  }
end

function M._reset()
  M.clear()
end

return M
