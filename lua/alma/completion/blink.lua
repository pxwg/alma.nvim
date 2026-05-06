local catalog = require("alma.catalog")

local M = {}
local Source = {}
Source.__index = Source

function Source.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.bo[bufnr].filetype == "alma" or vim.b[bufnr].alma_thread_id ~= nil
end

function Source:get_trigger_characters()
  return { "/", "@", "$", ">", ":" }
end

local function prefix_at_cursor(ctx)
  local line = ctx.line or ""
  local cursor_col = ctx.cursor and ctx.cursor[2] or vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, cursor_col)
  return before:match("([/@$>][%w%-%._:%/%~]*)$")
end

local function kind()
  local ok, types = pcall(require, "blink.cmp.types")
  if not ok then
    return {}
  end
  return types.CompletionItemKind
end

local function to_item(item)
  local kinds = kind()
  return {
    label = item.label,
    insertText = item.label,
    kind = kinds.Keyword or 14,
    detail = item.detail,
    documentation = item.documentation,
    data = item.data,
  }
end

function Source:get_completions(ctx, callback)
  local prefix = prefix_at_cursor(ctx)
  if not prefix or prefix == "" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local trigger = prefix:sub(1, 1)
  local items = catalog.static_for_trigger(trigger)
  local dynamic_kind = catalog.kind_for_trigger(trigger)
  catalog.ensure_refresh(dynamic_kind)
  vim.list_extend(items, catalog.dynamic(dynamic_kind))

  local out = {}
  local lower = prefix:lower()
  for _, item in ipairs(items) do
    if item.label and vim.startswith(item.label:lower(), lower) then
      table.insert(out, to_item(item))
    end
  end

  callback({
    items = out,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

function M.new(opts)
  return Source.new(opts)
end

return M
