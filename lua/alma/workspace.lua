local config = require("alma.config")
local rest = require("alma.rest")
local util = require("alma.util")

local M = {}

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
end

local function same_path(a, b)
  local left = normalize_path(a)
  local right = normalize_path(b)
  return left ~= nil and right ~= nil and left == right
end

function M.current(bufnr)
  return config.resolve_workspace(bufnr or vim.api.nvim_get_current_buf())
end

local function merge_workspace(base, data)
  data = data or {}
  return {
    id = data.id or base.id,
    name = data.name or base.name,
    path = normalize_path(data.path or base.path),
  }
end

function M.current_existing(bufnr, callback)
  local current = M.current(bufnr)
  rest.workspaces(function(items, err)
    if not items then
      callback(current, err)
      return
    end
    for _, item in ipairs(items or {}) do
      if same_path(item.path, current.path) then
        callback(merge_workspace(current, item), nil)
        return
      end
    end
    callback(current, nil)
  end)
end

function M.ensure(bufnr, callback)
  local workspace = M.current(bufnr)
  if workspace.id then
    callback(workspace, nil)
    return
  end
  rest.ensure_workspace(workspace, function(data, err)
    if not data then
      callback(nil, err)
      return
    end
    callback(merge_workspace(workspace, data), nil)
  end)
end

function M.thread_workspace_id(thread)
  return thread and (thread.workspaceId or thread.workspace_id or thread.workspaceID)
end

function M.thread_path(thread)
  return thread and (thread.cwd or thread.projectPath or thread.workspacePath or thread.path)
end

function M.matches_thread(workspace, thread)
  if not workspace or not thread then
    return false
  end
  local workspace_id = workspace.id
  local thread_workspace_id = M.thread_workspace_id(thread)
  if workspace_id and thread_workspace_id and tostring(workspace_id) == tostring(thread_workspace_id) then
    return true
  end
  return same_path(workspace.path, M.thread_path(thread))
end

function M.display(workspace)
  if not workspace then
    return "unknown workspace"
  end
  local name = workspace.name or (workspace.path and vim.fn.fnamemodify(workspace.path, ":t")) or workspace.id or "workspace"
  if workspace.path and workspace.path ~= "" then
    return tostring(name) .. "  " .. tostring(workspace.path)
  end
  return tostring(name)
end

function M.notify_error(action, err)
  util.notify("Alma workspace " .. action .. " failed: " .. tostring(err), vim.log.levels.ERROR)
end

return M
