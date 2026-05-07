local config = require("alma.config")
local util = require("alma.util")

local M = {}

M._setup = false

function M.setup(opts)
  if not util.version_at_least(0, 12, 0) then
    error("alma.nvim requires Neovim >= 0.12.0")
  end
  config.setup(opts or {})
  require("alma.commands").setup()
  require("alma.effects").start()
  M._setup = true
end

function M.open_thread(thread_id, opts)
  if not M._setup then
    M.setup()
  end
  opts = opts or {}
  local thread
  if opts.layout then
    thread = require("alma.ui.window").open(vim.tbl_extend("force", opts, { thread_id = thread_id }))
  else
    thread = require("alma.buffers").open_thread(thread_id, opts)
  end
  if thread and thread.id then
    require("alma.effects").refresh(thread.id)
  end
  return thread
end

function M.open(opts)
  if not M._setup then
    M.setup()
  end
  local thread = require("alma.ui.window").open(opts or {})
  require("alma.effects").refresh(thread.id)
  return thread
end

function M.toggle(opts)
  if not M._setup then
    M.setup()
  end
  local thread, win = require("alma.ui.window").toggle(opts or {})
  if thread and thread.id and win then
    require("alma.effects").refresh(thread.id)
  end
  return thread
end

function M.float(opts)
  if not M._setup then
    M.setup()
  end
  local thread = require("alma.ui.window").float(opts or {})
  require("alma.effects").refresh(thread.id)
  return thread
end

function M.sidebar(opts)
  if not M._setup then
    M.setup()
  end
  local thread = require("alma.ui.window").sidebar(opts or {})
  require("alma.effects").refresh(thread.id)
  return thread
end

function M.submit(prompt)
  if not M._setup then
    M.setup()
  end
  return require("alma.buffers").submit_current(prompt)
end

function M.stop()
  local thread = require("alma.state").thread_for_buf(0)
  if thread then
    require("alma.effects").stop(thread.id)
  end
end

function M.health()
  require("alma.health").command()
end

return M
