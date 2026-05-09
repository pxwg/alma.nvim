local config = require("alma.config")
local core = require("alma.core")
local events = require("alma.events")
local hooks = require("alma.hooks")
local rest = require("alma.rest")
local state = require("alma.state")
local util = require("alma.util")
local ws = require("alma.ws")

local M = {}

local client = nil
local running = false

local function get_thread(thread_id)
  return state.get_thread(thread_id)
end

local function dispatch(thread_id, event)
  local thread = get_thread(thread_id)
  if not thread then
    return
  end
  local _, effects = core.reduce_thread(thread, event)
  hooks.dispatch("thread_changed", {
    thread_id = thread.id,
    thread = thread,
    event = event,
    effects = effects,
  })
  if event and event.type == "ws_event" and event.name == "generation_completed" then
    hooks.dispatch("generation_completed", {
      thread_id = thread.id,
      thread = thread,
      event = event,
      data = event.data,
    })
  elseif event and event.type == "ws_event" and event.name == "generation_error" then
    hooks.dispatch("generation_error", {
      thread_id = thread.id,
      thread = thread,
      event = event,
      data = event.data,
      error = event.data and (event.data.error or event.data.message) or nil,
    })
  elseif event and event.type == "ws_event" and event.name == "proposal_received" then
    hooks.dispatch("proposal_received", {
      thread_id = thread.id,
      thread = thread,
      event = event,
      proposal = event.data,
    })
  end
  M.run(effects)
end

local function dispatch_all_transport(status, message)
  for thread_id, _ in pairs(state.threads) do
    dispatch(thread_id, { type = "transport", status = status, message = message })
  end
end

local function ensure_ws()
  if client and (client.status == "online" or client.status == "connecting") then
    return client
  end

  client = ws.new({
    url = config.ws_url(),
    on_status = function(status, message)
      dispatch_all_transport(status, message)
      if status == "online" then
        local pending = state.ws_pending
        state.ws_pending = {}
        for _, item in ipairs(pending) do
          M.send_ws(item.thread_id, item.payload)
        end
      end
    end,
    on_error = function(message)
      dispatch_all_transport("offline", message)
    end,
    on_event = function(raw)
      local normalized = events.normalize_ws_event(raw)
      if normalized.thread_id then
        dispatch(normalized.thread_id, normalized)
      elseif events.is_global_ws_event(normalized.name) then
        for thread_id, _ in pairs(state.threads) do
          dispatch(thread_id, normalized)
        end
      end
    end,
  })
  client:connect()
  return client
end

function M.start()
  if running then
    return
  end
  running = true
  ensure_ws()
end

function M.dispatch(thread_id, event)
  dispatch(thread_id, event)
end

function M.send_ws(thread_id, payload)
  local c = ensure_ws()
  if c.status ~= "online" then
    table.insert(state.ws_pending, { thread_id = thread_id, payload = payload })
    return
  end
  local ok, err = c:send_json(payload)
  if not ok then
    dispatch(thread_id, { type = "ws_send_failed", error = err })
  end
end

local function stop_timer(thread_id, name)
  local key = state.timer_key(thread_id, name)
  local timer = state.timers[key]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    state.timers[key] = nil
  end
end

local function start_timer(thread_id, name, delay)
  stop_timer(thread_id, name)
  local timer = vim.uv.new_timer()
  state.timers[state.timer_key(thread_id, name)] = timer
  timer:start(delay, 0, function()
    vim.schedule(function()
      stop_timer(thread_id, name)
      if name == "ack_timeout" then
        dispatch(thread_id, { type = "ack_timeout" })
      elseif name == "poll" then
        dispatch(thread_id, { type = "poll_tick" })
      elseif name == "refetch_debounce" then
        M.run({ { type = "rest_fetch_messages", thread_id = thread_id } })
      elseif name == "crew_refetch_debounce" then
        M.run({ { type = "rest_fetch_agent_crew", thread_id = thread_id } })
      end
    end)
  end)
end

local function run_one(effect)
  if effect.type == "ws_send" then
    M.send_ws(effect.thread_id, effect.payload)
  elseif effect.type == "rest_fetch_thread" then
    rest.thread(effect.thread_id, function(data, err)
      if data then
        dispatch(effect.thread_id, { type = "rest_thread_loaded", thread = data })
      else
        dispatch(effect.thread_id, { type = "rest_error", error = err })
      end
    end)
  elseif effect.type == "rest_fetch_messages" then
    rest.messages(effect.thread_id, function(data, err)
      if data then
        dispatch(effect.thread_id, { type = "rest_messages_loaded", messages = data })
      else
        dispatch(effect.thread_id, { type = "rest_error", error = err })
      end
    end)
  elseif effect.type == "rest_fetch_agent_crew" then
    rest.agent_crew(effect.thread_id, function(data, err)
      if data then
        dispatch(effect.thread_id, { type = "rest_agent_crew_loaded", agent_crew = data })
      else
        dispatch(effect.thread_id, { type = "rest_agent_crew_error", error = err })
      end
    end)
  elseif effect.type == "start_timer" then
    start_timer(effect.thread_id, effect.name, effect.delay)
  elseif effect.type == "stop_timer" then
    stop_timer(effect.thread_id, effect.name)
  elseif effect.type == "render" then
    require("alma.ui.render").schedule(get_thread(effect.thread_id))
  elseif effect.type == "append_event_log" then
    state.append_event(effect.thread_id, effect.event)
  elseif effect.type == "notify" then
    util.notify(effect.message, effect.level)
  elseif effect.type == "dispatch" then
    dispatch(effect.thread_id, effect.event)
  end
end

function M.run(effects)
  for _, effect in ipairs(effects or {}) do
    local ok, err = pcall(run_one, effect)
    if not ok then
      local thread = effect.thread_id and get_thread(effect.thread_id) or nil
      if thread then
        thread.last_error = err
        thread.status_message = "Neovim effect failed; state was kept alive."
        require("alma.ui.render").schedule(thread, 0)
      end
      util.notify("Alma effect failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

function M.refresh(thread_id)
  M.run({
    { type = "rest_fetch_thread", thread_id = thread_id },
    { type = "rest_fetch_messages", thread_id = thread_id },
    { type = "rest_fetch_agent_crew", thread_id = thread_id },
  })
end

function M.stop(thread_id)
  dispatch(thread_id, { type = "stop_requested" })
end

return M
