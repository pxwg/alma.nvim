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
  local thread = require("alma.buffers").open_thread(thread_id, opts)
  require("alma.effects").refresh(thread_id)
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
