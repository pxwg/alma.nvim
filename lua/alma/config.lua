local M = {}

local defaults = {
  api_url = vim.env.ALMA_API_URL or "http://127.0.0.1:23001",
  ws_url = nil,
  request_timeout_ms = 5000,
  ack_timeout_ms = 2000,
  poll_interval_ms = 1500,
  refetch_debounce_ms = 250,
  completion_ttl_ms = 30000,
  long_output_lines = 80,
  long_output_bytes = 12000,
  notify = true,
  resolve_cwd = function(bufnr)
    return vim.fs.root(bufnr, { ".git", "zk-lsp.toml" }) or vim.fn.getcwd(-1, -1)
  end,
  render = {
    show_raw_events = true,
    prompt_marker = "## You",
    separator = "───",
  },
}

local options = vim.deepcopy(defaults)

local function strip_trailing_slash(value)
  return (value:gsub("/+$", ""))
end

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
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

function M.resolve_cwd(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, cwd = pcall(options.resolve_cwd, bufnr)
  if ok and cwd and cwd ~= "" then
    return cwd
  end
  return vim.fn.getcwd(-1, -1)
end

return M
