local events = require("alma.events")
local state = require("alma.state")
local util = require("alma.util")

local M = {}

local function block_under_cursor()
  local thread = state.thread_for_buf(0)
  if not thread then
    return nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  for line = lnum, 1, -1 do
    if thread.render_index[line] then
      return thread.render_index[line], thread
    end
  end
  return nil, thread
end

local function scratch(name, filetype, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local function block_detail_lines(block)
  if not block then
    return { "No Alma block under cursor." }
  end
  if block.type == "ToolCallBlock" then
    local lines = {
      "tool: " .. tostring(block.tool or "unknown"),
      "state: " .. tostring(block.state or "unknown"),
      "",
      "input:",
    }
    util.list_extend(lines, util.to_lines(block.input))
    table.insert(lines, "")
    table.insert(lines, "output:")
    util.list_extend(lines, util.to_lines(block.output or block.text))
    return lines
  end
  return util.to_lines(events.block_text(block))
end

function M.open_under_cursor()
  local block = block_under_cursor()
  scratch("alma://detail", "text", block_detail_lines(block))
end

local function extract_locations(text)
  local items = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local file, lnum, col = line:match("([^:%s]+):(%d+):(%d+)")
    if not file then
      file, lnum = line:match("([^:%s]+):(%d+)")
    end
    if file and lnum then
      table.insert(items, {
        filename = vim.fn.fnamemodify(file, ":p"),
        lnum = tonumber(lnum),
        col = tonumber(col) or 1,
        text = line,
      })
    end
  end
  return items
end

function M.quickfix_under_cursor()
  local block, thread = block_under_cursor()
  if not block then
    util.notify("No Alma block under cursor", vim.log.levels.WARN)
    return
  end
  local items = extract_locations(events.block_text(block))
  if #items == 0 then
    util.notify("No file locations found in Alma block", vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, " ", {
    title = "Alma " .. util.short_id(thread.id),
    items = items,
  })
  vim.cmd.copen()
end

function M.quickfix_thread()
  local thread = state.thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not an Alma thread buffer", vim.log.levels.ERROR)
    return
  end
  local items = {}
  for _, block in ipairs(thread.blocks or {}) do
    util.list_extend(items, extract_locations(events.block_text(block)))
  end
  if #items == 0 then
    util.notify("No file locations found in Alma thread", vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, " ", {
    title = "Alma " .. util.short_id(thread.id),
    items = items,
  })
  vim.cmd.copen()
end

local function looks_like_diff(text)
  text = tostring(text or "")
  return text:find("\ndiff %-%-git ") or text:find("^diff %-%-git ") or text:find("\n%-%-%- ") or text:find("^%-%-%- ")
end

function M.diff_under_cursor()
  local block = block_under_cursor()
  if not block then
    util.notify("No Alma block under cursor", vim.log.levels.WARN)
    return
  end
  local text = events.block_text(block)
  if not looks_like_diff(text) then
    util.notify("No patch-like output found in Alma block", vim.log.levels.WARN)
    return
  end
  local bufnr = scratch("alma://diff", "diff", util.split_lines(text))
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd.diffthis()
  end)
end

return M
