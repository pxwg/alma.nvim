local state = require("alma.state")
local util = require("alma.util")

local M = {}

local static = {
  slash = {
    { label = "/new", detail = "Create a new Alma thread", command = "new" },
    { label = "/stop", detail = "Stop current generation", command = "stop" },
    { label = "/rename", detail = "Rename current thread", command = "rename" },
    { label = "/skill:<id>", detail = "Enable a skill for this request", kind = "skill" },
  },
  at = {
    { label = "@Bash", detail = "Enable Bash tool" },
    { label = "@Read", detail = "Enable Read tool" },
    { label = "@Grep", detail = "Enable Grep tool" },
    { label = "@Glob", detail = "Enable Glob tool" },
    { label = "@Task", detail = "Enable Task tool" },
    { label = "@mcp:<server>", detail = "Enable an MCP server" },
    { label = "@group:<group>", detail = "Enable a tool group" },
  },
  dollar = {
    { label = "$model:<id>", detail = "Set model for this request" },
    { label = "$reasoning:low", detail = "Low reasoning effort" },
    { label = "$reasoning:medium", detail = "Medium reasoning effort" },
    { label = "$reasoning:high", detail = "High reasoning effort" },
    { label = "$reasoning:xhigh", detail = "Extra high reasoning effort" },
    { label = "$temp:<n>", detail = "Set temperature" },
    { label = "$no-tools", detail = "Disable tools for this request" },
  },
  gt = {
    { label = ">buffer", detail = "Attach current buffer text" },
    { label = ">selection", detail = "Attach current selection" },
    { label = ">diagnostics", detail = "Attach current buffer diagnostics" },
    { label = ">diff", detail = "Attach project diff reference" },
    { label = ">file:<path>", detail = "Attach a file path reference" },
  },
}

local slash_commands = {}
local static_tools = {}

for _, item in ipairs(static.slash) do
  if item.command then
    slash_commands[item.label] = item.command
  end
end

for _, item in ipairs(static.at) do
  local name = item.label:match("^@([^:]+)$")
  if name then
    static_tools[name] = true
  end
end

local function trim(value)
  return util.trim(tostring(value or ""))
end

local function invalid(token, reason)
  return {
    token = token,
    valid = false,
    reason = reason or "unknown token",
  }
end

local function is_auto_selection(value)
  return value == "__auto__" or value == "auto"
end

local function add_known(names, value)
  if type(value) ~= "string" or value == "" then
    return
  end
  value = value:gsub("^@", ""):gsub("^mcp:", ""):gsub("^/skill:", "")
  if value ~= "" then
    names[value] = true
  end
end

