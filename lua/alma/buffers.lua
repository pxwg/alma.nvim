local config = require("alma.config")
local state = require("alma.state")
local util = require("alma.util")

local M = {}

local group = vim.api.nvim_create_augroup("alma.nvim.buffers", { clear = true })

local function setup_buffer_autocmds(bufnr, thread_id)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      require("alma.effects").dispatch(thread_id, { type = "buffer_visible" })
    end,
  })
  vim.api.nvim_create_autocmd({ "BufHidden", "BufWinLeave" }, {
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
end

function M.open_thread(thread_id, opts)
  opts = opts or {}
  local thread = state.get_thread(thread_id, {
    cwd = opts.cwd or config.resolve_cwd(0),
    workspace_id = opts.workspace_id,
  })

  if thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr) then
    util.open_or_focus_buf(thread.bufnr)
    return thread
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "alma://thread/" .. thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "alma"
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].undolevels = 1000
  state.bind_buffer(thread, bufnr)
  setup_buffer_autocmds(bufnr, thread_id)
  vim.api.nvim_set_current_buf(bufnr)
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
  if spec.prompt == "" then
    util.notify("Alma tokens parsed, but no user prompt remains", vim.log.levels.WARN)
    return
  end

  for _, warning in ipairs(spec.warnings or {}) do
    util.notify(warning, vim.log.levels.WARN)
  end

  local request = {
    spec = spec,
    payload = parser.compile_request(thread, spec),
    created_at = util.now_ms(),
  }
  require("alma.effects").dispatch(thread.id, { type = "submit", request = request })
end

return M
