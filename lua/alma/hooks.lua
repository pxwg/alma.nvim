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
    data = event,
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
