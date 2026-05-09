local config = require("alma.config")
local rest = require("alma.rest")
local util = require("alma.util")
local workspace = require("alma.workspace")

local M = {}

M._setup = false
M.context = require("alma.context")
M.hooks = require("alma.hooks")

local function setup_filetype_services()
  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
    pcall(vim.treesitter.language.register, "markdown", "alma")
    pcall(vim.treesitter.language.register, "markdown_inline", "alma.markdown_inline")
  end
end

function M.setup(opts)
  if not util.version_at_least(0, 12, 0) then
    error("alma.nvim requires Neovim >= 0.12.0")
  end
  config.setup(opts or {})
  setup_filetype_services()
  require("alma.commands").setup()
  require("alma.effects").start()
  M._setup = true
end

function M.open_thread(thread_id, opts)
  if not M._setup then
    M.setup()
  end
  opts = opts or {}
  if not thread_id or thread_id == "" then
    util.notify("Use :Alma new for a new project thread, or :Alma pick to choose one in this project.", vim.log.levels.WARN)
    return nil
  end
  local thread = require("alma.ui.window").open(vim.tbl_extend("force", opts, { thread_id = thread_id }))
  if thread and thread.id then
    require("alma.effects").refresh(thread.id)
  end
  return thread
end

function M.new_thread(opts)
  if not M._setup then
    M.setup()
  end
  opts = opts or {}
  workspace.ensure(opts.bufnr or vim.api.nvim_get_current_buf(), function(current_workspace, err)
    if not current_workspace then
      workspace.notify_error("resolution", err)
      return
    end
    local defaults = config.get()
    rest.create_thread({
      title = opts.title or "New Chat",
      workspace_id = current_workspace.id,
      path = current_workspace.path,
      model = opts.model ~= nil and opts.model or defaults.model,
      reasoning_effort = opts.reasoning_effort ~= nil and opts.reasoning_effort or defaults.reasoning_effort,
    }, function(thread_data, create_err)
      if not thread_data then
        util.notify("Unable to create Alma thread: " .. tostring(create_err), vim.log.levels.ERROR)
        return
      end
      local thread = require("alma.ui.window").open(vim.tbl_extend("force", opts, {
        thread_id = thread_data.id,
        workspace_id = current_workspace.id,
        cwd = current_workspace.path,
        workspace = current_workspace,
        model = opts.model ~= nil and opts.model or defaults.model,
        reasoning_effort = opts.reasoning_effort ~= nil and opts.reasoning_effort or defaults.reasoning_effort,
      }))
      if thread then
        thread.title = thread_data.title or thread.title
        require("alma.effects").refresh(thread.id)
      end
    end)
  end)
end

function M.pick_thread(opts)
  if not M._setup then
    M.setup()
  end
  require("alma.pickers").threads(vim.tbl_extend("force", { scope = "workspace" }, opts or {}))
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
