local config = require("alma.config")
local rest = require("alma.rest")
local state = require("alma.state")
local tokens = require("alma.ui.tokens")

local M = {}
local inflight = {}

local kind_to_prefix = {
  models = "$model:",
  skills = "/skill:",
  tools = "@",
  mcp_servers = "@mcp:",
}

local function normalize_entity(item, prefix)
  if type(item) == "string" then
    return { label = prefix .. item, detail = "Alma dynamic item" }
  end
  if type(item) ~= "table" then
    return nil
  end
  local id = item.id or item.key or item.name or item.model or item.slug
  if not id then
    return nil
  end
  return {
    label = prefix .. tostring(id),
    detail = item.title or item.name or item.description or "Alma dynamic item",
    documentation = item.description or item.prompt or nil,
    data = item,
  }
end

local function unwrap_list(data)
  if vim.islist(data) then
    return data
  end
  for _, key in ipairs({ "items", "data", "models", "skills", "tools", "servers", "mcpServers" }) do
    if vim.islist(data[key]) then
      return data[key]
    end
  end
  return {}
end

function M.static_for_trigger(trigger)
  return tokens.static_for_trigger(trigger)
end

function M.kind_for_trigger(trigger)
  if trigger == "$" then
    return "models"
  elseif trigger == "/" then
    return "skills"
  elseif trigger == "@" then
    return "tools"
  end
  return nil
end

function M.dynamic(kind)
  if not kind then
    return {}
  end
  return state.get_cache("catalog:" .. kind, config.get().completion_ttl_ms) or {}
end

function M.refresh(kind, callback)
  callback = callback or function() end
  if inflight[kind] then
    callback(M.dynamic(kind))
    return
  end
  inflight[kind] = true
  rest.catalog(kind, function(data)
    inflight[kind] = nil
    if not data then
      callback({})
      return
    end
    local prefix = kind_to_prefix[kind] or ""
    local items = {}
    for _, entity in ipairs(unwrap_list(data)) do
      local item = normalize_entity(entity, prefix)
      if item then
        table.insert(items, item)
      end
    end
    state.set_cache("catalog:" .. kind, items)
    callback(items)
  end)
end

function M.ensure_refresh(kind)
  if not kind then
    return
  end
  if state.get_cache("catalog:" .. kind, config.get().completion_ttl_ms) then
    return
  end
  M.refresh(kind)
end

function M.static()
  return tokens.static()
end

return M
