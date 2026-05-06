local config = require("alma.config")
local util = require("alma.util")

local M = {}

local static_commands = {
  ["/new"] = true,
  ["/stop"] = true,
  ["/rename"] = true,
}

local function current_metadata(thread)
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    source = "alma.nvim",
    bufnr = bufnr,
    cwd = thread and thread.cwd or config.resolve_cwd(bufnr),
    original_text = nil,
  }
end

local function context_for_token(token)
  local bufnr = vim.api.nvim_get_current_buf()
  if token == ">buffer" then
    return {
      type = "buffer",
      bufnr = bufnr,
      name = vim.api.nvim_buf_get_name(bufnr),
      text = util.read_buf_text(bufnr, 20000),
    }
  end
  if token == ">selection" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    if start_pos[2] > 0 and end_pos[2] >= start_pos[2] then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[2] - 1, end_pos[2], false)
      return {
        type = "selection",
        bufnr = bufnr,
        name = vim.api.nvim_buf_get_name(bufnr),
        text = table.concat(lines, "\n"),
      }
    end
    return { type = "selection", bufnr = bufnr, text = "" }
  end
  if token == ">diagnostics" then
    return {
      type = "diagnostics",
      bufnr = bufnr,
      diagnostics = vim.diagnostic.get(bufnr),
    }
  end
  if token == ">diff" then
    return { type = "diff", cwd = config.resolve_cwd(bufnr) }
  end
  local file = token:match("^>file:(.+)$")
  if file then
    return { type = "file", path = vim.fn.fnamemodify(file, ":p") }
  end
  local zk = token:match("^>zk:(.+)$")
  if zk then
    return { type = "zk", id = zk }
  end
  return nil
end

local function parse_token(token, spec)
  if token:sub(1, 1) == "/" then
    if static_commands[token] then
      spec.command = token:sub(2)
      return true
    end
    local skill = token:match("^/skill:(.+)$")
    if skill then
      table.insert(spec.skills, skill)
      return true
    end
    return false
  end

  if token:sub(1, 1) == "@" then
    local mcp = token:match("^@mcp:(.+)$")
    if mcp then
      table.insert(spec.mcp_servers, mcp)
      return true
    end
    local group = token:match("^@group:(.+)$")
    if group then
      table.insert(spec.tool_groups, group)
      return true
    end
    table.insert(spec.tools, token:sub(2))
    return true
  end

  if token:sub(1, 1) == "$" then
    local model = token:match("^%$model:(.+)$")
    if model then
      spec.model = model
      return true
    end
    local reasoning = token:match("^%$reasoning:(.+)$")
    if reasoning then
      spec.reasoning_effort = reasoning
      return true
    end
    local temp = token:match("^%$temp:(.+)$")
    if temp then
      spec.temperature = tonumber(temp)
      return true
    end
    if token == "$no-tools" then
      spec.no_tools = true
      return true
    end
    return false
  end

  if token:sub(1, 1) == ">" then
    local context = context_for_token(token)
    if context then
      table.insert(spec.ephemeral_context, context)
      return true
    end
    return false
  end

  return false
end

function M.parse_input(lines, thread)
  lines = lines or {}
  local spec = {
    thread_id = thread and thread.id or nil,
    cwd = thread and thread.cwd or config.resolve_cwd(0),
    prompt = nil,
    command = nil,
    skills = vim.deepcopy(thread and thread.config.skills or {}),
    tools = vim.deepcopy(thread and thread.config.tools or {}),
    tool_groups = {},
    mcp_servers = vim.deepcopy(thread and thread.config.mcp_servers or {}),
    model = thread and thread.config.model or nil,
    reasoning_effort = thread and thread.config.reasoning_effort or nil,
    temperature = nil,
    no_tools = false,
    ephemeral_context = {},
    warnings = {},
    metadata = current_metadata(thread),
  }

  local prompt_lines = {}
  local original = table.concat(lines, "\n")
  spec.metadata.original_text = original

  for _, line in ipairs(lines) do
    local trimmed = util.trim(line)
    local token = trimmed:match("^([/@$>][^%s]+)$")
    if token then
      if not parse_token(token, spec) then
        table.insert(spec.warnings, "Unknown Alma token kept in prompt: " .. token)
        table.insert(prompt_lines, line)
      end
    else
      table.insert(prompt_lines, line)
    end
  end

  spec.prompt = util.trim(table.concat(prompt_lines, "\n"))
  spec.skills = util.dedup(spec.skills)
  spec.tools = util.dedup(spec.tools)
  spec.mcp_servers = util.dedup(spec.mcp_servers)
  return spec
end

function M.compile_request(thread, spec)
  local payload = {
    type = "generate_response",
    data = {
      threadId = thread.id,
      userMessage = spec.prompt,
      model = spec.model or thread.config.model,
      reasoningEffort = spec.reasoning_effort or thread.config.reasoning_effort,
      tools = spec.tools,
      enabledMCPServerIds = spec.mcp_servers,
      source = "alma.nvim",
      noTools = spec.no_tools,
      ephemeralModel = spec.model,
      userMessageMetadata = spec.metadata,
      ephemeralContext = spec.ephemeral_context,
      fromQuickChat = false,
      hummingbirdContext = vim.NIL,
    },
  }

  if #spec.skills > 0 then
    -- Alma's observed handler does not document this field, but keeping it
    -- in metadata and the payload preserves per-request intent.
    payload.data.skillIds = spec.skills
    payload.data.userMessageMetadata.skillIds = spec.skills
  end

  return payload
end

return M
