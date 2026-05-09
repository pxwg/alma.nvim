local buffers = require("alma.buffers")
local config = require("alma.config")
local hooks = require("alma.hooks")
local state = require("alma.state")

local M = {}

local scratch_thread_id = "scratch"

local function valid_thread_buf(thread)
  return thread and thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr)
end

local function current_thread()
  return state.thread_for_buf(vim.api.nvim_get_current_buf())
end

local function first_open_thread()
  local threads = state.open_threads()
  return threads[1]
end

local function resolve_thread_id(thread_id, opts)
  opts = opts or {}
  if thread_id and thread_id ~= "" then
    return thread_id
  end
  if opts.thread_id and opts.thread_id ~= "" then
    return opts.thread_id
  end

  local thread = current_thread() or first_open_thread()
  if thread then
    return thread.id
  end

  return opts.default_thread_id or scratch_thread_id
end

local function ensure_thread(thread_id, opts)
  opts = opts or {}
  local resolved = resolve_thread_id(thread_id, opts)
  return buffers.ensure_thread(resolved, opts)
end

local function clamp(value, min_value, max_value)
  if max_value < min_value then
    return max_value
  end
  return math.min(math.max(value, min_value), max_value)
end

local function usable_editor_size()
  local columns = math.max(1, vim.o.columns)
  local lines = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
  return columns, lines
end

local function float_config(opts)
  opts = opts or {}
  local columns, lines = usable_editor_size()
  local width = clamp(tonumber(opts.width) or math.floor(columns * 0.72), math.min(40, columns), math.max(1, columns - 4))
  local height = clamp(tonumber(opts.height) or math.floor(lines * 0.78), math.min(12, lines), math.max(1, lines - 2))
  local col
  if opts.position == "right" then
    col = math.max(0, columns - width - 2)
  else
    col = math.max(0, math.floor((columns - width) / 2))
  end
  return {
    relative = "editor",
    style = "minimal",
    border = opts.border or "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = col,
  }
end

local function sidebar_width(opts)
  opts = opts or {}
  local columns = math.max(1, vim.o.columns)
  return clamp(tonumber(opts.width) or math.floor(columns * 0.38), math.min(32, columns), math.max(1, columns - 8))
end

local function focus_composer(thread, win)
  if not valid_thread_buf(thread) or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= thread.bufnr then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(thread.bufnr)
  local lnum = thread.prompt_start and (thread.prompt_start + 1) or line_count
  lnum = clamp(lnum, 1, line_count)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
end

local function render_and_focus(thread, win, layout)
  require("alma.ui.render").render(thread)
  focus_composer(thread, win)
  hooks.dispatch("thread_opened", {
    thread_id = thread.id,
    thread = thread,
    bufnr = thread.bufnr,
    win = win,
    layout = layout,
  })
  return thread, win
end

local function valid_win(win, bufnr)
  return win and vim.api.nvim_win_is_valid(win) and (not bufnr or vim.api.nvim_win_get_buf(win) == bufnr)
end

local function focus_normal_window()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
  return current
end

local function window_state(thread)
  thread.window = thread.window or {}
  return thread.window
end

local function visible_windows(thread)
  if not valid_thread_buf(thread) then
    return {}
  end
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(thread.bufnr)) do
    if valid_win(win, thread.bufnr) then
      table.insert(wins, win)
    end
  end
  return wins
end

function M.float(opts)
  opts = opts or {}
  local thread = ensure_thread(opts.thread_id, opts)
  local win_state = window_state(thread)
  local win = win_state.float_win
  if valid_win(win, thread.bufnr) then
    vim.api.nvim_set_current_win(win)
    return render_and_focus(thread, win, "float")
  end

  win = vim.api.nvim_open_win(thread.bufnr, true, float_config(opts))
  win_state.float_win = win
  win_state.last_layout = "float"
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  return render_and_focus(thread, win, "float")
end

function M.sidebar(opts)
  opts = opts or {}
  local thread = ensure_thread(opts.thread_id, opts)
  local win_state = window_state(thread)
  local win = win_state.sidebar_win
  if valid_win(win, thread.bufnr) then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_width, win, sidebar_width(opts))
    return render_and_focus(thread, win, "sidebar")
  end

  focus_normal_window()
  vim.cmd("botright vertical split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, thread.bufnr)
  pcall(vim.api.nvim_win_set_width, win, sidebar_width(opts))
  win_state.sidebar_win = win
  win_state.last_layout = "sidebar"
  vim.wo[win].winfixwidth = true
  return render_and_focus(thread, win, "sidebar")
end

function M.open(opts)
  opts = opts or {}
  local layout = opts.layout or config.get().window_layout or "float"
  if layout == "sidebar" then
    return M.sidebar(opts)
  end
  return M.float(opts)
end

local function hide_win(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local win_config = vim.api.nvim_win_get_config(win)
  local normal_count = 0
  for _, listed in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(listed) and vim.api.nvim_win_get_config(listed).relative == "" then
      normal_count = normal_count + 1
    end
  end
  if normal_count <= 1 and win_config.relative == "" then
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
    return
  end
  pcall(vim.api.nvim_win_close, win, false)
end

function M.close(opts)
  opts = opts or {}
  local thread_id = resolve_thread_id(opts.thread_id, opts)
  local thread = state.get_thread(thread_id)
  if not valid_thread_buf(thread) then
    return thread
  end
  for _, win in ipairs(visible_windows(thread)) do
    hide_win(win)
  end
  local win_state = window_state(thread)
  win_state.float_win = nil
  win_state.sidebar_win = nil
  return thread
end

function M.toggle(opts)
  opts = opts or {}
  local thread_id = resolve_thread_id(opts.thread_id, opts)
  local thread = state.get_thread(thread_id)
  if valid_thread_buf(thread) and #visible_windows(thread) > 0 then
    return M.close({ thread_id = thread_id })
  end
  local layout = opts.layout or (thread and thread.window and thread.window.last_layout) or config.get().window_layout or "float"
  return M.open(vim.tbl_extend("force", opts, {
    thread_id = thread_id,
    layout = layout,
  }))
end

return M