local function add_entity(names, item, prefix)
  if type(item) == "string" then
    add_known(names, item)
    return true
  end
  if type(item) ~= "table" then
    return false
  end
  local label = item.label
  if type(label) == "string" and prefix and vim.startswith(label, prefix) then
    add_known(names, label:sub(#prefix + 1))
    return true
  end
  local id = item.id or item.key or item.name or item.model or item.slug
  if id then
    add_known(names, tostring(id))
    return true
  end
  return false
end

local function configured_names(value, prefix)
  local names = {}
  local has_data = false
  if type(value) == "table" then
    has_data = #value > 0
    for _, item in ipairs(value) do
      has_data = add_entity(names, item, prefix) or has_data
    end
  elseif type(value) == "string" and value ~= "" and not is_auto_selection(value) then
    has_data = true
    add_entity(names, value, prefix)
  end
  return names, has_data
end

local function cached_catalog_names(kind, prefix)
  local names = {}
  local items = state.get_cache("catalog:" .. kind)
  if type(items) ~= "table" then
    return names, false
  end
  local has_data = #items > 0
  for _, item in ipairs(items) do
    has_data = add_entity(names, item, prefix) or has_data
  end
  return names, has_data
end

local function merge_names(...)
  local out = {}
  local has_data = false
  for index = 1, select("#", ...), 2 do
    local names = select(index, ...)
    local data = select(index + 1, ...)
    has_data = has_data or data == true
    for name, known in pairs(names or {}) do
      if known then
        out[name] = true
      end
    end
  end
  return out, has_data
end

local function classify_known_name(token, target, names, has_data, fallback_valid)
  if names[target] then
    return {
      token = token,
      valid = true,
      fallback = false,
    }
  end
  if has_data and not fallback_valid then
    return invalid(token, "unknown configured item: " .. target)
  end
  return {
    token = token,
    valid = true,
    fallback = true,
  }
end

local function thread_config(opts)
  local thread = opts and opts.thread
  return thread and thread.config or {}
end

local function classify_slash(token)
  local command = slash_commands[token]
  if command then
    return {
      token = token,
      valid = true,
      kind = "slash_command",
      command = command,
    }
  end

  local skill = token:match("^/skill:%s*(.+)$")
  skill = skill and trim(skill)
  if skill and skill ~= "" and skill ~= "<id>" then
    return {
      token = token,
      valid = true,
      kind = "skill",
      value = skill,
    }
  end

  return invalid(token, "unknown slash command")
end

local function classify_dollar(token)
  local model = token:match("^%$model:%s*(.+)$")
  model = model and trim(model)
  if model and model ~= "" and model ~= "<id>" then
    return {
      token = token,
      valid = true,
      kind = "selector",
      selector = "model",
      value = model,
    }
  end

  local reasoning = token:match("^%$reasoning:%s*(.+)$")
  reasoning = reasoning and trim(reasoning)
  if reasoning and reasoning ~= "" then
    return {
      token = token,
      valid = true,
      kind = "selector",
      selector = "reasoning",
      value = reasoning,
    }
  end

  local temperature = token:match("^%$temp:%s*(.+)$")
  temperature = temperature and trim(temperature)
  if temperature and temperature ~= "" then
    local number = tonumber(temperature)
    if number then
      return {
        token = token,
        valid = true,
        kind = "selector",
        selector = "temperature",
        value = number,
      }
    end
    return invalid(token, "temperature is not numeric")
  end

  if token == "$no-tools" then
    return {
      token = token,
      valid = true,
      kind = "selector",
      selector = "no_tools",
      value = true,
    }
  end

  return invalid(token, "unknown selector")
end

local function classify_mcp(token, target, opts)
  local cfg = thread_config(opts)
  local configured, configured_has_data = configured_names((opts and opts.mcp_servers) or cfg.mcp_servers, "@mcp:")
  local cached, cached_has_data = cached_catalog_names("mcp_servers", "@mcp:")
  local names, has_data = merge_names(configured, configured_has_data, cached, cached_has_data)
  local result = classify_known_name(token, target, names, has_data, opts and opts.accept_unknown_mentions)
  result.kind = "mention"
  result.mention = "mcp_server"
  result.value = target
  return result
end

local function classify_group(token, target, opts)
  local cfg = thread_config(opts)
  local configured, configured_has_data = configured_names((opts and opts.tool_groups) or cfg.tool_groups, "@group:")
  local result = classify_known_name(token, target, configured, configured_has_data, opts and opts.accept_unknown_mentions)
  result.kind = "mention"
  result.mention = "tool_group"
  result.value = target
  return result
end

local function classify_tool(token, target, opts)
  local cfg = thread_config(opts)
  local configured, configured_has_data = configured_names((opts and opts.tools) or cfg.tools, "@")
  local cached, cached_has_data = cached_catalog_names("tools", "@")
  local names, has_data = merge_names(configured, configured_has_data, cached, cached_has_data)
  for name, known in pairs(static_tools) do
    if known then
      names[name] = true
    end
  end
  local result = classify_known_name(token, target, names, has_data, opts and opts.accept_unknown_mentions)
  result.kind = "mention"
  result.mention = "tool"
  result.value = target
  return result
end

local function classify_at(token, opts)
  if vim.startswith(token, "@mcp:") then
    local mcp = trim(token:match("^@mcp:%s*(.*)$"))
    if mcp == "" or mcp == "<server>" then
      return invalid(token, "missing MCP server id")
    end
    return classify_mcp(token, mcp, opts)
  end

  if vim.startswith(token, "@group:") then
    local group = trim(token:match("^@group:%s*(.*)$"))
    if group == "" or group == "<group>" then
      return invalid(token, "missing tool group id")
    end
    return classify_group(token, group, opts)
  end

  local tool = token:match("^@([^%s]+)$")
  tool = tool and trim(tool)
  if tool and tool ~= "" then
    return classify_tool(token, tool, opts)
  end

  return invalid(token, "missing tool name")
end

function M.classify(token, opts)
  token = trim(token)
  if token == "" then
    return invalid(token, "empty token")
  end
  local prefix = token:sub(1, 1)
  if prefix == "/" then
    return classify_slash(token)
  elseif prefix == "$" then
    return classify_dollar(token)
  elseif prefix == "@" then
    return classify_at(token, opts or {})
  end
  return invalid(token, "unsupported token prefix")
end

function M.apply_to_spec(spec, classified)
  if not spec or not classified or not classified.valid then
    return false
  end

  if classified.kind == "slash_command" then
    spec.command = classified.command
    return true
  elseif classified.kind == "skill" then
    if type(spec.skills) ~= "table" then
      spec.skills = {}
    end
    table.insert(spec.skills, classified.value)
    return true
  elseif classified.kind == "mention" and classified.mention == "tool" then
    if type(spec.tools) ~= "table" then
      spec.tools = {}
    end
    table.insert(spec.tools, classified.value)
    return true
  elseif classified.kind == "mention" and classified.mention == "mcp_server" then
    if type(spec.mcp_servers) ~= "table" then
      spec.mcp_servers = {}
    end
    table.insert(spec.mcp_servers, classified.value)
    return true
  elseif classified.kind == "mention" and classified.mention == "tool_group" then
    spec.tool_groups = spec.tool_groups or {}
    table.insert(spec.tool_groups, classified.value)
    return true
  elseif classified.kind == "selector" and classified.selector == "model" then
    spec.model = classified.value
    spec.model_override = true
    return true
  elseif classified.kind == "selector" and classified.selector == "reasoning" then
    spec.reasoning_effort = classified.value
    spec.reasoning_override = true
    return true
  elseif classified.kind == "selector" and classified.selector == "temperature" then
    spec.temperature = classified.value
    return true
  elseif classified.kind == "selector" and classified.selector == "no_tools" then
    spec.no_tools = true
    return true
  end

  return false
end

function M.parse_into_spec(token, spec, opts)
  local classified = M.classify(token, opts)
  if not classified.valid then
    return false, classified
  end
  return M.apply_to_spec(spec, classified), classified
end

function M.extract_selectors(text)
  local out = {}
  for _, line in ipairs(util.split_lines(text or "")) do
    local classified = M.classify(util.trim(line))
    if classified.valid and classified.kind == "selector" then
      if classified.selector == "model" then
        out.model = out.model or classified.value
      elseif classified.selector == "reasoning" then
        out.reasoning_effort = out.reasoning_effort or classified.value
      end
    end
  end
  return out
end

function M.static_for_trigger(trigger)
  if trigger == "/" then
    return vim.deepcopy(static.slash)
  elseif trigger == "@" then
    return vim.deepcopy(static.at)
  elseif trigger == "$" then
    return vim.deepcopy(static.dollar)
  elseif trigger == ">" then
    return vim.deepcopy(static.gt)
  end
  return {}
end

function M.static()
  return static
end

return M
