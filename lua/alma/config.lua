local M = {}

local defaults = {
  api_url = vim.env.ALMA_API_URL or "http://127.0.0.1:23001",
  ws_url = nil,
  request_timeout_ms = 5000,
  ack_timeout_ms = 2000,
  poll_interval_ms = 1500,
  refetch_debounce_ms = 250,
  render_debounce_ms = 80,
  completion_ttl_ms = 30000,
  long_output_lines = 80,
  long_output_bytes = 12000,
  notify = true,
  model = nil,
  reasoning_effort = nil,
  window_layout = "float",
  resolve_workspace = function(ctx)
    local path = ctx.git_root or ctx.cwd or ctx.file_dir
    if not path or path == "" then
      path = vim.fn.getcwd(-1, -1)
    end
    return {
      path = path,
      name = vim.fn.fnamemodify(path, ":t"),
    }
  end,
  render = {
    show_raw_events = true,
    prompt_marker = "## You",
    separator = "───",
    tool_outputs = {
      mode = "smart",
      fallback = "raw",
      renderers = {},
    },
  },
}

local options = vim.deepcopy(defaults)

local function strip_trailing_slash(value)
  return (value:gsub("/+$", ""))
end

function M.setup(opts)
  opts = opts or {}
  if opts.resolve_cwd and not opts.resolve_workspace then
    local resolve_cwd = opts.resolve_cwd
    opts = vim.tbl_extend("force", opts, {
      resolve_workspace = function(ctx)
        local path = resolve_cwd(ctx.bufnr)
        return { path = path, name = path and vim.fn.fnamemodify(path, ":t") or nil }
      end,
    })
  end
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if type(options.api_url) == "function" then
    options.api_url = options.api_url()
  end
  options.api_url = strip_trailing_slash(options.api_url or defaults.api_url)
  if options.ws_url then
    options.ws_url = strip_trailing_slash(options.ws_url)
  end
end

function M.get()
  return options
end

function M.api_url()
  return strip_trailing_slash(options.api_url or defaults.api_url)
end

function M.ws_url()
  if options.ws_url and options.ws_url ~= "" then
    return options.ws_url
  end

  local base = M.api_url()
  if vim.startswith(base, "https://") then
    return "wss://" .. base:sub(9) .. "/ws/threads"
  end
  if vim.startswith(base, "http://") then
    return "ws://" .. base:sub(8) .. "/ws/threads"
  end
  if vim.startswith(base, "ws://") or vim.startswith(base, "wss://") then
    return strip_trailing_slash(base) .. "/ws/threads"
  end
  return "ws://" .. base .. "/ws/threads"
end

local function normalize_workspace(value, fallback_path)
  if type(value) == "string" then
    value = { path = value }
  elseif type(value) ~= "table" then
    value = {}
  end

  local path = value.path or value.cwd or value.root or fallback_path or vim.fn.getcwd(-1, -1)
  path = vim.fn.fnamemodify(path, ":p")
  path = strip_trailing_slash(path)
  return {
    id = value.id or value.workspace_id or value.workspaceId,
    name = value.name or vim.fn.fnamemodify(path, ":t"),
    path = path,
  }
end

local function workspace_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  local file_dir = file ~= "" and vim.fn.fnamemodify(file, ":p:h") or nil
  local cwd = vim.fn.getcwd(-1, -1)
  local git_root
  local ok, root = pcall(vim.fs.root, bufnr, { ".git" })
  if ok and root and root ~= "" then
    git_root = root
  end
  return {
    bufnr = bufnr,
    file = file ~= "" and file or nil,
    file_dir = file_dir,
    cwd = cwd,
    git_root = git_root,
  }
end

function M.resolve_workspace(bufnr)
  local ctx = workspace_context(bufnr)
  local ok, workspace = pcall(options.resolve_workspace, ctx)
  if not ok then
    require("alma.util").notify("Alma workspace resolver failed: " .. tostring(workspace), vim.log.levels.ERROR)
    workspace = nil
  end
  return normalize_workspace(workspace, ctx.git_root or ctx.cwd or ctx.file_dir)
end

function M.resolve_cwd(bufnr)
  return M.resolve_workspace(bufnr).path
end

return M
