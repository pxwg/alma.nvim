local catalog = require("alma.catalog")
local rest = require("alma.rest")
local state = require("alma.state")
local util = require("alma.util")

local M = {}

local function snacks()
  local ok, picker = pcall(require, "snacks.picker")
  if ok then
    return picker
  end
  util.notify("snacks.picker is not available", vim.log.levels.ERROR)
  return nil
end

local function text_item(label, detail, data)
  return {
    text = detail and (label .. "  " .. detail) or label,
    label = label,
    detail = detail,
    data = data,
  }
end

function M.threads()
  rest.threads(function(data, err)
    if not data then
      util.notify("Unable to fetch Alma threads: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local items = {}
    for _, thread in ipairs(data) do
      local title = thread.title or thread.id
      table.insert(items, text_item(title, thread.id, thread))
    end
    local picker = snacks()
    if not picker then
      return
    end
    picker.pick({
      title = "AlmaThreads",
      items = items,
      confirm = function(p, item)
        p:close()
        if item then
          require("alma").open_thread(item.data.id)
        end
      end,
    })
  end)
end

function M.buffers()
  local items = {}
  for _, thread in ipairs(state.open_threads()) do
    table.insert(items, {
      text = tostring(thread.title or thread.id) .. "  " .. tostring(thread.id),
      thread = thread,
    })
  end
  local picker = snacks()
  if not picker then
    return
  end
  picker.pick({
    title = "AlmaBuffers",
    items = items,
    confirm = function(p, item)
      p:close()
      if item and item.thread.bufnr then
        util.open_or_focus_buf(item.thread.bufnr)
      end
    end,
  })
end

function M.projects()
  rest.threads(function(data)
    local seen = {}
    local items = {}
    for _, thread in ipairs(data or {}) do
      local key = thread.workspaceId or thread.workspace_id or thread.cwd or thread.projectPath
      if key and not seen[key] then
        seen[key] = true
        table.insert(items, text_item(tostring(key), thread.title, thread))
      end
    end
    for _, thread in ipairs(state.open_threads()) do
      local key = thread.workspace_id or thread.cwd
      if key and not seen[key] then
        seen[key] = true
        table.insert(items, text_item(tostring(key), thread.title, thread))
      end
    end
    local picker = snacks()
    if not picker then
      return
    end
    picker.pick({
      title = "AlmaProjects",
      items = items,
      confirm = function(p, item)
        p:close()
        if item then
          util.notify("Selected Alma project " .. item.label)
        end
      end,
    })
  end)
end

local function current_thread()
  local thread = state.thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not an Alma thread buffer", vim.log.levels.ERROR)
  end
  return thread
end

function M.models()
  local thread = current_thread()
  if not thread then
    return
  end
  catalog.ensure_refresh("models")
  local items = vim.deepcopy(catalog.static().dollar)
  vim.list_extend(items, catalog.dynamic("models"))
  local picker = snacks()
  if not picker then
    return
  end
  picker.pick({
    title = "AlmaModels",
    items = vim.tbl_map(function(item)
      return text_item(item.label, item.detail, item)
    end, items),
    confirm = function(p, item)
      p:close()
      if not item then
        return
      end
      local label = item.data.label
      local model = label:match("^%$model:(.+)$")
      local reasoning = label:match("^%$reasoning:(.+)$")
      if model and model ~= "<id>" then
        thread.config.model = model
      elseif reasoning then
        thread.config.reasoning_effort = reasoning
      end
      require("alma.ui.render").render(thread)
    end,
  })
end

local function toggle(list, value)
  if type(list) ~= "table" then
    list = {}
  end
  for index, item in ipairs(list) do
    if item == value then
      table.remove(list, index)
      return list, false
    end
  end
  table.insert(list, value)
  return list, true
end

local function pick_toggle(kind, title, target_field)
  local thread = current_thread()
  if not thread then
    return
  end
  catalog.ensure_refresh(kind)
  local items = {}
  if kind == "tools" then
    items = vim.deepcopy(catalog.static().at)
  elseif kind == "skills" then
    items = { { label = "/skill:<id>", detail = "Enable a skill" } }
  elseif kind == "mcp_servers" then
    items = { { label = "@mcp:<server>", detail = "Enable an MCP server" } }
  end
  vim.list_extend(items, catalog.dynamic(kind))
  local picker = snacks()
  if not picker then
    return
  end
  picker.pick({
    title = title,
    items = vim.tbl_map(function(item)
      return text_item(item.label, item.detail, item)
    end, items),
    confirm = function(p, item)
      p:close()
      if not item then
        return
      end
      local label = item.data.label
      local value = label:gsub("^@", ""):gsub("^/skill:", ""):gsub("^mcp:", "")
      if value == "<server>" or value == "<id>" then
        return
      end
      local next_list, enabled = toggle(thread.config[target_field], value)
      thread.config[target_field] = next_list
      util.notify((enabled and "Enabled " or "Disabled ") .. label .. " for Alma thread defaults")
      require("alma.ui.render").render(thread)
    end,
  })
end

function M.tools()
  pick_toggle("tools", "AlmaTools", "tools")
end

function M.skills()
  pick_toggle("skills", "AlmaSkills", "skills")
end

function M.mcp_servers()
  pick_toggle("mcp_servers", "AlmaMCPServers", "mcp_servers")
end

function M.events()
  local thread = current_thread()
  if not thread then
    return
  end
  local items = {}
  for _, entry in ipairs(thread.event_log or {}) do
    table.insert(items, {
      text = entry.at .. "  " .. tostring(entry.event.name or entry.event.type or "event"),
      entry = entry,
    })
  end
  local picker = snacks()
  if not picker then
    return
  end
  picker.pick({
    title = "AlmaEvents",
    items = items,
    confirm = function(p, item)
      p:close()
      if item then
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].bufhidden = "wipe"
        vim.bo[bufnr].filetype = "lua"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, util.to_lines(item.entry))
        vim.api.nvim_set_current_buf(bufnr)
      end
    end,
  })
end

return M
