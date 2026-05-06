local config = require("alma.config")
local util = require("alma.util")

local M = {}

local function timeout_seconds()
  return tostring(math.max(1, math.ceil((config.get().request_timeout_ms or 5000) / 1000)))
end

local function request(method, path, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local url = path:match("^https?://") and path or (config.api_url() .. path)
  local args = {
    "curl",
    "-fsS",
    "-m",
    timeout_seconds(),
    "-X",
    method,
    "-H",
    "Accept: application/json",
  }

  if opts.body ~= nil then
    local encoded = util.json_encode(opts.body)
    table.insert(args, "-H")
    table.insert(args, "Content-Type: application/json")
    table.insert(args, "--data-binary")
    table.insert(args, encoded or "")
  end

  table.insert(args, url)

  vim.system(args, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, result.stderr ~= "" and result.stderr or ("curl exited " .. result.code))
        return
      end
      local decoded, err = util.json_decode(result.stdout)
      if not decoded then
        callback(nil, err)
        return
      end
      callback(decoded, nil)
    end)
  end)
end

function M.get(path, callback)
  return request("GET", path, nil, callback)
end

function M.health(callback)
  M.get("/api/health", callback)
end

function M.threads(callback)
  M.get("/api/threads", callback)
end

function M.thread(thread_id, callback)
  M.get("/api/threads/" .. vim.uri_encode(thread_id), callback)
end

function M.messages(thread_id, callback)
  M.get("/api/threads/" .. vim.uri_encode(thread_id) .. "/messages", callback)
end

local catalog_paths = {
  models = { "/api/models", "/api/ai/models", "/api/config/models" },
  skills = { "/api/skills" },
  tools = { "/api/tools", "/api/tool-definitions" },
  mcp_servers = { "/api/mcp/servers", "/api/mcp-servers", "/api/mcpServers" },
}

local function try_paths(paths, index, callback)
  local path = paths[index]
  if not path then
    callback(nil, "no catalog endpoint responded")
    return
  end
  M.get(path, function(data)
    if data then
      callback(data, nil, path)
      return
    end
    try_paths(paths, index + 1, callback)
  end)
end

function M.catalog(kind, callback)
  local paths = catalog_paths[kind]
  if not paths then
    callback(nil, "unknown catalog kind: " .. tostring(kind))
    return
  end
  try_paths(paths, 1, callback)
end

return M
