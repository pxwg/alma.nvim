local config = require("alma.config")
local context = require("alma.context")
local hooks = require("alma.hooks")
local state = require("alma.state")
local util = require("alma.util")

local M = {}

local group = vim.api.nvim_create_augroup("alma.nvim.buffers", { clear = true })
local view_autocmds_setup = false
local window_snapshots = {}

local restorable_window_options = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "wrap",
  "linebreak",
  "foldmethod",
  "foldexpr",
  "foldlevel",
  "conceallevel",
}

local alma_window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = true,
  linebreak = true,
  foldmethod = "expr",
  foldexpr = "v:lua.AlmaFoldExpr(v:lnum)",
  foldlevel = 0,
}

local function setup_view_autocmds()
  if view_autocmds_setup then
    return
  end
  view_autocmds_setup = true
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(event)
      local data = event.data or {}
      local v_event = vim.v.event or {}
      local win = tonumber(data.winid or v_event.winid or event.match)
      if not win or not vim.api.nvim_win_is_valid(win) then
        return
      end
      local thread = state.thread_for_buf(vim.api.nvim_win_get_buf(win))
      if thread then
        require("alma.ui.render").on_user_view_changed(thread, win, "viewport")
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      window_snapshots[tonumber(event.match)] = nil
    end,
  })
end

function M.apply_window_options(win, bufnr)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  bufnr = bufnr or vim.api.nvim_win_get_buf(win)
  if not bufnr or not state.thread_for_buf(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  if not window_snapshots[win] then
    local snapshot = {}
    for _, option in ipairs(restorable_window_options) do
      snapshot[option] = vim.wo[win][option]
    end
    window_snapshots[win] = snapshot
  end
  for option, value in pairs(alma_window_options) do
    vim.wo[win][option] = value
  end
  vim.wo[win].conceallevel = math.max(vim.wo[win].conceallevel, 1)
end

function M.restore_window_options(win)
  win = win or vim.api.nvim_get_current_win()
  local snapshot = win and window_snapshots[win]
  if not snapshot then
    return
  end
  if vim.api.nvim_win_is_valid(win) then
    for _, option in ipairs(restorable_window_options) do
      pcall(function()
        vim.wo[win][option] = snapshot[option]
      end)
    end
  end
  window_snapshots[win] = nil
end

local function setup_buffer_autocmds(bufnr, thread_id)
  setup_view_autocmds()
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.apply_window_options(vim.api.nvim_get_current_win(), bufnr)
      require("alma.effects").dispatch(thread_id, { type = "buffer_visible" })
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.restore_window_options(vim.api.nvim_get_current_win())
      require("alma.effects").dispatch(thread_id, { type = "buffer_hidden" })
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    buffer = bufnr,
    callback = function()
      require("alma.effects").dispatch(thread_id, { type = "buffer_hidden" })
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      state.buffers[bufnr] = nil
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local thread = state.get_thread(thread_id)
      if thread and vim.api.nvim_win_get_buf(win) == bufnr then
        require("alma.ui.render").on_user_view_changed(thread, win, "cursor")
      end
    end,
  })
end

function M.ensure_thread(thread_id, opts)
  opts = opts or {}
  local workspace = opts.workspace or (opts.workspace_id and { id = opts.workspace_id, path = opts.cwd }) or config.resolve_workspace(0)
  local thread = state.get_thread(thread_id, {
    cwd = opts.cwd or workspace.path,
    workspace_id = opts.workspace_id or workspace.id,
    workspace = workspace,
  })

  if thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr) then
    return thread
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "alma://thread/" .. thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  state.bind_buffer(thread, bufnr)
  vim.bo[bufnr].filetype = "alma"
  if pcall(vim.treesitter.start, bufnr, "markdown") then
    vim.bo[bufnr].syntax = ""
    vim.b[bufnr].current_syntax = nil
  else
    vim.bo[bufnr].syntax = "markdown"
  end
  vim.bo[bufnr].modifiable = true
  setup_buffer_autocmds(bufnr, thread_id)
  vim.keymap.set("n", "za", function()
    require("alma.ui.render").toggle_under_cursor()
  end, { buffer = bufnr, silent = true, desc = "Toggle Alma placeholder block" })
  require("alma.ui.render").render(thread)
  return thread
end

function M.open_thread(thread_id, opts)
  local thread = M.ensure_thread(thread_id, opts)
  util.open_or_focus_buf(thread.bufnr)
  require("alma.ui.render").render(thread)
  return thread
end

function M.collect_prompt(thread)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return {}
  end
  local start = thread.prompt_start
  if not start then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(thread.bufnr, start, -1, false)
  while #lines > 0 and util.is_blank(lines[1]) do
    table.remove(lines, 1)
  end
  while #lines > 0 and util.is_blank(lines[#lines]) do
    table.remove(lines, #lines)
  end
  return lines
end

function M.submit_current(args)
  local thread = state.thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not an Alma thread buffer", vim.log.levels.ERROR)
    return
  end

  local lines
  if args and args ~= "" then
    lines = { args }
  else
    lines = M.collect_prompt(thread)
  end
  if #lines == 0 or util.trim(table.concat(lines, "\n")) == "" then
    util.notify("No Alma prompt to submit", vim.log.levels.WARN)
    return
  end

  local parser = require("alma.parser")
  local spec = parser.parse_input(lines, thread)
  if spec.command == "stop" then
    require("alma.effects").stop(thread.id)
    return
  end
  if spec.prompt == "" and #(spec.images or {}) == 0 then
    util.notify("Alma tokens parsed, but no user prompt or image remains", vim.log.levels.WARN)
    return
  end

  for _, warning in ipairs(spec.warnings or {}) do
    util.notify(warning, vim.log.levels.WARN)
  end

  hooks.dispatch("before_submit", {
    thread_id = thread.id,
    thread = thread,
    spec = spec,
    lines = vim.deepcopy(lines),
  })

  local pending_attachments = context.list(thread.id)
  for _, item in ipairs(context.to_ephemeral_context_list(pending_attachments)) do
    table.insert(spec.ephemeral_context, item)
  end
  context.apply_compact_metadata(spec, pending_attachments)

  require("alma.ui.render").prepare_submit_follow(thread, vim.api.nvim_get_current_win())

  local payload = parser.compile_request(thread, spec)
  local attachment_parts, attachment_part_warnings = context.to_message_parts(pending_attachments)
  for _, warning in ipairs(attachment_part_warnings or {}) do
    util.notify("Alma attachment part skipped: " .. tostring(warning), vim.log.levels.WARN)
  end
  local user_parts = payload.data and payload.data.userMessage and payload.data.userMessage.parts
  if type(user_parts) == "table" then
    for _, part in ipairs(attachment_parts or {}) do
      table.insert(user_parts, part)
    end
  end
  local request = {
    spec = spec,
    payload = payload,
    created_at = util.now_ms(),
  }

  hooks.dispatch("request_compiled", {
    thread_id = thread.id,
    thread = thread,
    spec = spec,
    request = request,
    payload = payload,
  })

  require("alma.effects").dispatch(thread.id, { type = "submit", request = request })
  context.consume(thread.id)
  hooks.dispatch("after_submit", {
    thread_id = thread.id,
    thread = thread,
    spec = spec,
    request = request,
    payload = request.payload,
  })
end

return M
