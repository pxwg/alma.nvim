local catalog = require("alma.catalog")
local events = require("alma.events")
local rest = require("alma.rest")
local state = require("alma.state")
local util = require("alma.util")
local workspace = require("alma.workspace")

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

local function date_label(value)
  if type(value) ~= "string" then
    return ""
  end
  return value:gsub("T", " "):gsub("%.%d+Z$", "Z")
end

local function block_preview_text(block)
  local text = events.block_text(block)
  if text == "" then
    return ""
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 8 then
    lines = vim.list_slice(lines, 1, 8)
    table.insert(lines, "…")
  end
  return table.concat(lines, "\n")
end

local function render_thread_preview_lines(thread, messages)
  local lines = {
    "# " .. tostring(thread.title or thread.id),
    "",
    "thread: " .. tostring(thread.id),
    "workspace: " .. tostring(workspace.thread_workspace_id(thread) or "unknown"),
    "updated: " .. date_label(thread.updatedAt or thread.updated_at or thread.createdAt or thread.created_at),
    "",
  }
  local blocks = events.normalize_messages(messages or {})
  local start = math.max(1, #blocks - 7)
  for index = start, #blocks do
    local block = blocks[index]
    if block.type == "UserBlock" then
      table.insert(lines, "## You")
      table.insert(lines, block_preview_text(block))
      table.insert(lines, "")
    elseif block.type == "AssistantBlock" then
      table.insert(lines, "## Alma")
      table.insert(lines, block_preview_text(block))
      table.insert(lines, "")
    elseif block.type == "ReasoningBlock" then
      table.insert(lines, "### Reasoning")
      table.insert(lines, block_preview_text(block))
      table.insert(lines, "")
    elseif block.type == "ToolCallBlock" then
      table.insert(lines, "### Tool: " .. tostring(block.tool or "unknown"))
      table.insert(lines, block_preview_text(block))
      table.insert(lines, "")
    end
  end
  if #blocks == 0 then
    table.insert(lines, "No messages yet.")
  end
  return lines
end

local function set_preview_lines(ctx, lines, ft)
  ctx.preview:reset()
  ctx.preview:set_lines(lines)
  ctx.preview:highlight({ ft = ft or "markdown" })
end

local function preview_thread(ctx)
  local thread = ctx.item and ctx.item.data
  if not thread then
    set_preview_lines(ctx, { "No thread selected." })
    return
  end
  set_preview_lines(ctx, { "# " .. tostring(thread.title or thread.id), "", "Loading thread preview…" })
  rest.messages(thread.id, function(messages, err)
    if ctx.preview.item ~= ctx.item then
      return
    end
    if not messages then
      set_preview_lines(ctx, {
        "# " .. tostring(thread.title or thread.id),
        "",
        "Unable to load messages: " .. tostring(err),
      })
      return
    end
    set_preview_lines(ctx, render_thread_preview_lines(thread, messages))
  end)
end

local function list_workspace_files(path, limit)
  local lines = {}
  if type(path) ~= "string" or path == "" then
    return lines
  end
  local ok, iterator = pcall(vim.fs.dir, path)
  if not ok or not iterator then
    return lines
  end
  for name, typ in iterator do
    if name ~= ".git" then
      table.insert(lines, (typ == "directory" and "📁 " or "  ") .. name)
    end
    if #lines >= (limit or 24) then
      table.insert(lines, "…")
      break
    end
  end
  table.sort(lines)
  return lines
end

local function preview_workspace(ctx)
  local item = ctx.item and ctx.item.data or {}
  local threads = item.threads or {}
  local lines = {
    "# " .. tostring(item.name or item.id or "Workspace"),
    "",
    "path: " .. tostring(item.path or ""),
    "id: " .. tostring(item.id or ""),
    "threads: " .. tostring(#threads),
    "",
    "## Recent Threads",
  }
  for index, thread in ipairs(threads) do
    if index > 10 then
      table.insert(lines, "…")
      break
    end
    table.insert(lines, "- " .. tostring(thread.title or thread.id) .. "  " .. tostring(thread.id or ""))
  end
  if #threads == 0 then
    table.insert(lines, "No threads in this workspace.")
  end
  table.insert(lines, "")
  table.insert(lines, "## Files")
  vim.list_extend(lines, list_workspace_files(item.path, 24))
  set_preview_lines(ctx, lines)
end

local function pick_threads(scope, current_workspace)
  rest.threads(function(data, err)
    if not data then
      util.notify("Unable to fetch Alma threads: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local items = {}
    for _, thread in ipairs(data) do
      if scope ~= "workspace" or workspace.matches_thread(current_workspace, thread) then
        local title = thread.title or thread.id
        table.insert(items, text_item(title, thread.id, thread))
      end
    end
    local picker = snacks()
    if not picker then
      return
    end
    picker.pick({
      title = scope == "workspace" and ("AlmaThreads: " .. workspace.display(current_workspace)) or "AlmaThreadsGlobal",
      items = items,
      preview = preview_thread,
      confirm = function(p, item)
        p:close()
        if item then
          require("alma").open_thread(item.data.id, {
            workspace_id = workspace.thread_workspace_id(item.data),
            cwd = workspace.thread_path(item.data) or current_workspace and current_workspace.path,
            workspace = current_workspace,
          })
        end
      end,
    })
  end)
end

function M.threads(opts)
  opts = opts or {}
  local scope = opts.scope or "workspace"
  if scope ~= "workspace" then
    pick_threads(scope, nil)
    return
  end
  workspace.current_existing(opts.bufnr or vim.api.nvim_get_current_buf(), function(current_workspace)
    pick_threads(scope, current_workspace)
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
  rest.workspaces(function(workspaces)
    rest.threads(function(threads)
      local by_workspace = {}
      for _, thread in ipairs(threads or {}) do
        local key = workspace.thread_workspace_id(thread) or workspace.thread_path(thread)
        if key then
          by_workspace[key] = by_workspace[key] or {}
          table.insert(by_workspace[key], thread)
        end
      end
      local items = {}
      for _, item in ipairs(workspaces or {}) do
        item.threads = by_workspace[item.id] or by_workspace[item.path] or {}
        table.insert(items, text_item(item.name or item.path or item.id, tostring(item.threadCount or #item.threads), item))
      end
      local picker = snacks()
      if not picker then
        return
      end
      picker.pick({
        title = "AlmaProjects",
        items = items,
        preview = preview_workspace,
        confirm = function(p, item)
          p:close()
          if item then
            util.notify("Selected Alma project " .. item.label)
          end
        end,
      })
    end)
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
