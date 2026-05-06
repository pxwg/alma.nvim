local config = require("alma.config")

local M = {
  threads = {},
  buffers = {},
  timers = {},
  ws_pending = {},
  caches = {},
}

local function default_thread(id, opts)
  opts = opts or {}
  return {
    id = id,
    bufnr = opts.bufnr,
    cwd = opts.cwd or config.resolve_cwd(opts.bufnr or 0),
    workspace_id = opts.workspace_id,
    title = opts.title or ("Alma " .. tostring(id)),

    transport = "offline",
    lifecycle = "loading",
    generation = "idle",
    sync = "dirty",
    visibility = "visible",

    config = {
      model = opts.model,
      reasoning_effort = opts.reasoning_effort,
      tools = opts.tools or {},
      skills = opts.skills or {},
      mcp_servers = opts.mcp_servers or {},
      workspace_id = opts.workspace_id,
    },

    messages = {},
    blocks = {},
    local_blocks = {},
    raw_blocks = {},
    queue = {},
    event_log = {},
    render_index = {},
    folds = {},
    context_usage = nil,
    pending_request = nil,
    active_assistant_message_id = nil,
    backend_generating = false,
    last_event_at = nil,
    last_refetch_at = nil,
    last_error = nil,
    status_message = nil,
    prompt_start = nil,
    prompt_lines = nil,
  }
end

function M.get_thread(id, opts)
  if not id or id == "" then
    return nil
  end
  if not M.threads[id] then
    M.threads[id] = default_thread(id, opts)
  elseif opts then
    M.threads[id].cwd = opts.cwd or M.threads[id].cwd
    M.threads[id].workspace_id = opts.workspace_id or M.threads[id].workspace_id
  end
  return M.threads[id]
end

function M.thread_for_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local thread_id = vim.b[bufnr].alma_thread_id
  if thread_id then
    return M.threads[thread_id]
  end
  return nil
end

function M.bind_buffer(thread, bufnr)
  thread.bufnr = bufnr
  M.buffers[bufnr] = thread.id
  vim.b[bufnr].alma_thread_id = thread.id
  vim.b[bufnr].alma_workspace_id = thread.workspace_id
  vim.b[bufnr].alma_cwd = thread.cwd
end

function M.open_threads()
  local threads = {}
  for _, thread in pairs(M.threads) do
    if thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr) then
      table.insert(threads, thread)
    end
  end
  table.sort(threads, function(a, b)
    return tostring(a.title or a.id) < tostring(b.title or b.id)
  end)
  return threads
end

function M.append_event(thread_id, event)
  local thread = M.get_thread(thread_id)
  if not thread then
    return
  end
  table.insert(thread.event_log, {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = event,
  })
  if #thread.event_log > 500 then
    table.remove(thread.event_log, 1)
  end
end

function M.timer_key(thread_id, name)
  return tostring(thread_id) .. ":" .. tostring(name)
end

function M.set_cache(name, value)
  M.caches[name] = {
    at = require("alma.util").now_ms(),
    value = value,
  }
end

function M.get_cache(name, ttl_ms)
  local item = M.caches[name]
  if not item then
    return nil
  end
  if ttl_ms and require("alma.util").now_ms() - item.at > ttl_ms then
    return nil
  end
  return item.value
end

return M
